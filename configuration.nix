{
  pkgs,
  config,
  lib,
  ...
}:
let
  mqvpn = pkgs.callPackage ./patches/mqvpn-src.nix { };

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

  internalInterfaceName = "enp6s0";
  localIp = "172.16.0.1";

in
{
  options.services.mqvpn.interfaces = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "enp1s0f0"
      "enp1s0f3"
    ];
    description = "NICs used by MQVPN multi-WAN paths";
  };

  options.services.mqvpn.auth = lib.mkOption {
    type = lib.types.anything;
    default = builtins.fromJSON (builtins.readFile ./mqvpn-auth.json);
    description = "MQVPN client auth config (server_addr, auth_key, etc.)";
  };

  options.services.mqvpn.hybrid = lib.mkOption {
    type = lib.types.anything;
    default = {
      enabled = true;
      tcp = "auto";
    };
    description = "MQVPN hybrid TCP lane config";
  };

  config =
    let
      mqvpnAuth = config.services.mqvpn.auth;

      mqvpnConfig = pkgs.writeText "mqvpn.conf" (
        builtins.toJSON (
          {
            mode = "client";
            insecure = true;
            tun_name = "mqvpn0";
            dns = [
              "9.9.9.9"
              "1.1.1.1"
            ];
            log_level = "debug";
            kill_switch = false;
            reconnect = true;
            reconnect_interval = 5;
            scheduler = "wlb";
            mtu = 1300;
            manage_routes = false;
            hybrid = config.services.mqvpn.hybrid;
            paths = config.services.mqvpn.interfaces;
          }
          // mqvpnAuth
        )
      );
    in
    {
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
        "C /etc/nixos 0755 root root - ${./.}"
        "C /home/digicre/mqvpn-router 0755 digicre users - ${./.}"
      ];

      # ---------------------------------------------------------------------
      # 3. ルーティング & ファイアウォール
      # ---------------------------------------------------------------------
      boot.kernelPackages = pkgs.linuxPackages_latest;
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
      };
      networking.firewall.enable = true;
      networking.nat = {
        enable = true;
        internalInterfaces = [ internalInterfaceName ];
        externalInterface = "mqvpn0";
      };

      # ---------------------------------------------------------------------
      # 4. LAN側：DHCP/DNSサーバー
      # ---------------------------------------------------------------------

      systemd.services.kea-dhcp4-server = {
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
      # 9. MQVPN
      # ---------------------------------------------------------------------
      systemd.services.mqvpn = {
        description = "Multi-Queue VPN Tunnel Daemon";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        path = with pkgs; [
          iproute2
          iptables
          bash
        ];

        serviceConfig = {
          ExecStart = "${mqvpn}/bin/mqvpn --config ${mqvpnConfig}";
          Restart = "always";
          RestartSec = "5s";
          StateDirectory = "mqvpn";
        };
      };

      environment.systemPackages = with pkgs; [
        git
        vim
        btop
        cfspeedtest
        ethtool
        iperf3
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
      boot.zfs.forceImportRoot = false;

      system.stateVersion = "26.05";
    };
}
