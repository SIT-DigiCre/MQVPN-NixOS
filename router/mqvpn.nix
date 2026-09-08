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
      mqvpn = pkgs.callPackage ../pkgs/mqvpn-dbg.nix { };

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

      # クライアント config 一覧。
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

      # keeper スクリプトへ展開する WAN IF 一覧とサーバー IP
      wanIfaces = lib.concatStringsSep " " config.services.mqvpn.interfaces;
      serverHost = mqvpnAuth.server_addr or "";
    in
    {
      # 各クライアントの systemd unit
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
          # ルートキーパー (server pin + tunnel SNAT の維持)。
          # ECMP ライフサイクルは systemd-networkd が担う (下記参照)。
          #  - サーバー制御プレーン経路のピン (manage_routes=false のため上流の setup_routes
          #    は動かない。WAN デフォルトが消えても <server>/32 を GW 経由で維持する。
          #    GW は可視デフォルト優先。消失時は networkd reconfigure で自癒し、
          #    変化時のみ pin を更新
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
                # 最後に観測した WAN デフォルトの nexthops (GW 変更凍結の防止 — 前回の記憶)
                wan_nexthops=""
                while true; do
                  # 1) WAN GW の発見 (可視デフォルト優先) + サーバーピン
                  #    (/32 を nexthop 1 回で replace。IF ごとに分けると
                  #    最後の 1 本しか残らない)。
                  #    デフォルト消失時 (carrier はあるのに経路だけ無い) は
                  #    networkd に reconfigure させて DHCP 取り直しで自癒する
                  #    (復旧は次ループで可視デフォルトとして読む。今回は pin の
                  #    前回記憶を維持するためスキップ)。
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
        };

      # ECMP ライフサイクル (systemd-networkd)。
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

      # トンネル MTU(1382) 超の TCP セグメントはトンネル内で IP フラグメント化され、
      # オーバーヘッド/フラグメントロスで数割劣化する。FORWARD で MSS を出口 IF の
      # PMTU にクランプし、断片化を事前回避する (SLiRP 等 ICMP が戻らない環境では
      # 完全ブラックホールを防ぐ保険にもなる)。
      networking.firewall.extraCommands = ''
        iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      '';
    };
}
