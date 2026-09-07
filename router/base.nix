{
  pkgs,
  config,
  lib,
  ...
}:
let
  live-chart = pkgs.callPackage ../pkgs/live-chart.nix { };

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
in
{
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ rtl8127-firmware ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
    timeout = lib.mkForce 0;
  };
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  system.stateVersion = "26.05";

  # リポジトリ全体をシステムに配置
  systemd.tmpfiles.rules = [
    "C /home/digicre/mqvpn-router 0755 digicre users - ${./..}"
    "Z /home/digicre/mqvpn-router/.git 0755 digicre users - -"
  ];

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

  # sudo（wheelはパスワード不要）
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.glances = {
    enable = true;
    openFirewall = true;
    port = 80;
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    btop
    cfspeedtest
    ethtool
    iperf3
    live-chart
  ];

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
