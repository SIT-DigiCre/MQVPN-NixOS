{
  lib,
  pkgs,
  ...
}:
let
  # eth0: ts-mgmt (管理 + 上流への出口) / eth1: ts-mq (router への 10.200.0.0/24)
  # eth2: ts-ext (mnet VM 192.168.100.1 へのベンチ用出口)
  vmLanInterface = "eth1";
  vmWanInterface = "eth0";
  mqvpnServerSubnet = "192.168.0.0/24";
  mqvpnAuthKey = "mqvpn-test-key-2024";
  localIp = "10.200.99.2";

  mqvpnImage = (import ../container/mqvpn-server-image.nix { inherit pkgs; }).image;
  mqvpnPromImage = (import ../container/mqvpn-prometheus-image.nix { inherit pkgs; }).image;
  mqvpnGrafanaImage = (import ../container/mqvpn-grafana-image.nix { inherit pkgs; }).image;

  mqvpnCerts =
    pkgs.runCommand "mqvpn-certs"
      {
        nativeBuildInputs = [ pkgs.openssl ];
      }
      ''
        openssl ecparam -genkey -name prime256v1 -noout -out key.pem
        openssl req -new -x509 -key key.pem -out cert.pem -days 3650 \
          -subj "/CN=mqtt-server.local" -addext "subjectAltName=DNS:mqtt-server.local,IP:${localIp}"
        mkdir -p $out
        cp key.pem cert.pem $out/
      '';

  # コンテナは /etc/mqvpn/ 配下を参照する
  mqvpnServerBase = {
    mode = "server";
    listen = "0.0.0.0:443";
    subnet = mqvpnServerSubnet;
    tun_name = "mqvpn0";
    cert_file = "/etc/mqvpn/server.crt";
    key_file = "/etc/mqvpn/server.key";
    auth_key = mqvpnAuthKey;
    control_listen = "127.0.0.1:9090";
    log_level = "info";
    reinjection = "deadline";
    reorder = {
      enabled = "on";
      max_wait_ms = 100;
      cap_packets = 4096;
    };
    hybrid = {
      enabled = false;
      tcp = "auto";
      tcp_max_flows = 2048;
    };
  };

  # サーバー設定は 1 つの config を全インスタンスで共有する。
  # 差別化は ENV (MQVPN_SUBNET) + ポートフォワードのみ (compose 側で表現)
  mqvpnConf = pkgs.writeText "mqvpn-server.conf" (builtins.toJSON mqvpnServerBase);

  # compose 一式を 1 つの store ディレクトリに固める (compose の相対パス解決のため)。
  # prometheus / grafana は設定焼き込み済みの nix イメージを使うため、
  # ここに必要なのは compose ファイル + サーバー設定のみ。
  composeDir = pkgs.stdenv.mkDerivation {
    name = "mqvpn-compose-dir";
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/mqvpn-server-conf
      cp ${../container/docker-compose.yml} $out/docker-compose.yml
      cp -r ${mqvpnSrv}/* $out/mqvpn-server-conf/
    '';
  };

  # compose がマウントするサーバー設定 (server.conf / server.crt / server.key) を store から供給
  mqvpnSrv = pkgs.runCommand "mqvpn-srv" { } ''
    mkdir -p $out
    cp ${mqvpnConf} $out/server.conf
    cp ${mqvpnCerts}/cert.pem $out/server.crt
    cp ${mqvpnCerts}/key.pem $out/server.key
  '';
in
{
  networking.hostName = lib.mkForce "mogami-server";
  # VM ビルダーが net.ifnames=0 を kernel param に足すため interface 名は常に ethX

  networking.useDHCP = false;

  # eth0: mgmt (SSH 管理) + 上流への出口 (defaultGateway でホスト経由)
  networking.interfaces."${vmWanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.50.2";
        prefixLength = 24;
      }
    ];
  };

  networking.interfaces."${vmLanInterface}" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = localIp;
        prefixLength = 24;
      }
    ];
    # サーバーは mqvpn-srv2-br0 (10.200.99.0/24) に居り、ルーターからは
    # ホスト(ISP シム)経由の経路で到達する (WAN ブリッジ mqvpn-srv-br0 には非隣接)。
    # 各 WAN /24 (10.200.i.0/24) はホスト(10.200.99.1)経由で到達し、トンネル復路
    # (サーバー → クライアントの WAN IP) が通る。
    ipv4.routes = [
      {
        address = "10.200.0.0";
        prefixLength = 16;
        via = "10.200.99.1";
      }
    ];
  };

  # eth2: ts-ext (mnet へのベンチ用出口)
  networking.interfaces.eth2 = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "192.168.100.2";
        prefixLength = 24;
      }
    ];
  };

  # detect_iface は default route から出口 NIC を決める (無いと NAT が組まれない)
  networking.defaultGateway = "192.168.50.254";
  networking.nameservers = [ "1.1.1.1" ]; # compose のイメージ pull 用

  services.qemuGuest.enable = true;

  # net.* sysctl はコンテナから書けないためホスト側で有効化
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # host-net コンテナの mqvpn-server-nat.sh は「デフォルトルートの iface」
  # (= mgmt eth0) だけを MASQUERADE 対象にする。ベンチの ext 島 (192.168.100.0/24,
  # eth2 経由) へ抜ける復路が mnet でルーティング不能になるため、トンネル src の
  # eth2 向け SNAT を追加する (実機サーバーでは WAN がデフォルト iface なので不要)。
  networking.nat = {
    enable = true;
    externalInterface = "eth2";
    internalInterfaces = [ "mqvpn0" "mqvpn1" "mqvpn2" ];
  };

  virtualisation.docker.enable = true;
  virtualisation.docker.autoPrune.enable = true;
  virtualisation.diskSize = 12288;

  boot.kernelModules = [ "tun" ];
  systemd.tmpfiles.rules = [ "c /dev/net/tun 0600 root root 10 200" ];

  # 実環境と共通の compose をそのまま実行する。up はフォアグラウンド必須
  # (-d だとユニットが終了扱いになり ExecStop の down が全コンテナを消す)
  systemd.services = {
    "mqvpn-compose" = {
      description = "MQVPN servers + monitoring (docker compose)";
      after = [
        "docker.service"
        "network-online.target"
      ];
      wants = [
        "docker.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];

      path = [
        pkgs.docker
        pkgs.docker-compose
      ];

      serviceConfig = {
        ExecStartPre = [
          "${pkgs.docker}/bin/docker load -i ${mqvpnImage}"
          "${pkgs.docker}/bin/docker load -i ${mqvpnPromImage}"
          "${pkgs.docker}/bin/docker load -i ${mqvpnGrafanaImage}"
        ];
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f ${composeDir}/docker-compose.yml up --remove-orphans";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${composeDir}/docker-compose.yml down";
        Restart = "on-failure";
        RestartSec = "10";
      };
    };
  };

  virtualisation.vmVariant = {
    virtualisation.graphics = false;
    virtualisation.qemu.options = [ ];
    virtualisation.qemu.networkingOptions = lib.mkForce [
      "-nic tap,ifname=ts-mgmt,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:58"
      "-nic tap,ifname=ts-mq,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:59"
      "-nic tap,ifname=ts-ext,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:12:34:60"
    ];
  };

  hardware.enableRedistributableFirmware = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
      KbdInteractiveAuthentication = true;
    };
  };

  users.users.digicre = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = null;
    password = "server";
  };

  security.sudo.wheelNeedsPassword = false;

  networking.firewall.allowedTCPPorts = [
    22 # SSH
    3000 # grafana (browser アクセス用)
  ];
  networking.firewall.allowedUDPPorts = [
    443
    444
    445
  ];

  boot.initrd.systemd.enable = false;

  system.stateVersion = "26.05";

  environment.systemPackages = with pkgs; [
    iperf3
    perf
  ];
}
