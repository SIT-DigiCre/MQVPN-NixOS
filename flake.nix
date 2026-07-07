{
  description = "MQVPN Multi-WAN Router Live/Installer ISO";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
    in
    {
      nixosConfigurations = rec {
        iso = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./configuration.nix
            {
              image.baseName = lib.mkForce "mqvpn-router";
              # 試験の効率を上げるために、より軽量(低圧縮率)なアルゴリズムにしておく
              isoImage.squashfsCompression = "lz4";
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
              };
            }
          ];
        };
        router = iso // {
          modules = [
            ./configuration.nix
          ];
        };
      };
    };
}
