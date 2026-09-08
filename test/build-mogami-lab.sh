#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BRIDGE=mqvpn-br0
TAP_ROUTER=tr-mq
TAP_CLIENT=tc-mq
WAN_TAPS=(trw{0..11})
mkbridge() { sudo ip link add "$1" type bridge; sudo ip link set "$1" up; }
mktap() { sudo ip tuntap add "$1" mode tap user "$USER"; sudo ip link set "$1" master "$2"; sudo ip link set "$1" up; }

setup_network() {
  echo "=== cleanup stale interfaces ==="
  for tap in "${WAN_TAPS[@]}" ts-mgmt ts-mq tr-mgmt tc-mgmt tm-ext ts-ext tm-mgmt; do
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
  mkbridge mqvpn-srv-br0
  for tap in "${WAN_TAPS[@]}"; do
    mktap "$tap" mqvpn-srv-br0
    echo "  $tap -> mqvpn-srv-br0"
  done
  # 各 WAN 用ゲートウェイをホストが保持 (10.200.i.1/24) し、ISP シムの DHCP
  # (dnsmasq) でルーター WAN NIC に 10.200.i.2 + GW を配布する
  # → 本番の「WAN は DHCP で ISP 経由」と同形状。
  for i in {0..11}; do
    sudo ip addr add "10.200.$i.1/24" dev mqvpn-srv-br0 2>/dev/null || true
  done
  start_lab_dhcp

  echo "=== creating server bridge: mqvpn-srv2-br0 (10.200.99.0/24, ルーターから経路越し) ==="
  sudo ip link add mqvpn-srv2-br0 type bridge
  sudo ip link set mqvpn-srv2-br0 addr 02:00:00:50:00:03
  sudo ip addr add 10.200.99.1/24 dev mqvpn-srv2-br0 2>/dev/null || true
  sudo ip link set mqvpn-srv2-br0 up
  mktap ts-mq mqvpn-srv2-br0
  echo "  ts-mq -> mqvpn-srv2-br0"
  # ルーター<->サーバー間転送を許可 (非NAT: サーバーが WAN 側実 IP をそのまま見る)
  sudo iptables -I FORWARD -i mqvpn-srv-br0 -o mqvpn-srv2-br0 -j ACCEPT 2>/dev/null || true
  sudo iptables -I FORWARD -i mqvpn-srv2-br0 -o mqvpn-srv-br0 -j ACCEPT 2>/dev/null || true

  echo "=== creating LAN bridge: $BRIDGE ==="
  mkbridge $BRIDGE
  mktap $TAP_ROUTER $BRIDGE
  mktap $TAP_CLIENT $BRIDGE

  echo "=== creating mgmt bridge: mq-mgmt-br0 (192.168.50.0/24) ==="
  sudo ip link add mq-mgmt-br0 type bridge
  sudo ip link set mq-mgmt-br0 addr 02:00:00:50:00:01
  sudo ip addr add 192.168.50.254/24 dev mq-mgmt-br0 2>/dev/null || true
  sudo ip link set mq-mgmt-br0 up
  for tap in tr-mgmt ts-mgmt tc-mgmt tm-mgmt; do
    mktap "$tap" mq-mgmt-br0
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
    mktap "$tap" mq-ext-br0
    echo "  $tap -> mq-ext-br0"
  done
}

# ISP シム DHCP (dnsmasq) を専用 netns で立てる。MAC ピン留めで
# 10.200.i.2 + router 10.200.i.1 を配布し、現行の静的マッピングを再現する。
# MAC は test/mogami-vm.nix の allNics と対応 (trw0→eth1→10.200.0.2、
# trw1→eth3→10.200.1.2、…、trw11→eth13→10.200.11.2)。
# netns に閉じ込める理由: ホストの FW・ネットワーク設定に一切触れないため
# (netns は独自の FW テーブル = 既定 ACCEPT を持つ)。veth 片端をブリッジに
# 差すだけで L2 到達し、後片付けは `ip netns delete` 一発で残骸なし。
# 対象ブリッジ以外には一切触れない (dnsmasq 側は --bind-interfaces)。
start_lab_dhcp() {
  echo "=== starting lab DHCP (dnsmasq in netns mqvpn-isp) ==="
  local bin
  if command -v dnsmasq >/dev/null; then
    bin="$(command -v dnsmasq)"
  else
    echo "  dnsmasq not found, provisioning via nix (one-time download)"
    bin="$(nix build --no-link --print-out-paths 'nixpkgs#dnsmasq')/bin/dnsmasq"
  fi
  [ -x "$bin" ] || { echo "ERROR: dnsmasq provisioning failed"; exit 1; }
  # 再実行時に前回残があっても壊れないよう stop と同じ順で掃除する
  # (kill せず netns だけ消すと旧 dnsmasq が netns を掴んだまま残り、
  # pidfile 上書きで orphan 化 + 残存 isp-br で `ip link add` が File exists になる)。
  if [ -f /tmp/mqvpn-dnsmasq.pid ]; then
    sudo kill "$(cat /tmp/mqvpn-dnsmasq.pid)" 2>/dev/null || true
  fi
  sudo ip link delete isp-br 2>/dev/null || true
  sudo ip netns delete mqvpn-isp 2>/dev/null || true
  sudo ip netns add mqvpn-isp
  sudo ip link add isp-dhcp type veth peer name isp-br
  sudo ip link set isp-br master mqvpn-srv-br0
  sudo ip link set isp-br up
  sudo ip link set isp-dhcp netns mqvpn-isp
  sudo ip netns exec mqvpn-isp ip link set lo up
  sudo ip netns exec mqvpn-isp ip link set isp-dhcp up
  # dnsmasq は到着 IF 直下以外の subnet を配らないため、12 subnet 分を
  # veth に載せる (.254 は未使用。netns 内のみ有効)。
  # dnsmasq はアドレスの無い IF のパケットを捨てるため、この付与が必須。
  for i in {0..11}; do
    sudo ip netns exec mqvpn-isp ip addr add "10.200.$i.254/24" dev isp-dhcp
  done
  # 前回残のファイルを sudo で掃除 (dnsmasq は --user=root 固定のため root 所有になる)
  sudo rm -f /tmp/mqvpn-dnsmasq.pid /tmp/mqvpn-dnsmasq.leases /tmp/mqvpn-dnsmasq.log
  local macs=(5b 5d 5e 5f 60 61 62 63 64 65 66 68)
  local args=(
    --interface=isp-dhcp --bind-interfaces --port=0 --user=root
    --dhcp-authoritative --pid-file=/tmp/mqvpn-dnsmasq.pid
    --log-facility=/tmp/mqvpn-dnsmasq.log --dhcp-leasefile=/tmp/mqvpn-dnsmasq.leases
  )
  local i mac
  for i in {0..11}; do
    mac="52:54:00:12:34:${macs[$i]}"
    args+=(
      "--dhcp-host=$mac,10.200.$i.2,net:wan$i"
      "--dhcp-range=net:wan$i,10.200.$i.2,10.200.$i.2,255.255.255.0,10m"
      "--dhcp-option=net:wan$i,option:router,10.200.$i.1"
    )
  done
  sudo ip netns exec mqvpn-isp "$bin" "${args[@]}"
  echo "  dnsmasq pid: $(cat /tmp/mqvpn-dnsmasq.pid 2>/dev/null || echo '?') (log: /tmp/mqvpn-dnsmasq.log)"
}

# ビルドして出来たら即座にその VM を起動する (並列用)
build_and_start() {
  local link="$1" attr="$2" suffix="$3"
  echo "=== building $attr ==="
  rm -rf "$SCRIPT_DIR/result-$link" 2>/dev/null || true
  rm -f /tmp/result-$link 2>/dev/null || true
  nix build "path:$REPO_DIR#nixosConfigurations.$attr.config.system.build.vm" \
    --out-link /tmp/result-$link --print-build-logs
  ln -sf /tmp/result-$link "$SCRIPT_DIR/result-$link" 2>/dev/null || true
  echo "=== $attr build done; starting $suffix VM ==="
  setsid "$SCRIPT_DIR/start-vm.sh" "$suffix" </dev/null > "/tmp/mqvpn-$link.log" 2>&1 &
  echo $! > "/tmp/mqvpn-$link.pid"
}

# ネットワークは VM 起動前に必要なので先に構築
echo "=== network setup ==="
setup_network

# 全 VM を並列ビルドし、各 VM は自分のビルドが終わった瞬間に起動。
# server は docker 込みで一番重いので先頭に置き、他のビルド中に立ち上がる。
echo "=== building + launching VMs in parallel ==="
pids=()
for spec in "server:mogami-server:server" "mogami:mogami-vm:router" "client:mogami-client:client" "mnet:mogami-mnet:mnet"; do
  IFS=: read -r link attr suffix <<<"$spec"
  build_and_start "$link" "$attr" "$suffix" & pids+=($!)
done

fail=0
for p in "${pids[@]}"; do
  if ! wait "$p"; then echo "ERROR: a build job failed (pid $p)"; fail=1; fi
done
[ "$fail" -eq 0 ] || exit 1

echo ""
echo "=== done ==="
echo "WAN: 12x tap via mqvpn-srv-br0 (DHCP 10.200.i.2/24, GW 10.200.i.1 = ISP シム) -> host -> mqvpn-srv2-br0"
echo "Server: ts-mq via mqvpn-srv2-br0 (10.200.99.2, ルーターから経路越し)"
echo "LAN: $TAP_ROUTER + $TAP_CLIENT via $BRIDGE (172.16.0.0/12)"
echo "Mgmt: 4x tap via mq-mgmt-br0 (192.168.50.1 router / .2 server / .3 client / .4 mnet)"
echo "Ext: tm-ext + ts-ext via mq-ext-br0 (192.168.100.1 mnet / .2 server)"
echo "VM PIDs: /tmp/mqvpn-{mogami,server,client,mnet}.pid  logs: /tmp/mqvpn-*.log"
