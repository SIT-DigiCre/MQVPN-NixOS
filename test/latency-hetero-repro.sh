#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 実環境(7パス)の「パス間の不均質遅延・ロス」がサーバーCPUに与える影響を再現する
#
# 均一遅延の実験(latency-repro.sh)ではスループットは落ちてもサーバーCPUは
# 上がらなかった。実環境の「600Mbps @ サーバー単スレッド100%」は、パス間の
# RTT差(順序逆転 → 受信側の reorder/reinjection 処理)や実ロス(再送・重複処理)が
# 主因と仮説を立て、ルーター VM の WAN NIC (eth2/4-7) に netem を掛けて検証する。
#
# パス構成 (デフォルト = 実環境の分類に寄せた 5パス版):
#   eth2: Starlink系  45ms ±12ms, ロス1%
#   eth4: Starlink系  45ms ±12ms, ロス1%
#   eth5: モバイル系  75ms ±25ms, ロス0.5%
#   eth6: モバイル系  75ms ±25ms, ロス0.5%
#   eth7: eduroam系   15ms ±4ms,  ロス0.2%
#   共通: limit 100000 (netemのキュー溢れによる疑似ロスを防ぐ)
#
# Usage: ./test/latency-hetero-repro.sh [duration_sec] [udp_rate_mbps] [clear]
#   第3引数に clear を渡すと netem を消すだけ
# =============================================================================

DUR=${1:-15}
RATE=${2:-1000}
MODE=${3:-run}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

clear_netem() {
  "$SCRIPT_DIR/ssh-router.sh" 'for i in eth2 eth4 eth5 eth6 eth7; do sudo -n tc qdisc del dev $i root 2>/dev/null || true; done; echo cleared'
}

if [ "$MODE" = "clear" ]; then
  clear_netem
  exit 0
fi

echo "=== clearing old netem on router WAN NICs ==="
clear_netem

echo "=== applying heterogeneous netem on router WAN (eth2/4/5/6/7) ==="
"$SCRIPT_DIR/ssh-router.sh" 'sudo -n tc qdisc add dev eth2 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth4 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth5 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth6 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth7 root netem delay 15ms 4ms loss 0.2% limit 100000;
echo applied'

echo "=== tunnel RTT check (client -> 192.168.0.1) ==="
"$SCRIPT_DIR/ssh-client.sh" "ping -c 3 -W 3 192.168.0.1 2>&1 | tail -1"

echo "=== server + router mqvpn CPU samplers ==="
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
echo server-ok'

"$SCRIPT_DIR/ssh-router.sh" 'cat > /tmp/cpusamp.sh << "SAMP"
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
rm -f /tmp/cpu-router.log
nohup /tmp/cpusamp.sh '"$((DUR + 6))"' > /tmp/cpu-router.log 2>&1 &
echo router-ok'

echo "=== UDP ${RATE}Mbps x ${DUR}s (client -> tunnel) ==="
"$SCRIPT_DIR/ssh-client.sh" "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#iperf3 --command iperf3 -c 192.168.0.1 -p 6205 -u -b ${RATE}M -t ${DUR} -f m 2>&1 | grep -E 'sender|receiver' | tail -2" 2>&1 | grep -E "sender|receiver|error" || echo "(iperf3 failed - check server iperf3 on 6205)"

sleep 1
echo "=== server mqvpn CPU (100=1コア飽和) ==="
"$SCRIPT_DIR/ssh-server.sh" "head -$((DUR + 2)) /tmp/cpu-server.log" 2>&1 | tail -$((DUR + 1)) | head -$((DUR - 1))

echo "=== router mqvpn CPU (100=1コア飽和) ==="
"$SCRIPT_DIR/ssh-router.sh" "head -$((DUR + 2)) /tmp/cpu-router.log" 2>&1 | tail -$((DUR + 1)) | head -$((DUR - 1))

echo ""
echo "netem を外すには: sudo ./test/latency-hetero-repro.sh 0 0 clear"
