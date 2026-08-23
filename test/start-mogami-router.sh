#!/usr/bin/env bash
set -euo pipefail

ROUTER_VM="$(readlink -f /tmp/result-mogami)/bin/run-mogami-vm-vm"

echo "=== starting router VM ==="
echo "  SSH       : ssh digicre@192.168.50.1  (password: router)"
echo "  Dashboard : http://192.168.50.1/"
echo "  LAN       : tr-mq -> mqvpn-br0"
echo "  WAN       : 5x tap (trw0-4) -> mqvpn-srv-br0 -> server VM"
echo "  Mgmt      : tr-mgmt -> mq-mgmt-br0 "
echo ""

# NIC は全て test/mogami-vm.nix の networkingOptions (mkForce) で定義。
exec "$ROUTER_VM" -smp 4
