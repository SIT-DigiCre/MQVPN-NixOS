# ピン留め公式イメージ取得の定型 (prometheus / grafana で共有)。
# digest + sha256 固定の運用は変えない。
{ pkgs, imageName, imageDigest, finalImageName, finalImageTag, outputHash }:
pkgs.dockerTools.pullImage {
  inherit imageName imageDigest finalImageName finalImageTag outputHash;
  outputHashAlgo = "sha256";
}
