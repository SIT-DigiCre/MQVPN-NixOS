{
  pkgs,
}:
let
  # 公式prometheusをピン留めしprometheus.ymlを1レイヤ焼き込む。
  # host共有+loopback完結のためブリッジを経由しない
  # (UFW等のINPUT制限・サブネット変動の影響を受けない。compose側も参照)。
  # fromImage継承の注意はdocker-base.nix参照。
  prometheusBase = pkgs.callPackage ./docker-base.nix {
    imageName = "prom/prometheus";
    imageDigest = "sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0";
    finalImageName = "prom/prometheus";
    finalImageTag = "v3.14.0";
    outputHash = "sha256-8LJjocjSt/HMsXcSwbrLw8f6wH5yOqDzZ7SvVOkKqaw=";
  };

  # prometheus.ymlを/etc/prometheus/に配置するレイヤ (targetsはSSOTから生成)。
  # instance=サービス名に固定 (GrafanaのServer変数の初期選択と一致させる)。
  prometheusConf =
    let
      servers = import ./mqvpn-servers.nix;
      # exporter待受 (9091+idx*2) の導出はSSOT (mqvpn-servers.nix) と同一。
      serverTargets = builtins.concatStringsSep "\n" (
        map (i: "mqvpn-server-${toString i} ${toString (9091 + i * 2)}") servers.serverIdxs
      );
    in
    assert servers.serverIdxs != [ ];
    pkgs.runCommand "mqvpn-prometheus-etc" { } ''
        mkdir -p $out/etc/prometheus
        {
          printf 'global:\n  scrape_interval: 30s\n  scrape_timeout: 30s\n\nscrape_configs:\n  - job_name: mqvpn\n    static_configs:\n'
          while read -r n p; do
            printf '      - targets:\n          - "127.0.0.1:%s"\n        labels:\n          instance: %s\n          stack: mqvpn\n\n' "$p" "$n"
          done <<EOF
      ${serverTargets}
      EOF
        } > $out/etc/prometheus/prometheus.yml
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
        # loopback限定・9000固定 (9100はidx=5のcontrol APIと衝突するため)。
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
