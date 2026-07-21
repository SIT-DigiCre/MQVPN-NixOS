#!/usr/bin/env bash
set -euo pipefail

echo "=== cleanup ==="
pkill -f "qemu-system-x86_64.*mogami-vm" 2>/dev/null && echo "killed router VM" || true
pkill -f "qemu-system-x86_64.*mogami-server" 2>/dev/null && echo "killed server VM" || true
pkill -f "qemu-system-x86_64.*mogami-client" 2>/dev/null && echo "killed client VM" || true

echo "=== removing server bridge + taps ==="
sudo ip link delete mqvpn-srv-br0 2>/dev/null || true
for tap in trw0 trw1 trw2 trw3 trw4 ts-mq; do
  sudo ip link delete "$tap" 2>/dev/null || true
done

echo "=== removing LAN bridge + taps ==="
sudo ip link delete tc-mq 2>/dev/null || true
sudo ip link delete tr-mq 2>/dev/null || true
sudo ip link delete mqvpn-br0 2>/dev/null || true

rm -rf result-mogami result-client result-server
rm -f mogami-vm.qcow2 mogami-client.qcow2 mogami-server.qcow2
echo "done"
