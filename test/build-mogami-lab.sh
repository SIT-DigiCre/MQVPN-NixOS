#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BRIDGE=mqvpn-br0
TAP_ROUTER=tr-mq
TAP_CLIENT=tc-mq

echo "=== building ==="

echo "=== building mogami-vm ==="
rm -rf "$SCRIPT_DIR/result-mogami" 2>/dev/null || true
nix build "path:$REPO_DIR#nixosConfigurations.mogami-vm.config.system.build.vm" \
  --out-link /tmp/result-mogami --print-build-logs
ln -sf /tmp/result-mogami "$SCRIPT_DIR/result-mogami" 2>/dev/null || true

echo "=== building mogami-server ==="
rm -rf "$SCRIPT_DIR/result-server" 2>/dev/null || true
nix build "path:$REPO_DIR#nixosConfigurations.mogami-server.config.system.build.vm" \
  --out-link /tmp/result-server --print-build-logs
ln -sf /tmp/result-server "$SCRIPT_DIR/result-server" 2>/dev/null || true

echo "=== building mogami-client ==="
rm -rf "$SCRIPT_DIR/result-client" 2>/dev/null || true
nix build "path:$REPO_DIR#nixosConfigurations.mogami-client.config.system.build.vm" \
  --out-link /tmp/result-client --print-build-logs
ln -sf /tmp/result-client "$SCRIPT_DIR/result-client" 2>/dev/null || true

echo "=== cleanup stale interfaces ==="
for tap in trw0 trw1 trw2 trw3 trw4 ts-mq; do
  sudo ip link delete "$tap" 2>/dev/null || true
done
sudo ip link delete mqvpn-srv-br0 2>/dev/null || true
sudo ip link delete $TAP_CLIENT 2>/dev/null || true
sudo ip link delete $TAP_ROUTER 2>/dev/null || true
sudo ip link delete $BRIDGE 2>/dev/null || true

echo "=== creating server bridge: mqvpn-srv-br0 (10.200.0.0/24) ==="
sudo ip link add mqvpn-srv-br0 type bridge
sudo ip link set mqvpn-srv-br0 up
for tap in trw0 trw1 trw2 trw3 trw4; do
  sudo ip tuntap add "$tap" mode tap user "$USER"
  sudo ip link set "$tap" master mqvpn-srv-br0
  sudo ip link set "$tap" up
  echo "  $tap -> mqvpn-srv-br0"
done
sudo ip tuntap add ts-mq mode tap user "$USER"
sudo ip link set ts-mq master mqvpn-srv-br0
sudo ip link set ts-mq up
echo "  ts-mq -> mqvpn-srv-br0"

echo "=== creating LAN bridge: $BRIDGE ==="
sudo ip link add $BRIDGE type bridge
sudo ip link set $BRIDGE up
sudo ip tuntap add $TAP_ROUTER mode tap user "$USER"
sudo ip link set $TAP_ROUTER master $BRIDGE
sudo ip link set $TAP_ROUTER up
sudo ip tuntap add $TAP_CLIENT mode tap user "$USER"
sudo ip link set $TAP_CLIENT master $BRIDGE
sudo ip link set $TAP_CLIENT up

echo ""
echo "=== done ==="
echo "WAN: 5x tap via mqvpn-srv-br0 -> server VM (10.200.0.1)"
echo "LAN: $TAP_ROUTER + $TAP_CLIENT via $BRIDGE (172.16.0.0/12)"
