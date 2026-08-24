{
  stdenv,
  fetchurl,
}:

# 事前ビルドの静的バイナリ (GitHub Release) をそのまま同梱する。
# 静的リンクのため autoPatchelfHook 不要 (pkgs/mqvpn.nix と同様の tarball 方式)。
stdenv.mkDerivation rec {
  pname = "mqvpn-prometheus-exporter";
  version = "0.4.0";

  src = fetchurl {
    url = "https://github.com/mp0rta/mqvpn-prometheus-exporter/releases/download/v${version}/mqvpn-prometheus-exporter_${version}_linux_amd64.tar.gz";
    sha256 = "sha256-ksyVfFVPFcE1oP0niDb5GwUc6uEUcs+Z/nNCgz+B8vI=";
  };

  sourceRoot = ".";

  installPhase = ''
    install -Dm755 mqvpn-prometheus-exporter -t $out/bin
  '';
}