{
  lib,
  pkgs,
  ...
}:
# "実ネットワーク側" の VM (ベンチターゲット): サーバーのトンネル出口先。
# 専用サブネット (192.168.100.0/24) は他 VM のどの経路にも含まれないため、
# クライアント→トンネル→コンテナ NAT→server VM eth2→ここ、の
# フルチェーンを漏れなく測定できる。
{
  networking.hostName = lib.mkForce "mogami-mnet";

  networking.useDHCP = false;

  # eth0: tap tm-ext → mq-ext-br0 → server VM (eth2, 192.168.100.2)
  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.100.1";
        prefixLength = 24;
      }
    ];
  };

  # eth1: tap tm-mgmt → mq-mgmt-br0 (SSH 管理用)
  networking.interfaces.eth1 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.50.4";
        prefixLength = 24;
      }
    ];
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
    password = "mnet";
  };

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.allowedTCPPorts = [
    22
    6205
  ];
  networking.firewall.allowedUDPPorts = [ 6205 ];
  networking.firewall.allowedTCPPortRanges = [
    {
      from = 5201;
      to = 5300;
    }
  ];
  networking.firewall.allowedUDPPortRanges = [
    {
      from = 5201;
      to = 5300;
    }
  ];
  boot.initrd.systemd.enable = false;

  system.stateVersion = "26.05";

  environment.systemPackages = with pkgs; [ iperf3 ];

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [ ];
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tm-ext,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:61"
      "-nic tap,ifname=tm-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:62"
    ];
  };

  hardware.enableRedistributableFirmware = false;
  services.qemuGuest.enable = true;
}
