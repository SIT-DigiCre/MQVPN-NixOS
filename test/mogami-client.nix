{
  pkgs,
  lib,
  ...
}: {
  networking.hostName = "mogami-client";
  # NOTE: usePredictableInterfaceNames は VM ビルダーが boot.kernelParams に
  # net.ifnames=0 を追加するため実質無効。interface 名は常に ethX になる。

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [];
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tc-mq,script=no,downscript=no,model=virtio-net-pci"
      "-nic user,hostfwd=tcp::2222-:22,model=virtio-net-pci"
    ];
  };

  # eth0: tap tc-mq → router VM LAN (172.16.0.0/12)
  # eth1: QEMU user-mode (SSH port forwarding, internet via NAT)
  networking.interfaces."eth0" = {
    ipv4.addresses = [
      {
        address = "172.16.0.2";
        prefixLength = 12;
      }
    ];
  };

  networking.defaultGateway = "172.16.0.1";

  # SLiRP (eth1 / user-mode net) が IPv6 RA を出すため、放っておくと
  # クライアントは v6 経由で SLiRP 直抜けしてしまう (トンネル不通過)。
  # ラボではテストの妥当性のため v6 を無効化する (実機クライアントは配布側の管轄外)。
  networking.enableIPv6 = false;
  networking.dhcpcd.extraConfig = "noipv6";

  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
  };

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
      KbdInteractiveAuthentication = true;
    };
  };

  users.users.testuser = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    password = "test";
  };

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.enable = false;

  environment.systemPackages = with pkgs; [
    curl
    iperf3
    tcpdump
    mtr
    dnsutils
    netcat-gnu
  ];

  system.stateVersion = "26.05";
}
