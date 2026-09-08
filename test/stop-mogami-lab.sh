#!/usr/bin/env bash
set -euo pipefail

echo "=== cleanup ==="
for vm in mogami-vm mogami-server mogami-client mogami-mnet; do
  pkill -f "qemu-system-x86_64.*$vm" 2>/dev/null && echo "killed $vm VM" || true
done
if [ -f /tmp/mqvpn-dnsmasq.pid ]; then
  sudo kill "$(cat /tmp/mqvpn-dnsmasq.pid)" 2>/dev/null && echo "killed lab dnsmasq" || true
  for _ in {1..20}; do
    sudo kill -0 "$(cat /tmp/mqvpn-dnsmasq.pid)" 2>/dev/null || break
    sleep 0.1
  done
fi
sudo rm -f /tmp/mqvpn-dnsmasq.pid /tmp/mqvpn-dnsmasq.leases /tmp/mqvpn-dnsmasq.log
# ISP シム用 netns を消す (中の dnsmasq・veth ごと消える。残骸なし)
sudo ip netns delete mqvpn-isp 2>/dev/null || true

echo "=== removing server bridge + taps ==="
for br in mqvpn-srv-br0 mqvpn-srv2-br0 mq-ext-br0 mq-mgmt-br0 mqvpn-br0; do
  sudo ip link delete "$br" 2>/dev/null || true
done
for tap in trw{0..11} ts-mq tm-ext ts-ext tm-mgmt tr-mgmt ts-mgmt tc-mgmt tc-mq tr-mq; do
  sudo ip link delete "$tap" 2>/dev/null || true
done
# ルーター<->サーバー間 FORWARD 許可ルールの除去
sudo iptables -D FORWARD -i mqvpn-srv-br0 -o mqvpn-srv2-br0 -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i mqvpn-srv2-br0 -o mqvpn-srv-br0 -j ACCEPT 2>/dev/null || true

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

rm -rf "$SCRIPT_DIR/result-mogami" "$SCRIPT_DIR/result-client" "$SCRIPT_DIR/result-server" "$SCRIPT_DIR/result-mnet"
rm -f "$SCRIPT_DIR/mogami-vm.qcow2" "$SCRIPT_DIR/mogami-client.qcow2" "$SCRIPT_DIR/mogami-server.qcow2" "$SCRIPT_DIR/mogami-mnet.qcow2"

# ルートディレクトリの qcow2 も削除
rm -f "$REPO_DIR/mogami-vm.qcow2" "$REPO_DIR/mogami-client.qcow2" "$REPO_DIR/mogami-server.qcow2" "$REPO_DIR/mogami-mnet.qcow2"

echo "done"
