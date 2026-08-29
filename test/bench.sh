#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mqvpn ラボ統合ベンチ/プロファイルツール
#
# 調査で使った個別スクリプト (repro-cpu-saturation.sh) の機能を1つにまとめたもの。
# perf プロファイリングも可。
#
# Usage:
#   ./test/bench.sh wlbstate
#       直近の WLB round_start ログ (est_bw/pin_count 時系列) を両端から表示。
#       推定器の収束確認用: 計測前にこれで est_bw が安定していることを目視確認する。
#
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
#       本番 3x Starlink の実測物理回線再現: WAN 3 本 (eth1=A / eth3=B / eth4=C) に
#       実測を適用 — 下り A=217M/12ms, B=175M/11ms, C=107M/12ms+pareto
#       (chiken 2026-08-28: 強制出口下り 217/175/107M, 直結 ping RTT 24.8/22.5/23.1ms)。
#       実 RTT 差が小さいため再設計スケジューラは容量比例配分(崩壊なし)となる。
#       RTT は実測 min/max を jitter で変動(容量 rate は固定平均値)。
#       TCP 単一/多フローでの配分と UDP 全パス分散を per-path で表示。
#
#   ./test/bench.sh latab [sec]
#       容量は collapse3 と同一(実測 217/175/107M)、RTT だけ広げた不均質
#       (eth1=10ms / eth3=200ms / eth4=50ms)。バルク埋め負荷下でトンネル
#       RTT(p50/p95/p99) と小パケット UDP jitter を取得。pin ポリシー
#       (純容量 vs RTTダンプ) の A/B 用シナリオ。
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
#
#   ./test/bench.sh wlbstate
#       直近の WLB round_start ログ (est_bw/pin_count 時系列) を両端から表示。
#       推定器の収束確認用: 計測前にこれで est_bw が安定していることを目視確認する。
#
#   計測の前提 (WLB 推定器の収束):
#     - do_measure / do_latab は BENCH_WARMUP 秒 (既定 20, 環境変数で調整) の
#       負荷ウォームアップ後にのみ計測窓を置く。iperf3 --omit でレポートも除外。
#       これは「推定帯域幅が整う前の過渡状態を性能として測ってしまう」問題への対処。
#     - est_bw の収束は bench.sh wlbstate で確認できる。収束が遅い回線なら
#       BENCH_WARMUP を伸ばすこと。
#     - 連続計測 (collapse3 など) は実行間でスケジューラ状態 (est_bw/pin_credit/
#       フロー表) を引き継ぐが、WARMUP が現ネットワークへ再収束させる (60s idle
#       期限で前回フローも消える)。
#     - A/B 比較は BENCH_RUNS>1 (例: BENCH_RUNS=4) で複数回実行し、median/IQR を
#       報告する。1 回実行の数値は ±15-20% の実行間バラツキを持つ。
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HELLO_CMD="latency|hetero|collapse3|latab|uneven|measure|multistream|profile|stagger|wlbstate|clean"
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

  # 生コアごとの busy% サンプラ (ウィンドウ内最大)。Linux CFS が mqvpn インスタンス
  # (各実質シングルスレッド) を別 vCPU に振り分けているかを可視化するため。
  local coresamp
  coresamp=$(cat << 'CORESAMP'
#!/usr/bin/env bash
# per-core busy% sampler (max over window). /proc/stat の cpuN から
# (total - idle - iowait) / total を 1s ごとに計算し、各コアの最大を出力。
# 各秒ごと Running-max を吐く (cpusamp.sh と同様) — 計測窓終了前に
# 読まれても意味がある。bench.sh の samp_cores は tail -1 で取得。
declare -A mtotal mbusy maxp
DUR="${1:-30}"
i=0
while [ "$i" -lt "$DUR" ]; do
  sleep 1
  i=$((i+1))
  while read -r line; do
    case "$line" in
      cpu[0-9]*) ;;
      *) continue ;;
    esac
    fields=($line)
    idx="${fields[0]}"
    total=$(( ${fields[1]} + ${fields[2]} + ${fields[3]} + ${fields[4]} + ${fields[5]} + ${fields[6]} + ${fields[7]} + ${fields[8]} ))
    busy=$(( total - ${fields[4]} - ${fields[5]} ))
    if [ -n "${mtotal[$idx]}" ]; then
      dt=$(( total - ${mtotal[$idx]} )); [ "$dt" -le 0 ] && dt=1
      db=$(( busy - ${mbusy[$idx]} ))
      pct=$(( db * 100 / dt ))
      if [ -z "${maxp[$idx]}" ] || [ "$pct" -gt "${maxp[$idx]}" ]; then maxp[$idx]=$pct; fi
    fi
    mtotal[$idx]=$total; mbusy[$idx]=$busy
  done < /proc/stat
  out=""
  for c in "${!maxp[@]}"; do out="$out $c=${maxp[$c]}%"; done
  echo "$out" | tr ' ' '\n' | sed '/^$/d' | sort -V | tr '\n' ' '
  echo
done
CORESAMP
)
  printf '%s\n' "$coresamp" | ssh_srv 'cat > /tmp/cpucore.sh && chmod +x /tmp/cpucore.sh' >/dev/null 2>&1 || true
  printf '%s\n' "$coresamp" | ssh_rtr 'cat > /tmp/cpucore.sh && chmod +x /tmp/cpucore.sh' >/dev/null 2>&1 || true
}

# --- netem ---
# WAN NIC 一覧の唯一の情報源は mogami-vm の services.mqvpn.interfaces
# (= test/mogami-vm.nix の vmWanInterfaces)。flake から導出して同期ずれを防ぐ。
rtr_wan=($(nix eval --json "path:$(cd "$SCRIPT_DIR/.." && pwd)#nixosConfigurations.mogami-vm.config.services.mqvpn.interfaces" 2>/dev/null | tr -d '[]"' | tr ',' ' ' || true))
[ "${#rtr_wan[@]}" -gt 0 ] || { echo "ERROR: WAN NIC 一覧を flake から取得できない" >&2; exit 1; }

clear_netem() {
  ssh_rtr "for i in ${rtr_wan[*]}; do sudo -n tc qdisc del dev \$i root 2>/dev/null || true; done; echo netem-cleared" 2>/dev/null || true
  clear_netem_host
}
# 下り(down)は server→router のトンネルパケットが host の WAN タップ egress を通る。
# router 側 egress netem は上りしか絞らないため、下りを絞るには host 側タップの
# egress に netem を掛ける。mqvpn.interfaces = [eth1,eth3,eth4] の実タップは
# mogami-vm.nix allNics の順: eth1=trw0, eth3=trw1, eth4=trw2  (eth2 は tr-mgmt)。
host_wan=(trw0 trw1 trw2)

# --- 実測物理回線モデル (selection-vs-delivered.md 2026-08-28 強制出口 n=5) ---
# 下り容量平均 Mbps (rate は固定値)。RTT は実測 min/max を jitter で変動。
declare -A RATE_MEAN=( [eth1]=217 [eth3]=175 [eth4]=107 )
# 各 WAN の netem delay 指定 (apply_* が上書き)。RTT 変動(jitter+distribution)を保持。
declare -A DELAY_SPEC=( [eth1]="delay 12ms 3ms distribution normal" [eth3]="delay 11ms 4ms distribution normal" [eth4]="delay 12ms 6ms distribution pareto" )

clear_netem_host() {
  for t in "${host_wan[@]}"; do sudo -n tc qdisc del dev "$t" root 2>/dev/null || true; done; echo netem-cleared-host
}
apply_uniform_host() {
  local ms="$1"
  for t in "${host_wan[@]}"; do sudo -n tc qdisc replace dev "$t" root netem delay ${ms}ms limit 100000; done; echo applied-host
}
apply_hetero_host() {
  local p
  for i in "${!host_wan[@]}"; do
    if [ "$i" -lt 5 ]; then p="delay 45ms 12ms loss 1%"
    elif [ "$i" -lt 10 ]; then p="delay 75ms 25ms loss 0.5%"
    else p="delay 15ms 4ms loss 0.2%"
    fi
    sudo -n tc qdisc replace dev "${host_wan[$i]}" root netem $p limit 100000
  done; echo applied-host
}
apply_collapse3_host() {
  # 実測物理容量/RTT。下り 217/175/107M(平均), RTT 平均 24.8/22.5/23.1ms→片道≈/2 で変動。
  # C(Mini) のみ最大 40.9ms のジッター(pareto)。netem は対称なので下り容量でモデル。
  # DELAY_SPEC/RATE_MEAN は collapse3 側で設定済(本関数は host 側 egress に同じを適用)。
  local i w
  for i in "${!host_wan[@]}"; do
    w=${rtr_wan[$i]}
    sudo -n tc qdisc replace dev "${host_wan[$i]}" root netem ${DELAY_SPEC[$w]} rate ${RATE_MEAN[$w]}mbit limit 100000
  done; echo applied-host
}

# latab: 容量は collapse3 と同一(実測 217/175/107M)、RTT だけ広げる。
# 容量を固定し RTT のみ変化させることで、pin ポリシーの違い(純容量 vs RTTダンプ)
# を孤立計測する (latab シナリオ用)。
apply_latab_host() {
  # 容量は collapse3 と同一(実測 217/175/107M, 固定平均値)。RTT は latab 用に拡大(下を参照)。
  local i w
  for i in "${!host_wan[@]}"; do
    w=${rtr_wan[$i]}
    sudo -n tc qdisc replace dev "${host_wan[$i]}" root netem ${DELAY_SPEC[$w]} rate ${RATE_MEAN[$w]}mbit limit 100000
  done; echo applied-host
}

# 帯域不均一 + RTT 不均一 (本番の「回線ごとに容量が違う」ケース)。
# 意図的に「RTT が大きい回線ほど太い」: eth1=200M/10ms, eth3=600M/200ms,
# eth4=300M/50ms。RTTダンプ系ポリシーだと太い eth3 を捨てるため、
# 容量ベースポリシーとの差が最も出る (uneven シナリオ用)。
apply_uneven_host() {
  local specs=("delay 10ms rate 200mbit" "delay 200ms rate 600mbit" "delay 50ms rate 300mbit")
  for i in "${!host_wan[@]}"; do
    sudo -n tc qdisc replace dev "${host_wan[$i]}" root netem ${specs[$i]} limit 100000
  done; echo applied-host
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

# 本番 3x Starlink の実測物理回線 (selection-vs-delivered.md 2026-08-28 強制出口 n=5
# 平均下り + real-env.md §3.1 直結 ping RTT)。WAN 3 本と一致。
# 下り容量: A(eth1,Flat)=217M / B(eth3,Move)=175M / C(eth4,Mini)=107M (合計≈499M)。
# RTT(router→VPS 直結): A=24.8 B=22.5 C=23.1ms(平均)、C のみ最大 40.9ms のジッター。
# netem delay は片道なので測定 RTT/2 を指定 (ラボ ping RTT≈実測)。上りは 36/37/20M だが
# netem は対称のため下り容量でモデル (ACK 少数のため下り律速にならず)。
# 実 RTT 差は小さいため再設計スケジューラは容量比例配分となり、1 パス崩壊は再現しない
# (本番 real-env.md「崩壊なし」と整合)。崩壊を見たいなら latab/uneven で RTT 差を拡大。
apply_collapse3() {
  # 実測物理容量/RTT: 下り 217/175/107M(平均), RTT 平均 24.8/22.5/23.1ms を片道≈/2 で
  # 変動付き(min/max は選択/配分に影響)。C(Mini) のみジッター tail 大(pareto, 最大 40.9ms)。
  # 容量 rate は固定平均値(217/175/107M)。RTT は実測 min/max を jitter で変動。
  DELAY_SPEC[eth1]="delay 12ms 3ms distribution normal"
  DELAY_SPEC[eth3]="delay 11ms 4ms distribution normal"
  DELAY_SPEC[eth4]="delay 12ms 6ms distribution pareto"
  local cmd="" i w
  for i in "${!rtr_wan[@]}"; do
    w=${rtr_wan[$i]}
    cmd+="sudo -n tc qdisc replace dev $w root netem ${DELAY_SPEC[$w]} rate ${RATE_MEAN[$w]}mbit limit 100000;"
  done
  ssh_rtr "$cmd echo applied" 2>/dev/null
}

# latab: 容量同一・RTT のみ広げた不均質 (collapse3 の容量 217/175/107M を維持し、
# RTT 差を意図的に拡大)。idx0 = eth1: 10ms/217M  idx1 = eth3: 200ms/175M  idx2 = eth4: 50ms/107M
apply_latab() {
  # 容量は collapse3 と同一(実測 217/175/107M, 固定平均値)。RTT のみ拡大して pin ポリシーを孤立計測。
  DELAY_SPEC[eth1]="delay 10ms"; DELAY_SPEC[eth3]="delay 200ms"; DELAY_SPEC[eth4]="delay 50ms"
  local cmd="" i w
  for i in "${!rtr_wan[@]}"; do
    w=${rtr_wan[$i]}
    cmd+="sudo -n tc qdisc replace dev $w root netem ${DELAY_SPEC[$w]} rate ${RATE_MEAN[$w]}mbit limit 100000;"
  done
  ssh_rtr "$cmd echo applied" 2>/dev/null
}

# uneven: 帯域不均一 + RTT 不均一。遅い回線ほど太い:
# idx0 = eth1: 10ms/200M   idx1 = eth3: 200ms/600M   idx2 = eth4: 50ms/300M
apply_uneven() {
  local specs=(
    "delay 10ms rate 200mbit"
    "delay 200ms rate 600mbit"
    "delay 50ms rate 300mbit"
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
  ssh_srv "rm -f /tmp/cpuCoresS.log; nohup /tmp/cpucore.sh ${dur} > /tmp/cpuCoresS.log 2>&1 & echo ok" >/dev/null 2>&1 || true
  ssh_rtr "rm -f /tmp/cpuCoresR.log; nohup /tmp/cpucore.sh ${dur} > /tmp/cpuCoresR.log 2>&1 & echo ok" >/dev/null 2>&1 || true
}

samp_max() { # $1=host S|R
  local h="$1"
  if [ "$h" = "S" ]; then
    ssh_srv 'grep -o "jiffies/s=[0-9]*" /tmp/cpuS.log | sort -t= -k2 -n | tail -1 | sed "s/jiffies\/s=//"' 2>/dev/null | tail -1
  else
    ssh_rtr 'grep -o "jiffies/s=[0-9]*" /tmp/cpuR.log | sort -t= -k2 -n | tail -1 | sed "s/jiffies\/s=//"' 2>/dev/null | tail -1 || echo "?"
  fi
}

samp_cores() { # $1=host S|R  ->  "cpu0=47% cpu1=45% ..." (window max per core)
  if [ "$1" = "S" ]; then
    ssh_srv 'tail -1 /tmp/cpuCoresS.log' 2>/dev/null | tail -1
  else
    ssh_rtr 'tail -1 /tmp/cpuCoresR.log' 2>/dev/null | tail -1
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

# -----------------------------------------------------------------------------
# WLB 推定器収束の観測 (wlbstate プロクシ + 適応的ウォームアップ用)
#   xquic の |wlb|round_start|est_bw は現ビルドで mqvpn ログに出ないため、
#   STATUS の per-path 実測レート (tx+rx 差分) を proxy に使う。
#   STATUS 周期は 5-30s 不規則なので、snap が進むまで 5s ずつ待つ。
wlb_snap() { # 直近 STATUS の path 行を "ts id path tx rx" に正規化 (mqvpn-0 固定)
  ssh_rtr 'sudo journalctl -n 400 --no-pager -u mqvpn-0.service 2>/dev/null | grep -E "path[0-9]=eth" | tail -3 | sed -E "s/^[A-Za-z]{3} [0-9]+ ([0-9:]+) .*path([0-9])=([a-z0-9]+) srtt=[^ ]* tx=([0-9]+) rx=([0-9]+).*/\1 \2 \3 \4 \5/"' 2>/dev/null | grep -vE '^fetching|Warning:'
}

# 2 つの "id rate" 列が全 path で pct% 以内に収まっていれば 0(安定) を返す
rates_stable() {
  local p="$1" c="$2" pct="$3"
  [ -n "$p" ] && [ -n "$c" ] || return 1
  awk -v pct="$pct" '
    NR==FNR{p[$1]=$2;next}
    ($1 in p){m++; base=p[$1]; if(base==0)base=$2; if(base==0)next; d=$2-base; if(d<0)d=-d; if(d*100/base>pct){exit 1}}
    END{if(m==0)exit 1}
  ' <(printf '%s\n' "$p") <(printf '%s\n' "$c") >/dev/null
}

# 2 つの raw snap (ts id path tx rx) から per-path レート(Mbps) "id rate" を出力
wlb_rates_of() { # $1=raw_snap_a $2=raw_snap_b
  paste <(printf '%s\n' "$1") <(printf '%s\n' "$2") | awk '{split($1,t,":"); split($6,u,":"); dt=(u[1]*3600+u[2]*60+u[3])-(t[1]*3600+t[2]*60+t[3]); if(dt<=0)dt=5; rate=($9-$4)+($10-$5); printf "path%s %.0f\n", $2, rate*8/(dt*1000000)}'
}

# 推定器が収束するまで待ち、実ウォームアップ秒数を echo。
# wlb_snap を 5s ごとに poll (ブロックしない) し、per-path 実測レートが
# BENCH_STEADY_PCT(既定15)% 以内に 2 回連続安定なら抜ける。
# 最小 min / 最大 max の間で挟む (STATUS が出なければ max で抜ける)。
wait_wlb_steady() {
  local min=${1:-60} max=${2:-120} pct=${BENCH_STEADY_PCT:-15}
  local t0=$SECONDS prev_raw="" prev_rates="" cur_raw cur_rates stable=0 used=$max
  while [ $(( SECONDS - t0 )) -lt "$max" ]; do
    cur_raw=$(wlb_snap)
    if [ -n "$prev_raw" ] && [ "$prev_raw" != "$cur_raw" ]; then
      cur_rates=$(wlb_rates_of "$prev_raw" "$cur_raw")
      if [ -n "$prev_rates" ] && rates_stable "$prev_rates" "$cur_rates" "$pct"; then
        stable=$((stable+1))
        if [ "$stable" -ge 2 ] && [ $(( SECONDS - t0 )) -ge "$min" ]; then used=$(( SECONDS - t0 )); break; fi
      else stable=0; fi
      prev_rates="$cur_rates"
    fi
    prev_raw="$cur_raw"
    sleep 5
  done
  [ $(( SECONDS - t0 )) -lt "$min" ] && used=$min
  echo "$used"
}

# 公平性指標: FAIR_JAIN (Jain) / FAIR_CPRMSE (容量比例 RMSE %) をセット
#   $1=mbps(indexed) $2=ceil(indexed) $3=total
compute_fairness() {
  local -n _M=$1 _C=$2; local total=$3
  local sum=0 sumsq=0 n=0 sceil=0 x i
  for i in "${!_M[@]}"; do x=${_M[i]:-0}; sum=$((sum+x)); sumsq=$((sumsq+x*x)); n=$((n+1)); sceil=$((sceil+${_C[i]:-0})); done
  FAIR_JAIN=0; [ "$sumsq" -gt 0 ] && FAIR_JAIN=$(awk "BEGIN{printf \"%.4f\",($sum*$sum)/($n*$sumsq)}")
  FAIR_CPRMSE=null
  if [ "$sceil" -gt 0 ] && [ "$total" -gt 0 ]; then
    local se=0 i
    for i in "${!_M[@]}"; do local ideal=$(( total * ${_C[i]:-0} / sceil )); local e=$(( ${_M[i]:-0} - ideal )); [ "$e" -lt 0 ] && e=$(( -e )); se=$(( se + e*e )); done
    FAIR_CPRMSE=$(awk "BEGIN{printf \"%.1f\",sqrt($se)/$total*100}")
  fi
}

# BENCH_JSON=1 で $BENCH_JSON_FILE (既定 test/bench-results.jsonl) に 1 行追記。
#   $1=cmd $2=label $3=warmup_used $4=total $5=mbps(indexed) $6=ceil(indexed) $7=paths(space)
emit_bench_json() {
  [ -n "${BENCH_JSON:-}" ] || return 0
  local f="${BENCH_JSON_FILE:-$SCRIPT_DIR/bench-results.jsonl}"
  local cmd="$1" label="$2" wu="$3" total="$4" mn="$5" cn="$6" paths="$7"
  local -n M=$mn C=$cn
  compute_fairness "$mn" "$cn" "$total"
  local pj="" i=0 p util
  for p in $paths; do
    if [ "${C[i]:-0}" = 0 ]; then util=null; else util=$(( ${M[i]:-0} * 100 / ${C[i]:-0} )); fi
    [ -n "$pj" ] && pj="$pj,"
    pj="$pj{\"iface\":\"$p\",\"mbps\":${M[i]:-0},\"ceil\":${C[i]:-0},\"util\":$util}"
    i=$((i+1))
  done
  printf '{"ts":"%s","cmd":"%s","label":"%s","warmup_used":%s,"total_mbps":%s,"fairness_jain":%s,"cap_prop_rmse_pct":%s,"paths":[%s]}\n' \
    "$(date -u +%FT%TZ)" "$cmd" "$label" "$wu" "$total" "$FAIR_JAIN" "$FAIR_CPRMSE" "$pj" >> "$f"
}

# 計測の正しさ (chiken 議論の反映):
#   WLB の推定器 (est_bw EWMA / 配信レートピーク) は収束に分単位かかるため、
#   負荷開始直後からの窓平均は「推定器が整う前の過渡状態」を性能として出してしまう。
#   そのため WARMUP 秒間は負荷のみ流し、per-path rx は WARMUP 後の定常窓
#   [B0 → B1] の差分でのみ集計する。
#   ウォームアップは既定で「適応的」: bench.sh wlbstate の推定器プロクシを用い、
#   per-path 実測レートが BENCH_STEADY_PCT(既定15)% 以内に 2 回連続安定するまで待つ。
#   最小 BENCH_WARMUP(既定20) / 最大 BENCH_WARMUP_MAX(既定45) で挟む。
#   固定ウォームアップに戻す: BENCH_ADAPTIVE_WARMUP=0。
#   収束の目視確認は bench.sh wlbstate。連続計測間のスケジューラ状態引き継ぎは
#   WARMUP が現ネットワークへ吸収する。
#   出力には公平性指標を付与: Jain 指数 (1=完全公平) と容量比例 RMSE%(ceil 既知時)。
#   BENCH_JSON=1 で ./bench-results.jsonl に実測を 1 行/run 追記 (A/B 比較・時系列用)。
#
# do_measure [tcp|udp] [P] [rate_M] [down|up] [sec]
#   iperf3 を流しつつ各 WAN の rx スループット・ceiling 比・利用率・TOTAL・fairness を表示。
#   ceiling は tc qdisc から動的取得するので uniform/hetero/collapse3 いずれでも正しく出る。
#   BENCH_RUNS>1 なら複数回実行し median/IQR (バラツキをノイズとして可視化)。
measure_once() {
  local proto="$1" P="$2" rate="$3" dir="$4" sec="$5" warmup="$6"
  local flag="" uflag=""
  local adaptive=0
  [ "${BENCH_ADAPTIVE_WARMUP:-1}" != "0" ] && adaptive=1
    local warmup_max="${BENCH_WARMUP_MAX:-45}"
  [ "$warmup_max" -lt "$warmup" ] && warmup_max=$(( warmup + 30 ))
  [ "$dir" = "down" ] && flag="-R"
  [ "$proto" = "udp" ] && uflag="-u"
  ensure_iperfd_mnet; ensure_rmem; ensure_wmem_mnet; ship_common

  # 各 WAN の netem ceiling (Mbit) を tc から動的取得
  declare -A CEIL
  for w in "${rtr_wan[@]}"; do
    local c; c=$(ssh_rtr "tc qdisc show dev $w 2>/dev/null | grep -o 'rate [0-9]*Mbit' | grep -o '[0-9]*' || true" 2>/dev/null | tail -1)
    CEIL[$w]=${c:-0}
  done

  # 負荷を流しつつ定常窓を計測。単一フロー(P=1)ではウォームアップ中に TCP コネクションが
  # リセットされると計測窓が 0 になる(フレーク)。TOTAL=0 の場合は再計測する。
  # 回数は BENCH_RETRY で指定(既定 3)。
  local attempt=0 max_attempts="${BENCH_RETRY:-3}"
  local tot=0 w_used="$warmup" mbps ceil util i=0
  local -a MBPS=() CEIL2=() B0=() B1=()
  while :; do
    attempt=$((attempt + 1))
    local wp=$(( warmup_max + sec + 5 ))
    samp_start "$((wp + 4))"
    ssh_cli "iperf3 -c $TARGET -p $PORT ${uflag} ${flag} -P $P -b ${rate}M -t $wp > /tmp/mb.txt 2>&1" &
    local IP=$!

    w_used="$warmup"
    if [ "$adaptive" = 1 ]; then
      w_used=$(wait_wlb_steady "$warmup" "$warmup_max")
    else
      sleep "$warmup"
    fi

    # 定常窓 [B0 -> B1] のみで集計
    B0=(); i=0
    for w in "${rtr_wan[@]}"; do B0[$i]=$(rx_bytes "$w"); i=$((i + 1)); done
    sleep "$sec"
    B1=(); i=0
    for w in "${rtr_wan[@]}"; do B1[$i]=$(rx_bytes "$w"); i=$((i + 1)); done
    kill "$IP" 2>/dev/null; wait "$IP" 2>/dev/null || true

    tot=0; MBPS=(); CEIL2=(); i=0
    for w in "${rtr_wan[@]}"; do
      mbps=$(( (B1[i] - B0[i]) * 8 / (sec * 1000000) ))
      ceil=${CEIL[$w]}
      tot=$((tot + mbps)); MBPS[i]=$mbps; CEIL2[i]=$ceil; i=$((i + 1))
    done

    if [ "$tot" -gt 0 ] || [ "$attempt" -ge "$max_attempts" ]; then break; fi
    echo "  (retry $attempt/$max_attempts: TOTAL=0, re-running measurement)" >&2
  done

  echo "== $proto P=$P $dir @ ${sec}s steady (after ${w_used}s warmup; WAN: ${rtr_wan[*]}) =="
  i=0
  for w in "${rtr_wan[@]}"; do
    mbps=${MBPS[i]}; ceil=${CEIL[$w]}
    if [ "$ceil" = 0 ]; then util="NA"; else util=$(( mbps * 100 / ceil )); fi
    printf "  %-6s %8d Mbps  ceil %sM  util %s%%\n" "$w" "$mbps" "$ceil" "$util"
    i=$((i + 1))
  done
  echo "  TOTAL (tunnel-bound) = ${tot} Mbps"
  compute_fairness MBPS CEIL2 "$tot"
  echo "  fairness (Jain) = $FAIR_JAIN  cap-prop RMSE = ${FAIR_CPRMSE}%"
  emit_bench_json "measure" "$proto P=$P $dir @ ${sec}s steady (after ${w_used}s warmup)" "$w_used" "$tot" MBPS CEIL2 "${rtr_wan[*]}"
  echo "  client: $(ssh_cli 'g=$(grep -E "\[SUM\] 0\.00-" /tmp/mb.txt 2>/dev/null | tail -1); [ -z "$g" ] && g=$(grep -E "\[SUM\]" /tmp/mb.txt 2>/dev/null | tail -1); echo "$g"' 2>&1 | grep -vE 'fetching|Warning:' | tail -1)"
  echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
  echo "  rtrCores: $(samp_cores R)"
}

do_measure() {
  local proto="${1:-tcp}" P="${2:-20}" rate="${3:-1200}" dir="${4:-down}" sec="${5:-15}"
  local warmup="${BENCH_WARMUP:-20}" runs="${BENCH_RUNS:-1}"
  local out t
  local -a totals=()
  for _ in $(seq 1 "$runs"); do
    out=$(measure_once "$proto" "$P" "$rate" "$dir" "$sec" "$warmup")
    printf '%s\n' "$out"
    t=$(printf '%s\n' "$out" | grep -o 'TOTAL (tunnel-bound) = [0-9]*' | grep -o '[0-9]*$')
    [ -n "$t" ] && totals+=("$t")
  done
    if [ "$runs" -gt 1 ]; then
    echo "== summary over ${#totals[@]} runs (Mbps, steady-state) =="
    printf '%s\n' "${totals[@]}" | sort -n | awk '{a[NR]=$1} END{n=NR; if(n==0) exit; q1i=(int((n+1)/4)<1)?1:int((n+1)/4); q3i=(int(3*(n+1)/4)<1)?1:int(3*(n+1)/4); med=(n%2)?a[(n+1)/2]:((a[n/2]+a[n/2+1])/2); printf "  median=%d  IQR=[%d,%d]  min=%d max=%d\n", med, a[q1i], a[q3i], a[1], a[n]}'
  fi
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
#   注記: この実験は「フロー開始タイミング(ウォームアップ盲目窓)の影響」そのものを
#   測るためのもので、開始位相を含む窓平均が目的。do_measure のような warmup 分離は
#   意図的に行わない (ピン決定はフロー開始瞬間に起き、開始位相の除外は測定対象の破壊)。
do_stagger() {
  local N="${1:-20}" gap="${2:-1}" sec="${3:-15}" proto="${4:-tcp}" dir="${5:-down}"
  local flag="" uflag="" win=$(( gap * (N - 1) + sec ))
  [ "$dir" = "down" ] && flag="-R"
  [ "$proto" = "udp" ] && uflag="-u"
  ensure_iperfd_mnet; ensure_rmem; ensure_wmem_mnet; ship_common

  declare -A CEIL
  for w in "${rtr_wan[@]}"; do
    local c; c=$(ssh_rtr "tc qdisc show dev $w 2>/dev/null | grep -o 'rate [0-9]*Mbit' | grep -o '[0-9]*' || true" 2>/dev/null | tail -1)
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
  echo "  rtrCores: $(samp_cores R)"
}

# do_latab [sec] [label]
#   wide-RTT シナリオでバルク埋め負荷下の実効遅延を計測する。pin ポリシー
#   (純容量 vs RTTダンプ vs 容量ピークキャッシュ) の違いを浮き彫りにするため、
#   以下を同時取得する:
#     - トンネル RTT (負荷下): ping TARGET の p50/p95/p99
#     - 小パケット UDP jitter: iperf3 -u -l 64 -b 10M (down)
#   負荷は BENCH_WARMUP (既定 20) 秒間だけ先に流して定常化させ (--omit で除外)、
#   ping/jitter と per-path rx はウォームアップ後の定常窓 [B0 → B1] でのみ計測する。
#   計測対象の過渡状態混入を防ぐため (推定器の収束 ≫ 計測窓 問題への対処)。
do_latab() {
  local sec="${1:-15}"
  local label="${2:-latab}" warmup="${BENCH_WARMUP:-20}"
  local adaptive=0
  [ "${BENCH_ADAPTIVE_WARMUP:-1}" != "0" ] && adaptive=1
    local warmup_max="${BENCH_WARMUP_MAX:-45}"
  [ "$warmup_max" -lt "$warmup" ] && warmup_max=$(( warmup + 30 ))
  local wp=$(( warmup_max + sec + 5 ))
  ensure_iperfd_mnet; ensure_rmem; ensure_wmem_mnet; ship_common
  declare -A CEIL
  for w in "${rtr_wan[@]}"; do
    local c; c=$(ssh_rtr "tc qdisc show dev $w 2>/dev/null | grep -o 'rate [0-9]*Mbit' | grep -o '[0-9]*' || true" 2>/dev/null | tail -1)
    CEIL[$w]=${c:-0}
  done

  samp_start "$((wp + 4))"
  ssh_cli "iperf3 -c $TARGET -p $PORT -R -P 20 -b 1200M -t $wp > /tmp/fill.txt 2>&1" &
  local FILL=$!

  local w_used="$warmup"
  if [ "$adaptive" = 1 ]; then
    w_used=$(wait_wlb_steady "$warmup" "$warmup_max")
  else
    sleep "$warmup"
  fi

  # 定常窓 [B0 -> B1] のみで集計 (B1 は fill 終端で取る。jitter は別負荷なので混入させない)
  local -a B0=()
  local i=0 w
  for w in "${rtr_wan[@]}"; do B0[$i]=$(rx_bytes "$w"); i=$((i + 1)); done

  # トンネル RTT (負荷下) p50/p95/p99 — 生サンプルを受け取りローカルで集計
  local pings
  pings=$(ssh_cli "ping -c $((sec * 5)) -i 0.2 $TARGET 2>/dev/null | grep -o 'time=[0-9.]*' | sed 's/time=//'" 2>/dev/null)
  local pingres
  pingres=$(echo "$pings" | sort -n | awk 'NF{a[NR]=$1; n=NR} END{ if(n==0){print "no samples"; exit} i95=int(n*0.95); i99=int(n*0.99); if(i95<1)i95=1; if(i99<1)i99=1; printf "p50=%.2f p95=%.2f p99=%.2f min=%.2f max=%.2f", a[int(n/2)], a[i95], a[i99], a[1], a[n] }')

  local -a B1=()
  i=0
  for w in "${rtr_wan[@]}"; do B1[$i]=$(rx_bytes "$w"); i=$((i + 1)); done
  wait "$FILL" 2>/dev/null || true

  # 小パケット UDP jitter (負荷窓外だが「負荷下」近似として取得)
  local jit
  jit=$(ssh_cli "iperf3 -c $TARGET -u -b 10M -l 64 -t 10 -R 2>/dev/null | grep -E 'receiver' | tail -1" 2>/dev/null)

  echo "== $label (steady after ${w_used}s warmup; RTT window=${sec}s) =="
  local tot=0 mbps ceil util
  local -a MBPS=() CEIL2=()
  i=0
  for w in "${rtr_wan[@]}"; do
    mbps=$(( (B1[i] - B0[i]) * 8 / (sec * 1000000) ))
    ceil=${CEIL[$w]}
    if [ "$ceil" = 0 ]; then util="NA"; else util=$(( mbps * 100 / ceil )); fi
    printf "  %-6s %8d Mbps  ceil %sM  util %s%%\n" "$w" "$mbps" "$ceil" "$util"
    tot=$((tot + mbps)); MBPS[i]=$mbps; CEIL2[i]=$ceil; i=$((i + 1))
  done
  echo "  TOTAL (tunnel-bound) = ${tot} Mbps"
  compute_fairness MBPS CEIL2 "$tot"
  echo "  fairness (Jain) = $FAIR_JAIN  cap-prop RMSE = ${FAIR_CPRMSE}%"
  emit_bench_json "latab" "$label (steady after ${w_used}s warmup)" "$w_used" "$tot" MBPS CEIL2 "${rtr_wan[*]}"
  echo "  tunnel RTT (ping p50/p95/p99, load): ${pingres}"
  echo "  udp64 jitter (load): ${jit}"
  echo "  srvCPU: $(samp_max S)  rtrCPU: $(samp_max R)"
  echo "  srvCores: $(samp_cores S)"
  echo "  rtrCores: $(samp_cores R)"
}

# --- クライアントの UDP 受信バッファ拡大 ---
# 高レート測定 (特に RTT≈0 のラボ) では受信側ソケット溢れがロスに見えるため、
# rmem を 64MB に拡大する (chiken/mqvpn-loss-investigation.md 参照)
ensure_rmem() {
  ssh_cli 'sudo -n sysctl -w net.core.rmem_max=67108864 net.core.rmem_default=67108864 >/dev/null; echo rmem-ok' >/dev/null 2>&1 || true
}

# --- mnet (下りの iperf 送信側) の TCP 窓拡大 ---
# 高 RTT パス (200ms→RTT 400ms) で内側 TCP が BDP に達するには wmem ≥ 20MB が
# 必要。既定 4MB だと 80Mbps/フローで頭打ちになり、スケジューラの分配ではなく
# 内側 TCP の窓が律速に見える (latab/uneven の eth3 低レートの正体)。
ensure_wmem_mnet() {
  "$SCRIPT_DIR/ssh-mnet.sh" 'sudo -n sysctl -w net.core.wmem_max=67108864 net.core.wmem_default=67108864 net.ipv4.tcp_wmem="4096 131072 67108864" net.core.rmem_max=67108864 net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null; echo wmem-ok' >/dev/null 2>&1 || true
}

# =============================================================================
CMDRUN="latency|hetero|collapse3|latab|uneven|measure|multistream|profile|stagger|clean"

case "$CMD" in
  clean)
    clear_netem
    # サーバーは compose (mqvpn-compose unit) が管理するコンテナ群。
    # 稼働判定/再起動は docker 経由にする (旧 systemd 直起動は廃止)
    ssh_srv 'sudo -n docker ps --filter name=mqvpn-server --format "{{.Names}}" | grep -q . && echo running || { sudo -n systemctl restart mqvpn-compose; sleep 3; echo restarted; }' 2>/dev/null | tail -1
    ;;
  latency)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    clear_netem; apply_uniform "$MS"; apply_uniform_host "$MS"; sleep 8
    do_measure tcp 20 "$RATE" "$DIR" "$SEC"
    ;;
  hetero)
    RATE="${1:-800}"; SEC="${2:-15}"; DIR="${3:-down}"
    clear_netem; apply_hetero; apply_hetero_host; sleep 8
    do_measure tcp 20 "$RATE" "$DIR" "$SEC"
    ;;
  collapse3)
    clear_netem; apply_collapse3; apply_collapse3_host; sleep 8
    do_measure tcp 1 1200 down 15
    do_measure tcp 20 1200 down 15
    do_measure udp 20 1500 down 15
    ;;
  latab)
    clear_netem; apply_latab; apply_latab_host; sleep 8
    do_latab "${1:-15}" "latab (cap=collapse3 実測 217/175/107M; RTT eth1=10ms eth3=200ms eth4=50ms)"
    ;;
  uneven)
    clear_netem; apply_uneven; apply_uneven_host; sleep 8
    do_latab "${1:-15}" "uneven (eth1=10ms/200M eth3=200ms/600M eth4=50ms/300M)"
    ;;
  measure)
    PROTO="${1:-tcp}"; P="${2:-20}"; RATE="${3:-1200}"; DIR="${4:-down}"; SEC="${5:-15}"
    do_measure "$PROTO" "$P" "$RATE" "$DIR" "$SEC"
    ;;
  multistream)
    N="${1:-10}"; SEC="${2:-20}"
    ensure_iperfd_mnet; ensure_rmem; ensure_wmem_mnet; ship_common
    "$SCRIPT_DIR/repro-cpu-saturation.sh" "$N" "$SEC"
    ;;
  profile)
    MS="${1:-50}"; RATE="${2:-800}"; SEC="${3:-15}"; DIR="${4:-down}"
    ensure_iperfd_mnet; ensure_rmem; ensure_wmem_mnet; ship_common; clear_netem; apply_uniform "$MS"; apply_uniform_host "$MS"
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
wlbstate)
    # 推定器収束の目視確認: ルーター STATUS ログの per-path 実測レートを
    # 2 点観測の差分 (tx+rx → Mbps) で表示。値が安定すればスケジューラの
    # 分配が現ネットワークに収束したとみなして計測を開始する。
    # 注記: xquic 内部の |wlb|round_start|est_bw ログは現ビルドでは mqvpn の
    # ログ出力に流れないため、ここでは STATUS の実測レートを proxy に使う。
    # STATUS の周期は 5-30s 程度で不規則なため、snap が進むまで 5s ずつ待つ。
    s1=$(wlb_snap)
    s2=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
      sleep 5
      s2=$(wlb_snap)
      [ -n "$s2" ] && [ "$s1" != "$s2" ] && break
    done
    echo "== WLB steady-state proxy (router STATUS per-path rate) =="
    if [ -n "$s1" ] && [ -n "$s2" ] && [ "$s1" != "$s2" ]; then
      # 観測間隔は 2 点の時刻差から算出 (STATUS 周期は不規則のため固定 5s で割らない)
      paste <(printf '%s\n' "$s1") <(printf '%s\n' "$s2") | awk '{split($1,t,":"); split($6,u,":"); dt=(u[1]*3600+u[2]*60+u[3])-(t[1]*3600+t[2]*60+t[3]); if(dt<=0)dt=5; rate=($9-$4)+($10-$5); printf "  path%s %s: %.0f Mbps (dt=%ds)\n", $2, $3, rate*8/(dt*1000000), dt}'
    else
      echo "  (STATUS path 行を捕捉できず。ログが流れていないか、mqvpn が応答なし)"
    fi
    ;;
  *)
    echo "unknown: $CMD (use: $CMDRUN)"; exit 1;
    ;;
esac
