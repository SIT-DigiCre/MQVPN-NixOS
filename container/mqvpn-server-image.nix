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
  entrypoint = pkgs.writeScript "mqvpn-oci-entrypoint" (builtins.readFile ./mqvpn-oci-entrypoint.sh);

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
