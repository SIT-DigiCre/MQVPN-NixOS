#!/usr/bin/env bash
# usage: start-vm.sh <server|router|client|mnet>
# build-mogami-lab.sh から呼ばれる (各 VM はビルド完了と同時に起動)。
set -euo pipefail

role="${1:?usage: $0 <server|router|client|mnet>}"
# VMイメージは使い捨てなので /tmp 配下に置く (flake内に置くと
# `nix build path:...` が巨大qcow2ごと /nix/store にコピーし続けて
# ディスクを圧迫するため)。
IMGDIR="/tmp/mqvpn-vm-images"
mkdir -p "$IMGDIR"
case "$role" in
  server)
    img="mogami-server.qcow2"
    vm="$(readlink -f /tmp/result-server)/bin/run-mogami-server-vm"
    echo "=== starting server VM ==="
    echo "  SSH  : ssh digicre@192.168.50.2  (password: server)"
    echo "  WAN  : ts-mq -> mqvpn-srv2-br0 (10.200.99.2) -> host -> router VM"
    echo "  Mgmt : ts-mgmt -> mq-mgmt-br0 "
    ;;
  router)
    img="mogami-vm.qcow2"
    vm="$(readlink -f /tmp/result-mogami)/bin/run-mogami-vm-vm"
    echo "=== starting router VM ==="
    echo "  SSH       : ssh digicre@192.168.50.1  (password: router)"
    echo "  Dashboard : http://192.168.50.1/"
    echo "  LAN       : tr-mq -> mqvpn-br0"
    echo "  WAN       : 12x tap (trw0-11) -> mqvpn-srv-br0 (DHCP 10.200.i.2/24, GW 10.200.i.1) -> host -> server VM (10.200.99.2)"
    echo "  Mgmt      : tr-mgmt -> mq-mgmt-br0 "
    ;;
  client)
    img="mogami-client.qcow2"
    vm="$(readlink -f /tmp/result-client)/bin/run-mogami-client-vm"
    echo "=== starting client VM ==="
    echo "  SSH     : ssh testuser@192.168.50.3  (password: test)"
    echo "  TestIF  : tc-mq -> mqvpn-br0 -> router (172.16.0.2/12)"
    echo "  Mgmt    : tc-mgmt -> mq-mgmt-br0 "
    ;;
  mnet)
    img="mogami-mnet.qcow2"
    vm="$(readlink -f /tmp/result-mnet)/bin/run-mogami-mnet-vm"
    echo "=== starting mnet VM (実ネットワーク側 / ベンチターゲット) ==="
    echo "  SSH     : ssh digicre@192.168.50.4  (password: mnet)"
    echo "  TestIF  : tm-ext -> mq-ext-br0 -> server VM eth2 (192.168.100.1/24)"
    echo "  Mgmt    : tm-mgmt -> mq-mgmt-br0 (192.168.50.4)"
    ;;
  *)
    echo "unknown role: $role (use: server|router|client|mnet)" >&2
    exit 1
    ;;
esac
echo ""

export NIX_DISK_IMAGE="$IMGDIR/$img"
exec "$vm" -smp 2
