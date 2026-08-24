#!/usr/bin/env bash
set -euo pipefail

# "実ネットワーク側" VM (mnet): ベンチターゲット
echo "=== cleanup mnet ==="
pkill -f "qemu-system-x86_64.*mogami-mnet" 2>/dev/null && echo "killed mnet VM" || true
sudo ip link delete mq-ext-br0 2>/dev/null || true
for tap in tm-ext ts-ext tm-mgmt; do
  sudo ip link delete "$tap" 2>/dev/null || true
done