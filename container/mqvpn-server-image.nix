{
  pkgs,
}:
let
  mqvpnExporter = pkgs.callPackage ../pkgs/mqvpn-exporter.nix { };
  mqvpnSrc = pkgs.callPackage ../pkgs/mqvpn-src.nix { };

  # 本家 nat スクリプト + sysctl ラッパ。コンテナから net.* sysctl 書込は
  # 常に EPERM (値は netns 作成時にホストから継承) ため、sysctl スタブが
  # net.* への -w のみ成功扱いとする (他は本来の sysctl へ渡す)
  natScript = pkgs.stdenv.mkDerivation {
    pname = "mqvpn-server-nat";
    inherit (mqvpnSrc) version src;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/bin
      cp scripts/mqvpn-server-nat.sh $out/bin/mqvpn-server-nat.sh
      chmod +x $out/bin/mqvpn-server-nat.sh
      cat > $out/bin/sysctl <<'EOF'
      #!/bin/sh
      if [ "$1" = "-w" ]; then
        key="''${2%%=*}"
        case "$key" in
          net.*) echo "sysctl: skip (read-only in container): $key" >&2; exit 0 ;;
        esac
      fi
      exec ${pkgs.procps}/bin/sysctl "$@"
      EOF
      chmod +x $out/bin/sysctl
    '';
  };

  # 1 サーバ = 1 コンテナ。config は 1 枚を全インスタンスで共有し、差別化
  # (仮想サブネット等) は MQVPN_SUBNET / MQVPN_TUN_NAME の env が行う (JSON 専用)
  entrypoint = pkgs.writeScript "mqvpn-oci-entrypoint" ''
    #!${pkgs.bash}/bin/bash
    # NOTE: イメージに /usr/bin/env は無いため shebang は store の bash を直接指す
    set -euo pipefail

    CONF="''${MQVPN_CONF:-/etc/mqvpn/server.conf}"
    if [ ! -f "$CONF" ]; then
      echo "mqvpn-oci: no $CONF (mount the config)" >&2
      exit 1
    fi

    # env 上書きは JSON config 専用 — INI と組み合わせると黙って crash loop に
    # 落ちるため、JSON でなければ明示エラーで停止する
    if [ -n "''${MQVPN_SUBNET:-}" ] || [ -n "''${MQVPN_TUN_NAME:-}" ]; then
      if ! jq -e . "$CONF" >/dev/null 2>&1; then
        echo "mqvpn-oci: MQVPN_SUBNET/MQVPN_TUN_NAME 上書きには JSON config が必要です (INI は非対応): $CONF" >&2
        echo "mqvpn-oci: config を JSON 形式に変換するか、上書き env を外してください" >&2
        exit 1
      fi
    fi
    if [ -n "''${MQVPN_SUBNET:-}" ] || [ -n "''${MQVPN_TUN_NAME:-}" ]; then
      mkdir -p /tmp
      jq --arg s "''${MQVPN_SUBNET:-}" --arg t "''${MQVPN_TUN_NAME:-}" \
        '(.subnet |= if $s == "" then . else $s end)
         | (.tun_name |= if $t == "" then . else $t end)' \
        "$CONF" > /tmp/server.conf
      CONF=/tmp/server.conf
    fi

    echo "mqvpn-oci: nat setup $CONF"
    mqvpn-server-nat.sh setup "$CONF"

    # 制御 API は daemon のシングルスレッド内で処理され高負荷時に秒単位で劣化
    # するため、exporter の timeout には余裕を持たせる。
    # ログは stdout に出る (docker logs で scrape 失敗を確認できる)
    mqvpn-prometheus-exporter -web.listen-address=0.0.0.0:9091 \
      -mqvpn.address=127.0.0.1:9090 -mqvpn.timeout=30s \
      -mqvpn.scrape-budget=25s &

    fails=0
    cleanup() {
      set +e
      pkill -f "mqvpn --config" 2>/dev/null
      mqvpn-server-nat.sh teardown "$CONF" 2>/dev/null
    }
    trap cleanup EXIT

    while :; do
      echo "mqvpn-oci: starting $CONF"
      mqvpn --config "$CONF" &
      pid=$!
      set +e
      wait "$pid"
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        fails=$((fails + 1))
      else
        fails=0
      fi
      if [ "$fails" -ge 10 ]; then
        echo "mqvpn-oci: $CONF failed 10 times in a row — exiting" >&2
        exit 1
      fi
      echo "mqvpn-oci: $CONF exited ($rc) — restarting in 5s" >&2
      sleep 5
    done
  '';

  # writeScript の出力は単一ファイル。dockerTools.buildLayeredImage は contents を
  # イメージルートへマージするため、このファイルを直接 contents に入れると
  # "Not a directory" で失敗する。そこでディレクトリでラップし、ルートの
  # /mqvpn-oci-entrypoint に実体を置く。
  entrypointLayer = pkgs.runCommand "mqvpn-oci-entrypoint-layer" { } ''
    mkdir -p $out
    cp ${entrypoint} $out/mqvpn-oci-entrypoint
    chmod +x $out/mqvpn-oci-entrypoint
  '';

  # buildEnv が各パッケージの bin/ を /bin に統合する。
  # natScript と procps が共に /bin/sysctl を提供するため衝突し、
  # 先に列挙した natScript のスタブが優先される (コンテナ内 net.* 書き込みを no-op 化)。
  rootEnv = pkgs.buildEnv {
    name = "mqvpn-server-root";
    paths = [
      natScript
      mqvpnSrc
      mqvpnExporter
      pkgs.bash
      pkgs.dockerTools.binSh
      pkgs.iproute2
      pkgs.iptables
      pkgs.procps
      pkgs.coreutils
      pkgs.gnused
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
    ];
    pathsToLink = [ "/bin" ];
    ignoreCollisions = true;
  };

  image = pkgs.dockerTools.buildLayeredImage {
    name = "mqvpn-server";
    tag = "latest";
    contents = [
      rootEnv
      entrypointLayer
    ];
    config = {
      Env = [ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ];
      # NOTE: スクリプトの shebang 直 exec が docker (runc) で ENOEXEC になる
      # ため、インタプリタを明示して起動する
      Cmd = [
        "/bin/bash"
        "${entrypointLayer}/mqvpn-oci-entrypoint"
      ];
      ExposedPorts = {
        "443/udp" = { };
      };
      Volumes = {
        "/etc/mqvpn" = { };
      };
      Healthcheck = {
        Test = [
          "CMD-SHELL"
          "pgrep -f 'mqvpn --config' >/dev/null && ls /sys/class/net | grep -q '^mqvpn'"
        ];
        # ナノ秒 (time.Duration)。秒で書くと 5ns になり常に unhealthy になる
        Interval = 30000000000;
        Timeout = 10000000000;
        StartPeriod = 15000000000;
        Retries = 3;
      };
    };
  };
in
{
  inherit
    entrypoint
    natScript
    rootEnv
    ;
  inherit image;
}
