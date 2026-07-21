#!/usr/bin/env bash
set -euo pipefail

SERVER_VM="$(readlink -f /tmp/result-server)/bin/run-mogami-server-vm"

echo "=== starting server VM ==="
echo "  SSH       : ssh digicre@localhost -p 2224  (password: server)"
echo "  Boot logs will appear below."
echo "  Ctrl+C to stop."
echo ""

exec "$SERVER_VM"
