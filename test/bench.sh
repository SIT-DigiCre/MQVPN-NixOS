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
#       ルーター WAN の netem を解除し、サーバー(compose の mqvpn-server-*)
#       が停止していれば再起動する
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
#       (OCI イメージ同梱のリリースバイナリ。ECMP 全コンテナの mqvpn を対象に
#       するためシンボル注釈はバイナリ側に無い — 集計は [kernel]/[.] 単位)
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
# サーバーは OCI コンテナ (ECMP で複数) — mqvpn プロセスを全 PID 合算する。
# ホストの /proc にはコンテナプロセスも見えるため pgrep はホスト側で足りる。
pids=$(pgrep -x mqvpn 2>/dev/null | tr '\n' ' ')
[ -n "$pids" ] || { echo "no mqvpn process"; exit 0; }
echo "sampling pids=$pids"
sum_jiffies() { # f=14(utime)|15(stime)
  local f="$1" s=0 p
  for p in $pids; do
    [ -r "/proc/$p/stat" ] || continue
    s=$((s + $(awk "{print \$$f}" "/proc/$p/stat")))
  done
  echo "$s"
}
prev_ut=$(sum_jiffies 14)
prev_st=$(sum_jiffies 15)
i=0
while [ "$i" -lt "${1:-30}" ]; do
  sleep 1
  i=$((i+1))
  ut=$(sum_jiffies 14)
  st=$(sum_jiffies 15)
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
rtr_wan=(eth1 eth3 eth4 eth5 eth6)

clear_netem() {
  ssh_rtr 'for i in eth1 eth3 eth4 eth5 eth6; do sudo -n tc qdisc del dev $i root 2>/dev/null || true; done; echo netem-cleared' 2>/dev/null || true
}

apply_uniform() {
  local ms="$1"
  ssh_rtr "for i in eth1 eth3 eth4 eth5 eth6; do
    sudo -n tc qdisc replace dev \$i root netem delay ${ms}ms limit 100000 2>/dev/null ||
    sudo -n tc qdisc add dev \$i root netem delay ${ms}ms limit 100000
  done; echo applied" 2>/dev/null
}

apply_hetero() {
  ssh_rtr 'sudo -n tc qdisc add dev eth1 root netem delay 45ms 12ms loss 1% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth1 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth3 root netem delay 45ms 12ms loss 1% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth3 root netem delay 45ms 12ms loss 1% limit 100000;
sudo -n tc qdisc add dev eth4 root netem delay 75ms 25ms loss 0.5% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth4 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth5 root netem delay 75ms 25ms loss 0.5% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth5 root netem delay 75ms 25ms loss 0.5% limit 100000;
sudo -n tc qdisc add dev eth6 root netem delay 15ms 4ms loss 0.2% limit 100000 2>/dev/null || sudo -n tc qdisc replace dev eth6 root netem delay 15ms 4ms loss 0.2% limit 100000;
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
# ターゲット: 既定は mnet VM (フルチェーン計測 — ルーターの ECMP が
# 自動で A/B 両サーバーへフローを振り分ける)。
# BENCH_TARGET=192.168.0.1 でトンネル peer 宛の従来計測も可能 (非推奨)。
TARGET="${BENCH_TARGET:-192.168.100.1}"

# サーバーコンテナ名を動的解決 (mqvpn-server-N のハードコードを避ける)
SRV_CTR=$("$SCRIPT_DIR/ssh-server.sh" 'sudo docker ps --filter name=mqvpn-server --format "{{.Names}}" | head -1' 2>/dev/null | tr -d '\r')
SRV_CTR="${SRV_CTR:-mqvpn-server-0}"

ensure_iperfd_mnet() {
  # 172.17.0.0/16 (docker0) への戻りルートは mogami-mnet.nix で静的に宣言済み。
  # トンネル (tun mtu 1382) より大きいデータグラムは frag-needed ICMP で
  # iperf3 の送信が abort する (初回 DOWN 0/0 の根本原因) —
  # mnet の MTU をコンテナの tun MTU に合わせ、PMTU 学習に依存しないようにする
  # (UDP のみの暫定対応。根本解決は TCP MSS clamp / 正しい route MTU の設定)。
  TUN_MTU=$("$SCRIPT_DIR/ssh-server.sh" "sudo docker exec $SRV_CTR cat /sys/class/net/mqvpn0/mtu" 2>/dev/null | tail -1)
  if [ -n "$TUN_MTU" ] && [ "$TUN_MTU" -gt 0 ] 2>/dev/null; then
    "$SCRIPT_DIR/ssh-mnet.sh" "sudo -n ip link set eth0 mtu $TUN_MTU" >/dev/null 2>&1
  fi
  "$SCRIPT_DIR/ssh-mnet.sh" 'for p in 6205 $(seq 5201 5300); do ss -tln | grep -q $p || iperf3 -s -p $p -D --logfile /tmp/i3-$p.log 2>/dev/null; done; echo iperfd-mnet-ok' >/dev/null 2>&1 || true
}

run_udp() { # rate dir sec
  local rate="$1" dir="$2" sec="$3"
  local flag=""
  [ "$dir" = "down" ] && flag="-R"
  ssh_cli "iperf3 -c $TARGET -p 6205 -u ${flag} -b ${rate}M -t ${sec} -f m 2>&1 | grep receiver | tail -1" 2>/dev/null | tail -1
}


# --- サーバー→クライアント実IP への戻りルートは intentionally 付けない ---
# ルーター側 NAPT(MASQUERADE) のため復路宛先はトンネル端点(192.168.0.2)となり、
# サーバーの 192.168.0.0/24 connected route で足りる。戻りルート(172.16.0.0/12)
# は NAPT 構成では不要(過去の SLiRP 環境限定シナリオ)。DOWN 計測は mnet
# (192.168.100.1) 宛をクライアントから -R で打ち、NAPT 互換の流れで行う。

# --- クライアントの UDP 受信バッファ拡大 ---
# 高レート測定 (特に RTT≈0 のラボ) では受信側ソケット溢れがロスに見えるため、
# rmem を 64MB に拡大する (chiken/mqvpn-loss-investigation.md 参照)
ensure_rmem() {
  ssh_cli 'sudo -n sysctl -w net.core.rmem_max=67108864 net.core.rmem_default=67108864 >/dev/null; echo rmem-ok' >/dev/null 2>&1 || true
}

# =============================================================================
CMDRUN="latency|hetero|multistream|profile|clean"

case "$CMD" in
  clean)
    clear_netem
    # サーバーは compose (mqvpn-compose unit) が管理するコンテナ群。
    # 稼働判定/再起動は docker 経由にする (旧 systemd 直起動は廃止)
    ssh_srv 'sudo -n docker ps --filter name=mqvpn-server --format "{{.Names}}" | grep -q . && echo running || { sudo -n systemctl restart mqvpn-compose; sleep 3; echo restarted; }' 2>/dev/null | tail -1
    ;;
  latency)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    ensure_iperfd_mnet; ensure_rmem; ship_common; clear_netem; apply_uniform "$MS"
    sleep 8
    ssh_cli "ping -c 2 -W 3 $TARGET 2>&1 | tail -1" 2>/dev/null | tail -1
    samp_start "$((SEC + 6))"
    out=$(run_udp "$RATE" "$DIR" "$SEC")
    sleep 1
    echo "== ${DIR} ${RATE}M @ ${MS}ms =="
    echo "  iperf : $out"
    echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
    ;;
  hetero)
    RATE="${1:-800}"; SEC="${2:-15}"; DIR="${3:-down}"
    ensure_iperfd_mnet; ensure_rmem; ship_common; clear_netem; apply_hetero
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
    ensure_iperfd_mnet; ensure_rmem; ship_common
    "$SCRIPT_DIR/repro-cpu-saturation.sh" "$N" "$SEC"
    ;;
  profile)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    ensure_iperfd_mnet; ensure_rmem; ship_common; clear_netem; apply_uniform "$MS"
    sleep 8
    PERF=$(ssh_srv "command -v perf 2>/dev/null | tail -1")
    [ -n "$PERF" ] || { echo "perf not found on server"; exit 1; }
    PERFDATA=/tmp/perf.data
    # ECMP で複数コンテナに分散 → 全 mqvpn プロセスを対象に (ホスト perf は
    # コンテナプロセスへホスト PID でアタッチできる)
    ssh_srv "rm -f ${PERFDATA}; sudo -n bash -c 'p=\$(pgrep -x mqvpn | paste -sd, -); [ -n \"\$p\" ] || { echo no-mqvpn >/tmp/perf-record.log; exit 1; }; nohup ${PERF} record -F 99 -e cpu-clock -g -p \$p -o ${PERFDATA} -- sleep $((SEC + 4)) >/tmp/perf-record.log 2>&1 &'" >/dev/null 2>&1
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
