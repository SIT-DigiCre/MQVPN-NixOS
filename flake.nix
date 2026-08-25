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
    { self, nixpkgs, disko, impermanence, nix-index-database, ... }:
    let
      inherit (nixpkgs) lib;

      commonModules = [
        nix-index-database.nixosModules.nix-index
        { programs.nix-index-database.comma.enable = true; }
      ];
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt;

      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          mqvpnServerOci = import ./container/mqvpn-server-image.nix { inherit pkgs; };
          mqvpnPrometheusOci = import ./container/mqvpn-prometheus-image.nix { inherit pkgs; };
          mqvpnGrafanaOci = import ./container/mqvpn-grafana-image.nix { inherit pkgs; };
          # 3 イメージを 1 つのバンドルにまとめる (ビルド/ロードを 1 コマンドに)。
          # 出力ディレクトリに各 tar への symlink と、docker load 一括スクリプトを置く。
          mqvpnOciBundle = pkgs.runCommand "mqvpn-oci-bundle" { } ''
            mkdir -p $out
            ln -s ${mqvpnServerOci.image} $out/mqvpn-server.tar
            ln -s ${mqvpnPrometheusOci.image} $out/mqvpn-prometheus.tar
            ln -s ${mqvpnGrafanaOci.image} $out/mqvpn-grafana.tar
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
              # 試験の効率を上げるために、より軽量(低圧縮率)なアルゴリズムにしておく
              isoImage.squashfsCompression = "lz4";
              isoImage = {
                makeEfiBootable = true;
                makeUsbBootable = true;
              };

              zramSwap.enable = true;

              # インストール対象のシステムを事前ビルドしてISOに含める（インストール時の負荷軽減）
              system.extraDependencies = [
                self.nixosConfigurations.mogami.config.system.build.toplevel
              ];

               # リポジトリ全体をライブ環境にコピー
               systemd.tmpfiles.rules = [
                 "C /home/nixos/mqvpn-router 0755 nixos users - ${./.}"
                 "C /home/nixos/install-router.sh 0755 nixos users - ${./install-router.sh}"
               ];

              # インストーラー環境にdisko-installコマンドをプリインストール
              environment.systemPackages = [
                disko.packages.x86_64-linux.disko-install
              ];

              console.keyMap = "jp106";
            }
          ] ++ commonModules;
        };
        mogami = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            disko.nixosModules.disko
            ./disko.nix
            impermanence.nixosModules.impermanence
            ./persistence.nix
            ./configuration.nix
          ] ++ commonModules;
        };
        mogami-vm = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./configuration.nix
            ./test/mogami-vm.nix
          ] ++ commonModules;
        };
        mogami-client = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-client.nix
          ] ++ commonModules;
        };
        mogami-server = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-server.nix
          ] ++ commonModules;
        };
        mogami-mnet = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./test/mogami-mnet.nix
          ] ++ commonModules;
        };
      };
    };
}
