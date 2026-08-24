#!/usr/bin/env bash
set -euo pipefail

SERVER_VM="$(readlink -f /tmp/result-server)/bin/run-mogami-server-vm"

echo "=== starting server VM ==="
echo "  SSH  : ssh digicre@192.168.50.2  (password: server)"
echo "  WAN  : ts-mq -> mqvpn-srv-br0 -> router VM"
echo "  Mgmt : ts-mgmt -> mq-mgmt-br0 "
echo ""

exec "$SERVER_VM" -smp 2
