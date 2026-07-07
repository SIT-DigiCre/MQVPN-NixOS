{
  description = "MQVPN Multi-WAN Router Live/Installer ISO and Router Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";
  };

  outputs =
    {
      nixpkgs,
      disko,
      impermanence,
      ...
    }:
    let
      inherit (nixpkgs) lib;
    in
    {
      nixosConfigurations = {
        iso = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            # 適当に使ってみたら名前解決ができなかったので、とりあえず無効にする(これで直った)
            # ./configuration.nix
            {
              image.baseName = lib.mkForce "mqvpn-router";
              # 試験の効率を上げるために、より軽量(低圧縮率)なアルゴリズムにしておく
              isoImage.squashfsCompression = "lz4";
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
              };

              # リポジトリ全体をライブ環境にコピー
              systemd.tmpfiles.rules = [
                "C+ /home/nixos/mqvpn-router 0755 nixos users - ${./.}"
                "C+ /home/nixos/install.sh 0755 nixos users - ${./install.sh}"
                "C+ /root/mqvpn-router 0750 root root - ${./.}"
              ];

              # インストーラー環境にdisko-installコマンドをプリインストール
              environment.systemPackages = [
                disko.packages.x86_64-linux.disko-install
              ];
            }
          ];
        };
        router = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            impermanence.nixosModules.impermanence
            ./persistence.nix
            ./configuration.nix
            {
              users.users.digicre = {
                isNormalUser = true;
                extraGroups = [ "wheel" ];
                hashedPassword = "$y$j9T$TGjAbr5yoNT4sgFdsZyRN0$8TrbfpDZw5KH2PHQLVW2QZ1xrtvG75mK9vyjX0qVxE1";
              };
            }
          ];
        };
      };
    };
}
