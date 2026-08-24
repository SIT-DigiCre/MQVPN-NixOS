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
#
# 前提:
#   - mnet VM に iperfd が常駐 (bench.sh の ensure_iperfd_mnet で起動)
#   - サーバー→クライアント実IP の戻りルートは不要（ルーター NAPT のため復路は
#     トンネル端点宛。サーバーの 192.168.0.0/24 connected route で足りる）
#   - サーバー mqvpn の CPU 負荷は `docker stats` で確認
# =============================================================================

N=${1:-10}
DUR=${2:-20}
PORT_BASE=5201

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${BENCH_TARGET:-192.168.100.1}"

echo "=== ${N} 並列 iperf3 → ${TARGET} (${DUR}s, ルーター ECMP が A/B 両トンネルへ自動振り分け) ==="
"$SCRIPT_DIR/ssh-client.sh" "rm -f /tmp/ip_*.json /tmp/ip_*.err
for i in \$(seq 1 ${N}); do
  p=\$((i + ${PORT_BASE} - 1))
  (iperf3 -c ${TARGET} -p \$p -t ${DUR} --json > /tmp/ip_\$p.json 2>/tmp/ip_\$p.err) &
done
wait
for i in \$(seq 1 ${N}); do
  p=\$((i + ${PORT_BASE} - 1))
  b=\$(jq -r \".end.sum_sent.bits_per_second // 0\" /tmp/ip_\$p.json 2>/dev/null)
  printf \"client %2d: %.0f Mbit/s\\n\" \$i \$(awk -v v=\$b \"BEGIN{printf \\\"%.1f\\\", v/1e6}\")
done
jq -s \"[.[] | .end.sum_sent.bits_per_second // 0] | {total_mbit_s: (add/1e6), clients_with_data: ([.[]|select(.>0)]|length)}\" /tmp/ip_*.json"
