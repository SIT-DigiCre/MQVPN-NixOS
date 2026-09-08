{
  lib,
  pkgs,
  ...
}:
# ベンチターゲットVM: クライアント→トンネル→NAT→server eth2→ここのフルチェーンを測定。
{
  imports = [ ./test-base.nix ];

  networking.hostName = lib.mkForce "mogami-mnet";

  networking.useDHCP = false;

  networking.interfaces.eth0 = {
    # tap tm-ext → server VM (192.168.100.2)
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.100.1";
        prefixLength = 24;
      }
    ];
  };

  networking.interfaces.eth1 = {
    # tap tm-mgmt (SSH管理用)
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

  environment.systemPackages = with pkgs; [ iperf3 ];

  virtualisation.vmVariant = {
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=tm-ext,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:61"
      "-nic tap,ifname=tm-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:62"
    ];
  };

  hardware.enableRedistributableFirmware = false;
  services.qemuGuest.enable = true;
}
