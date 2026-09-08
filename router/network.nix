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

  # 全IFをsystemd-networkdに一本化 (dhcpcd不使用)。
  # WANはDHCP+per-WAN metricで共存 (fail-open時はmetricフォールバックに委ねる)。
  networking.useNetworkd = true;
  networking.dhcpcd.enable = false;

  services.chrony = {
    enable = true;
    extraConfig = ''
      allow 172.16.0.0/12
    '';
  };
  # resolved無効化: stub :53 が unbound (0.0.0.0:53) と競合するため
  # (labでLAN DNS全滅を確認)。自身の解決はunbound (127.0.0.1) が担う。
  services.resolved.enable = false;
  networking.nameservers = [ "127.0.0.1" ];

  systemd.network.networks = {
    "10-lan" = {
      matchConfig.Name = lanInterface;
      address = [ "${localIp}/12" ];
    };
  }
  // lib.listToAttrs (
    lib.imap0 (
      i: name:
      lib.nameValuePair "10-wan${toString i}" {
        matchConfig.Name = name;
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.RouteMetric = i + 1;
      }
    ) config.services.mqvpn.interfaces
  );

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
      123
    ];
  };
}
