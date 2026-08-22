{ stdenv, fetchurl, autoPatchelfHook, zlib }:

stdenv.mkDerivation rec {
  pname = "live-chart";
  version = "v1.0_ubuntu_22.04";

  src = fetchurl {
    url = "https://github.com/devalexqt/network_monitor_live_chart/releases/download/${version}/live_chart";
    sha256 = "sha256-LzrOj8os4LFSU0DmmnitanMNlIYQmdvQ73nyUe8cRKw=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];

  buildInputs = [
    stdenv.cc.cc.lib
    zlib
  ];

  dontUnpack = true;

  installPhase = ''
    install -Dm755 $src $out/bin/live_chart
  '';
}