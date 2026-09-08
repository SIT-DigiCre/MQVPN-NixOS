{
  description = "MQVPN Multi-WAN Router Live/Installer ISO and Router Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence.url = "github:nix-community/impermanence";

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      nix-index-database,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      commonModules = [
        nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
      ];
    in
    {
      formatter.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = with pkgs; [
            treefmt
            nixfmt
            shfmt
          ];
          text = ''exec treefmt "$@"'';
        };

      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          mqvpnServerOci = import ./container/mqvpn-server-image.nix { inherit pkgs; };
          mqvpnPrometheusOci = import ./container/mqvpn-prometheus-image.nix { inherit pkgs; };
          mqvpnGrafanaOci = import ./container/mqvpn-grafana-image.nix { inherit pkgs; };
          # 3イメージを1バンドル化 (ビルド/loadを1コマンドに。compose同梱で版本一致)。
          mqvpnComposeFile = pkgs.callPackage ./container/mqvpn-compose-file.nix { };
          mqvpnOciBundle = pkgs.runCommand "mqvpn-oci-bundle" { } ''
            mkdir -p $out
            ln -s ${mqvpnServerOci.image} $out/mqvpn-server.tar
            ln -s ${mqvpnPrometheusOci.image} $out/mqvpn-prometheus.tar
            ln -s ${mqvpnGrafanaOci.image} $out/mqvpn-grafana.tar
            cp ${mqvpnComposeFile} $out/docker-compose.yml
            cat > $out/load-all.sh <<'EOF'
            #!/bin/sh
            d=$(cd "$(dirname "$0")" && pwd)
            for f in mqvpn-server.tar mqvpn-prometheus.tar mqvpn-grafana.tar; do
              docker load -i "$d/$f" || exit 1
            done
            echo "mqvpn OCI images loaded"
            EOF
            chmod +x $out/load-all.sh
          '';
        in
        {
          mqvpn-oci = mqvpnOciBundle;
        };

      nixosConfigurations = {
        iso = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            {
              image.baseName = lib.mkForce "mqvpn-router";
              # 試験効率のため軽量圧縮。
              isoImage.squashfsCompression = "lz4";
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
              };

              zramSwap.enable = true;

              # 導入対象を事前ビルドして同梱 (インストール時の負荷軽減)。
              system.extraDependencies = [
                self.nixosConfigurations.mogami.config.system.build.toplevel
              ];

              systemd.tmpfiles.rules = [
                "C /home/nixos/mqvpn-router 0755 nixos users - ${./.}"
                "C /home/nixos/install-router.sh 0755 nixos users - ${./install-router.sh}"
              ];

              environment.systemPackages = [
                disko.packages.x86_64-linux.disko-install
              ];

              console.keyMap = "jp106";
            }
          ]
          ++ commonModules;
        };
        mogami = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            impermanence.nixosModules.impermanence
            ./persistence.nix
            ./router
          ]
          ++ commonModules;
        };
        mogami-vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./router
            ./test/mogami-vm.nix
          ]
          ++ commonModules;
        };
        mogami-client = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-client.nix
          ]
          ++ commonModules;
        };
        mogami-server = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-server.nix
          ]
          ++ commonModules;
        };
        mogami-mnet = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-mnet.nix
          ]
          ++ commonModules;
        };
      };
    };
}
