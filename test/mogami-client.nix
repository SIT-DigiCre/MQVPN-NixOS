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
    # 管理は mq-mgmt-br0 の tap (mgmt にデフォルトルート無し → テスト経路の外に
    # 抜ける経路が構造的に存在しない)
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tc-mq,script=no,downscript=no,model=virtio-net-pci"
      "-nic tap,ifname=tc-mgmt,script=no,downscript=no,model=virtio-net-pci"
    ];
  };

  # eth0: tap tc-mq → router VM LAN (172.16.0.0/12、デフォルトルートはここ)
  # eth1: tap tc-mgmt → mq-mgmt-br0 (192.168.50.3/24、ルート無し = SSH 管理専用)
  networking.interfaces."eth0" = {
    ipv4.addresses = [
      {
        address = "172.16.0.2";
        prefixLength = 12;
      }
    ];
  };

  networking.interfaces."eth1" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.50.3";
        prefixLength = 24;
      }
    ];
  };

  networking.defaultGateway = "172.16.0.1";

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
    jq
    tcpdump
    mtr
    dnsutils
    netcat-gnu
  ];

  system.stateVersion = "26.05";
}
