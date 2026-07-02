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

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.libevent
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
  # ---------------------------------------------------------------------
  # 1. ホスト名をもがみにする
  # ---------------------------------------------------------------------
  networking.hostName = "mogami";

  # ---------------------------------------------------------------------
  # 2. ISOイメージ固有の設定
  # ---------------------------------------------------------------------
  image.fileName = "mqvpn-router.iso";
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;
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
    # externalInterface = "enp1s0f2";
  };

  networking.interfaces."mqvpn0".ipv4.routes = [
    {
      address =
        let
          addr = (builtins.fromJSON (builtins.readFile ./mqvpn.conf)).server_addr;
        in
        builtins.head (lib.splitString ":" addr);
      prefixLength = 32;
    }
  ];

  # ---------------------------------------------------------------------
  # 4. LAN側：DHCP/DNSサーバー（dnsmasq）
  # ---------------------------------------------------------------------
  networking.interfaces."${internalInterfaceName}".ipv4.addresses = [
    {
      address = localIp;
      prefixLength = 8;
    }
  ];

  # services.dnsmasq = {
  #   enable = true;
  #   settings = {
  #     interface = internalInterfaceName;
  #     bind-interfaces = true;
  #     listen-address =
  #       (builtins.head config.networking.interfaces."${internalInterfaceName}".ipv4.addresses).address;
  #     dhcp-range = "10.0.0.50,10.255.255.254,24h";
  #     dhcp-option = [
  #       "3,10.0.0.1" # デフォルトゲートウェイ
  #       "6,10.0.0.1" # DNSサーバ
  #     ];
  #     log-dhcp = true;
  #   };
  # };
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      interfaces-config = {
        interfaces = [ internalInterfaceName ];
      };
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
      80 # netdata用(下記)
      8080
    ];
    allowedUDPPorts = [ 53 ];
  };

  # ---------------------------------------------------------------------
  # 5. WebUI（Cockpit）設定
  # ---------------------------------------------------------------------
  services.cockpit = {
    enable = true;
    port = 9090;
    openFirewall = true;
    settings.WebService.AllowUnencrypted = true;
  };

  services.netdata = {
    enable = true;
    config.global."bind to" = "0.0.0.0:8080";
    user = "root";
  };

  # ---------------------------------------------------------------------
  # 6. MQVPN Systemdサービス
  # ---------------------------------------------------------------------
  systemd.services.mqvpn = {
    description = "Multi-Queue VPN Tunnel Daemon";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${mqvpn}/bin/mqvpn --config ${./mqvpn.conf}";
      Restart = "always";
      RestartSec = "5s";
      StateDirectory = "mqvpn";
    };
  };

  environment.systemPackages = with pkgs; [
    vim
    yazi
    btop
    speedtest-cli
  ];

  time.timeZone = "Asia/Tokyo";
  # i18n.defaultLocale = "ja_JP.UTF-8";

  console.keyMap = "jp106";
}
