{
  pkgs,
  config,
  lib,
  ...
}:
let
  mqvpn = pkgs.callPackage ./pkgs/mqvpn-dbg.nix { };

  live-chart = pkgs.callPackage ./pkgs/live-chart.nix { };

  rtl8127-firmware = pkgs.stdenv.mkDerivation {
    name = "rtl8127-firmware";
    src = pkgs.fetchurl {
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_nic/rtl8127a-1.fw";
      sha256 = "1q1hvf8blhh8vv2nik89nplnvh3a6pfxl7rr02wwgrv5jljdkpbc";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/lib/firmware/rtl_nic
      cp $src $out/lib/firmware/rtl_nic/rtl8127a-1.fw
    '';
  };

  internalInterfaceName = config.services.mqvpn.lanInterface;
  localIp = "172.16.0.1";

in
{
  options.services.mqvpn.interfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "NICs used by MQVPN multi-WAN paths";
  };

  options.services.mqvpn.auth = lib.mkOption {
    type = lib.types.anything;
    description = ''
      MQVPN クライアントのシークレット設定: auth_key とサーバー IP (server_addr は
      **IP のみ**。port を含めてはならない — port は公開情報で services.mqvpn.clientPorts
      が供給)。server_addr / auth_key は全クライアント共通で、クライアントごとに
      ファイルを分けることはできない (複数クライアントは clientPorts の port のみで区別)。
    '';
  };

  options.services.mqvpn.clientPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    description = ''
      クライアントの接続先 server port リスト。サーバー IP (auth.server_addr) と
      WAN NIC (interfaces) は全クライアント共通のため、port のみ個別指定する。
      0-indexed: unit は mqvpn-0, mqvpn-1, ...、TUN 名は mqvpn0, mqvpn1, ... と
      リスト順に自動付与。ECMP weight は全トンネル 1 (共通 NIC セットのため不変)。
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
      mqvpnAuth = config.services.mqvpn.auth;

      # 全クライアント共通の設定テンプレート (tun_name / server_addr は下で付与)
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

      # クライアント config 一覧 (0-indexed: リスト順に unit は mqvpn-0, mqvpn-1, ...、
      # TUN 名は mqvpn0, mqvpn1, ... と自動付与)。
      # server_addr = IP (auth) + port (clientPorts の各要素)
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

      # 各クライアントの systemd unit
      clientUnits = lib.listToAttrs (
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
      );

      # keeper スクリプトへ展開する WAN IF 一覧とサーバー IP
      wanIfaces = lib.concatStringsSep " " config.services.mqvpn.interfaces;
      serverHost = mqvpnAuth.server_addr or "";
    in
    {
      boot.kernelParams = [
        "ipv6.disable=1"
      ];
      hardware.enableRedistributableFirmware = true;
      hardware.firmware = [ rtl8127-firmware ];
      nix.settings.experimental-features = [
        "nix-command"
        "flakes"
      ];

      # ---------------------------------------------------------------------
      # 1. ホスト名をもがみにする
      # ---------------------------------------------------------------------
      networking.hostName = "mogami";

      services.mqvpn = {
        interfaces = [
          "enp1s0f0"
          "enp1s0f1"
          "enp1s0f2"
          "enp1s0f3"
          "enp6s0"
          "enp8s0"
          "enp9s0"
        ];
        auth = builtins.fromJSON (builtins.readFile ./mqvpn-auth.json);
        clientPorts = [
          443
          444
          445
        ];
        cc = "bbr";
        lanInterface = "enp10s0";
        hybrid = {
          enabled = false;
          tcp = "auto";
          tcp_max_flows = 2048;
        };
        reorder = {
          enabled = "on";
          max_wait_ms = 100;
          cap_packets = 4096;
        };
      };

      # ---------------------------------------------------------------------
      # 2. 基本設定
      # ---------------------------------------------------------------------
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
      networking.interfaces."${internalInterfaceName}" = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = localIp;
            prefixLength = 12;
          }
        ];
      };

      # リポジトリ全体をシステムに配置
      systemd.tmpfiles.rules = [
        "C /home/digicre/mqvpn-router 0755 digicre users - ${./.}"
        "Z /home/digicre/mqvpn-router/.git 0755 digicre users - -"
      ];

      # ---------------------------------------------------------------------
      # 3. ルーティング & ファイアウォール
      # ---------------------------------------------------------------------
      boot.kernelPackages = pkgs.linuxPackages_latest;
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.rp_filter" = 2;
        # ECMP (複数トンネル) をフロー単位 (L4) でハッシュ分割する
        "net.ipv4.fib_multipath_hash_policy" = 1;
      };
      networking.enableIPv6 = false;
      networking.dhcpcd.extraConfig = ''
        noipv6
      '';
      networking.firewall.checkReversePath = false;
      networking.firewall.enable = true;
      networking.nat = {
        enable = true;
        internalInterfaces = [ internalInterfaceName ];
        # 全トンネルに mark ベースの MASQUERADE。
        # 現在の nixpkgs は externalInterface=null なら総称ルール
        # (-m mark --mark 0x1 -j MASQUERADE) を自前発行するためこの行は重複だが、
        # モジュール内部実装に依存せず明示するために残す (nixpkgs 更新で挙動が
        # 変わる可能性があるため削除しない)。
        extraCommands = lib.concatStringsSep "\n" (
          map (c: ''
            iptables -t nat -A nixos-nat-post -o ${c.tunName} -m mark --mark 0x1 -j MASQUERADE
          '') mqvpnClientConfigs
        );
      };

      # トンネル MTU(1382) 超の TCP セグメントはトンネル内で IP フラグメント化され、
      # オーバーヘッド/フラグメントロスで数割劣化する。FORWARD で MSS を出口 IF の
      # PMTU にクランプし、断片化を事前回避する (SLiRP 等 ICMP が戻らない環境では
      # 完全ブラックホールを防ぐ保険にもなる)。
      networking.firewall.extraCommands = ''
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      '';

      # ---------------------------------------------------------------------
      # 4. LAN側：DHCP/DNSサーバー
      # ---------------------------------------------------------------------

      services.kea.dhcp4 = {
        enable = true;
        settings = {
          interfaces-config.interfaces = [ internalInterfaceName ];
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
          loggers = [
            {
              name = "kea-dhcp4";
              output_options = [
                {
                  output = "stdout";
                }
              ];
              severity = "INFO";
            }
          ];
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

      # ---------------------------------------------------------------------
      # 5. ユーザー
      # ---------------------------------------------------------------------

      users.users.digicre = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
        hashedPassword = "$y$j9T$TGjAbr5yoNT4sgFdsZyRN0$8TrbfpDZw5KH2PHQLVW2QZ1xrtvG75mK9vyjX0qVxE1";
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJXSxCLvKhPW5EtaLCrOkXDLr2q85q6X2RYMgYKldRVR mogami"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKbmCSnxi4i+LHKTtZsX++GocB95+Px+uMGC0rywgiXe tsukumo"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPUGyRn1gNjc0ReWsCgHOjOXVOO6t9sx28yTo/Sikf+ iroiro"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIedWYFepCNptG5dre4jOqvC5O9RkkdALYjz/uLD6rLk glyzinieh"
        ];
      };

      # 全WAN NICをまとめて監視するエイリアス
      programs.bash.shellAliases = {
        live-chart = "live_chart -i '${lib.concatStringsSep "," config.services.mqvpn.interfaces}'";
      };

      # ---------------------------------------------------------------------
      # 6. sudo（wheelはパスワード不要）
      # ---------------------------------------------------------------------

      security.sudo.wheelNeedsPassword = false;

      # ---------------------------------------------------------------------
      # 7. SSH
      # ---------------------------------------------------------------------

      services.openssh = {
        enable = true;
        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
        };
      };

      # ---------------------------------------------------------------------
      # 8. WebUI
      # ---------------------------------------------------------------------

      services.glances = {
        enable = true;
        openFirewall = true;
        port = 80;
      };

      # ---------------------------------------------------------------------
      # 8b. ECMP ライフサイクル (systemd-networkd)
      # ---------------------------------------------------------------------
      # TUN (mqvpn*) の出現/再作成に追従して ECMP default を維持する。
      # dev-only MultiPathRoute (@mqvpnX、gateway 不要・weight 1) で PtP TUN に直結。
      # KeepConfiguration + ManageForeign* no で mqvpn 割当のアドレスには触れない。
      # 他 IF (LAN/WAN/mgmt) は従来の classic 管理のまま混在運用する。
      # netlink イベントで自動復旧するため、手書きポーリングは不要 (lab spike で検証)。
      systemd.network.enable = true;
      systemd.network.networks."40-mqvpn" = {
        matchConfig.Name = "mqvpn*";
        networkConfig = {
          # nixpkgs の Network セクション検査に無い ManageForeign* は書けないため、
          # KeepConfiguration のみ指定 (lab spike でこの組合せの無害を確認済み)。
          KeepConfiguration = true;
        };
        routes = [
          {
            Destination = "0.0.0.0/0";
            MultiPathRoute = map (c: "@${c.tunName} 1") mqvpnClientConfigs;
          }
        ];
      };

      # ---------------------------------------------------------------------
      # 9. MQVPN (全クライアントは clientPorts から一様生成される)
      # ---------------------------------------------------------------------
      systemd.services = lib.mkMerge [
        {
          kea-dhcp4-server = {
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];

            preStart = ''
              echo "Waiting for interface ${internalInterfaceName} to be Running..."
              for i in {1..120}; do
                if ${pkgs.iproute2}/bin/ip link show dev "${internalInterfaceName}" 2>/dev/null | grep -q "LOWER_UP"; then
                  echo "Interface ${internalInterfaceName} is up and running"
                  exit 0
                fi
                sleep 1
              done

              echo "Timeout waiting for interface ${internalInterfaceName}."
              exit 1
            '';

            serviceConfig = {
              Restart = lib.mkForce "always";
              RestartSec = "5s";
            };
          };
        }
        clientUnits
        # ルートキーパー (server pin + tunnel SNAT の維持)。
        # ECMP ライフサイクルは systemd-networkd が担う (下記 [X.] 参照)。
        #  - サーバー制御プレーン経路のピン (manage_routes=false のため上流の setup_routes
        #    は動かない。WAN デフォルトが消えても <server>/32 を GW 経由で維持する。
        #    GW は可視デフォルト優先・無ければ dhcpcd リースで補完し、変化時のみ更新)
        #  - router-local → tunnel の SNAT 確保 (tun_validate_src 対策):
        #    router 側 mqvpn は TUN-ingress の src≠自 tunnel IP を silent drop する。
        #    LAN 側は NAT mark (0x1) で MASQUERADE され out-dev addr になるため常時一致
        #    するが、router-local (unbound 上流等) は mark 無しで素通しされ、ECMP 下の
        #    src 選択がトンネルと独立に分散 → 約2/3落下 (lab実証: spray 63–86%)。
        #    `-o mqvpn+ MASQUERADE` で out-dev addr に確定させ常時一致させる。
        #    LAN 側は既存 mark 規則と同値で無害。chiken/mqvpn-many-clients-scale.md §4 参照
        #  - fail-open はカーネルの metric フォールバックに委ねる (per-WAN デフォルト
        #    metric 1–12 が常駐し、ECMP 消失時は自動でそちらへ落ちる)。復元操作は不要
        # 60秒ポーリング (GW 変化は稀なため。設定変更は全て冪等)。
        {
          mqvpn-path-keeper = {
            description = "server-pin / tunnel SNAT keeper";
            after = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wants = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wantedBy = [ "multi-user.target" ];

            path = with pkgs; [
              iproute2
              gawk
              iptables
              # ピン用 GW の補完発見 (dhcpcd -U で現在リースを読む)
              dhcpcd
            ];

            serviceConfig = {
              Restart = "always";
              RestartSec = "5";
              ExecStart = pkgs.writeShellScript "mqvpn-path-keeper.sh" ''
                wan_ifaces="${wanIfaces}"
                server_host="${serverHost}"
                # 最後に観測した WAN デフォルトの nexthops (GW 変更凍結の防止 — 前回の記憶)
                wan_nexthops=""
                while true; do
                  # 1) WAN GW の発見 (可視デフォルト優先、無ければ dhcpcd リースで補完) +
                  #    サーバーピン (/32 を nexthop 1 回で replace。IF ごとに分けると
                  #    最後の 1 本しか残らない)
                  new_wan=""
                  if [ -n "$server_host" ]; then
                    for ifx in $wan_ifaces; do
                      gw=$(ip -4 route show dev "$ifx" default 2>/dev/null | awk '{print $3; exit}')
                      if [ -z "$gw" ] || [ "$gw" = "0.0.0.0" ]; then
                        gw=$(dhcpcd -U "$ifx" 2>/dev/null | sed -n 's/^routers=//p' | awk '{print $1}')
                      fi
                      [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] || continue
                      # 複数 nexthop のマルチパスには nexthop キーワードが必須
                      # (単一時も有効。無いと replace 失敗しサーバー宛がトンネル内をループする)
                      new_wan="$new_wan nexthop via $gw dev $ifx"
                    done
                  fi
                  [ -n "$new_wan" ] && wan_nexthops="$new_wan"
                  if [ -n "$wan_nexthops" ] && [ -n "$server_host" ]; then
                    if ! ip route replace $server_host $wan_nexthops 2>/dev/null; then
                      echo "mqvpn-path-keeper: server pin replace failed: ip route replace $server_host $wan_nexthops" >&2
                    fi
                  fi
                  # 2) router-local → tunnel の SNAT 確保 (tun_validate_src 対策)。
                  #    -o mqvpn+ で MASQUERADE すると out-dev addr に確定し常時一致する
                  #    (ECMP spray 維持、トンネル IP 変更にも追従)。LAN 側は既存 mark
                  #    規則と同値で無害。flush されても次ループで復旧する。
                  iptables -t nat -C nixos-nat-post -o "mqvpn+" -j MASQUERADE 2>/dev/null ||
                    iptables -t nat -A nixos-nat-post -o "mqvpn+" -j MASQUERADE 2>/dev/null || true
                  sleep 60
                done
              '';
            };
          };
        }
      ];

      environment.systemPackages = with pkgs; [
        git
        vim
        btop
        cfspeedtest
        ethtool
        iperf3
        live-chart
      ];

      # ---------------------------------------------------------------------
      # 10. ロケール
      # ---------------------------------------------------------------------

      time.timeZone = "Asia/Tokyo";
      console.keyMap = "jp106";

      # i18n.defaultLocale = "ja_JP.UTF-8";
      # fonts = {
      #   fontconfig.enable = true;
      #   packages = [
      #     pkgs.noto-fonts-cjk-sans
      #   ];
      # };
      # hardware.graphics.enable = true;
      # services.kmscon = {
      #   enable = true;
      #   # hwRender = true;
      #   config = {
      #     font-name = "Noto Sans Mono CJK JP";
      #     font-size = 14;
      #   };
      # };

      # ---------------------------------------------------------------------
      # 11. ブートローダー・システム状態バージョン
      # ---------------------------------------------------------------------
      boot.loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
        timeout = lib.mkForce 0;
      };
      system.stateVersion = "26.05";
    };
}
