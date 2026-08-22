{
  pkgs,
  ...
}:
# プロファイリング用のシンボル付き mqvpn ビルド。
#
# 通常ビルド (mqvpn-src.nix) は nixpkgs の strip 処理でシンボルが消えるため、
# perf で関数名が取れない。ここでは:
#   - CMAKE_BUILD_TYPE を RelWithDebInfo (-O2 -g) に変更
#   - dontStrip = true (デバッグセクション保持)
# をする。性能特性は通常ビルドとほぼ同等なので、実験の再現にも安全に使える。
#
# 使い方: このファイルを import している箇所 (configuration.nix,
#         test/mogami-server.nix など) を参照。
(pkgs.callPackage ./mqvpn-src.nix { }).overrideAttrs (a: {
  dontStrip = true;
  preBuild = ''
    sed -i 's/-DCMAKE_BUILD_TYPE=Release/-DCMAKE_BUILD_TYPE=RelWithDebInfo/g' build.sh
  '';
})