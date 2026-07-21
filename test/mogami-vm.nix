{
  config,
  lib,
  pkgs,
  ...
}: let
  # ens3:   build-vm default (IPv4LL/link-local, unused)
  # ens10:  tap tr-mq - LAN (static 172.16.0.1/12)
  # ens12:  SLiRP mgmt (hostfwd tcp::2223→:22, 10.0.3.0/24)
  # ens11/13-16:  WAN — defined by real/test variant
  vmLanInterface = "ens10";
  vmWanInterfaces = ["ens11" "ens13" "ens14" "ens15" "ens16"];
in {
  networking.hostName = lib.mkForce "mogami-vm";
  networking.usePredictableInterfaceNames = lib.mkForce true;

  networking.useDHCP = false;

  networking.interfaces.ens3.useDHCP = false;

  # Mgmt (static — SLiRP, SSH port forwarding tcp::2223→:22)
  networking.interfaces.ens12.useDHCP = false;
  networking.interfaces.ens12.ipv4.addresses = [{
    address = "10.0.3.15";
    prefixLength = 24;
  }];

  # LAN (static)
  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "172.16.0.1";
      prefixLength = 12;
    }];
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

  users.users.digicre = {
    hashedPassword = lib.mkForce null;
    password = "router";
  };

  swapDevices = lib.mkForce [];

  boot.resumeDevice = lib.mkForce "";
  boot.initrd.systemd.services.rollback.wantedBy = lib.mkForce [];

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
