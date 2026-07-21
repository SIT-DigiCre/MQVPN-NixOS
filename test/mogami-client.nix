{
  pkgs,
  lib,
  ...
}: {
  networking.hostName = "mogami-client";
  networking.usePredictableInterfaceNames = lib.mkDefault true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [];
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tc-mq,script=no,downscript=no,model=virtio-net-pci"
      "-nic user,hostfwd=tcp::2222-:22,model=virtio-net-pci"
    ];
  };

  networking.interfaces."ens3" = {
    ipv4.addresses = [
      {
        address = "172.16.0.2";
        prefixLength = 12;
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
    tcpdump
    mtr
    dnsutils
    netcat-gnu
  ];

  system.stateVersion = "26.05";
}
