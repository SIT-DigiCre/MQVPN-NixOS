#!/usr/bin/env bash
set -euo pipefail

TAP_ROUTER="${TAP_ROUTER:-tr-mq}"
ROUTER_VM="$(readlink -f /tmp/result-mogami)/bin/run-mogami-vm-vm"

echo "=== starting router VM ==="
echo "  SSH       : ssh digicre@localhost -p 2223  (password: router)"
echo "  Dashboard : http://localhost:8080"
echo "  LAN       : tr-mq -> mqvpn-br0"
echo "  WAN       : 5x tap (trw0-4) -> mqvpn-srv-br0 -> server VM"

exec "$ROUTER_VM" \
  -netdev tap,id=lan,ifname="$TAP_ROUTER",script=no,downscript=no -device virtio-net-pci,netdev=lan,mac=52:54:00:12:34:57 \
  -netdev tap,id=wan0,ifname=trw0,script=no,downscript=no -device virtio-net-pci,netdev=wan0,mac=52:54:00:12:34:58 \
  -netdev user,id=mgmt,hostfwd=tcp::2223-:22,hostfwd=tcp::8080-:80,net=10.0.3.0/24 -device virtio-net-pci,netdev=mgmt,mac=52:54:00:12:34:59 \
  -netdev tap,id=wan1,ifname=trw1,script=no,downscript=no -device virtio-net-pci,netdev=wan1,mac=52:54:00:12:34:5a \
  -netdev tap,id=wan2,ifname=trw2,script=no,downscript=no -device virtio-net-pci,netdev=wan2,mac=52:54:00:12:34:5b \
  -netdev tap,id=wan3,ifname=trw3,script=no,downscript=no -device virtio-net-pci,netdev=wan3,mac=52:54:00:12:34:5c \
  -netdev tap,id=wan4,ifname=trw4,script=no,downscript=no -device virtio-net-pci,netdev=wan4,mac=52:54:00:12:34:5d
