{
  pkgs,
}:
let
  mqvpnExporter = pkgs.callPackage ../pkgs/mqvpn-exporter.nix { };
  mqvpnDbg = pkgs.callPackage ../pkgs/mqvpn-dbg.nix { };

  # nat+sysctlラッパ。コンテナからnet.*書込は常にEPERMのため、
  # sysctlスタブがnet.*への-wのみ成功扱いにする。
  natScript = pkgs.stdenv.mkDerivation {
    pname = "mqvpn-server-nat";
    inherit (mqvpnDbg) version src;
    # nat scriptはsrcから直接コピーされるため個別にパッチする。
    patches = [
      ../patches/mqvpn-server-nat-retry-iface.patch
      ../patches/mqvpn-server-nat-teardown-per-subnet.patch
    ];
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

  # 1サーバ=1コンテナ。config共有・差分はenvが行う (導出式はSSOT参照。JSON専用)。
  entrypointLayer = pkgs.writeTextDir "mqvpn-oci-entrypoint" (
    builtins.readFile ./mqvpn-oci-entrypoint.sh
  );

  # natScriptとprocpsが共に/bin/sysctlを提供するため衝突するが、
  # 先に列挙したスタブを優先させる (ignoreCollisions)。
  rootEnv = pkgs.buildEnv {
    name = "mqvpn-server-root";
    paths = [
      natScript
      mqvpnDbg
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
      pkgs.iperf3 # 運用測定用 (docker execで-sを立てる)
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
      # shebang直execはruncでENOEXECになるためインタプリタ明示。
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
        # ナノ秒指定。秒で書くと5nsになり常にunhealthy。
        Interval = 30000000000;
        Timeout = 10000000000;
        StartPeriod = 15000000000;
        Retries = 3;
      };
    };
  };
in
{
  inherit image;
}
