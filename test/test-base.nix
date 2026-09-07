# test/mogami-*.nix 共通の定型設定。実効値が同一のもののみ置く。
# openssh/firewall/ユーザー定義は VM ごとに実効値が異なるため各ファイルに残す。
# NOTE: mogami-vm は ./router と値が被るため mkDefault 化している
# (素の定義が優先され、client/server/mnet ではこの既定値がそのまま効く)。
{ lib, ... }:
{
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  system.stateVersion = lib.mkDefault "26.05";

  virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
}
