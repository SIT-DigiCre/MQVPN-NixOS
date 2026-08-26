{
  pkgs,
}:
let
  # 公式 prometheus イメージをピン (digest + sha256) してベースにし、
  # prometheus.yml (scrape targets は compose の mqvpn-server-* から自動生成) を
  # 1 レイヤ焼き込む。
  #
  # NOTE: この nixpkgs の buildLayeredImage + fromImage は base config のうち
  # Env しか継承しない (Entrypoint/Cmd/User/Volumes 等は落ちる) ため、
  # 必要フィールドは明示する。値はピンした v3.14.0 の Dockerfile/config 由来。
  prometheusBase = pkgs.dockerTools.pullImage {
    imageName = "prom/prometheus";
    imageDigest = "sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0";
    finalImageName = "prom/prometheus";
    finalImageTag = "v3.14.0";
    outputHash = "sha256-8LJjocjSt/HMsXcSwbrLw8f6wH5yOqDzZ7SvVOkKqaw=";
    outputHashAlgo = "sha256";
  };

  # 起動 wrapper: コンテナのデフォルトゲートウェイ (= ホスト, host-net での
  # exporter の待受アドレス) を ip route から求め、prometheus.yml 内の
  # ${MQVPN_EXPORTER_HOST} を sed で差し替えてから prometheus を起動する。
  # IP を焼き込まないので docker bridge サブネットが変わっても追従する。
  entrypoint = pkgs.writeScript "mqvpn-prometheus-entrypoint" ''
    #!/bin/sh
    GW=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
    if [ -z "$GW" ]; then
      GW=172.17.0.1
    fi
    sed 's|''${MQVPN_EXPORTER_HOST}|'"$GW"'|g' \
      /etc/prometheus/prometheus.yml > /tmp/prometheus.yml
    exec /bin/prometheus "$@"
  '';

  # writeScript の出力は単一ファイル。buildLayeredImage は contents をルートへ
  # マージするため単一ファイルは "Not a directory" で失敗する。ディレクトリで
  # ラップする (サーバーイメージと同じ作法)
  entrypointLayer = pkgs.runCommand "mqvpn-prometheus-entrypoint-layer" { } ''
    mkdir -p $out
    cp ${entrypoint} $out/mqvpn-prometheus-entrypoint
    chmod +x $out/mqvpn-prometheus-entrypoint
  '';

  # prometheus.yml を生成して /etc/prometheus/ に配置するレイヤ。
  # mqvpn job の targets は compose の mqvpn-server-* サービス + その
  # MQVPN_INSTANCE_IDX から自動生成する (host-net では exporter ポートが
  # インスタンスごとに違う: 9091+idx*2。instance ラベルはサービス名に固定)。
  prometheusConf =
    pkgs.runCommand "mqvpn-prometheus-etc"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        mkdir -p $out/etc/prometheus
        python3 - "$out/etc/prometheus/prometheus.yml" << 'PY'
        import re, sys
        dst = sys.argv[1]
        compose = open("${./docker-compose.yml}").read()
        services = []
        for m in re.finditer(r"^  (mqvpn-server-[0-9]+):", compose, re.M):
            start = m.start()
            nxt = compose.find("\n  mqvpn-server-", start + 1)
            block = compose[start:nxt if nxt != -1 else None]
            i = re.search(r"MQVPN_INSTANCE_IDX=(\d+)", block)
            assert i, f"{m.group(1)} に MQVPN_INSTANCE_IDX がない (host-net では必須)"
            services.append((m.group(1), int(i.group(1))))
        # host-net 運用で idx 指定が必須のため、1 台も拾えないのは config の
        # 書き間違い。見本 targets が stale のまま焼き込まれる事故を防ぐため
        # ビルド失敗にする
        assert services, "compose に mqvpn-server-* (MQVPN_INSTANCE_IDX) が見つからない"
        tmpl = open("${./prometheus/prometheus.yml.template}").read()
        blocks = "\n".join(
            '      - targets:\n          - "''${{MQVPN_EXPORTER_HOST}}:{p}"\n'
            '        labels:\n          instance: {n}\n          stack: mqvpn'.format(
                p=9091 + idx * 2, n=n)
            for n, idx in services
        )
        # テンプレートの見本ブロック全体 (- targets: 〜) を生成分へ置き換える。
        # 先頭の - targets: を残して後続を差し込むと二重化するため、見本を
        # 丸ごと破棄して generate 分を static_configs: 直下に置く
        head, sep, tail = tmpl.partition("      - targets:")
        assert sep, "prometheus.yml.template に - targets: ブロックが見つからない"
        out_y = head + blocks + "\n"
        # 焼き込み済み instance ラベルと拾ったサーバー名が一致すること
        baked = re.findall(r'^\s+instance: ([^ ]+)$', out_y, re.M)
        assert baked == [n for n, _ in services], f"instance 不一致: baked={baked} expected={[n for n,_ in services]}"
        open(dst, "w").write(out_y)
        PY
      '';

  image = pkgs.dockerTools.buildLayeredImage {
    name = "mqvpn-prometheus";
    tag = "latest";
    fromImage = prometheusBase;
    contents = [
      prometheusConf
      entrypointLayer
      pkgs.iproute2 # wrapper が ip route でゲートウェイを取得するため
    ];
    config = {
      User = "nobody"; # 公式イメージと同一 (tsdb パスは 3.14.0 では nobody 所有)
      Entrypoint = [ "${entrypointLayer}/mqvpn-prometheus-entrypoint" ];
      Cmd = [
        "--config.file=/tmp/prometheus.yml"
        "--storage.tsdb.path=/prometheus"
      ];
      WorkingDir = "/prometheus";
      ExposedPorts = {
        "9090/tcp" = { };
      };
      Volumes = {
        "/prometheus" = { };
      };
    };
  };
in
{
  inherit prometheusConf image;
}
