{
  config,
  lib,
  pkgs,
  ...
}: let
  # eth0:   build-vm default (IPv4LL/link-local, unused)
  # eth1:   tap tr-mq - LAN (static 172.16.0.1/12)
  # eth3:   SLiRP mgmt (hostfwd tcp::2223→:22, 10.0.2.0/24)
  # eth2/4-7:  WAN - 5× tap via mqvpn-srv-br0 → server VM (10.200.0.1)
  vmLanInterface = "eth1";
  vmWanInterfaces = ["eth2" "eth4" "eth5" "eth6" "eth7"];
in {
  networking.hostName = lib.mkForce "mogami-vm";

  networking.useDHCP = false;

  networking.interfaces.eth0.useDHCP = false;

  # Mgmt (DHCP — SLiRP, SSH port forwarding tcp::2223→:22)
  networking.interfaces.eth3.useDHCP = true;

  # LAN (static)
  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "172.16.0.1";
      prefixLength = 12;
    }];
  };

  # WAN (5× tap — 10.200.0.0/24)
  networking.interfaces.eth2.useDHCP = false;
  networking.interfaces.eth2.ipv4.addresses = [{ address = "10.200.0.2"; prefixLength = 24; }];
  networking.interfaces.eth4.useDHCP = false;
  networking.interfaces.eth4.ipv4.addresses = [{ address = "10.200.0.3"; prefixLength = 24; }];
  networking.interfaces.eth5.useDHCP = false;
  networking.interfaces.eth5.ipv4.addresses = [{ address = "10.200.0.4"; prefixLength = 24; }];
  networking.interfaces.eth6.useDHCP = false;
  networking.interfaces.eth6.ipv4.addresses = [{ address = "10.200.0.5"; prefixLength = 24; }];
  networking.interfaces.eth7.useDHCP = false;
  networking.interfaces.eth7.ipv4.addresses = [{ address = "10.200.0.6"; prefixLength = 24; }];

  # auth はシークレットのみ (server_addr は IP のみ、port は公開オプション clientPorts で指定)
  services.mqvpn.auth = {
    server_addr = "10.200.0.1";
    auth_key = "mqvpn-test-key-2024";
  };

  services.qemuGuest.enable = true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.forwardPorts = [];
    virtualisation.qemu.options = [];
  };
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [];

  networking.nat.internalInterfaces = lib.mkForce [vmLanInterface];

  services.kea.dhcp4.settings.interfaces-config.interfaces = lib.mkForce [vmLanInterface];

  services.mqvpn.interfaces = vmWanInterfaces;

  # クライアントは port リストで定義 (IP は auth.server_addr、WAN NIC は interfaces)
  services.mqvpn.clientPorts = [ 443 4432 ];

  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  users.users.digicre = {
    hashedPassword = lib.mkForce null;
    password = "router";
  };


  systemd.services.kea-dhcp4-server.preStart = lib.mkForce ''
    echo "Waiting for interface ${vmLanInterface} to be Running..."
    for i in {1..120}; do
      if ${pkgs.iproute2}/bin/ip link show dev "${vmLanInterface}" 2>/dev/null | grep -q "LOWER_UP"; then
        echo "Interface ${vmLanInterface} is up and running"
        exit 0
      fi
      sleep 1
    done
    echo "Timeout waiting for interface ${vmLanInterface}."
    exit 1
  '';
}
