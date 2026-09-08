# mogami-*.nix共通の既定値 (実効値が同一のもののみ)。
# 前提: net.ifnames=0のためIF名は常にethX / mgmtにデフォルトルート無し。
# openssh/firewall/ユーザーはVM毎に異なるため各ファイルに残す。
# NOTE: mogami-vmはrouterと値が被るためmkDefault化 (素定義優先)。
{ lib, ... }:
{
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  system.stateVersion = lib.mkDefault "26.05";

  virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
}
