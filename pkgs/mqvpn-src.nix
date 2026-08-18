{ pkgs, stdenv, fetchFromGitHub, ... }:

let
  version = "0.15.0";
in stdenv.mkDerivation {
  pname = "mqvpn";
  inherit version;

  src = fetchFromGitHub {
    owner = "mp0rta";
    repo = "mqvpn";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-64tF6TgzCZZhh1VAo4KhlzRRfAAsQuSPhOCL/+r+6os=";
  };

  patches = [ ../patches/mqvpn-max-paths.patch ];

  dontUseCmakeConfigure = true;
  nativeBuildInputs = with pkgs; [ cmake makeWrapper autoPatchelfHook git ];
  buildInputs = with pkgs; [ libevent ];

  buildPhase = ''
    # 上流のビルドスクリプトを流用(boringssl → xquic → mqvpn)。
    # Nix 環境では libevent ヘッダの場所チェック(/usr/include)が無意味なため除去
    sed -i '/if ! find -L \/usr\/include/,/^fi$/d' build.sh
    patchShebangs build.sh
    ./build.sh
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib
    cp build/mqvpn $out/bin/
    cp build/libmqvpn.so* third_party/xquic/build/libxquic.so $out/lib/
    ln -sf libmqvpn.so.2 $out/lib/libmqvpn.so
  '';

  preFixup = ''
    patchelf --set-rpath "$out/lib" $out/bin/mqvpn
    patchelf --set-rpath "$out/lib" $out/lib/libmqvpn.so.2
  '';
}
