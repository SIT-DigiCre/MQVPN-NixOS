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
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;

      nixosConfigurations = {
        iso = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
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
                "C /home/nixos/mqvpn-router 0755 nixos users - ${./.}"
                "C+ /home/nixos/install.sh 0755 nixos users - ${./install.sh}"
                "C+ /root/mqvpn-router 0750 root root - ${./.}"
              ];

              # インストーラー環境にdisko-installコマンドをプリインストール
              environment.systemPackages = [
                disko.packages.x86_64-linux.disko-install
              ];

              console.keyMap = "jp106";
            }
          ];
        };
        mogami = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            impermanence.nixosModules.impermanence
            ./persistence.nix
            ./configuration.nix
          ];
        };
        mogami-vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            impermanence.nixosModules.impermanence
            ./persistence.nix
            ./configuration.nix
            ./test/mogami-vm.nix
          ];
        };
        mogami-client = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-client.nix
          ];
        };
        mogami-server = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-server.nix
            {
              virtualisation.vmVariant = {
                virtualisation.graphics = false;
                virtualisation.forwardPorts = [ ];
                virtualisation.qemu.networkingOptions = lib.mkForce [
                  "-nic user,hostfwd=tcp::2224-:22,model=virtio-net-pci"
                  "-nic tap,ifname=ts-mq,script=no,downscript=no,model=virtio-net-pci"
                ];
              };
            }
          ];
        };
      };
    };
}
