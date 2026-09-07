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
  # mqvpn job の targets は compose の mqvpn-server-* サービス +
  # MQVPN_INSTANCE_IDX から作る: 127.0.0.1:(9091+idx*2)。
  # YAML 読みは yq に任せ、手書き正規表現は持たない
  # instance ラベルはサービス名に固定する (Grafana の Server 変数 =
  # label_values(mqvpn_build_info, instance) と焼き込み済み初期選択が一致する)。
  prometheusConf =
    pkgs.runCommand "mqvpn-prometheus-etc"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
      }
      ''
        mkdir -p $out/etc/prometheus
        mapfile -t svcs < <(yq --yaml-fix-merge-anchor-to-spec -r '.services | to_entries[] | select(.key | test("^mqvpn-server-[0-9]+$")) | .key' ${./docker-compose.yml})
        [ "''${#svcs[@]}" -gt 0 ] || { echo "compose に mqvpn-server-* が見つからない" >&2; exit 1; }
        {
          cat <<'YAML'
        global:
          scrape_interval: 30s
          scrape_timeout: 30s

        scrape_configs:
          - job_name: mqvpn
            static_configs:
        YAML
          for n in "''${svcs[@]}"; do
            idx=$(n="$n" yq --yaml-fix-merge-anchor-to-spec -r '.services[env(n)].environment[] | select(test("^MQVPN_INSTANCE_IDX=")) | split("=")[1]' ${./docker-compose.yml})
            [ -n "$idx" ] || { echo "$n に MQVPN_INSTANCE_IDX がない (host-net では必須)" >&2; exit 1; }
            [[ "$idx" =~ ^[0-9]+$ ]] || { echo "$n の MQVPN_INSTANCE_IDX が数値でない: $idx" >&2; exit 1; }
            printf '      - targets:\n          - "127.0.0.1:%d"\n        labels:\n          instance: %s\n          stack: mqvpn\n\n' "$((9091 + idx * 2))" "$n"
          done
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
