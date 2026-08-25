{
  config,
  lib,
  pkgs,
  ...
}: let
  # 管理ネットワークは専用 tap ブリッジ mq-mgmt-br0 (192.168.50.0/24)。
  # VM 内に mgmt のデフォルトルートは置かない (テスト経路の外への経路を構造的に持たない)。
  #
  #  qemu 引数順 (networkingOptions) = eth 番号:
  #   eth0:    tap tr-mq    - LAN (static 172.16.0.1/12)
  #   eth1:    tap trw0     - WAN0
  #   eth2:    tap tr-mgmt  - mgmt (static 192.168.50.1/24, ルート無し)
  #   WAN: eth1(trw0) + eth3-13(trw1-11) = 12 パス
  vmLanInterface = "eth0";
  vmMgmtInterface = "eth2";
  vmWanInterfaces = ["eth1" "eth3" "eth4" "eth5" "eth6" "eth7" "eth8" "eth9" "eth10" "eth11" "eth12" "eth13"];
  vmMgmtAddr = "192.168.50.1";
  # ECMP 対象の WAN: eth 番号 → サーバーブリッジ側アドレス
  vmWanAddresses = {
    eth1 = "10.200.0.2";
    eth3 = "10.200.0.3";
    eth4 = "10.200.0.4";
    eth5 = "10.200.0.5";
    eth6 = "10.200.0.6";
    eth7 = "10.200.0.7";
    eth8 = "10.200.0.8";
    eth9 = "10.200.0.9";
    eth10 = "10.200.0.10";
    eth11 = "10.200.0.11";
    eth12 = "10.200.0.12";
    eth13 = "10.200.0.13";
  };

  # q35 の既定 NIC スロット上限(~8)を超えるため、各 NIC を明示的な PCIe
  # root port に付ける。前提: マシンは q35 (ルートバス名 pcie.0) であること。
  # slot は 16-29 を使用 (低番号は disk/rng/gpu 等が占有)。この構成で mogami-vm
  # は 14 NIC (WAN12 + LAN + mgmt) で実際に起動し、12 パス動作を確認済み。
  allNics = [
    { tap = "tr-mq";   mac = "52:54:00:12:34:5a"; }
    { tap = "trw0";    mac = "52:54:00:12:34:5b"; }
    { tap = "tr-mgmt"; mac = "52:54:00:12:34:5c"; }
    { tap = "trw1";    mac = "52:54:00:12:34:5d"; }
    { tap = "trw2";    mac = "52:54:00:12:34:5e"; }
    { tap = "trw3";    mac = "52:54:00:12:34:5f"; }
    { tap = "trw4";    mac = "52:54:00:12:34:60"; }
    { tap = "trw5";    mac = "52:54:00:12:34:61"; }
    { tap = "trw6";    mac = "52:54:00:12:34:62"; }
    { tap = "trw7";    mac = "52:54:00:12:34:63"; }
    { tap = "trw8";    mac = "52:54:00:12:34:64"; }
    { tap = "trw9";    mac = "52:54:00:12:34:65"; }
    { tap = "trw10";   mac = "52:54:00:12:34:66"; }
    { tap = "trw11";   mac = "52:54:00:12:34:67"; }
  ];
in {
  networking.hostName = lib.mkForce "mogami-vm";

  networking.useDHCP = false;

  # LAN / mgmt / WAN の静的設定
  networking.interfaces = lib.mkMerge [
    {
      "${vmLanInterface}" = {
        useDHCP = false;
        ipv4.addresses = [{ address = "172.16.0.1"; prefixLength = 12; }];
      };
      "${vmMgmtInterface}" = {
        useDHCP = false;
        ipv4.addresses = [{ address = vmMgmtAddr; prefixLength = 24; }];
      };
    }
    (lib.mapAttrs' (iface: addr: {
      name = iface;
      value = {
        useDHCP = false;
        ipv4.addresses = [{ address = addr; prefixLength = 24; }];
      };
    })
    vmWanAddresses)
  ];

  # qemu の NIC 構成を完全に明示 (ビルダー既定の user-net を含め一切自動追加させない)。
  # MAC は 3 VM 間で共有ブリッジ上ユニークになるよう明示 (-nic の MAC 省略時は
  # 52:54:00:12:34:56 + index の決定的な値になり、他 VM と衝突するため不可)
  virtualisation.vmVariant.virtualisation.qemu.networkingOptions = lib.mkForce (
    lib.flatten (lib.imap0 (i: nic: [
      "-device" "pcie-root-port,id=rpp${toString i},bus=pcie.0,slot=${toString (16 + i)},chassis=${toString (i + 1)}"
      "-netdev" "tap,id=net${toString i},ifname=${nic.tap},script=no,downscript=no"
      "-device" "virtio-net-pci,bus=rpp${toString i},netdev=net${toString i},addr=0x0,mac=${nic.mac}"
    ]) allNics)
  );

  # auth はシークレットのみ (server_addr は IP のみ、port は公開オプション clientPorts で指定)
  services.mqvpn.auth = {
    server_addr = "10.200.0.1";
    auth_key = "mqvpn-test-key-2024";
  };

  services.qemuGuest.enable = true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [];
  };
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [];

  networking.nat.internalInterfaces = lib.mkForce [vmLanInterface];

  services.kea.dhcp4.settings.interfaces-config.interfaces = lib.mkForce [vmLanInterface];

  services.mqvpn.interfaces = vmWanInterfaces;

  # クライアントは port リストで定義 (IP は auth.server_addr、WAN NIC は interfaces)
  services.mqvpn.clientPorts = [ 443 444 ];

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
