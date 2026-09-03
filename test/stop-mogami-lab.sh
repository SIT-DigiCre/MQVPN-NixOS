#!/usr/bin/env bash
set -euo pipefail

echo "=== cleanup ==="
pkill -f "qemu-system-x86_64.*mogami-vm" 2>/dev/null && echo "killed router VM" || true
pkill -f "qemu-system-x86_64.*mogami-server" 2>/dev/null && echo "killed server VM" || true
pkill -f "qemu-system-x86_64.*mogami-client" 2>/dev/null && echo "killed client VM" || true
pkill -f "qemu-system-x86_64.*mogami-mnet" 2>/dev/null && echo "killed mnet VM" || true

echo "=== removing server bridge + taps ==="
sudo ip link delete mqvpn-srv-br0 2>/dev/null || true
sudo ip link delete mqvpn-srv2-br0 2>/dev/null || true
for tap in trw0 trw1 trw2 trw3 trw4 trw5 trw6 trw7 trw8 trw9 trw10 trw11 ts-mq; do
  sudo ip link delete "$tap" 2>/dev/null || true
done
# ルーター<->サーバー間 FORWARD 許可ルールの除去
sudo iptables -D FORWARD -i mqvpn-srv-br0 -o mqvpn-srv2-br0 -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i mqvpn-srv2-br0 -o mqvpn-srv-br0 -j ACCEPT 2>/dev/null || true

echo "=== removing ext bridge (mnet) + taps ==="
sudo ip link delete mq-ext-br0 2>/dev/null || true
for tap in tm-ext ts-ext tm-mgmt; do
  sudo ip link delete "$tap" 2>/dev/null || true
done

echo "=== removing mgmt bridge + taps ==="
sudo ip link delete mq-mgmt-br0 2>/dev/null || true
for tap in tr-mgmt ts-mgmt tc-mgmt; do
  sudo ip link delete "$tap" 2>/dev/null || true
done

echo "=== cleaning host forward/SNAT residue (mq-mgmt 関連ルール全消し) ==="
# -o realif は実行のたびに変わり得るため、iptables-save の該当行を一括で -D する
sudo sh -c 'iptables-save -t filter | grep -E "FORWARD.*(mq-mgmt-br0|192\.168\.50\.2)" | sed "s/^-A/-D/" | xargs -r -L1 iptables -t filter' 2>/dev/null || true
sudo sh -c 'iptables-save -t nat | grep -E "POSTROUTING.*192\.168\.50\.2" | sed "s/^-A/-D/" | xargs -r -L1 iptables -t nat' 2>/dev/null || true
# グローバル ip_forward を起動前の値に戻す
if [ -f /tmp/mqvpn-ipforward ]; then
  sudo sysctl -w net.ipv4.ip_forward="$(cat /tmp/mqvpn-ipforward)" >/dev/null 2>&1 || true
  rm -f /tmp/mqvpn-ipforward
fi
# 対象ルールが残っていないか確認 (0 なら正常)
leo=$(sudo -n iptables-save 2>/dev/null | grep -cE "mq-mgmt|192\.168\.50\.2" || true)
echo "  remaining mq-mgmt rules: ${leo}"

echo "=== removing LAN bridge + taps ==="
sudo ip link delete tc-mq 2>/dev/null || true
sudo ip link delete tr-mq 2>/dev/null || true
sudo ip link delete mqvpn-br0 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

rm -rf "$SCRIPT_DIR/result-mogami" "$SCRIPT_DIR/result-client" "$SCRIPT_DIR/result-server" "$SCRIPT_DIR/result-mnet"
rm -f "$SCRIPT_DIR/mogami-vm.qcow2" "$SCRIPT_DIR/mogami-client.qcow2" "$SCRIPT_DIR/mogami-server.qcow2" "$SCRIPT_DIR/mogami-mnet.qcow2"

# ルートディレクトリの qcow2 も削除
rm -f "$REPO_DIR/mogami-vm.qcow2" "$REPO_DIR/mogami-client.qcow2" "$REPO_DIR/mogami-server.qcow2" "$REPO_DIR/mogami-mnet.qcow2"

echo "done"
