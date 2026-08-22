#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 実環境の WAN 経路遅延がトンネル性能(サーバー単スレッドCPU)に与える影響を再現する
#
# 背景: 実環境(Ryzen 9 7900, 7パス: Starlink×3/モバイル×3/eduroam×1)では
#       600Mbps 程度でサーバーの単スレッド mqvpn CPU が 100% になる。
#       ラボ(遅延≈0ms の 5 本の tap)では ~3Gbps まで通る。
#       この差が「経路遅延」に起因するかを tc netem で検証する。
#
# netem の適用先:
#   - ts-mq  (サーバー側 tap):   クライアント→サーバー方向に +DELAYms
#   - trw0-4 (ルーター側 tap×5): サーバー→クライアント方向に +DELAYms
#   よって往復 RTT は約 +2×DELAYms 増加する。
#
# Usage (sudo 必須: tap の qdisc を触るため):
#   sudo ./test/latency-repro.sh [delay_ms] [duration_sec] [udp_rate_mbps]
#   例: sudo ./test/latency-repro.sh 50 15 1000
#        → RTT +100ms、15秒間、UDP 1000Mbps で計測
#
# 出力:
#   - クライアント→トンネル先(192.168.0.1)の RTT
#   - iperf3 UDP の受信レートとロス率
#   - サーバー/ルーターの mqvpn CPU (jiffies/s, 100=1コア飽和)
# =============================================================================

DELAY=${1:-50}
DUR=${2:-15}
RATE=${3:-1000}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAPS=(trw0 trw1 trw2 trw3 trw4 ts-mq)

if [ "$(id -u)" != 0 ]; then
  echo "ERROR: needs root (sudo) to configure tap qdiscs"
  exit 1
fi

cleanup() {
  for t in "${TAPS[@]}"; do
    tc qdisc del dev "$t" root 2>/dev/null || true
  done
  echo "=== netem cleared ==="
}
trap cleanup EXIT

echo "=== applying netem: +${DELAY}ms each direction (ts-mq + trw0-4) ==="
for t in "${TAPS[@]}"; do
  tc qdisc replace dev "$t" root netem delay "${DELAY}ms"
done

echo "=== tunnel RTT check (client -> 192.168.0.1) ==="
"$SCRIPT_DIR/ssh-client.sh" "ping -c 3 -W 3 192.168.0.1 2>&1 | tail -1"

echo "=== server mqvpn CPU sampler + router sampler ==="
"$SCRIPT_DIR/ssh-server.sh" 'cat > /tmp/cpusamp.sh << "SAMP"
#!/usr/bin/env bash
pid=$(pgrep -x mqvpn | head -1)
echo "sampling pid=$pid"
prev_ut=$(awk "{print \$14}" /proc/$pid/stat)
prev_st=$(awk "{print \$15}" /proc/$pid/stat)
i=0
while [ "$i" -lt "${1:-30}" ]; do
  sleep 1
  i=$((i+1))
  ut=$(awk "{print \$14}" /proc/$pid/stat)
  st=$(awk "{print \$15}" /proc/$pid/stat)
  d_j=$(( (ut + st) - (prev_ut + prev_st) ))
  echo "t=${i}s jiffies/s=${d_j}"
  prev_ut=$ut
  prev_st=$st
done
SAMP
chmod +x /tmp/cpusamp.sh
rm -f /tmp/cpu-server.log
nohup /tmp/cpusamp.sh '"$((DUR + 6))"' > /tmp/cpu-server.log 2>&1 &
echo server-sampler-started'

echo "=== UDP ${RATE}Mbps x ${DUR}s (client -> tunnel) ==="
"$SCRIPT_DIR/ssh-client.sh" "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#iperf3 --command iperf3 -c 192.168.0.1 -p 6205 -u -b ${RATE}M -t ${DUR} -f m 2>&1 | grep -E 'sender|receiver' | tail -2" 2>&1 | grep -E "server is running|sender|receiver|error|refused" || echo "(iperf3 failed - check server iperf3 on 6205)"

echo "=== server mqvpn CPU ==="
sleep 1
"$SCRIPT_DIR/ssh-server.sh" "cat /tmp/cpu-server.log" 2>&1 | tail -$((DUR + 5)) | head -$((DUR + 2))
