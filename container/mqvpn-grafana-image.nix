{
  pkgs,
}:
let
  # 公式grafanaをピン留めしprovisioning一式を1レイヤ焼き込む。
  # fromImage継承の注意はdocker-base.nix参照 (値は12.4.9のDockerfile/config由来)。
  grafanaBase = pkgs.callPackage ./docker-base.nix {
    imageName = "grafana/grafana";
    imageDigest = "sha256:9b58461280b4d2992d4399823c9427d0fcf5f0fd7f376c93f2dea876158b867b";
    finalImageName = "grafana/grafana";
    finalImageTag = "12.4.9";
    outputHash = "sha256-lymzqkW6FW4sDvy6IIKsKytfm97uGObEFXXlWrPF8eA=";
  };

  mqvpnDashBase = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/mp0rta/mqvpn-prometheus-exporter/e4cafa9168c997832459055f7c6612dc1fb266ef/dashboards/mqvpn-grafana.json";
    sha256 = "sha256-3l1g7jmWiCBts8X3BxX0YhsMpDOpouhSaSKFthLkCpQ=";
  };

  # provisioning一式の配置レイヤ。ダッシュボード変換の内容は
  # mqvpn-dashboard-per-server.py参照。writableパスを含めるとbaseの所有者
  # (grafana/472)を上書きして起動失敗するため、/var/lib/grafanaには触らない。
  provisioning =
    pkgs.runCommand "mqvpn-grafana-provisioning"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        mkdir -p $out/etc/grafana/provisioning/datasources \
                 $out/etc/grafana/provisioning/dashboards \
                 $out/etc/grafana/dashboards
        cp ${./mon/datasource.yml} $out/etc/grafana/provisioning/datasources/datasource.yml
        cp ${./mon/dashboards.yml} $out/etc/grafana/provisioning/dashboards/dashboards.yml
        # 初期選択サーバー名はSSOTから (py側はargvで受ける)。
        python3 ${./dashboards/mqvpn-dashboard-per-server.py} \
          ${mqvpnDashBase} $out/etc/grafana/dashboards/mqvpn-grafana.json ${builtins.concatStringsSep " " (import ./mqvpn-servers.nix).serverNames}
      '';

  image = pkgs.dockerTools.buildLayeredImage {
    name = "mqvpn-grafana";
    tag = "latest";
    fromImage = grafanaBase;
    contents = [ provisioning ];
    config = {
      User = "472"; # grafana (公式イメージと同一)
      Entrypoint = [ "/run.sh" ];
      WorkingDir = "/usr/share/grafana";
      ExposedPorts = {
        "3000/tcp" = { };
      };
    };
  };
in
{
  inherit provisioning image;
}
