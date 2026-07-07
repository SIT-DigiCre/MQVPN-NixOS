{
  pkgs,
  config,
  lib,
  ...
}:

let
  mqvpn = pkgs.stdenv.mkDerivation rec {
    pname = "mqvpn-binary";
    version = "0.8.0";

    # GitHub Releasesからコンパイル済みのバイナリを直接取得します。
    src = pkgs.fetchurl {
      url = "https://github.com/mp0rta/mqvpn/releases/download/v${version}/mqvpn_${version}_amd64.tar.gz";
      sha256 = "sha256-ENDGF3lIGwlwo+9QjuGoJyXX2nSyc09KMS5sTenoUfA=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    buildInputs = with pkgs; [
      stdenv.cc.cc.lib
      libevent
    ];

    # アーカイブを展開した後のディレクトリ
    sourceRoot = ".";

    installPhase = ''
      install -Dm755 bin/mqvpn -t $out/bin
      install -Dm644 lib/libmqvpn.so* lib/libxquic.so -t $out/lib
    '';
  };

  internalInterfaceName = "enp17s0f1";
  localIp = "172.16.0.1";
in
{
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # ---------------------------------------------------------------------
  # 1. ホスト名をもがみにする
  # ---------------------------------------------------------------------
  networking.hostName = "mogami";

  # ---------------------------------------------------------------------
  # 2. ISOイメージ固有の設定
  # ---------------------------------------------------------------------
  networking.networkmanager.enable = true;

  # ---------------------------------------------------------------------
  # 3. ルーティング & ファイアウォール
  # ---------------------------------------------------------------------
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  networking.firewall.enable = true;
  networking.nat = {
    enable = true;
    internalInterfaces = [ internalInterfaceName ];
    externalInterface = "mqvpn0";
  };

  networking.interfaces."mqvpn0".ipv4.routes = [
    {
      address =
        let
          addr = (builtins.fromJSON (builtins.readFile ./mqvpn.conf)).server_addr;
        in
        builtins.head (lib.splitString ":" addr);
      prefixLength = 32;
      via = "10.0.0.1";
    }
  ];

  # ---------------------------------------------------------------------
  # 4. LAN側：DHCP/DNSサーバー
  # ---------------------------------------------------------------------
  networking.interfaces."${internalInterfaceName}".ipv4.addresses = [
    {
      address = localIp;
      prefixLength = 12;
    }
  ];

  systemd.services.kea-dhcp4-server = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    preStart = ''
      echo "Waiting for interface ${internalInterfaceName} to be Running..."
      for i in {1..120}; do
        if ${pkgs.iproute2}/bin/ip link show dev "${internalInterfaceName}" 2>/dev/null | grep -q "UP"; then
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
      53
      8080 # netdata用(下記)
    ];
    allowedUDPPorts = [
      53
      67
    ];
  };

  # ---------------------------------------------------------------------
  # 5. WebUI設定
  # ---------------------------------------------------------------------

  services.glances = {
    enable = true;
    openFirewall = true;
    port = 80;
  };

  # ---------------------------------------------------------------------
  # 6. MQVPN Systemdサービス
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
      iperf3
    ];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${./mqvpn.conf}";
      Restart = "always";
      RestartSec = "5s";
      StateDirectory = "mqvpn";
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    btop
    speedtest-cli
  ];

  # ---------------------------------------------------------------------
  # 7. ロケール
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
}
