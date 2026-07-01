{ config, pkgs, lib, ... }:

let
  # ---------------------------------------------------------------------
  # 1. MQVPNをソースコードからビルド
  # ---------------------------------------------------------------------
  mqvpn = pkgs.stdenv.mkDerivation rec {
    pname = "mqvpn";
    version = "0.8.0";

    src = pkgs.fetchFromGitHub {
      owner = "mp0rta";
      repo = "mqvpn";
      rev = "v${version}";
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      # git clone --recurse-submodules を再現
      fetchSubmodules = true;
    };

    # ビルドに必要なツール
    nativeBuildInputs = [ 
      pkgs.cmake 
      pkgs.pkg-config 
      pkgs.go 
      pkgs.perl 
      pkgs.gcc
    ];

    # 依存ライブラリ
    buildInputs = [ 
      pkgs.libevent 
    ];

    # Nix標準の自動CMake設定をスキップ
    dontUseCmakeConfigure = true;

    buildPhase = ''
      export HOME=$TMPDIR

      # 1. Build BoringSSL
      cd third_party/xquic/third_party/boringssl
      mkdir -p build && cd build
      cmake -DBUILD_SHARED_LIBS=0 -DCMAKE_C_FLAGS="-fPIC" -DCMAKE_CXX_FLAGS="-fPIC" ..
      make -j$NIX_BUILD_CORES ssl crypto
      cd ../../../../..

      # 2. Build xquic
      cd third_party/xquic
      mkdir -p build && cd build
      cmake -DCMAKE_BUILD_TYPE=Release -DSSL_TYPE=boringssl \
            -DSSL_PATH=../third_party/boringssl \
            -DXQC_ENABLE_BBR2=ON \
            -DXQC_ENABLE_FEC=ON \
            -DXQC_ENABLE_XOR=ON ..
      make -j$NIX_BUILD_CORES
      cd ../../..

      # 3. Build mqvpn
      mkdir -p build && cd build
      cmake -DCMAKE_BUILD_TYPE=Release \
            -DXQUIC_BUILD_DIR=../third_party/xquic/build ..
      make -j$NIX_BUILD_CORES
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp mqvpn $out/bin/
      chmod +x $out/bin/mqvpn
    '';
  };

in {
  # ---------------------------------------------------------------------
  # 2. ISOイメージ固有の設定（Live USB用）
  # ---------------------------------------------------------------------
  isoImage.isoName = "mqvpn-router.iso";
  isoImage.makeEfiBootable = true;
  isoImage.makeUsbBootable = true;

  # Live環境起動時に最初からネットワークを有効化する
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
    # マザーボード内蔵LAN
    internalInterfaces = [ "enp3s0" ]; 
    # 束ねた後の仮想インターフェース
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
      dhcp-range = "10.0.0.50,10.255.255.254,24h";
      dhcp-option = [
        "3,10.0.0.1" # ゲートウェイ
        "6,10.0.0.1" # DNS
      ];
    };
  };

  # 内蔵LANのIP固定化
  networking.interfaces.enp3s0.ipv4.addresses = [{
    address = "10.0.0.1";
    prefixLength = 32;
  }];

  # ---------------------------------------------------------------------
  # 5. WebUI（Cockpit）設定
  # ---------------------------------------------------------------------
  services.cockpit = {
    enable = true;
    port = 9090;
    openFirewall = true;
    # NetworkManagerをCockpitから操作できるようにする
    settings = {
      WebService = {
        AllowUnencrypted = true;
      };
    };
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

    # 起動時に設定ディレクトリとダミーファイルがなければ作成
    preStart = ''
      mkdir -p /var/lib/mqvpn
      if [ ! -f /var/lib/mqvpn/mqvpn.conf ]; then
        echo "# MQVPN Configuration" > /var/lib/mqvpn/mqvpn.conf
      fi
    '';
  };

  # ---------------------------------------------------------------------
  # 7. システムパッケージ & ロケール
  # ---------------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    mqvpn
    vim
    git
    networkmanager
  ];

  time.timeZone = "Asia/Tokyo";
  i18n.defaultLocale = "ja_JP.UTF-8";
}