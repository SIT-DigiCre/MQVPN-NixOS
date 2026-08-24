#!/usr/bin/env bash
set -euo pipefail

MN_VM="$(readlink -f /tmp/result-mnet)/bin/run-mogami-mnet-vm"

echo "=== starting mnet VM (実ネットワーク側 / ベンチターゲット) ==="
echo "  SSH     : ssh digicre@192.168.50.4  (password: mnet)"
echo "  TestIF  : tm-ext -> mq-ext-br0 -> server VM eth2 (192.168.100.1/24)"
echo "  Mgmt    : tm-mgmt -> mq-mgmt-br0 (192.168.50.4)"
echo ""

exec "$MN_VM" -smp 2