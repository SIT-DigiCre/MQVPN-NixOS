{
  pkgs,
  ...
}:
# perf用シンボル付きビルド (stripで消えるためRelWithDebInfo+dontStrip)。
# 性能は通常ビルドとほぼ同等。参照: router/mqvpn.nix, container/mqvpn-server-image.nix。
(pkgs.callPackage ./mqvpn-src.nix { }).overrideAttrs (a: {
  dontStrip = true;
  preBuild = ''
    sed -i 's/-DCMAKE_BUILD_TYPE=Release/-DCMAKE_BUILD_TYPE=RelWithDebInfo/g' build.sh
  '';
})
