{
  config,
  lib,
  pkgs,
  ...
}: let
  # ens3: QEMU user-mode (internet access via NAT)
  # ens4: tap ts-mq → mqvpn-srv-br0 → router VM (10.200.0.0/24)
  vmLanInterface = "ens4";
  vmWanInterface = "ens3";
  mqvpnServerSubnet = "10.10.0.0/24";
  mqvpnAuthKey = "mqvpn-test-key-2024";
  localIp = "10.200.0.1";

  mqvpn = pkgs.callPackage ../patches/mqvpn-src.nix { };

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
    tls_cert = "${mqvpnCerts}/cert.pem";
    tls_key = "${mqvpnCerts}/key.pem";
    auth_key = mqvpnAuthKey;
    log_level = "debug";
    hybrid = {
      enabled = true;
      tcp = "auto";
      egress_allow = [ "0.0.0.0/0" ];
    };
  });
in {
  networking.hostName = lib.mkForce "mogami-server";
  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.networkmanager.enable = lib.mkForce false;

  networking.useDHCP = true;

  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = localIp;
      prefixLength = 24;
    }];
  };

  # ens3 gets a default route via QEMU user gateway for internet access (NAT external)

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.nat = {
    enable = true;
    internalInterfaces = ["mqvpn0"];
    externalInterface = vmWanInterface;
    extraCommands = ''
      ${pkgs.iptables}/sbin/iptables -t nat -A nixos-nat-post -o ${vmWanInterface} -s 10.10.0.0/24 -j MASQUERADE
    '';
    extraStopCommands = ''
      ${pkgs.iptables}/sbin/iptables -t nat -D nixos-nat-post -o ${vmWanInterface} -s 10.10.0.0/24 -j MASQUERADE 2>/dev/null || true
    '';
  };

  services.qemuGuest.enable = true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.forwardPorts = [];
    virtualisation.qemu.options = [];
  };

  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [];

  systemd.services.mqvpn-server = {
    description = "MQVPN VPN Server";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    wantedBy = ["multi-user.target"];

    path = with pkgs; [iproute2 iptables];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${mqvpnConfig} --cert ${mqvpnCerts}/cert.pem --key ${mqvpnCerts}/key.pem";
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
    hashedPassword = lib.mkForce null;
    password = "server";
  };

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.enable = false;

  swapDevices = lib.mkForce [];

  boot.initrd.systemd.enable = lib.mkForce false;

  boot.resumeDevice = lib.mkForce "";

  system.stateVersion = "26.05";

  environment.systemPackages = with pkgs; [iperf3];
}
