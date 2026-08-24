#!/usr/bin/env bash
set -euo pipefail

CLIENT_VM="$(readlink -f /tmp/result-client)/bin/run-mogami-client-vm"

echo "=== starting client VM ==="
echo "  SSH     : ssh testuser@192.168.50.3  (password: test)"
echo "  TestIF  : tc-mq -> mqvpn-br0 -> router (172.16.0.2/12)"
echo "  Mgmt    : tc-mgmt -> mq-mgmt-br0 "
echo ""

exec "$CLIENT_VM" -smp 2
