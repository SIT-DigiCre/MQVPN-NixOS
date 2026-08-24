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
  #   eth0: tap tr-mq    - LAN (static 172.16.0.1/12)
  #   eth1: tap trw0     - WAN0
  #   eth2: tap tr-mgmt  - mgmt (static 192.168.50.1/24, ルート無し)
  #   eth3-6: tap trw1-4 - WAN1-4
  vmLanInterface = "eth0";
  vmMgmtInterface = "eth2";
  vmWanInterfaces = ["eth1" "eth3" "eth4" "eth5" "eth6"];
  vmMgmtAddr = "192.168.50.1";
  # ECMP 対象の WAN: eth 番号 → サーバーブリッジ側アドレス
  vmWanAddresses = {
    eth1 = "10.200.0.2";
    eth3 = "10.200.0.3";
    eth4 = "10.200.0.4";
    eth5 = "10.200.0.5";
    eth6 = "10.200.0.6";
  };
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
  virtualisation.vmVariant.virtualisation.qemu.networkingOptions = lib.mkForce [
    "-nic tap,ifname=tr-mq,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5a"
    "-nic tap,ifname=trw0,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5b"
    "-nic tap,ifname=tr-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5c"
    "-nic tap,ifname=trw1,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5d"
    "-nic tap,ifname=trw2,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5e"
    "-nic tap,ifname=trw3,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:5f"
    "-nic tap,ifname=trw4,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:60"
  ];

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
