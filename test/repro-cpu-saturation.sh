#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mqvpn サーバーのシングルスレッド CPU 飽和を再現する
#
# 下流で複数クライアントが speedtest を同時実行した状況を模擬する。
# iperf3 サーバーは 1 ポートにつき 1 テストしか処理できないため、
# クライアントごとに別ポートでサーバーを立てて並列テストを行う。
#
# Usage:
#   ./test/repro-cpu-saturation.sh [num_clients] [duration_sec]
#
# 出力:
#   - クライアントごとのスループット (Mbit/s) と合計
#   - サーバー VM の mqvpn プロセス CPU (jiffies/s) — 100 = 1コア飽和
# =============================================================================

N=${1:-10}
DUR=${2:-20}
PORT_BASE=5201

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== step 1: iperf3 server をサーバー VM に ${N} 本起動 (port ${PORT_BASE}-$((PORT_BASE + N - 1))) ==="
"$SCRIPT_DIR/ssh-server.sh" "pkill -x iperf3 2>/dev/null; sleep 1; for p in \$(seq ${PORT_BASE} $((PORT_BASE + N - 1))); do iperf3 -s -p \$p -D -1 --logfile /tmp/iperf3-\$p.log; done; sleep 2; echo listening=\$(ss -tln | grep -cE ':(52[0-9]{2})')"

echo "=== step 2: サーバー VM の mqvpn CPU サンプラを起動 ==="
"$SCRIPT_DIR/ssh-server.sh" 'cat > /tmp/cpusamp.sh << "SAMPLER"
#!/usr/bin/env bash
pid=$(pgrep -x mqvpn | head -1)
echo "sampling pid=$pid"
prev_ut=$(awk "{print \$14}" /proc/$pid/stat)
prev_st=$(awk "{print \$15}" /proc/$pid/stat)
prev_sys=$(awk "{s=\$1+\$2+\$3+\$4+\$5+\$6+\$7+\$8} END{print s}" /proc/stat)
i=0
while [ "$i" -lt "${1:-30}" ]; do
  sleep 1
  i=$((i+1))
  ut=$(awk "{print \$14}" /proc/$pid/stat)
  st=$(awk "{print \$15}" /proc/$pid/stat)
  sys=$(awk "{s=\$1+\$2+\$3+\$4+\$5+\$6+\$7+\$8} END{print s}" /proc/stat)
  d_j=$(( (ut + st) - (prev_ut + prev_st) ))
  d_s=$(( sys - prev_sys ))
  echo "t=${i}s jiffies/s=${d_j}"
  prev_ut=$ut
  prev_st=$st
  prev_sys=$sys
done
SAMPLER
chmod +x /tmp/cpusamp.sh
rm -f /tmp/cpu.log
nohup /tmp/cpusamp.sh '"$((DUR + 6))"' > /tmp/cpu.log 2>&1 &
echo sampler-started'

echo "=== step 3: クライアント VM から ${N} 並列で iperf3 実行 (${DUR}s) ==="
"$SCRIPT_DIR/ssh-client.sh" "rm -f /tmp/ip_*.json /tmp/ip_*.err
for p in \$(seq ${PORT_BASE} $((PORT_BASE + N - 1))); do
  (iperf3 -c 192.168.0.1 -p \$p -t ${DUR} --json > /tmp/ip_\$p.json 2>/tmp/ip_\$p.err) &
done
wait
for p in \$(seq ${PORT_BASE} $((PORT_BASE + N - 1))); do
  b=\$(jq -r \".end.sum_sent.bits_per_second // 0\" /tmp/ip_\$p.json 2>/dev/null)
  printf \"client %2d: %.0f Mbit/s\\n\" \$((p - ${PORT_BASE} + 1)) \$(awk -v v=\$b \"BEGIN{printf \\\"%.1f\\\", v/1e6}\")
done
jq -s \"[.[] | .end.sum_sent.bits_per_second // 0] | {total_mbit_s: (add/1e6), clients_with_data: ([.[]|select(.>0)]|length)}\" /tmp/ip_*.json"

echo "=== step 4: サーバー mqvpn CPU ログ (100 jiffies/s = 1コア飽和) ==="
sleep 1
"$SCRIPT_DIR/ssh-server.sh" "cat /tmp/cpu.log"
