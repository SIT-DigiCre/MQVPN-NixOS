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

echo "=== building mogami-mnet ==="
rm -rf "$SCRIPT_DIR/result-mnet" 2>/dev/null || true
nix build "path:$REPO_DIR#nixosConfigurations.mogami-mnet.config.system.build.vm" \
  --out-link /tmp/result-mnet --print-build-logs
ln -sf /tmp/result-mnet "$SCRIPT_DIR/result-mnet" 2>/dev/null || true

echo "=== cleanup stale interfaces ==="
for tap in trw0 trw1 trw2 trw3 trw4 trw5 trw6 trw7 trw8 trw9 trw10 trw11 ts-mgmt ts-mq tr-mgmt tc-mgmt tm-ext ts-ext tm-mgmt; do
  sudo ip link delete "$tap" 2>/dev/null || true
done
sudo ip link delete mqvpn-srv-br0 2>/dev/null || true
sudo ip link delete mqvpn-srv2-br0 2>/dev/null || true
sudo ip link delete mq-mgmt-br0 2>/dev/null || true
sudo ip link delete mq-ext-br0 2>/dev/null || true
sudo ip link delete $TAP_CLIENT 2>/dev/null || true
sudo ip link delete $TAP_ROUTER 2>/dev/null || true
sudo ip link delete $BRIDGE 2>/dev/null || true

echo "=== creating WAN bridge: mqvpn-srv-br0 (per-WAN /24 GW = ISP シム) ==="
sudo ip link add mqvpn-srv-br0 type bridge
sudo ip link set mqvpn-srv-br0 up
for tap in trw0 trw1 trw2 trw3 trw4 trw5 trw6 trw7 trw8 trw9 trw10 trw11; do
  sudo ip tuntap add "$tap" mode tap user "$USER"
  sudo ip link set "$tap" master mqvpn-srv-br0
  sudo ip link set "$tap" up
  echo "  $tap -> mqvpn-srv-br0"
done
# 各 WAN 用ゲートウェイをホストが保持 (10.200.i.1/24)。ルーター WAN NIC は
# 静的デフォルトルートでこの GW を経由し、サーバー(10.200.99.2)へ抜ける
# → 本番の「WAN は ISP 経由でサーバーへ抜ける」と同形状 (DHCP は不要)。
for i in $(seq 0 11); do
  sudo ip addr add "10.200.$i.1/24" dev mqvpn-srv-br0 2>/dev/null || true
  done

echo "=== creating server bridge: mqvpn-srv2-br0 (10.200.99.0/24, ルーターから経路越し) ==="
sudo ip link add mqvpn-srv2-br0 type bridge
sudo ip link set mqvpn-srv2-br0 addr 02:00:00:50:00:03
sudo ip addr add 10.200.99.1/24 dev mqvpn-srv2-br0 2>/dev/null || true
sudo ip link set mqvpn-srv2-br0 up
sudo ip tuntap add ts-mq mode tap user "$USER"
sudo ip link set ts-mq master mqvpn-srv2-br0
sudo ip link set ts-mq up
echo "  ts-mq -> mqvpn-srv2-br0"
# ルーター<->サーバー間転送を許可 (非NAT: サーバーが WAN 側実 IP をそのまま見る)
sudo iptables -I FORWARD -i mqvpn-srv-br0 -o mqvpn-srv2-br0 -j ACCEPT 2>/dev/null || true
sudo iptables -I FORWARD -i mqvpn-srv2-br0 -o mqvpn-srv-br0 -j ACCEPT 2>/dev/null || true

echo "=== creating LAN bridge: $BRIDGE ==="
sudo ip link add $BRIDGE type bridge
sudo ip link set $BRIDGE up
sudo ip tuntap add $TAP_ROUTER mode tap user "$USER"
sudo ip link set $TAP_ROUTER master $BRIDGE
sudo ip link set $TAP_ROUTER up
sudo ip tuntap add $TAP_CLIENT mode tap user "$USER"
sudo ip link set $TAP_CLIENT master $BRIDGE
sudo ip link set $TAP_CLIENT up

echo "=== creating mgmt bridge: mq-mgmt-br0 (192.168.50.0/24) ==="
sudo ip link add mq-mgmt-br0 type bridge
sudo ip link set mq-mgmt-br0 addr 02:00:00:50:00:01
sudo ip addr add 192.168.50.254/24 dev mq-mgmt-br0 2>/dev/null || true
sudo ip link set mq-mgmt-br0 up
for tap in tr-mgmt ts-mgmt tc-mgmt tm-mgmt; do
  sudo ip tuntap add "$tap" mode tap user "$USER"
  sudo ip link set "$tap" master mq-mgmt-br0
  sudo ip link set "$tap" up
  echo "  $tap -> mq-mgmt-br0"
done
# サーバー (トンネル集約点) だけが上流へ抜けられる: forwarding + SNAT
# 双方向とも -I (先頭挿入) — ホストの FORWARD に既存 DROP (Docker/firewalld 等) が
# あっても前に挿入されるため片方向だけ通る事態を防ぐ。-A は後続 DROP の後になり
# 戻りが落ちうる。許可は 192.168.50.2 (サーバー) 限定 — クライアント (192.168.50.3)
# やルーター (192.168.50.1) が万一 mgmt 経由で送信しても実ネットワークへ出られない。
echo "$(cat /proc/sys/net/ipv4/ip_forward)" > /tmp/mqvpn-ipforward 2>/dev/null || true
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
realif=$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") { print $(i+1); exit } }')
if [ -n "$realif" ]; then
  sudo iptables -t nat -C POSTROUTING -s 192.168.50.2 -o "$realif" -j MASQUERADE 2>/dev/null ||
    sudo iptables -t nat -A POSTROUTING -s 192.168.50.2 -o "$realif" -j MASQUERADE
  sudo iptables -C FORWARD -i mq-mgmt-br0 -s 192.168.50.2 -j ACCEPT 2>/dev/null ||
    sudo iptables -I FORWARD -i mq-mgmt-br0 -s 192.168.50.2 -j ACCEPT
  sudo iptables -C FORWARD -o mq-mgmt-br0 -d 192.168.50.2 -j ACCEPT 2>/dev/null ||
    sudo iptables -I FORWARD -o mq-mgmt-br0 -d 192.168.50.2 -j ACCEPT
  echo "  exit: 192.168.50.2 -> $realif (SNAT, FORWARD は .2 限定)"
else
  echo "  WARN: default route iface を特定できず、出口の転送設定はスキップ (server→internet 無効)"
fi

echo "=== creating ext bridge (mnet 用): mq-ext-br0 (192.168.100.0/24, 純ラボ島) ==="
sudo ip link add mq-ext-br0 type bridge
sudo ip link set mq-ext-br0 addr 02:00:00:50:00:02
sudo ip link set mq-ext-br0 up
for tap in tm-ext ts-ext; do
  sudo ip tuntap add "$tap" mode tap user "$USER"
  sudo ip link set "$tap" master mq-ext-br0
  sudo ip link set "$tap" up
  echo "  $tap -> mq-ext-br0"
done

echo ""
echo "=== done ==="
echo "WAN: 12x tap via mqvpn-srv-br0 (static /24, GW 10.200.i.1 = ISP シム) -> host -> mqvpn-srv2-br0"
echo "Server: ts-mq via mqvpn-srv2-br0 (10.200.99.2, ルーターから経路越し)"
echo "LAN: $TAP_ROUTER + $TAP_CLIENT via $BRIDGE (172.16.0.0/12)"
echo "Mgmt: 4x tap via mq-mgmt-br0 (192.168.50.1 router / .2 server / .3 client / .4 mnet)"
echo "Ext: tm-ext + ts-ext via mq-ext-br0 (192.168.100.1 mnet / .2 server)"
