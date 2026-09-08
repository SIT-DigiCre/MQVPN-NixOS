{
  pkgs,
  stdenv,
  fetchFromGitHub,
  ...
}:

let
  version = "0.16.1";
in
stdenv.mkDerivation {
  pname = "mqvpn";
  inherit version;

  src = fetchFromGitHub {
    owner = "mp0rta";
    repo = "mqvpn";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-1l3n+HIT/T0l8qXOaKjcBcCE4Vy8+l5liqIiU/xm3NI=";
  };

  patches = [
    ../patches/mqvpn-max-paths.patch
    ../patches/xquic-wlb-capacity-pinning.patch
    # 低RTT優遇 (容量比例ベースライン上。独立revert可能に分離)。
    ../patches/xquic-wlb-rtt-favor.patch
    ../patches/xquic-reinjection-scan.patch
    # xquic-reinjection-rate-limit: 再注入スキャンを2ms間引き (CPU削減)。
    # 遅延上界+≤2msはdeadline/PTO比で無視でき、PTOが救済するため回復特性は不変。
    # 飽和下800M要求で795Mbps/0.65%ロス (前710-734/8-11%)、上限~600M→~1.06Gbps。
    # 間隔はXQC_REINJ_SCAN_INTERVAL_USで調整。
    ../patches/xquic-reinjection-rate-limit.patch
  ];

  dontUseCmakeConfigure = true;
  nativeBuildInputs = with pkgs; [
    cmake
    autoPatchelfHook
    git
  ];
  buildInputs = with pkgs; [ libevent ];

  buildPhase = ''
    # Nixでは/usr/include検査が無意味なため除去し上流build.shを流用。
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

  # 上流産物は/build/へのRPATHを残すため$out/libへ付け替え必須 (削除でRPATHエラー)。
  preFixup = ''
    patchelf --set-rpath "$out/lib" $out/bin/mqvpn
    patchelf --set-rpath "$out/lib" $out/lib/libmqvpn.so.3
  '';
}
