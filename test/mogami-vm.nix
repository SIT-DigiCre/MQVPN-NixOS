{
  lib,
  ...
}:
let
  # qemu引数順=eth番号:
  #   eth0: tap tr-mq - LAN (static 172.16.0.1/12)
  #   eth1: tap trw0  - WAN0 / eth2: tap tr-mgmt - mgmt (static 192.168.50.1/24)
  #   WAN: eth1(trw0)+eth3-13(trw1-11)=12パス (内mqvpnが使うのは3本)
  vmLanInterface = "eth0";
  vmMgmtInterface = "eth2";
  vmMgmtAddr = "192.168.50.1";

  # q35のNIC上限(~8)超え対策: 各NICを明示PCIe root port (slot 16-29) に付ける。
  allNics = [
    {
      tap = "tr-mq";
      mac = "52:54:00:12:34:5a";
    }
    {
      tap = "trw0";
      mac = "52:54:00:12:34:5b";
    }
    {
      tap = "tr-mgmt";
      mac = "52:54:00:12:34:5c";
    }
    {
      tap = "trw1";
      mac = "52:54:00:12:34:5d";
    }
    {
      tap = "trw2";
      mac = "52:54:00:12:34:5e";
    }
    {
      tap = "trw3";
      mac = "52:54:00:12:34:5f";
    }
    {
      tap = "trw4";
      mac = "52:54:00:12:34:60";
    }
    {
      tap = "trw5";
      mac = "52:54:00:12:34:61";
    }
    {
      tap = "trw6";
      mac = "52:54:00:12:34:62";
    }
    {
      tap = "trw7";
      mac = "52:54:00:12:34:63";
    }
    {
      tap = "trw8";
      mac = "52:54:00:12:34:64";
    }
    {
      tap = "trw9";
      mac = "52:54:00:12:34:65";
    }
    {
      tap = "trw10";
      mac = "52:54:00:12:34:66";
    }
    {
      tap = "trw11";
      mac = "52:54:00:12:34:68";
    }
  ];
in
{
  imports = [ ./test-base.nix ];

  networking.hostName = lib.mkForce "mogami-vm";

  # mgmtのみtest固有。LAN/WANはrouter/の生成に任せる。
  # spare WANはnixpkgs既定のfallback DHCP (metric 1024) のまま: 使用3本の
  # metric 1-3が常に勝つためfail-open順序は保たれる。
  systemd.network.networks."10-mgmt" = {
    matchConfig.Name = vmMgmtInterface;
    address = [ "${vmMgmtAddr}/24" ];
  };

  # qemu NIC構成を完全明示 (user-net自動追加の抑止)。
  # MAC省略時は決定的値で他VMと衝突するため明示必須。
  virtualisation.vmVariant.virtualisation.qemu.networkingOptions = lib.mkForce (
    lib.flatten (
      lib.imap0 (i: nic: [
        "-device"
        "pcie-root-port,id=rpp${toString i},bus=pcie.0,slot=${toString (16 + i)},chassis=${toString (i + 1)}"
        "-netdev"
        "tap,id=net${toString i},ifname=${nic.tap},script=no,downscript=no"
        "-device"
        "virtio-net-pci,bus=rpp${toString i},netdev=net${toString i},addr=0x0,mac=${nic.mac}"
      ]) allNics
    )
  );

  # authはシークレットのみ (port指定はrouter/mqvpn.nixのoption参照)。
  services.mqvpn.auth = lib.mkForce {
    server_addr = "10.200.99.2";
    auth_key = "mqvpn-test-key-2024";
  };

  services.qemuGuest.enable = true;

  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [ ];

  # 使用WANは3本に絞る (NIC12本は将来の拡張用に残す)。
  services.mqvpn.interfaces = lib.mkForce [
    "eth1"
    "eth3"
    "eth4"
  ];
  services.mqvpn.lanInterface = lib.mkForce vmLanInterface;

  services.mqvpn.clientPorts = lib.mkForce (import ../container/mqvpn-servers.nix).serverPorts;

  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  users.users.digicre = {
    hashedPassword = lib.mkForce null;
    password = "router";
  };
}
