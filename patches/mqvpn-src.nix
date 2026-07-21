{ pkgs, stdenv, fetchgit, fetchFromGitHub, ...
}:

let
  version = "0.13.1";

  boringssl = stdenv.mkDerivation {
    name = "boringssl";
    src = fetchgit {
      url = "https://github.com/google/boringssl.git";
      rev = "7b4784a3de4a7699d7e18886d9cf3b700fe4c718";
      hash = "sha256-KJsoVNOnO6ROzz13pGHCOJeLPrG9I5YGDFrGXzz7qas=";
    };
    nativeBuildInputs = [ pkgs.cmake pkgs.ninja ];
    cmakeFlags = [
      "-DBUILD_SHARED_LIBS=0"
      "-DCMAKE_C_FLAGS=-fPIC"
      "-DCMAKE_CXX_FLAGS=-fPIC"
    ];
  };

in stdenv.mkDerivation {
  pname = "mqvpn";
  inherit version;

  src = fetchFromGitHub {
    owner = "mp0rta";
    repo = "mqvpn";
    rev = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-IK0SpVsh0kLmIB5vpYw1W1XTH4nn9JeaZ556Vu87nmY=";
  };

  patches = [ ./xquic-antiamp-fix.patch ];

  dontUseCmakeConfigure = true;
  nativeBuildInputs = with pkgs; [ cmake makeWrapper autoPatchelfHook ];
  buildInputs = with pkgs; [ libevent ];

  buildPhase = ''
    # BoringSSL
    bssl_dir="$PWD/third_party/xquic/third_party/boringssl"
    rm -rf "$bssl_dir"
    mkdir -p "$bssl_dir"
    cp -r --no-preserve=mode ${boringssl.src}/* "$bssl_dir/"
    chmod -R u+w "$bssl_dir"

    cmake -S "$bssl_dir" -B "$bssl_dir/build" \
      -DBUILD_SHARED_LIBS=0 \
      -DCMAKE_C_FLAGS="-fPIC" \
      -DCMAKE_CXX_FLAGS="-fPIC"
    make -C "$bssl_dir/build" -j$(nproc) ssl crypto

    # xquic
    xquic_dir="$PWD/third_party/xquic"
    cmake -S "$xquic_dir" -B "$xquic_dir/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DSSL_TYPE=boringssl \
      -DSSL_PATH="$bssl_dir" \
      -DXQC_ENABLE_BBR2=ON \
      -DXQC_ENABLE_UNLIMITED=ON
    make -C "$xquic_dir/build" -j$(nproc)

    # mqvpn
    cmake -S "$PWD" -B "$PWD/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DXQUIC_BUILD_DIR="$xquic_dir/build"
    make -C "$PWD/build" -j$(nproc)
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
