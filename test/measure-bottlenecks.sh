#!/usr/bin/env bash
# =============================================================================
# mqvpn ラボ ボトルネック一斉計測
#
# 各ホップのスループット・CPU・netem 上限を、負荷中にサンプリングして
# 「どこが詰まっているか」を可視化する。想定ボトルネック:
#   - サーバー mqvpn-server のシングルスレッド CPU (doc: mqvpn-single-thread-cpu-bottleneck)
#   - 各 WAN パスの netem 上限に対する利用率
#   - ルーター mqvpn の CPU
#   - トンネル (mqvpn0/mqvpn1) の実効スループット
#
# Usage:
#   ./test/measure-bottlenecks.sh [duration_sec] [target_ip] [port]
#     duration_sec : 負荷を流す秒数 (既定 20) — ウォームアップ後の計測窓
#     target_ip    : iperf 宛先 (既定 192.168.100.1 = mnet)
#     port         : iperf ポート (既定 6205)
#     BENCH_WARMUP : 負荷だけ流して捨てる秒数 (既定 30)。
#                    WLB 推定器 (est_bw 等) は分単位で収束するため、ここで
#                    「推定器が整う前」を窓から除外する (= 負荷全体は WARMUP+DUR)。
#                    収束確認: ./test/bench.sh wlbstate
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUR="${1:-20}"
TARGET="${2:-192.168.100.1}"
PORT="${3:-6205}"
WARMUP="${BENCH_WARMUP:-30}"

ssh_srv() { timeout 90 "$SCRIPT_DIR/ssh-server.sh" "$@"; }
ssh_rtr() { timeout 90 "$SCRIPT_DIR/ssh-router.sh" "$@"; }
ssh_cli() { timeout 90 "$SCRIPT_DIR/ssh-client.sh" "$@"; }
ssh_mnet() { timeout 90 "$SCRIPT_DIR/ssh-mnet.sh" "$@"; }

# --- iperfd を mnet に常駐 (bench.sh と同じ) ---
ssh_mnet 'for p in '"$PORT"' $(seq 5201 5300); do ss -tln | grep -q ":$p " || iperf3 -s -p $p -D --logfile /tmp/i3-$p.log 2>/dev/null; done; echo ok' >/dev/null 2>&1 || true

BLOG=/tmp/mb_bytes.log; SLOG=/tmp/mb_srv.log; RLOG=/tmp/mb_rtr.log
: > "$BLOG"; : > "$SLOG"; : > "$RLOG"

snap_bytes() { # eth1/3/4 + mqvpn0/1 の rx tx を 10 個出力
  ssh_rtr 'for d in eth1 eth3 eth4 mqvpn0 mqvpn1; do ip -s link show $d | awk "/RX:/{getline;printf \"%s \",\$1} /TX:/{getline;printf \"%s \",\$1}"; done; echo' 2>/dev/null | grep -vE "fetching|Warning:"
}
snap_srv() { # サーバー mqvpn コンテナの CPU%
  ssh_srv 'sudo docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}"' 2>/dev/null | grep -vE "fetching|Warning:"
}
snap_rtr() { # ルーター全 CPU の busy/total (jiffies)
  ssh_rtr 'grep "^cpu " /proc/stat | awk "{b=\$2+\$3+\$4; t=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9; print b, t}"' 2>/dev/null | grep -vE "fetching|Warning:"
}

echo "############ MQVPN LAB BOTTLENECK PROFILER ############"
echo "duration=$DUR  target=$TARGET  port=$PORT"
echo
echo "=== [static] netem ceiling per WAN path ==="
ssh_rtr 'for d in eth1 eth3 eth4; do printf "  %-6s %s\n" "$d" "$(tc qdisc show dev $d | grep -o "rate [0-9]*Mbit")"; done' 2>&1 | grep -vE "fetching|Warning:"
echo "  (合計上限: $(ssh_rtr 's=0; for d in eth1 eth3 eth4; do r=$(tc qdisc show dev $d | grep -o "rate [0-9]*Mbit" | grep -o "[0-9]*"); s=$((s+r)); done; echo ${s}Mbit')"
echo
echo "=== [static] mqvpn paths / srtt (latest STATUS) ==="
ssh_rtr 'sudo journalctl -n 200 --no-pager 2>/dev/null | grep -E "path[0-2]=eth" | tail -3' 2>&1 | grep -vE "fetching|Warning:"

echo
echo "=== running load: iperf3 -P 20 -R -t $((WARMUP + DUR)) s (client -> $TARGET) ==="
printf '(sampling window: steady-state after %ss warmup, window=%ss)\n' "$WARMUP" "$DUR"
ssh_cli "iperf3 -c $TARGET -p $PORT -P 20 -R -t $((WARMUP + DUR)) --omit $WARMUP > /tmp/mb_iperf.txt 2>&1" &
IPERF=$!

sleep "$WARMUP"
for ((i=0; i<DUR; i+=5)); do
  echo "$(snap_bytes)" >> "$BLOG"
  echo "$(snap_srv)"   >> "$SLOG"
  echo "$(snap_rtr)"   >> "$RLOG"
  sleep 5
done
wait "$IPERF" || true

echo
echo "=== [result] aggregate throughput (client SUM receiver; avg over full iperf window WARMUP+DUR — steady figure is per-path TOTAL below) ==="
ssh_cli "grep 'SUM.*receiver' /tmp/mb_iperf.txt 2>/dev/null" 2>&1 | grep -vE "fetching|Warning:" | tail -1

# --- per-path / per-tunnel スループット ---
read -r -a B0 <<< "$(head -1 "$BLOG")"
read -r -a B1 <<< "$(tail -1 "$BLOG")"
pairs=(eth1:0,1 eth3:2,3 eth4:4,5 mqvpn0:6,7 mqvpn1:8,9)
echo
echo "=== [result] per-interface throughput (Mbps, window=$DUR s) ==="
printf "  %-8s %10s %10s %12s\n" IFACE "rx+tx_Mbps" "ceiling" "util%"
# ceiling 配列 (eth1/3/4 のみ)
declare -A CEIL=( [eth1]=458 [eth3]=400 [eth4]=450 )
total=0
for p in "${pairs[@]}"; do
  name="${p%%:*}"; idx="${p##*:}"; rx=${idx%,*}; tx=${idx#*,}
  d=$(( (${B1[$tx]} + ${B1[$rx]}) - (${B0[$tx]} + ${B0[$rx]}) ))
  mbps=$(( d * 8 / (DUR * 1000000) ))
  ceil="${CEIL[$name]:-NA}"
  if [ "$ceil" != "NA" ]; then util=$(( mbps * 100 / ceil )); else util="NA"; fi
  printf "  %-8s %10d %10s %11s%%\n" "$name" "$mbps" "$ceil" "$util"
  total=$((total + mbps))
done
echo "  -----------------------------------------"
echo "  TOTAL (tunnel-bound) = ${total} Mbps"

# --- サーバー CPU (最大値) ---
echo
echo "=== [result] server mqvpn CPU% (max over window) ==="
grep -E "mqvpn-server" "$SLOG" | sed 's/%//' | awk '{v=$2+0; if(v>max) max=v} END{printf "  max mqvpn-server CPU = %.0f%%\n", max}' || echo "  (no data)"

# --- ルーター CPU ---
echo
echo "=== [result] router total CPU% (window avg) ==="
awk 'NR==1{b0=$1; t0=$2} {b1=$1; t1=$2} END{if(t1>t0) printf "  %.0f%%\n", (b1-b0)*100/(t1-t0); else print "  n/a"}' "$RLOG"

echo
echo "=== interpretation ==="
echo "  - 合計 << netem 上限(1308M) ならパス帯域ではなく他が詰まってる"
echo "  - server mqvpn CPU ~100% ならシングルスレッド飽和 (doc: single-thread-cpu-bottleneck)"
echo "  - 各パス util% が低いままなら wlb が分散させており崩壊レジーム外"
