{
  lib,
  pkgs,
  ...
}:
let
  # eth0: ts-mgmt (管理 + 上流への出口) / eth1: ts-mq (router への 10.200.0.0/24)
  # eth2: ts-ext (mnet VM 192.168.100.1 へのベンチ用出口)
  vmLanInterface = "eth1";
  vmWanInterface = "eth0";

  firstIdx = builtins.head mqvpnServers.serverIdxs;
  firstPort = builtins.head mqvpnServers.serverPorts;
  mqvpnServerSubnet = "192.168.${toString firstIdx}.0/24";
  mqvpnAuthKey = "mqvpn-test-key-2024";
  localIp = "10.200.99.2";

  mqvpnImage = (import ../container/mqvpn-server-image.nix { inherit pkgs; }).image;
  mqvpnPromImage = (import ../container/mqvpn-prometheus-image.nix { inherit pkgs; }).image;
  mqvpnGrafanaImage = (import ../container/mqvpn-grafana-image.nix { inherit pkgs; }).image;

  mqvpnServers = import ../container/mqvpn-servers.nix;

  mqvpnCerts =
    pkgs.runCommand "mqvpn-certs"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        openssl ecparam -genkey -name prime256v1 -noout -out key.pem
        openssl req -new -x509 -key key.pem -out cert.pem -days 3650 \
          -subj "/CN=mqtt-server.local" -addext "subjectAltName=DNS:mqtt-server.local,IP:${localIp}"
        mkdir -p $out
        cp key.pem cert.pem $out/
      '';

  mqvpnServerBase = {
    mode = "server";
    listen = "0.0.0.0:${toString firstPort}";
    subnet = mqvpnServerSubnet;
    tun_name = "mqvpn${toString firstIdx}";
    cert_file = "/etc/mqvpn/server.crt";
    key_file = "/etc/mqvpn/server.key";
    auth_key = mqvpnAuthKey;
    control_listen = "127.0.0.1:${toString (9090 + firstIdx * 2)}";
    log_level = "info";
    reinjection = "deadline";
    reorder = {
      enabled = "on";
      max_wait_ms = 100;
      cap_packets = 4096;
    };
    hybrid = {
      enabled = false;
      tcp = "auto";
      tcp_max_flows = 2048;
    };
  };

  # 1config共有・差分はENV+ポートフォワードのみ (compose側で表現)。
  mqvpnConf = pkgs.writeText "mqvpn-server.conf" (builtins.toJSON mqvpnServerBase);

  # compose一式を1 storeディレクトリに固める (SSOT生成物を使用)。
  composeFile = pkgs.callPackage ../container/mqvpn-compose-file.nix { };
  composeDir = pkgs.stdenv.mkDerivation {
    name = "mqvpn-compose-dir";
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/mqvpn-server-conf
      cp ${composeFile} $out/docker-compose.yml
      cp -r ${mqvpnSrv}/* $out/mqvpn-server-conf/
    '';
  };

  mqvpnSrv = pkgs.runCommand "mqvpn-srv" { } ''
    mkdir -p $out
    cp ${mqvpnConf} $out/server.conf
    cp ${mqvpnCerts}/cert.pem $out/server.crt
    cp ${mqvpnCerts}/key.pem $out/server.key
  '';
in
{
  imports = [ ./test-base.nix ];

  networking.hostName = lib.mkForce "mogami-server";

  networking.useDHCP = false;

  # eth0: mgmt (SSH 管理) + 上流への出口 (defaultGateway でホスト経由)
  networking.interfaces."${vmWanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.50.2";
        prefixLength = 24;
      }
    ];
  };

  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = localIp;
        prefixLength = 24;
      }
    ];
    # ホスト(ISPシム)経由で各WAN /24に到達 (トンネル復路用)。
    ipv4.routes = [
      {
        address = "10.200.0.0";
        prefixLength = 16;
        via = "10.200.99.1";
      }
    ];
  };

  # eth2: ts-ext (mnet へのベンチ用出口)
  networking.interfaces.eth2 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.100.2";
        prefixLength = 24;
      }
    ];
  };

  # detect_ifaceはdefault routeから出口NICを決める (無いとNATが組まれない)。
  networking.defaultGateway = "192.168.50.254";
  networking.nameservers = [ "1.1.1.1" ];

  services.qemuGuest.enable = true;

  # net.*はコンテナから書けないためホスト側で有効化 (詳細はserver-image側)。
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # host-netコンテナはdefault routeのifaceのみMASQUERADEするため、
  # ext島 (192.168.100.0/24) 向けSNATを追加 (実機では不要なlab固有措置)。
  networking.nat = {
    enable = true;
    externalInterface = "eth2";
    internalInterfaces = map (i: "mqvpn${toString i}") mqvpnServers.serverIdxs;
  };

  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  virtualisation.diskSize = 12288;

  boot.kernelModules = [ "tun" ];
  systemd.tmpfiles.rules = [ "c /dev/net/tun 0600 root root 10 200" ];

  # 実環境と共通のcomposeをそのまま実行。upはフォアグラウンド必須
  # (-dだとExecStopのdownが全コンテナを消す)。
  systemd.services = {
    "mqvpn-compose" = {
      description = "MQVPN servers + monitoring (docker compose)";
      after = [
        "docker.service"
        "network-online.target"
      ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.docker
        pkgs.docker-compose
      ];

      serviceConfig = {
        ExecStartPre = [
          "${pkgs.docker}/bin/docker load -i ${mqvpnImage}"
          "${pkgs.docker}/bin/docker load -i ${mqvpnPromImage}"
          "${pkgs.docker}/bin/docker load -i ${mqvpnGrafanaImage}"
        ];
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f ${composeDir}/docker-compose.yml up --remove-orphans";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${composeDir}/docker-compose.yml down";
        Restart = "on-failure";
        RestartSec = "10";
      };
    };
  };

  virtualisation.vmVariant = {
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=ts-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:58"
      "-nic tap,ifname=ts-mq,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:59"
      "-nic tap,ifname=ts-ext,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:60"
    ];
  };

  hardware.enableRedistributableFirmware = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
      KbdInteractiveAuthentication = true;
    };
  };

  users.users.digicre = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = null;
    password = "server";
  };

  networking.firewall.allowedTCPPorts = [
    22 # SSH
  ];
  networking.firewall.allowedUDPPorts = mqvpnServers.serverPorts;

  boot.initrd.systemd.enable = false;

  environment.systemPackages = with pkgs; [
    iperf3
    perf
  ];
}
