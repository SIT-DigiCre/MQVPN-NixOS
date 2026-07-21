#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/stop-mogami-lab.sh" 2>/dev/null || true
"$SCRIPT_DIR/build-mogami-lab.sh"

echo "=== Starting router VM (background) ==="
ROUTER_VM="$(readlink -f /tmp/result-mogami)/bin/run-mogami-vm-vm"
nohup "$ROUTER_VM" \
  -netdev tap,id=lan,ifname=tr-mq,script=no,downscript=no -device virtio-net-pci,netdev=lan,mac=52:54:00:12:34:57 \
  -netdev tap,id=wan0,ifname=trw0,script=no,downscript=no -device virtio-net-pci,netdev=wan0,mac=52:54:00:12:34:58 \
  -netdev user,id=mgmt,hostfwd=tcp::2223-:22,hostfwd=tcp::8080-:80,net=10.0.3.0/24 -device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:34:59 \
  -netdev tap,id=wan1,ifname=trw1,script=no,downscript=no -device virtio-net-pci,netdev=wan1,mac=52:54:00:12:34:5a \
  -netdev tap,id=wan2,ifname=trw2,script=no,downscript=no -device virtio-net-pci,netdev=wan2,mac=52:54:00:12:34:5b \
  -netdev tap,id=wan3,ifname=trw3,script=no,downscript=no -device virtio-net-pci,netdev=wan3,mac=52:54:00:12:34:5c \
  -netdev tap,id=wan4,ifname=trw4,script=no,downscript=no -device virtio-net-pci,netdev=wan4,mac=52:54:00:12:34:5d \
  > /tmp/mqvpn-router.log 2>&1 &
ROUTER_PID=$!

echo "=== Starting server VM (background) ==="
SERVER_VM="$(readlink -f /tmp/result-server)/bin/run-mogami-server-vm"
nohup "$SERVER_VM" \
  > /tmp/mqvpn-server.log 2>&1 &
SERVER_PID=$!

echo "=== Starting client VM (background) ==="
CLIENT_VM="$(readlink -f /tmp/result-client)/bin/run-mogami-client-vm"
nohup "$CLIENT_VM" \
  > /tmp/mqvpn-client.log 2>&1 &
CLIENT_PID=$!

echo ""
echo "=== Lab is UP ==="
echo "  Router PID : $ROUTER_PID  (log: /tmp/mqvpn-router.log)"
echo "  Server PID : $SERVER_PID  (log: /tmp/mqvpn-server.log)"
echo "  Client PID : $CLIENT_PID  (log: /tmp/mqvpn-client.log)"
echo ""
echo "  SSH Router    : ./test/ssh-router.sh"
echo "  SSH Server    : ./test/ssh-server.sh"
echo "  SSH Client    : ./test/ssh-client.sh"
echo "  Follow logs   : tail -f /tmp/mqvpn-router.log"
echo "  Stop lab      : ./test/stop-mogami-lab.sh"
