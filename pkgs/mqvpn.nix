{ stdenv, fetchurl, autoPatchelfHook, libevent }:

stdenv.mkDerivation rec {
  pname = "mqvpn-binary";
  version = "0.15.0";

  src = fetchurl {
    url = "https://github.com/mp0rta/mqvpn/releases/download/v${version}/mqvpn_${version}_amd64.tar.gz";
    sha256 = "sha256-/Qvv4Vzpmnf3W+GJIyUwpE0ZszPF2T6CAC9EdLovHI8=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    stdenv.cc.cc.lib
    libevent
  ];

  sourceRoot = ".";

  installPhase = ''
    install -Dm755 bin/mqvpn -t $out/bin
    install -Dm644 lib/libmqvpn.so* lib/libxquic.so -t $out/lib
  '';
}
