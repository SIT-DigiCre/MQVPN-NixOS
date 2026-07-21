{
  config,
  lib,
  pkgs,
  ...
}: let
  # ens3:   build-vm default (IPv4LL/link-local, unused)
  # ens10:  tap tr-mq - LAN (static 172.16.0.1/12)
  # ens12:  SLiRP mgmt (hostfwd tcp::2223→:22, 10.0.3.0/24)
  # ens11/13-16:  WAN - 5× tap via mqvpn-srv-br0 → server VM (10.200.0.1)
  vmLanInterface = "ens10";
  vmWanInterfaces = ["ens11" "ens13" "ens14" "ens15" "ens16"];
  ip = "${pkgs.iproute2}/bin/ip";
in {
  networking.hostName = lib.mkForce "mogami-vm";
  networking.usePredictableInterfaceNames = lib.mkForce true;

  networking.useDHCP = false;

  networking.interfaces.ens3.useDHCP = false;

  # Mgmt (static — SLiRP, SSH port forwarding tcp::2223→:22)
  networking.interfaces.ens12.useDHCP = false;
  networking.interfaces.ens12.ipv4.addresses = [{
    address = "10.0.3.15";
    prefixLength = 24;
  }];

  # LAN (static)
  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "172.16.0.1";
      prefixLength = 12;
    }];
  };

  # WAN (5× tap — 10.200.0.0/24)
  networking.interfaces.ens11.useDHCP = false;
  networking.interfaces.ens11.ipv4.addresses = [{ address = "10.200.0.2"; prefixLength = 24; }];
  networking.interfaces.ens13.useDHCP = false;
  networking.interfaces.ens13.ipv4.addresses = [{ address = "10.200.0.3"; prefixLength = 24; }];
  networking.interfaces.ens14.useDHCP = false;
  networking.interfaces.ens14.ipv4.addresses = [{ address = "10.200.0.4"; prefixLength = 24; }];
  networking.interfaces.ens15.useDHCP = false;
  networking.interfaces.ens15.ipv4.addresses = [{ address = "10.200.0.5"; prefixLength = 24; }];
  networking.interfaces.ens16.useDHCP = false;
  networking.interfaces.ens16.ipv4.addresses = [{ address = "10.200.0.6"; prefixLength = 24; }];

  boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 2;
  networking.firewall.checkReversePath = false;

  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = ''
      # WAN 毎のルーティングテーブル（source-based multi-WAN）
      100 wan0
      101 wan1
      102 wan2
      103 wan3
      104 wan4
      # LAN → mqvpn0
      42 lan
    '';
  };

  # テストサーバーの認証情報
  services.mqvpn.auth = {
    server_addr = "10.200.0.1:443";
    auth_key = "mqvpn-test-key-2024";
  };

  # MQVPN multipath: source-based routing for WAN
  systemd.services.setup-policy-routing = {
    description = "Setup policy routing for multi-WAN";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${ip} route add 10.200.0.0/24 dev ens11 src 10.200.0.2 table 100
      ${ip} route add default via 10.200.0.1 dev ens11 table 100
      ${ip} rule add from 10.200.0.2 table 100 priority 100

      ${ip} route add 10.200.0.0/24 dev ens13 src 10.200.0.3 table 101
      ${ip} route add default via 10.200.0.1 dev ens13 table 101
      ${ip} rule add from 10.200.0.3 table 101 priority 101

      ${ip} route add 10.200.0.0/24 dev ens14 src 10.200.0.4 table 102
      ${ip} route add default via 10.200.0.1 dev ens14 table 102
      ${ip} rule add from 10.200.0.4 table 102 priority 102

      ${ip} route add 10.200.0.0/24 dev ens15 src 10.200.0.5 table 103
      ${ip} route add default via 10.200.0.1 dev ens15 table 103
      ${ip} rule add from 10.200.0.5 table 103 priority 103

      ${ip} route add 10.200.0.0/24 dev ens16 src 10.200.0.6 table 104
      ${ip} route add default via 10.200.0.1 dev ens16 table 104
      ${ip} rule add from 10.200.0.6 table 104 priority 104

      ${ip} route add default via 10.200.0.1 dev ens11
    '';
  };

  # LAN → mqvpn0 のルーティング（manage_routes=false のため手動追加）
  systemd.services.mqvpn-post = {
    description = "MQVPN post-setup: route + NAT for LAN";
    after = [ "mqvpn.service" ];
    bindsTo = [ "mqvpn.service" ];
    wantedBy = [ "mqvpn.service" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    script = ''
      for i in $(seq 1 30); do
        ${ip} link show mqvpn0 2>/dev/null | grep -q LOWER_UP && break
        sleep 1
      done

      # LAN traffic → mqvpn0 経由
      ${ip} rule add iif ${vmLanInterface} lookup 42 priority 42
      ${ip} route add 172.16.0.0/12 dev mqvpn0 table 42
      ${ip} route add default dev mqvpn0 table 42
      ${ip} route add 10.200.0.0/24 dev ens11 table 42
    '';
    preStop = ''
      ${ip} rule del priority 42 2>/dev/null || true
    '';
  };

  services.qemuGuest.enable = true;

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.forwardPorts = [];
    virtualisation.qemu.options = [];
  };
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [];

  networking.nat.internalInterfaces = lib.mkForce [vmLanInterface];
  networking.nat.extraCommands = ''
    ${pkgs.iptables}/sbin/iptables -t nat -A nixos-nat-post -o mqvpn0 -s 172.16.0.0/12 -j MASQUERADE
  '';
  networking.nat.extraStopCommands = ''
    ${pkgs.iptables}/sbin/iptables -t nat -D nixos-nat-post -o mqvpn0 -s 172.16.0.0/12 -j MASQUERADE 2>/dev/null || true
  '';

  services.kea.dhcp4.settings.interfaces-config.interfaces = lib.mkForce [vmLanInterface];

  services.mqvpn.interfaces = vmWanInterfaces;

  users.users.digicre = {
    hashedPassword = lib.mkForce null;
    password = "router";
  };

  swapDevices = lib.mkForce [];

  boot.resumeDevice = lib.mkForce "";
  boot.initrd.systemd.services.rollback.wantedBy = lib.mkForce [];

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
