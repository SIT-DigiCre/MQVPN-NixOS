{
  pkgs,
  lib,
  ...
}:
{
  imports = [ ./test-base.nix ];

  networking.hostName = "mogami-client";

  virtualisation.vmVariant = {
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tc-mq,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:56"
      "-nic tap,ifname=tc-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:57"
    ];
  };

  # eth0はrouter LANからDHCP受領 (実機クライアントと同動作)。
  networking.interfaces."eth0" = {
    useDHCP = true;
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
    extraGroups = [ "wheel" ];
    password = "test";
  };

  networking.firewall.allowedTCPPorts = [ 22 ];

  environment.systemPackages = with pkgs; [
    curl
    iperf3
    jq
    tcpdump
    mtr
    dnsutils
    netcat-gnu
  ];
}
