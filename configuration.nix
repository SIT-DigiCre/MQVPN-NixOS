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
    default = [
      "enp1s0f0"
      "enp1s0f1"
      "enp1s0f2"
      "enp1s0f3"
      "enp6s0"
      "enp8s0"
      "enp9s0"
    ];
    description = "NICs used by MQVPN multi-WAN paths";
  };

  options.services.mqvpn.auth = lib.mkOption {
    type = lib.types.anything;
    default = builtins.fromJSON (builtins.readFile ./mqvpn-auth.json);
    description = ''
      MQVPN クライアントのシークレット設定: auth_key とサーバー IP (server_addr は
      **IP のみ**。port を含めてはならない — port は公開情報で services.mqvpn.clientPorts
      が供給)。server_addr / auth_key は全クライアント共通で、クライアントごとに
      ファイルを分けることはできない (複数クライアントは clientPorts の port のみで区別)。
    '';
  };

  options.services.mqvpn.clientPorts = lib.mkOption {
    type = lib.types.listOf lib.types.port;
    default = [ 443 444 ];
    description = ''
      クライアントの接続先 server port リスト。サーバー IP (auth.server_addr) と
      WAN NIC (interfaces) は全クライアント共通のため、port のみ個別指定する。
      0-indexed: unit は mqvpn-0, mqvpn-1, ...、TUN 名は mqvpn0, mqvpn1, ... と
      リスト順に自動付与。ECMP weight は全トンネル 1 (共通 NIC セットのため不変)。
    '';
  };

  options.services.mqvpn.hybrid = lib.mkOption {
    type = lib.types.anything;
    default = {
      enabled = false;
      tcp = "auto";
      tcp_max_flows = 2048;
    };
   description = "MQVPN hybrid TCP lane config";
  };

  options.services.mqvpn.lanInterface = lib.mkOption {
    type = lib.types.str;
    default = "enp10s0";
    description = "LAN-facing interface (kea DHCP / NAT / 起動待機の対象)";
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
        cc = "bbr";
        reinjection = "deadline";
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

      # ECMP 対象のトンネル一覧 (dev + weight=1)。peer はサーバーから配布されるため
      # 設定値を持たず、ECMP keeper が実行時にカーネルから導出する。
      ecmpTunnels = map (c: {
        dev = c.tunName;
        weight = 1;
      }) mqvpnClientConfigs;

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

      # ---------------------------------------------------------------------
      # 2. 基本設定
      # ---------------------------------------------------------------------
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
              option-data = [
                {
                  name = "routers";
                  data = localIp;
                }
                {
                  name = "domain-name-servers";
                  data = localIp;
                }
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
        # ルートキーパー:
        #  - サーバー制御プレーン経路のピン (manage_routes=false のため上流の setup_routes
        #    は動かない。WAN デフォルトが消えても <server>/32 を GW 経由で維持する)
        #  - ECMP デフォルトの再アサート (tun 再作成時はカーネルが ECMP ルートを全削除。
        #    生存トンネルのみでアサートし、1 本でも生きていれば必ず張る)
        #  - fail-open: 全トンネル死亡時は WAN デフォルトを復元
        {
          mqvpn-ecmp-assert = {
            description = "ECMP default / server-pin route keeper";
            after = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wants = [ "network-online.target" ] ++ map (c: "${c.unitName}.service") mqvpnClientConfigs;
            wantedBy = [ "multi-user.target" ];

            path = with pkgs; [
              iproute2
              gawk
              # fail-open / ピン用 GW の補完発見 (dhcpcd -U で現在リースを読む)
              dhcpcd
            ];

            serviceConfig = {
              Restart = "always";
              RestartSec = "5";
              ExecStart = pkgs.writeShellScript "mqvpn-ecmp-assert.sh" ''
                # peer はサーバーから配布されるため kernel から導出する
                peer_of() {
                  ip -o addr show dev "$1" |
                    awk '$3=="inet" { for (i=1; i<=NF; i++) if ($i=="peer") { split($(i+1), a, "/"); print a[1]; break } }'
                }
                wan_ifaces="${wanIfaces}"
                server_host="${serverHost}"
                # 最後に観測した WAN デフォルトの nexthops (トンネル稼働中は ECMP に置換され
                # 見えないため、復元用にループ間で保持 — 前回の記憶)
                wan_nexthops=""
                wan_restored=""
                while true; do
                  # 1) WAN GW の発見 (可視デフォルト優先、無ければ dhcpcd リースで補完 —
                  #    GW 変更凍結の防止) + サーバーピン (/32 を nexthop 1 回で
                  #    replace。IF ごとに分けると最後の 1 本しか残らない)
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
                      echo "mqvpn-ecmp-assert: server pin replace failed: ip route replace $server_host $wan_nexthops" >&2
                    fi
                  fi

                  # 2) 生存トンネル集合を nhid グループ (id 2000) に同期して ECMP デフォルトを張る。
                  #    tun 再作成でカーネルが nh ごと削除してもグループは自動縮退し
                  #    ルートは生存メンバーで継続 (旧方式の全削除黒塗りが消える)。
                  #    全滅時はカーネルがグループ/ルートを消す → fail-open へ。
                  members=""
                  ${lib.concatStringsSep "\n" (
                    lib.imap1 (i: t: ''
                      dev="${t.dev}"
                      nhid=$((1000 + ${toString i}))
                      peer=$(peer_of "$dev")
                      if [ -n "$peer" ]; then
                        # PtP トンネル(mqvpn*) は dev のみでピアが確定する。
                        # `via $peer` は mqvpn0 が副アドレス(192.168.0.2/32 brd ...)を
                        # 持つ場合に "invalid gateway" で失敗するため dev のみを指定。
                        ip nexthop add id $nhid dev $dev 2>/dev/null ||
                          ip nexthop replace id $nhid dev $dev 2>/dev/null ||
                          echo "mqvpn-ecmp-assert: nexthop $nhid sync failed ($dev)" >&2
                        members="$members/$nhid"
                      else
                        ip nexthop del id $nhid 2>/dev/null
                      fi
                    '') ecmpTunnels
                  )}
                  if [ -n "$members" ]; then
                    m="''${members#/}"
                    ip nexthop add id 2000 group "$m" 2>/dev/null ||
                      ip nexthop replace id 2000 group "$m" 2>/dev/null ||
                      echo "mqvpn-ecmp-assert: group 2000 sync failed ($m)" >&2
                    if ! ip route replace default nhid 2000 2>/dev/null; then
                      echo "mqvpn-ecmp-assert: default nhid 2000 replace failed (members=$m)" >&2
                    fi
                    wan_restored=""
                  else
                    # fail-open: 全トンネル死亡時は WAN デフォルトを復元。
                    # 遷移時のみ成功ログ、失敗は毎ループログ (自己修復までの診断用)
                    if [ -n "$wan_nexthops" ]; then
                      if ip route replace default $wan_nexthops 2>/dev/null; then
                        [ -z "$wan_restored" ] && echo "mqvpn-ecmp-assert: fail-open: WAN default restored ($wan_nexthops)" >&2
                        wan_restored=1
                      else
                        echo "mqvpn-ecmp-assert: fail-open FAILED: $wan_nexthops (retry next loop)" >&2
                        wan_restored=""
                      fi
                    fi
                  fi
                  sleep 3
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
