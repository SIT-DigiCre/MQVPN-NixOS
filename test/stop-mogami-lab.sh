#!/usr/bin/env bash
set -euo pipefail

echo "=== cleanup ==="
pkill -f "qemu-system-x86_64.*mogami-vm" 2>/dev/null && echo "killed router VM" || true
pkill -f "qemu-system-x86_64.*mogami-server" 2>/dev/null && echo "killed server VM" || true
pkill -f "qemu-system-x86_64.*mogami-client" 2>/dev/null && echo "killed client VM" || true
pkill -f "qemu-system-x86_64.*mogami-mnet" 2>/dev/null && echo "killed mnet VM" || true

echo "=== removing server bridge + taps ==="
sudo ip link delete mqvpn-srv-br0 2>/dev/null || true
for tap in trw0 trw1 trw2 trw3 trw4 ts-mq; do
  sudo ip link delete "$tap" 2>/dev/null || true
done

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
sudo sh -c 'iptables-save | grep -E "(POSTROUTING -s 192\.168\.50\.2 -o|FORWARD (-i mq-mgmt-br0|-o mq-mgmt-br0))" | sed "s/^-A/-D/" | xargs -r -n1 iptables -t filter' 2>/dev/null || true
sudo sh -c 'iptables-save -t nat | grep "POSTROUTING -s 192\.168\.50\.2" | sed "s/^-A/-D/" | xargs -r -n1 iptables -t nat' 2>/dev/null || true
sudo sysctl -w net.ipv4.conf.mq-mgmt-br0.forwarding=0 >/dev/null 2>&1 || true
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

rm -rf result-mogami result-client result-server
rm -f mogami-vm.qcow2 mogami-client.qcow2 mogami-server.qcow2
echo "done"
