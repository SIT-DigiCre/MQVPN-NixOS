#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mqvpn ラボ統合ベンチ/プロファイルツール
#
# 調査で使った個別スクリプト (repro-cpu-saturation.sh / latency-repro.sh /
# latency-hetero-repro.sh) の機能を1つにまとめたもの。perf プロファイリングも可。
#
# Usage:
#   ./test/bench.sh clean
#       ルーター WAN の netem を解除し、サーバーを標準サービス (ビルド時設定) に戻す
#
#   ./test/bench.sh latency <delay_ms> [rate] [sec] [dir]
#       ルーター WAN NIC 全てに均一 netem (遅延のみ, limit 100000)。
#       dir: up (クライアント送信=ルーターが送信側) / down (サーバー送信)
#       例: ./test/bench.sh latency 50 800 15 down
#
#   ./test/bench.sh hetero [rate] [sec] [dir]
#       実パス想定の不均質 netem (45/45/75/75/15ms + ロス) を適用
#
#   ./test/bench.sh multistream <n> [sec]
#       下流 n クライアント並列 (iperf3 ポート別) + サーバー CPU
#
#   ./test/bench.sh profile <delay_ms> [rate] [sec] [dir]
#       netem 適用 + サーバー(send側) の perf record/report
#       (要: サーバーが pkgs/mqvpn-dbg.nix ビルドのシンボル付きバイナリで動作)
#       注意: perf の CPU 集計は dmesg/perf 権限が要るので sudo 使用 (サーバー側)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELLO_CMD="latency|hetero|multistream|profile|clean"
[ $# -ge 1 ] || { echo "usage: $0 <$HELLO_CMD> [...]"; exit 1; }
CMD="$1"; shift || true

# --- SSH ヘルパ (ssh-*.sh は nix shell で sshpass を用意する) ---
ssh_srv() { "$SCRIPT_DIR/ssh-server.sh" "$@"; }
ssh_rtr() { timeout 90 "$SCRIPT_DIR/ssh-router.sh" "$@"; }
ssh_cli() { "$SCRIPT_DIR/ssh-client.sh" "$@"; }

SAMPLER_DUR=30

# --- サンプラ等の配送 ---
ship_common() {
  local samp
  samp=$(cat << 'SAMP'
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
)
  printf '%s\n' "$samp" | ssh_srv 'cat > /tmp/cpusamp.sh && chmod +x /tmp/cpusamp.sh' >/dev/null 2>&1 || true
  printf '%s\n' "$samp" | ssh_rtr 'cat > /tmp/cpusamp.sh && chmod +x /tmp/cpusamp.sh' >/dev/null 2>&1 || true
}

# --- netem ---
rtr_wan=(eth2 eth4 eth5 eth6 eth7)

clear_netem() {
  ssh_rtr 'for i in eth2 eth4 eth5 eth6 eth7; do sudo -n tc qdisc del dev $i root 2>/dev/null || true; done; echo netem-cleared' 2>/dev/null || true
}

apply_uniform() {
  local ms="$1"
  ssh_rtr "for i in eth2 eth4 eth5 eth6 eth7; do
    sudo -n tc qdisc replace dev \$i root netem delay ${ms}ms limit 100000 2>/dev/null ||
    sudo -n tc qdisc add dev \$i root netem delay ${ms}ms limit 100000
  done; echo applied" 2>/dev/null
}

apply_hetero() {
  ssh_rtr 'sudo -n tc qdisc add dev eth2 root netem delay 45ms 12ms loss 1% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth2 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth4 root netem delay 45ms 12ms loss 1% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth4 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth5 root netem delay 75ms 25ms loss 0.5% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth5 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth6 root netem delay 75ms 25ms loss 0.5% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth6 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth7 root netem delay 15ms 4ms loss 0.2% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth7 root netem delay 15ms 4ms loss 0.2% limit 100000;
echo applied' 2>/dev/null
}

# === iperf3 ===
samp_start() {
  local dur="$1"
  ssh_srv "rm -f /tmp/cpuS.log; nohup /tmp/cpusamp.sh ${dur} > /tmp/cpuS.log 2>&1 & echo ok" >/dev/null 2>&1 || true
  ssh_rtr "rm -f /tmp/cpuR.log; nohup /tmp/cpusamp.sh ${dur} > /tmp/cpuR.log 2>&1 & echo ok" >/dev/null 2>&1 || true
}

samp_max() { # $1=host S|R
  local h="$1"
  if [ "$h" = "S" ]; then
    ssh_srv 'grep -o "jiffies/s=[0-9]*" /tmp/cpuS.log | sort -t= -k2 -n | tail -1 | sed "s/jiffies\/s=//"' 2>/dev/null | tail -1
  else
    ssh_rtr 'grep -o "jiffies/s=[0-9]*" /tmp/cpuR.log | sort -t= -k2 -n | tail -1 | sed "s/jiffies\/s=//"' 2>/dev/null | tail -1 || echo "?"
  fi
}

# --- iperf3 ---
run_udp() { # rate dir sec
  local rate="$1" dir="$2" sec="$3"
  local flag=""
  [ "$dir" = "down" ] && flag="-R"
  ssh_cli "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#iperf3 --command iperf3 -c 192.168.0.1 -p 6205 -u ${flag} -b ${rate}M -t ${sec} -f m 2>&1 | grep receiver | tail -1" 2>/dev/null | tail -1
}

ensure_iperfd() {
  ssh_srv 'ss -tln | grep -q 6205 || iperf3 -s -p 6205 -D --logfile /tmp/iperf3-6205.log; echo iperfd-ok' >/dev/null 2>&1 || true
}

# =============================================================================
CMDRUN="latency|hetero|multistream|profile|clean"

case "$CMD" in
  clean)
    clear_netem
    ssh_srv 'sudo -n pkill -x mqvpn 2>/dev/null; sudo -n systemctl start mqvpn-server 2>/dev/null; sleep 3; echo restored' 2>/dev/null | tail -1
    ;;
  latency)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    ensure_iperfd; ship_common; clear_netem; apply_uniform "$MS"
    sleep 8
    ssh_cli "ping -c 2 -W 3 192.168.0.1 2>&1 | tail -1" 2>/dev/null | tail -1
    samp_start "$((SEC + 6))"
    out=$(run_udp "$RATE" "$DIR" "$SEC")
    sleep 1
    echo "== ${DIR} ${RATE}M @ ${MS}ms =="
    echo "  iperf : $out"
    echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
    ;;
  hetero)
    RATE="${1:-800}"; SEC="${2:-15}"; DIR="${3:-down}"
    ensure_iperfd; ship_common; clear_netem; apply_hetero
    sleep 8
    samp_start "$((SEC + 6))"
    out=$(run_udp "$RATE" "$DIR" "$SEC")
    sleep 1
    echo "== hetero ${DIR} ${RATE}M =="
    echo "  iperf : $out"
    echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
    ;;
  multistream)
    N="${1:-10}"; SEC="${2:-20}"
    ensure_iperfd; ship_common
    "$SCRIPT_DIR/repro-cpu-saturation.sh" "$N" "$SEC"
    ;;
  profile)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    ensure_iperfd; ship_common; clear_netem; apply_uniform "$MS"
    sleep 8
    PERF=$(ssh_srv "command -v perf 2>/dev/null | tail -1")
    [ -n "$PERF" ] || PERF=$(ssh_srv "nix --extra-experimental-features 'nix-command flakes' shell nixpkgs#linuxPackages_latest.perf -c bash -c 'command -v perf' 2>/dev/null | tail -1")
    [ -n "$PERF" ] || { echo "perf not found on server"; exit 1; }
    PERFDATA=/tmp/perf.data
    ssh_srv "rm -f ${PERFDATA}; sudo -n bash -c 'nohup ${PERF} record -F 99 -e cpu-clock -g -p \$(pgrep -x mqvpn) -o ${PERFDATA} -- sleep $((SEC + 4)) >/tmp/perf-record.log 2>&1 &'" >/dev/null 2>&1
    out=$(run_udp "$RATE" "$DIR" "$SEC")
    sleep 5
    echo "== profile ${DIR} ${RATE}M @ ${MS}ms =="
    echo "  iperf : $out"
    ssh_srv "sudo -n ${PERF} report -i ${PERFDATA} --stdio --sort symbol --no-child --percent-limit 2 2>&1 | grep -E '^ *[0-9.]+\%  \[\.\]' | head -12" 2>/dev/null | tail -12
    ;;
  *)
    echo "unknown: $CMD (use: $CMDRUN)"; exit 1
    ;;
esac
