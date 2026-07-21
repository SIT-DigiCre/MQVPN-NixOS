#!/usr/bin/env bash
set -euo pipefail

CLIENT_VM="$(readlink -f /tmp/result-client)/bin/run-mogami-client-vm"

echo "=== starting client VM ==="
echo "  SSH direct : ssh testuser@localhost -p 2222  (password: test)"
echo "  SSH proxy  : ssh -J digicre@localhost:2223 testuser@172.16.0.2"
echo "  Boot logs will appear below."
echo "  Ctrl+C to stop."
echo ""

exec "$CLIENT_VM"
