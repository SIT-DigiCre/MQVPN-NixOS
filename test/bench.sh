#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mqvpn ラボ統合ベンチ/プロファイルツール
#
# 調査で使った個別スクリプト (repro-cpu-saturation.sh) の機能を1つにまとめたもの。
# perf プロファイリングも可。
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
#       実パス想定の不均質 netem (Starlink系45ms×5 / モバイル系75ms×5 /
#       eduroam系15ms×2 + ロス) を適用
#
#   ./test/bench.sh collapse3
#       本番 3x Starlink 崩壊再現: WAN 3 本 (eth1=A / eth3=B / eth4=C) に
#       A=30ms/458M, B=42ms+pareto/400M, C=35ms/450M を適用し、TCP 単一/多フロー
#       での 1 パス固着(崩壊) と UDP での全パス分散を per-path で表示。
#
#   ./test/bench.sh measure [tcp|udp] [P] [rate] [dir] [sec]
#       任意の netem 下で iperf3 を流し、各 WAN の rx スループット・ceiling 比・
#       利用率・TOTAL・クライアント合計を表示 (collapse3 等で事前に netem を掛けて使う)。
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

HELLO_CMD="latency|hetero|collapse3|measure|multistream|profile|stagger|clean"
[ $# -ge 1 ] || { echo "usage: $0 <$HELLO_CMD> [...]"; exit 1; }
CMD="$1"; shift || true

# --- SSH ヘルパ (ssh-*.sh は nix shell で sshpass を用意する) ---
ssh_srv() { "$SCRIPT_DIR/ssh-server.sh" "$@"; }
ssh_rtr() { timeout 90 "$SCRIPT_DIR/ssh-router.sh" "$@"; }
ssh_cli() { "$SCRIPT_DIR/ssh-client.sh" "$@"; }

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
# WAN NIC 一覧の唯一の情報源は mogami-vm の services.mqvpn.interfaces
# (= test/mogami-vm.nix の vmWanInterfaces)。flake から導出して同期ずれを防ぐ。
rtr_wan=($(nix eval --json "path:$(cd "$SCRIPT_DIR/.." && pwd)#nixosConfigurations.mogami-vm.config.services.mqvpn.interfaces" 2>/dev/null | tr -d '[]"' | tr ',' ' ' || true))
[ "${#rtr_wan[@]}" -gt 0 ] || { echo "ERROR: WAN NIC 一覧を flake から取得できない" >&2; exit 1; }

clear_netem() {
  ssh_rtr "for i in ${rtr_wan[*]}; do sudo -n tc qdisc del dev \$i root 2>/dev/null || true; done; echo netem-cleared" 2>/dev/null || true
}

apply_uniform() {
  local ms="$1"
  ssh_rtr "for i in ${rtr_wan[*]}; do
    sudo -n tc qdisc replace dev \$i root netem delay ${ms}ms limit 100000
  done; echo applied" 2>/dev/null
}

# 不均質 netem: 実環境の分類比 (Starlink3 : モバイル3 : eduroam1) を 12 パス向けに
# 拡大した比 (Starlink5 : モバイル5 : eduroam2)。リスト先頭から順に割り当てる。
apply_hetero() {
  local cmd="" i p
  for i in "${!rtr_wan[@]}"; do
    if [ "$i" -lt 5 ]; then
      p="delay 45ms 12ms loss 1%"
    elif [ "$i" -lt 10 ]; then
      p="delay 75ms 25ms loss 0.5%"
    else
      p="delay 15ms 4ms loss 0.2%"
    fi
    cmd+="sudo -n tc qdisc replace dev ${rtr_wan[$i]} root netem $p limit 100000;"
  done
  ssh_rtr "$cmd echo applied" 2>/dev/null
}

# 本番 3x Starlink 崩壊再現 (WAN は 3 本に削減済み、本番物理 3 回線と一致)。
# idx0 = Starlink A (最安・最安定・最高率 → ピン集中先): delay 30ms rate 458mbit
# idx1 = Starlink B (ジッター大, 稀スパイク=pareto):     delay 42ms 15ms distribution pareto rate 400mbit
# idx2 = Starlink C (中間):                              delay 35ms rate 450mbit
apply_collapse3() {
  local specs=(
    "delay 30ms rate 458mbit"
    "delay 42ms 15ms distribution pareto rate 400mbit"
    "delay 35ms rate 450mbit"
  )
  local cmd="" i
  for i in "${!rtr_wan[@]}"; do
    cmd+="sudo -n tc qdisc replace dev ${rtr_wan[$i]} root netem ${specs[$i]} limit 100000;"
  done
  ssh_rtr "$cmd echo applied" 2>/dev/null
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
# iperf ポート (ensure_iperfd_mnet が mnet に 6205 + 5201..5300 を開く)
PORT="${BENCH_PORT:-6205}"

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

# --- unified measurement with per-path rx breakdown ---
# 各 WAN の rx バイト数を取得 (ssh ラッパの "fetching/Warning" 行を数値のみに絞る)
rx_bytes() { # $1=iface
  ssh_rtr "ip -s link show $1 2>/dev/null | awk '/RX:/{getline;print \$1}'" 2>/dev/null | grep -E '^[0-9]+$' | tail -1
}

# do_measure [tcp|udp] [P] [rate_M] [down|up] [sec]
#   iperf3 を流しつつ各 WAN の rx スループット・ceiling 比・利用率・TOTAL を表示。
#   ceiling は tc qdisc から動的取得するので uniform/hetero/collapse3 いずれでも正しく出る。
do_measure() {
  local proto="${1:-tcp}" P="${2:-20}" rate="${3:-1200}" dir="${4:-down}" sec="${5:-15}"
  local flag="" uflag=""
  [ "$dir" = "down" ] && flag="-R"
  [ "$proto" = "udp" ] && uflag="-u"
  ensure_iperfd_mnet; ensure_rmem; ship_common

  # 各 WAN の netem ceiling (Mbit) を tc から動的取得
  declare -A CEIL
  for w in "${rtr_wan[@]}"; do
    local c; c=$(ssh_rtr "tc qdisc show dev $w 2>/dev/null | grep -o 'rate [0-9]*Mbit' | grep -o '[0-9]*'" 2>/dev/null | tail -1)
    CEIL[$w]=${c:-0}
  done

  # 負荷前の rx スナップショット
  declare -A B0
  for w in "${rtr_wan[@]}"; do B0[$w]=$(rx_bytes "$w"); done

  samp_start "$((sec + 4))"
  ssh_cli "iperf3 -c $TARGET -p $PORT ${uflag} ${flag} -P $P -b ${rate}M -t $sec > /tmp/mb.txt 2>&1" &
  local IP=$!
  sleep $((sec + 2))
  wait "$IP" 2>/dev/null || true

  echo "== $proto P=$P $dir @ ${sec}s (WAN: ${rtr_wan[*]}) =="
  local tot=0 w mbps ceil util B1
  for w in "${rtr_wan[@]}"; do
    B1=$(rx_bytes "$w")
    mbps=$(( (${B1:-0} - ${B0[$w]:-0}) * 8 / (sec * 1000000) ))
    ceil=${CEIL[$w]}
    if [ "$ceil" = 0 ]; then util="NA"; else util=$(( mbps * 100 / ceil )); fi
    printf "  %-6s %8d Mbps  ceil %sM  util %s%%\n" "$w" "$mbps" "$ceil" "$util"
    tot=$((tot + mbps))
  done
  echo "  TOTAL (tunnel-bound) = ${tot} Mbps"
  echo "  client: $(ssh_cli "grep -E 'SUM|receiver' /tmp/mb.txt 2>/dev/null" 2>&1 | grep -vE 'fetching|Warning:' | tail -1)"
  echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
}


# --- サーバー→クライアント実IP への戻りルートは intentionally 付けない ---
# ルーター側 NAPT(MASQUERADE) のため復路宛先はトンネル端点(192.168.0.2)となり、
# サーバーの 192.168.0.0/24 connected route で足りる。戻りルート(172.16.0.0/12)
# は NAPT 構成では不要(過去の SLiRP 環境限定シナリオ)。DOWN 計測は mnet
# (192.168.100.1) 宛をクライアントから -R で打ち、NAPT 互換の流れで行う。

# do_stagger [N] [gap_s] [sec] [tcp|udp] [down|up]
#   複数コネクションを gap 秒ずつずらして同時開始し、到着が分散する際に
#   WLB がピンを各パスへ振り分けるかを per-path で計測する。
#   各コネクションは異ポート(5201..)なので別フロー(=別ピン)として扱われる。
do_stagger() {
  local N="${1:-20}" gap="${2:-1}" sec="${3:-15}" proto="${4:-tcp}" dir="${5:-down}"
  local flag="" uflag="" win=$(( gap * (N - 1) + sec ))
  [ "$dir" = "down" ] && flag="-R"
  [ "$proto" = "udp" ] && uflag="-u"
  ensure_iperfd_mnet; ensure_rmem; ship_common

  declare -A CEIL
  for w in "${rtr_wan[@]}"; do
    local c; c=$(ssh_rtr "tc qdisc show dev $w 2>/dev/null | grep -o 'rate [0-9]*Mbit' | grep -o '[0-9]*'" 2>/dev/null | tail -1)
    CEIL[$w]=${c:-0}
  done
  declare -A B0
  for w in "${rtr_wan[@]}"; do B0[$w]=$(rx_bytes "$w"); done

  samp_start "$((win + 4))"
  local i p
  for i in $(seq 1 "$N"); do
    p=$((5200 + i))
    ssh_cli "iperf3 -c $TARGET -p $p ${uflag} ${flag} -t $sec > /tmp/stg-$i.txt 2>&1" &
    sleep "$gap"
  done
  sleep $((win + 2)); wait 2>/dev/null || true

  echo "== stagger $proto N=$N gap=${gap}s window=${win}s $dir =="
  local tot=0 w mbps ceil util B1
  for w in "${rtr_wan[@]}"; do
    B1=$(rx_bytes "$w")
    mbps=$(( (${B1:-0} - ${B0[$w]:-0}) * 8 / (win * 1000000) ))
    ceil=${CEIL[$w]}
    if [ "$ceil" = 0 ]; then util="NA"; else util=$(( mbps * 100 / ceil )); fi
    printf "  %-6s %8d Mbps  ceil %sM  util %s%%\n" "$w" "$mbps" "$ceil" "$util"
    tot=$((tot + mbps))
  done
  echo "  TOTAL (tunnel-bound) = ${tot} Mbps"
  echo "  rtrCPU: $(samp_max R)"
}

# --- クライアントの UDP 受信バッファ拡大 ---
# 高レート測定 (特に RTT≈0 のラボ) では受信側ソケット溢れがロスに見えるため、
# rmem を 64MB に拡大する (chiken/mqvpn-loss-investigation.md 参照)
ensure_rmem() {
  ssh_cli 'sudo -n sysctl -w net.core.rmem_max=67108864 net.core.rmem_default=67108864 >/dev/null; echo rmem-ok' >/dev/null 2>&1 || true
}

# =============================================================================
CMDRUN="latency|hetero|collapse3|measure|multistream|profile|stagger|clean"

case "$CMD" in
  clean)
    clear_netem
    # サーバーは compose (mqvpn-compose unit) が管理するコンテナ群。
    # 稼働判定/再起動は docker 経由にする (旧 systemd 直起動は廃止)
    ssh_srv 'sudo -n docker ps --filter name=mqvpn-server --format "{{.Names}}" | grep -q . && echo running || { sudo -n systemctl restart mqvpn-compose; sleep 3; echo restarted; }' 2>/dev/null | tail -1
    ;;
  latency)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    clear_netem; apply_uniform "$MS"; sleep 8
    do_measure tcp 20 "$RATE" "$DIR" "$SEC"
    ;;
  hetero)
    RATE="${1:-800}"; SEC="${2:-15}"; DIR="${3:-down}"
    clear_netem; apply_hetero; sleep 8
    do_measure tcp 20 "$RATE" "$DIR" "$SEC"
    ;;
  collapse3)
    clear_netem; apply_collapse3; sleep 8
    do_measure tcp 1 1200 down 15
    do_measure tcp 20 1200 down 15
    do_measure udp 20 1500 down 15
    ;;
  measure)
    PROTO="${1:-tcp}"; P="${2:-20}"; RATE="${3:-1200}"; DIR="${4:-down}"; SEC="${5:-15}"
    do_measure "$PROTO" "$P" "$RATE" "$DIR" "$SEC"
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
    out=$(do_measure udp 20 "$RATE" "$DIR" "$SEC" 2>&1)
    sleep 5
    echo "== profile ${DIR} ${RATE}M @ ${MS}ms =="
    echo "  iperf : $out"
    ssh_srv "sudo -n ${PERF} report -i ${PERFDATA} --stdio --sort symbol --no-child --percent-limit 2 2>&1 | grep -E '^ *[0-9.]+\%  \[\.\]' | head -12" 2>/dev/null | tail -12
    ;;
  stagger)
    N="${1:-20}"; GAP="${2:-1}"; SEC="${3:-15}"; PROTO="${4:-tcp}"; DIR="${5:-down}"
    do_stagger "$N" "$GAP" "$SEC" "$PROTO" "$DIR"
    ;;
  *)
    echo "unknown: $CMD (use: $CMDRUN)"; exit 1;
    ;;
esac
