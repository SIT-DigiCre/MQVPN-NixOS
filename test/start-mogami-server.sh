#!/usr/bin/env bash
set -euo pipefail

SERVER_VM="$(readlink -f /tmp/result-server)/bin/run-mogami-server-vm"

echo "=== starting server VM ==="
echo "  SSH       : ssh digicre@localhost -p 2224  (password: server)"
echo "  LAN       : ts-mq -> mqvpn-srv-br0 -> router VM"
echo "  Tunnel    : mqvpn0 (10.10.0.1)"
echo ""

exec "$SERVER_VM" -smp 4
