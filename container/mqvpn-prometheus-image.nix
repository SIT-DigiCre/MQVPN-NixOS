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
  prometheusBase = pkgs.callPackage ./docker-base.nix {
    imageName = "prom/prometheus";
    imageDigest = "sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0";
    finalImageName = "prom/prometheus";
    finalImageTag = "v3.14.0";
    outputHash = "sha256-8LJjocjSt/HMsXcSwbrLw8f6wH5yOqDzZ7SvVOkKqaw=";
  };

  # prometheus.yml を生成して /etc/prometheus/ に配置するレイヤ。
  # targets はサーバー集合の SSOT (./mqvpn-servers.nix) から作る。
  # instance ラベルはサービス名に固定する (Grafana の Server 変数 =
  # label_values(mqvpn_build_info, instance) と焼き込み済み初期選択が一致する)。
  prometheusConf =
    let
      servers = import ./mqvpn-servers.nix;
      # "name port" 行 (exporter 待受 = 9091+idx*2 は entrypoint 側の導出と同一)。
      serverTargets = builtins.concatStringsSep "\n" (
        map (i: "mqvpn-server-${toString i} ${toString (9091 + i * 2)}") servers.serverIdxs
      );
    in
    assert servers.serverIdxs != [];
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
