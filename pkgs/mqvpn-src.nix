{ pkgs, stdenv, fetchFromGitHub, ... }:

let
  version = "0.16.0";
in stdenv.mkDerivation {
  pname = "mqvpn";
  inherit version;

  src = fetchFromGitHub {
    owner = "mp0rta";
    repo = "mqvpn";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-W96uDbXUBQKIZDStUEwMtaphME21SA7WaJCRFR/lgWk=";
  };

  patches = [
    ../patches/mqvpn-max-paths.patch
    ../patches/xquic-reinjection-scan.patch
    # トレードオフ: 再注入スキャンをモード毎に2msに間引き(要CPU削減)。
    # 対価は (1) 再注入の遅延上界 +≤2ms — deadline(実質20ms下限) や
    #    PTO 再送(~RTT=100ms) と比べ無視できる。危険局面(2ms窓内ロス)は
    #    PTO が救済するため実効損失回復特性は不変。
    # (2) 複製送信が~2ms刻みのバーストに固まる — レート換算は元送信と同程度。
    # 計測: 飽和下 800M 要求で 795Mbps/0.65%ロス(パッチ前 710-734/8-11%)、
    #   上限 ~600M→~1.06Gbps。間隔は XQC_REINJ_SCAN_INTERVAL_US で調整可。
    # メンテ: vendored xquic の fork 差分が増える(アップグレード追従コスト)。
    ../patches/xquic-reinjection-rate-limit.patch
  ];

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
    ln -sf libmqvpn.so.3 $out/lib/libmqvpn.so
  '';

  preFixup = ''
    patchelf --set-rpath "$out/lib" $out/bin/mqvpn
    patchelf --set-rpath "$out/lib" $out/lib/libmqvpn.so.3
  '';
}
