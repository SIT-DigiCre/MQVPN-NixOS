# ピン留め公式イメージ取得の定型。fromImage継承はEnvのみのため、
# Entrypoint/Cmd/User等は各イメージ側で明示すること。
{
  pkgs,
  imageName,
  imageDigest,
  finalImageName,
  finalImageTag,
  outputHash,
}:
pkgs.dockerTools.pullImage {
  inherit
    imageName
    imageDigest
    finalImageName
    finalImageTag
    outputHash
    ;
  outputHashAlgo = "sha256";
}
