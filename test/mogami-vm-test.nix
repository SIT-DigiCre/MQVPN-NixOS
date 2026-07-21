# サーバーVM接続モード
# WAN: 5x tap (trw0-4) via mqvpn-srv-br0 → サーバーVM (10.200.0.1)
{ config, lib, pkgs, ... }: {
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

  # ポリシールーティング: source IP ベースで各インターフェースから送信
  boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 2;

  networking.iproute2 = {
    enable = true;
    rttablesExtraConfig = ''
      # WAN毎のルーティングテーブル
      100 wan0
      101 wan1
      102 wan2
      103 wan3
      104 wan4
    '';
  };

  networking.interfaces.ens11.ipv4.routes = [
    { address = "10.200.0.0"; prefixLength = 24; via = null; }
  ];
  networking.interfaces.ens13.ipv4.routes = [
    { address = "10.200.0.0"; prefixLength = 24; via = null; }
  ];
  networking.interfaces.ens14.ipv4.routes = [
    { address = "10.200.0.0"; prefixLength = 24; via = null; }
  ];
  networking.interfaces.ens15.ipv4.routes = [
    { address = "10.200.0.0"; prefixLength = 24; via = null; }
  ];
  networking.interfaces.ens16.ipv4.routes = [
    { address = "10.200.0.0"; prefixLength = 24; via = null; }
  ];

  systemd.services.setup-policy-routing = let
    ip = "${pkgs.iproute2}/bin/ip";
  in {
    description = "Setup policy routing for multi-WAN";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # wan0 (ens11, 10.200.0.2): デフォルトルート
      ${ip} route add 10.200.0.0/24 dev ens11 proto kernel scope link src 10.200.0.2 table 100
      ${ip} route add default via 10.200.0.1 dev ens11 table 100
      ${ip} rule add from 10.200.0.2 table 100 priority 100

      # wan1 (ens13, 10.200.0.3)
      ${ip} route add 10.200.0.0/24 dev ens13 proto kernel scope link src 10.200.0.3 table 101
      ${ip} route add default via 10.200.0.1 dev ens13 table 101
      ${ip} rule add from 10.200.0.3 table 101 priority 101

      # wan2 (ens14, 10.200.0.4)
      ${ip} route add 10.200.0.0/24 dev ens14 proto kernel scope link src 10.200.0.4 table 102
      ${ip} route add default via 10.200.0.1 dev ens14 table 102
      ${ip} rule add from 10.200.0.4 table 102 priority 102

      # wan3 (ens15, 10.200.0.5)
      ${ip} route add 10.200.0.0/24 dev ens15 proto kernel scope link src 10.200.0.5 table 103
      ${ip} route add default via 10.200.0.1 dev ens15 table 103
      ${ip} rule add from 10.200.0.5 table 103 priority 103

      # wan4 (ens16, 10.200.0.6)
      ${ip} route add 10.200.0.0/24 dev ens16 proto kernel scope link src 10.200.0.6 table 104
      ${ip} route add default via 10.200.0.1 dev ens16 table 104
      ${ip} rule add from 10.200.0.6 table 104 priority 104

      # メインテーブルのデフォルトゲートウェイ (ens11経由)
      ${ip} route add default via 10.200.0.1 dev ens11 metric 100
    '';
  };

  # テストサーバーの認証情報で上書き
  services.mqvpn.auth = lib.mkForce {
    server_addr = "10.200.0.1:443";
    auth_key = "mqvpn-test-key-2024";
  };
}
