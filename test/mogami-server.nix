{
  lib,
  pkgs,
  ...
}:
let
  # eth0: tap ts-mgmt → mq-mgmt-br0 (192.168.50.2/24, 管理 + 上流への出口)
  # eth1: tap ts-mq → mqvpn-srv-br0 → router VM (10.200.0.0/24)
  vmLanInterface = "eth1";
  vmWanInterface = "eth0";
  # サーバー = トンネル集約点 (実機の VPN サーバー相当) で、上流への出口を持つ:
  # トンネル復元後のトラフィックを NAT (eth0) → ホスト経由で実ネットワークへ。
  # デフォルトルートはホスト (192.168.50.254)。ルーター/クライアントは出口を
  # 持たないため、外部へは必ずトンネルを経由する (直抜け構造なし)。
  mqvpnServerSubnet = "192.168.0.0/24";
  mqvpnAuthKey = "mqvpn-test-key-2024";
  localIp = "10.200.0.1";

  mqvpn = pkgs.callPackage ../pkgs/mqvpn-dbg.nix { };

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
    listen = "0.0.0.0:443";
    subnet = mqvpnServerSubnet;
    tun_name = "mqvpn0";
    cert_file = "${mqvpnCerts}/cert.pem";
    key_file = "${mqvpnCerts}/key.pem";
    auth_key = mqvpnAuthKey;
    log_level = "info";
    reinjection = "off";
    hybrid = {
      enabled = true;
      tcp = "auto";
      tcp_max_flows = 2048;
    };
  };

  mqvpnConfig = pkgs.writeText "mqvpn-server.json" (builtins.toJSON mqvpnServerBase);

  # マルチサーバー構成用の 2 つ目のサーバー (ECMP 検証用)
  # 同一 VM 内でポート 4432 / サブネット 192.168.1.0/24 / tun mqvpn1。差分のみ上書き。
  mqvpnConfigB = pkgs.writeText "mqvpn-server-b.json" (
    builtins.toJSON (
      mqvpnServerBase
      // {
        listen = "0.0.0.0:4432";
        subnet = "192.168.1.0/24";
        tun_name = "mqvpn1";
      }
    )
  );
in
{
  networking.hostName = lib.mkForce "mogami-server";
  # NOTE: usePredictableInterfaceNames は VM ビルダーが boot.kernelParams に
  # net.ifnames=0 を追加するため実質無効。interface 名は常に ethX になる。

  networking.useDHCP = false;

  # eth0: mgmt (mq-mgmt-br0, SSH 管理専用・デフォルトルート無し)
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
  };

  services.qemuGuest.enable = true;

  # トンネル復元後のトラフィックを上流 (eth0 → ホスト) へ NAT
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.nat = {
    enable = true;
    internalInterfaces = [
      "mqvpn0"
      "mqvpn1"
    ];
    externalInterface = vmWanInterface;
  };
  networking.defaultGateway = "192.168.50.254";

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [ ];
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=ts-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:58"
      "-nic tap,ifname=ts-mq,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:59"
    ];
  };

  hardware.enableRedistributableFirmware = false;

  systemd.services.mqvpn-server = {
    description = "MQVPN VPN Server A";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      iproute2
      iptables
    ];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${mqvpnConfig}";
      Restart = "on-failure";
      RestartSec = "5";
    };
  };

  systemd.services.mqvpn-server-b = {
    description = "MQVPN VPN Server B";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      iproute2
      iptables
    ];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${mqvpnConfigB}";
      Restart = "on-failure";
      RestartSec = "5";
    };
  };

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

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.enable = false;

  boot.initrd.systemd.enable = false;

  system.stateVersion = "26.05";

  environment.systemPackages = with pkgs; [
    iperf3
    perf
  ];
}
