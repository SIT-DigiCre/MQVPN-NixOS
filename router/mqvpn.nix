{
  pkgs,
  config,
  lib,
  ...
}:
{
  options.services.mqvpn.interfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "NICs used by MQVPN multi-WAN paths";
  };

  options.services.mqvpn.auth = lib.mkOption {
    type = lib.types.anything;
    description = ''
      MQVPNクライアントのシークレット: server_addrはIPのみ (portを含めない。
      portは公開情報でclientPortsが供給)。server_addr/auth_keyは全クライアント共通。
    '';
  };

  options.services.mqvpn.clientPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    description = ''
      接続先server portリスト。リスト順にunit mqvpn-N/TUN mqvpnNを自動付与
      (0-indexed)。ECMP weightは全トンネル1。
    '';
  };

  options.services.mqvpn.hybrid = lib.mkOption {
    type = lib.types.anything;
    description = "MQVPN hybrid TCP lane config";
  };

  options.services.mqvpn.reorder = lib.mkOption {
    type = lib.types.anything;
    description = "MQVPN reorder shim config (client TUN side)";
  };

  options.services.mqvpn.lanInterface = lib.mkOption {
    type = lib.types.str;
    description = "LAN-facing interface (kea DHCP / NAT / 起動待機の対象)";
  };

  options.services.mqvpn.cc = lib.mkOption {
    type = lib.types.enum [
      "bbr"
      "bbr2"
      "cubic"
      "none"
    ];
    description = "MQVPN congestion control algorithm (bbr, bbr2, cubic, none)";
  };

  config =
    let
      mqvpn = pkgs.callPackage ../pkgs/mqvpn-dbg.nix { };

      mqvpnAuth = config.services.mqvpn.auth;

      mqvpnClientTemplate = {
        mode = "client";
        insecure = true;
        log_level = "info";
        kill_switch = false;
        reconnect = true;
        reconnect_interval = 5;
        scheduler = "wlb";
        cc = config.services.mqvpn.cc;
        reinjection = "deadline";
        reorder = config.services.mqvpn.reorder;
        manage_routes = false;
        hybrid = config.services.mqvpn.hybrid;
        paths = config.services.mqvpn.interfaces;
      };

      mqvpnClientConfigs = lib.imap0 (i: port: {
        index = i;
        unitName = "mqvpn-${toString i}";
        tunName = "mqvpn${toString i}";
        file = pkgs.writeText "mqvpn-${toString i}.conf" (
          builtins.toJSON (
            mqvpnClientTemplate
            // {
              tun_name = "mqvpn${toString i}";
              server_addr = "${mqvpnAuth.server_addr}:${toString port}";
            }
            // (builtins.removeAttrs mqvpnAuth [ "server_addr" ])
          )
        );
      }) config.services.mqvpn.clientPorts;

      wanIfaces = lib.concatStringsSep " " config.services.mqvpn.interfaces;
      serverHost = mqvpnAuth.server_addr or "";
    in
    {
      systemd.services =
        lib.listToAttrs (
          map (c: {
            name = c.unitName;
            value = {
              description = "Multi-Queue VPN Tunnel Daemon (${c.tunName})";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];

              path = with pkgs; [
                iproute2
                iptables
                bash
              ];

              serviceConfig = {
                ExecStart = "${mqvpn}/bin/mqvpn --config ${c.file}";
                Restart = "always";
                RestartSec = "5s";
              };
            };
          }) mqvpnClientConfigs
        )
        // {
          # server pin + tunnel SNATの維持 (60秒ポーリング・全て冪等)。
          # ECMP自体は下のsystemd-networkdが担う。fail-openはnetwork.nixの
          # metricフォールバックに委ね、復元操作は不要。
          #  - server pin: manage_routes=falseのため<server>/32をGW経由で維持。
          #    GW消失時はnetworkd reconfigureで自癒 (変化時のみpin更新)。
          #  - tunnel SNAT (-o mqvpn+ MASQUERADE): router-local発の素通しが
          #    tun_validate_srcで約2/3落下する対策 (lab実証spray 63–86%)。
          #    詳細は chiken/mqvpn-many-clients-scale.md §4。
          mqvpn-path-keeper = {
            description = "server-pin / tunnel SNAT keeper";
            after = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wants = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wantedBy = [ "multi-user.target" ];

            path = with pkgs; [
              iproute2
              gawk
              iptables
              systemd
            ];

            serviceConfig = {
              Restart = "always";
              RestartSec = "5";
              ExecStart = pkgs.writeShellScript "mqvpn-path-keeper.sh" ''
                wan_ifaces="${wanIfaces}"
                server_host="${serverHost}"
                # 前回観測のWAN nexthops (GW変更の凍結防止用に記憶)
                wan_nexthops=""
                while true; do
                  # WAN GW発見 (可視デフォルト優先) +サーバーピン (/32をnexthop
                  # 1回でreplace。消失時はnetworkd reconfigureで自癒させ、
                  # 今回は前回記憶の維持のためスキップ)。
                  new_wan=""
                  if [ -n "$server_host" ]; then
                    for ifx in $wan_ifaces; do
                      gw=$(ip -4 route show dev "$ifx" default 2>/dev/null | awk '{print $3; exit}')
                      if [ -z "$gw" ] || [ "$gw" = "0.0.0.0" ]; then
                        if ip link show dev "$ifx" 2>/dev/null | grep -q "LOWER_UP"; then
                          networkctl reconfigure "$ifx" 2>/dev/null || true
                        fi
                        continue
                      fi
                      # マルチパスにはnexthop必須 (無いとreplace失敗しサーバー宛がトンネル内ループ)
                      new_wan="$new_wan nexthop via $gw dev $ifx"
                    done
                  fi
                  [ -n "$new_wan" ] && wan_nexthops="$new_wan"
                  if [ -n "$wan_nexthops" ] && [ -n "$server_host" ]; then
                    if ! ip route replace $server_host $wan_nexthops 2>/dev/null; then
                      echo "mqvpn-path-keeper: server pin replace failed: ip route replace $server_host $wan_nexthops" >&2
                    fi
                  fi
                  # router-local→tunnelのSNAT確保 (tun_validate_src対策。flushされても次ループで復旧)。
                  iptables -t nat -C nixos-nat-post -o "mqvpn+" -j MASQUERADE 2>/dev/null ||
                    iptables -t nat -A nixos-nat-post -o "mqvpn+" -j MASQUERADE 2>/dev/null || true
                  sleep 60
                done
              '';
            };
          };
        };

      # ECMP default維持: TUN出現/再作成に追従 (dev-only MultiPathRoute、
      # weight 1)。KeepConfigurationのみ。ManageForeignRoutes=noはextraConfigで
      # 書けるがあえて付けない (TUN上にforeign route無し・stale残留回避。
      # chiken/mqvpn-many-clients-scale.md §7参照)。netlinkで自動復旧。
      systemd.network.enable = true;
      systemd.network.networks."40-mqvpn" = {
        matchConfig.Name = "mqvpn*";
        networkConfig = {
          # KeepConfigurationのみ (lab spikeで実証済み。理由は上記)。
          KeepConfiguration = true;
        };
        routes = [
          {
            Destination = "0.0.0.0/0";
            MultiPathRoute = map (c: "@${c.tunName} 1") mqvpnClientConfigs;
          }
        ];
      };

      # MTU1382超はトンネル内フラグメント化で数割劣化するためMSSクランプで事前回避
      # (ICMPが戻らない環境のブラックホール保険も兼ねる)。
      networking.firewall.extraCommands = ''
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      '';
    };
}
