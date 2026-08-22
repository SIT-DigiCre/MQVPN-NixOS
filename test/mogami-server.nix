{
  lib,
  pkgs,
  ...
}: let
  # eth0: QEMU user-mode (internet access via NAT)
  # eth1: tap ts-mq → mqvpn-srv-br0 → router VM (10.200.0.0/24)
  vmLanInterface = "eth1";
  vmWanInterface = "eth0";
  mqvpnServerSubnet = "192.168.0.0/24";
  mqvpnAuthKey = "mqvpn-test-key-2024";
  localIp = "10.200.0.1";

  mqvpn = pkgs.callPackage ../pkgs/mqvpn-dbg.nix { };

  mqvpnCerts = pkgs.runCommand "mqvpn-certs" {
    nativeBuildInputs = [pkgs.openssl];
  } ''
    openssl ecparam -genkey -name prime256v1 -noout -out key.pem
    openssl req -new -x509 -key key.pem -out cert.pem -days 3650 \
      -subj "/CN=mqtt-server.local" -addext "subjectAltName=DNS:mqtt-server.local,IP:${localIp}"
    mkdir -p $out
    cp key.pem cert.pem $out/
  '';

  mqvpnConfig = pkgs.writeText "mqvpn-server.json" (builtins.toJSON {
    mode = "server";
    listen = "0.0.0.0:443";
    subnet = mqvpnServerSubnet;
    tun_name = "mqvpn0";
    cert_file = "${mqvpnCerts}/cert.pem";
    key_file = "${mqvpnCerts}/key.pem";
    auth_key = mqvpnAuthKey;
    log_level = "info";
    reinjection = "deadline";
    hybrid = {
      enabled = true;
      tcp = "auto";
      tcp_max_flows = 2048;
      # ラボ専用: 帯域テストの TCP レーン宛先に slirp GW の 10.0.2.2
      # (常にホストの loopback へ届く固定アドレス)を使うため。
      # egress ACL がデフォルトで RFC1918 宛を拒否するので明示許可する
      egress_allow = [ "10.0.2.0/24" ];
    };
  });
in {
  networking.hostName = lib.mkForce "mogami-server";
  # NOTE: usePredictableInterfaceNames は VM ビルダーが boot.kernelParams に
  # net.ifnames=0 を追加するため実質無効。interface 名は常に ethX になる。

  networking.useDHCP = true;

  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = localIp;
      prefixLength = 24;
    }];
  };

  # eth0 (QEMU user-mode) gets a default route via QEMU gateway for internet access (NAT external)

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.nat = {
    enable = true;
    internalInterfaces = ["mqvpn0"];
    externalInterface = vmWanInterface;

  };

  services.qemuGuest.enable = true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.forwardPorts = [];
    virtualisation.qemu.options = [];
  };

  hardware.enableRedistributableFirmware = false;

  systemd.services.mqvpn-server = {
    description = "MQVPN VPN Server";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    path = with pkgs; [iproute2 iptables];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${mqvpnConfig}";
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
    extraGroups = ["wheel"];
    hashedPassword = null;
    password = "server";
  };

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.enable = false;

  boot.initrd.systemd.enable = false;

  system.stateVersion = "26.05";

  environment.systemPackages = with pkgs; [iperf3];
}
