{ config, pkgs, lib, ... }:

let
  # ---------------------------------------------------------------------
  # 1. MQVPN バイナリ組み込み定義（コンパイル不要・超高速ビルド版）
  # ---------------------------------------------------------------------
  mqvpn = pkgs.stdenv.mkDerivation rec {
    pname = "mqvpn-binary";
    version = "0.8.0";

    # GitHub Releasesからコンパイル済みのバイナリを直接取得します。
    # ※実際のファイル名（tar.gzか単一バイナリか等）に合わせてURLを微調整してください。
    src = pkgs.fetchurl {
      url = "https://github.com/mp0rta/mqvpn/releases/download/v${version}/mqvpn_${version}_amd64.tar.gz";
      # ダミーハッシュ。初回ビルド時のエラーで本物のハッシュに書き換えます。
      sha256 = "sha256-ENDGF3lIGwlwo+9QjuGoJyXX2nSyc09KMS5sTenoUfA=";
    };

    # NixOS環境で外部バイナリを動かすための魔法（依存ライブラリのパスを自動解決）
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    
    # MQVPN（C/Go）が動的リンクで必要としそうなライブラリ群
    buildInputs = [ 
      pkgs.stdenv.cc.cc.lib 
      pkgs.libevent 
    ];

    # アーカイブを展開した後のディレクトリ
    sourceRoot = ".";

    installPhase = ''
      mkdir -p $out/bin
      # 展開されたファイルの中から mqvpn 実行バイナリを探して配置
      find . -type f -name "*mqvpn*" -executable -exec install -m755 {} $out/bin/mqvpn \;
    '';
  };

in {
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
  boot.kernel.sysctl = { "net.ipv4.ip_forward" = 1; };
  networking.firewall.enable = true;
  networking.nat = {
    enable = true;
    internalInterfaces = [ "enp3s0" ]; 
    externalInterface = "mqvpn0"; 
  };

  # ---------------------------------------------------------------------
  # 4. LAN側：DHCP/DNSサーバー（dnsmasq）
  # ---------------------------------------------------------------------
  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "enp3s0";
      bind-interfaces = true;
      listen-address = "10.0.0.1";
      dhcp-range = "10.0.0.50,10.0.0.254,24h";
      dhcp-option = [ "3,10.0.0.1" "6,10.0.0.1" ];
    };
  };

  networking.interfaces.enp3s0.ipv4.addresses = [{
    address = "10.0.0.1";
    prefixLength = 24;
  }];

  # ---------------------------------------------------------------------
  # 5. WebUI（Cockpit）設定
  # ---------------------------------------------------------------------
  services.cockpit = {
    enable = true;
    port = 9090;
    openFirewall = true;
    settings.WebService.AllowUnencrypted = true;
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
      ExecStart = "${mqvpn}/bin/mqvpn --config /var/lib/mqvpn/mqvpn.conf";
      Restart = "always";
      RestartSec = "5s";
      User = "root";
    };

    preStart = ''
      mkdir -p /var/lib/mqvpn
      if [ ! -f /var/lib/mqvpn/mqvpn.conf ]; then
        echo "# MQVPN Configuration" > /var/lib/mqvpn/mqvpn.conf
      fi
    '';
  };

  environment.systemPackages = with pkgs; [
    mqvpn
    vim
    git
    networkmanager
  ];

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "ja_JP.UTF-8";
}
