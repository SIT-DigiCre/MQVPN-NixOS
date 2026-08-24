{
  pkgs,
}:
let
  # 公式 grafana イメージをピン (digest + sha256) してベースにし、
  # provisioning (datasource / dashboards provider / 生成済みダッシュボード) を
  # 1 レイヤ焼き込む。
  #
  # NOTE: この nixpkgs の buildLayeredImage + fromImage は base config のうち
  # Env しか継承しない (Entrypoint/User/ExposedPorts 等は落ちる) ため、
  # 必要フィールドは明示する。値はピンした 12.4.9 の Dockerfile/config 由来。
  grafanaBase = pkgs.dockerTools.pullImage {
    imageName = "grafana/grafana";
    imageDigest = "sha256:9b58461280b4d2992d4399823c9427d0fcf5f0fd7f376c93f2dea876158b867b";
    finalImageName = "grafana/grafana";
    finalImageTag = "12.4.9";
    outputHash = "sha256-lymzqkW6FW4sDvy6IIKsKytfm97uGObEFXXlWrPF8eA=";
    outputHashAlgo = "sha256";
  };

  mqvpnDashBase = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/mp0rta/mqvpn-prometheus-exporter/e4cafa9168c997832459055f7c6612dc1fb266ef/dashboards/mqvpn-grafana.json";
    sha256 = "sha256-3l1g7jmWiCBts8X3BxX0YhsMpDOpouhSaSKFthLkCpQ=";
  };

  # イメージ内の絶対パスに provisioning 一式を配置するレイヤ。
  # ダッシュボードはサーバー別版へ変換してから焼く (変換の内容は
  # mqvpn-dashboard-per-server.py を参照: ${DS_PROMETHEUS} 置換 / uid 変更 /
  # Server テンプレ変数追加 / 全 PROMQL への instance 注入)。
  # 書込み先 (/var/lib/grafana) は一切触らない:
  #  - /etc/grafana/provisioning/...  は grafana が読むだけ
  #  - /etc/grafana/dashboards/...    は provider の読取りパス
  #    (mon/dashboards.yml 側で同パスに変更済み)
  # 焼き込みレイヤの所有者は root のため、writable パス (/var/lib/grafana 等) を
  # 含めると base イメージの所有者 (grafana/472) を上書きして起動失敗する
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
        python3 ${./dashboards/mqvpn-dashboard-per-server.py} \
          ${mqvpnDashBase} $out/etc/grafana/dashboards/mqvpn-grafana.json \
          ${./docker-compose.yml}
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
