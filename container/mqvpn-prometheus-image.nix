{
  pkgs,
}:
let
  # 公式 prometheus イメージをピン (digest + sha256) してベースにし、
  # prometheus.yml (scrape targets は compose の mqvpn-server-* から自動生成) を
  # 1 レイヤ焼き込む。
  #
  # ネットワークモデル: prometheus は network_mode: host (compose 側) で動かし、
  # サーバー同様にホスト netns を共有する。exporter はホストの
  # 127.0.0.1:9091+idx*2 で待つため、スクレイプは常に loopback で完結する
  # (ブリッジを経由しない → UFW 等の INPUT 制限・サブネット変動の影響を受けない)。
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

  # prometheus.yml を生成して /etc/prometheus/ に配置するレイヤ。
  # mqvpn job の targets は compose の mqvpn-server-* サービス + その
  # MQVPN_INSTANCE_IDX から自動生成する: 127.0.0.1:(9091+idx*2)。
  # instance ラベルはサービス名に固定する (Grafana の Server 変数 =
  # label_values(mqvpn_build_info, instance) と焼き込み済み初期選択が一致する)。
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
            '      - targets:\n          - "127.0.0.1:{p}"\n'
            '        labels:\n          instance: {n}\n          stack: mqvpn'.format(
                p=9091 + idx * 2, n=n)
            for n, idx in services
        )
        # テンプレートの見本ブロック全体 (- targets: 〜) を生成分へ置き換える。
        # 先頭の - targets: を残して後続を差し込むと二重化するため、見本を
        # 丸ごと破棄して生成分を static_configs: 直下に置く
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
    contents = [ prometheusConf ];
    config = {
      User = "nobody"; # 公式イメージと同一 (tsdb パスは 3.14.0 では nobody 所有)
      Entrypoint = [ "/bin/prometheus" ];
      Cmd = [
        "--config.file=/etc/prometheus/prometheus.yml"
        # loopback 限定で公開しない。ポートは control API (9090+idx*2) /
        # exporter (9091+idx*2) の家族 (9090..9217) と重ならない 9000 を固定
        # (9100 だと idx=5 の control API と衝突する)
        "--web.listen-address=127.0.0.1:9000"
        "--storage.tsdb.path=/prometheus"
      ];
      WorkingDir = "/prometheus";
      ExposedPorts = {
        "9000/tcp" = { };
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
