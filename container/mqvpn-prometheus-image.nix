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

  # prometheus.yml を生成して /etc/prometheus/ に配置するレイヤ。
  # mqvpn job の targets は compose の mqvpn-server-* サービス名から自動生成する
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
        names = re.findall(r"^\s+(mqvpn-server-[0-9]+):", compose, re.M)
        # サーバーが 1 台も拾えないのは config の書き間違い。見本 targets が
        # stale のまま焼き込まれる事故を防ぐためビルド失敗にする
        assert names, "compose に mqvpn-server-* サービスが見つからない (docker-compose.yml を確認)"
        tmpl = open("${./prometheus/prometheus.yml.template}").read()
        targets = "".join(f'          - "{n}:9091"\n' for n in names)
        out_y, replaced = re.subn(r"(?<=- targets:)\n(?:          - .*\n)+", "\n" + targets, tmpl)
        assert replaced == 1, f"prometheus.yml の targets ブロック置換が {replaced} 回 (1 が期待)"
        # 焼き込み済み行と拾ったサーバー名が一致すること
        baked = re.findall(r'^\s+- "([^"]+):9091"$', out_y, re.M)
        assert baked == names, f"targets 不一致: baked={baked} expected={names}"
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
