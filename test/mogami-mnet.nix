{
  lib,
  pkgs,
  ...
}:
# "実ネットワーク側" の VM (ベンチターゲット): サーバーのトンネル出口先。
# 専用サブネット (192.168.100.0/24) は他 VM のどの経路にも含まれないため、
# クライアント→トンネル→コンテナ NAT→docker0→server VM→ここ、の
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

  # iperfd からの返送先はコンテナ NAT 元 (172.17.0.0/16, docker0) —
  # server VM 経由で戻る。
  networking.interfaces.eth0.ipv4.routes = [
    {
      address = "172.17.0.0";
      prefixLength = 16;
      via = "192.168.100.2";
    }
  ];

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

  networking.firewall.enable = false;
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
