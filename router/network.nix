{
  pkgs,
  config,
  lib,
  ...
}:
let
  lanInterface = config.services.mqvpn.lanInterface;
  localIp = "172.16.0.1";
in
{
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.rp_filter" = 2;
    # ECMP (複数トンネル) をフロー単位 (L4) でハッシュ分割する
    "net.ipv4.fib_multipath_hash_policy" = 1;
  };
  networking.enableIPv6 = false;
  networking.firewall.checkReversePath = false;

  # 全 IF を systemd-networkd で管理し、dhcpcd は使わない (単一スタック化)。
  # WAN は DHCP (本番 ISP / lab の ISP シム) で GW を取得し、per-WAN metric で
  # 共存させる (fail-open 時のフォールバック順序。lab 12 本・本番 7 本とも同式)。
  networking.useNetworkd = true;
  networking.dhcpcd.enable = false;

  services.chrony = {
    enable = true;
    extraConfig = ''
      allow 172.16.0.0/12
    '';
  };
  # systemd-resolved は無効化: 127.0.0.53 の stub が :53 を掴むと unbound
  # (0.0.0.0:53) が bind 競合で起動失敗する。起動順のレースで勝敗が変わるため
  # 確定的に無効化する (lab で LAN DNS 全滅を確認)。ルーター自身の名前解決は
  # unbound (127.0.0.1) が担う。
  services.resolved.enable = false;
  # resolved 無効化に伴い、ルーター自身の参照先を unbound (127.0.0.1) に固定する
  # (既定の stub-resolv.conf は 127.0.0.53 を指すため)。
  networking.nameservers = [ "127.0.0.1" ];

  # LAN は静的。WAN は services.mqvpn.interfaces の順に DHCP + metric 付与。
  systemd.network.networks =
    {
      "10-lan" = {
        matchConfig.Name = lanInterface;
        address = [ "${localIp}/12" ];
      };
    }
    // lib.listToAttrs (lib.imap0
      (i: name: lib.nameValuePair "10-wan${toString i}" {
        matchConfig.Name = name;
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.RouteMetric = i + 1;
      })
      config.services.mqvpn.interfaces);

  networking.firewall.enable = true;
  networking.nat = {
    enable = true;
    internalInterfaces = [ lanInterface ];
  };

  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config.interfaces = [ lanInterface ];
      valid-lifetime = 3600;
      renew-timer = 1800;
      subnet4 = [
        {
          id = 1;
          subnet = "172.16.0.0/12";
          pools = [
            {
              pool = "172.16.0.50 - 172.31.255.254";
            }
          ];
          option-data =
            map
              (name: {
                inherit name;
                data = localIp;
              })
              [
                "routers"
                "domain-name-servers"
                "ntp-servers"
              ];
        }
      ];
    };
  };
  systemd.services.kea-dhcp4-server = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    preStart = ''
      echo "Waiting for interface ${lanInterface} to be Running..."
      for i in {1..120}; do
        if ${pkgs.iproute2}/bin/ip link show dev "${lanInterface}" 2>/dev/null | grep -q "LOWER_UP"; then
          echo "Interface ${lanInterface} is up and running"
          exit 0
        fi
        sleep 1
      done

      echo "Timeout waiting for interface ${lanInterface}."
      exit 1
    '';

    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        prefetch = "yes";
        serve-expired = "yes";
        num-threads = 4;
        interface = [ "0.0.0.0" ];
        access-control = [
          "127.0.0.0/8 allow"
          "172.16.0.0/12 allow"
        ];
        local-data = "\"${config.networking.hostName}.local. IN A ${localIp}\"";
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "9.9.9.9"
            "1.1.1.1"
          ];
        }
      ];
    };
  };
  networking.firewall = {
    allowedTCPPorts = [
      22
      53
    ];
    allowedUDPPorts = [
      53
      67
      123 # NTP
    ];
  };
}
