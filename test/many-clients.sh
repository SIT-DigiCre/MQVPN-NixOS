#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# many-clients.sh: 下流の多クライアント環境を模した実環境寄りテスト
#
# 背景 (bench.sh との違い):
#   bench.sh の measure / multistream / stagger は全て mogami-client 単一 VM の
#   単一 IP (DHCP の 172.16.0.x 1 個)・単一 MAC から発射される。実環境 (70 人規模,
#   chiken/mqvpn-real-env.md) との乖離:
#     1. ECMP ハッシュのエントロピー不足: 単一 srcIP では port のみが分散要素。
#        実環境は srcIP が 70〜140 種類あり、トンネル間の振り分けが変わる。
#     2. conntrack / NAT テーブルのスケール未検証: 単一 IP の P=20 と 70IP×1 は
#        エントリ数が違い、GC・衝突・上限の出方が違う。
#     3. DHCP (Kea) / ARP / DNS (unbound) の多端末負荷が未測定:
#        140 並列 DNS で 34% 欠損した事例あり (configuration.nix の unbound 注释)。
#     4. トラフィック mix が bulk のみ: 実態は多数の小フロー + たまの speedtest。
#
# 方式: client VM 内に N 個の仮想クライアントを生やす。2 モード:
#   - alias (既定, 軽量): eth0 に secondary IP (172.31.250.1〜, pool 末尾側) を付与。
#     ECMP / conntrack / mix 試験用。DHCP・L2 は試験しない。
#   - l2: eth0 上に macvlan (mc0...) を N 個作り、各々 DHCP で Kea から実リース取得。
#     DHCP ストーム / ARP / MAC 多様性まで試験。from-rule + table で復路を macvlan
#     に戻す (policy routing)。
#
# Usage:
#   ./test/many-clients.sh up [N] [--l2]       # 仮想クライアント作成 (既定 N=70)
#   ./test/many-clients.sh down                # 後片付け (必ず実行)
#   ./test/many-clients.sh status              # 状態表示 (lease/conntrack/ECMP 等)
#   ./test/many-clients.sh bulk [N] [sec] [down|up]  # N 並列 bulk (各1フロー, srcIP 別)
#   ./test/many-clients.sh mix [N] [K] [sec] [down|up]  # trickle(N) + burst(K)
#   ./test/many-clients.sh dns [N] [Q] [fixed|diverse] [spread_ms]  # N 並列 DNS バースト
#     diverse: クエリ毎に別 QNAME (RANDOM 付きで negative cache も効かないフル再帰)。
#     spread_ms>0 で各台の開始を分散し一斉性の影響を分離。per-query 遅延分布＋unbound CPU 付き
#   ./test/many-clients.sh dhcp-storm [N]      # l2 全台の同時 release/renew
#   ./test/many-clients.sh netem <ms|hetero|asym|clear>  # WAN netem (bench.sh と同型)
#     ms: 上下均一遅延。up はルーター WAN egress、下りはホスト tap egress に
#         付与するため RTT には往復分 (約 2x ms) が載る。例: netem 10 ≒ RTT+20ms
#         (実回線 23ms の再現は base 2.5ms + netem 10)。hetero: 不均質
#         (45ms/12ms/loss1% 系×3)。asym: 非対称容量 (up 35M / down 150M,
#         delay 12ms) で bufferbloat 気味の実回線再現。bulk/mix/dns の前に掛けて使う
#
# 前提: lab 起動済み (test/up.sh)。mnet の iperf ポートは必要分だけ自動で足す
#   (5301 以降は実行時に iptables で一時開放。down では閉じないが lab 破棄で消える)。
# 注意: client VM (2vCPU) 自体が 140 並列 iperf の CPU 天井になる場合あり。
#   bulk の client 側合計が頭打ちで per-WAN に余裕があれば client 律速を疑うこと。
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -ge 1 ] || { echo "usage: $0 <up|down|status|bulk|mix|dns|dhcp-storm|netem> [...]"; exit 1; }
CMD="$1"; shift || true

ssh_rtr() { timeout 90 "$SCRIPT_DIR/ssh-router.sh" "$@"; }
ssh_cli() { timeout 120 "$SCRIPT_DIR/ssh-client.sh" "$@"; }
ssh_mnet() { timeout 90 "$SCRIPT_DIR/ssh-mnet.sh" "$@"; }
ssh_srv() { timeout 90 "$SCRIPT_DIR/ssh-server.sh" "$@"; }

TARGET="${BENCH_TARGET:-192.168.100.1}"
PORT_BASE=5201
ALIAS_BASE="172.31.250"   # Kea pool 末尾側。逐次割当では到達しない領域
MC_MAX=250

# WAN NIC 一覧は flake が唯一の情報源 (bench.sh と同じ)
rtr_wan=($(nix eval --json "path:$(cd "$SCRIPT_DIR/.." && pwd)#nixosConfigurations.mogami-vm.config.services.mqvpn.interfaces" 2>/dev/null | nix shell nixpkgs#jq --command jq -r '.[]' 2>/dev/null || true))
[ "${#rtr_wan[@]}" -gt 0 ] || { echo "ERROR: WAN NIC 一覧を flake から取得できない" >&2; exit 1; }

iface_counter() { # $1=iface $2=RX|TX (数値のみ返す)
  ssh_rtr "ip -s link show $1 2>/dev/null | awk '/$2:/{getline;print \$1}'" 2>/dev/null | grep -E '^[0-9]+$' | tail -1
}
rx_bytes() { iface_counter "$1" RX; }

# トンネル確立待ち (起動直後の bulk 空振り防止。bench.sh の wait_wlb_steady の軽量版:
# ECMP メンバー数＋peer 付与を見る。QUIC ハンドシェイク完了まで最大 120s)
wait_tunnels() {
  local i n
  for i in $(seq 1 24); do
    n=$(ssh_rtr 'm=$(ip route show default 2>/dev/null | grep -c "nexthop dev mqvpn"); p=$(for d in mqvpn0 mqvpn1 mqvpn2; do ip -o addr show $d 2>/dev/null | grep -o "peer [0-9.]*"; done | wc -l); echo "$m/$p"' 2>/dev/null | grep -oE '[0-9]+/[0-9]+' | tail -1)
    [ "$n" = "3/3" ] && { echo "tunnels ready (ECMP 3 + peers 3)"; return 0; }
    sleep 5
  done
  echo "WARN: tunnels not fully ready ($n). continue anyway" >&2
  return 0
}
tx_bytes() { iface_counter "$1" TX; }

# --- netem (bench.sh と同型。使う WAN は mqvpn の 3 本のみ) ---
# 下りは server→router パケットがホスト WAN tap の egress を通るため、
# router 側ではなくホスト側 tap (trw0-2 ↔ eth1,eth3,eth4) に掛ける。
host_wan=(trw0 trw1 trw2)
mc_netem() { # $1=clear|hetero|asym|$ms
  local spec="$1" rcmd hcmd
  case "$spec" in
    clear) ssh_rtr "for i in ${rtr_wan[*]}; do sudo -n tc qdisc del dev \$i root 2>/dev/null || true; done; echo netem-cleared" 2>/dev/null | tail -1
      for t in "${host_wan[@]}"; do sudo -n tc qdisc del dev "$t" root 2>/dev/null || true; done; echo "netem-cleared-host"; return ;;
    hetero) rcmd="delay 45ms 12ms loss 1% limit 100000"; hcmd="$rcmd" ;;
    asym) rcmd="delay 12ms rate 35mbit limit 100000"; hcmd="delay 12ms rate 150mbit limit 100000" ;;
    *) rcmd="delay ${spec}ms limit 100000"; hcmd="$rcmd" ;;
  esac
  ssh_rtr "for i in ${rtr_wan[*]}; do sudo -n tc qdisc replace dev \$i root netem $rcmd; done; echo applied" 2>/dev/null | tail -1
  for t in "${host_wan[@]}"; do sudo -n tc qdisc replace dev "$t" root netem $hcmd; done
  echo "applied-host${spec:+ ($spec)}"
}
do_netem() { # $1=ms|hetero|asym|clear
  case "${1:-}" in
    clear|hetero|asym) mc_netem "$1" ;;
    ''|*[!0-9]*) echo "usage: $0 netem <delay_ms|hetero|asym|clear>"; exit 1 ;;
    *) mc_netem "$1" ;;
  esac
  sleep 3 # WLB/TCP の過渡が落ち着くまで少し待つ (厳密な収束待ちは bench.sh wlbstate)
}

# mnet に N ポート分の iperfd を確保 + 5301 以降の FW を一時開放
ensure_iperfd_mnet() { # $1=N
  local n="$1" p
  ssh_mnet "for p in \$(seq $PORT_BASE $((PORT_BASE + n - 1))); do ss -tln | grep -q \":\$p \" || iperf3 -s -p \$p -D --logfile /tmp/i3-\$p.log 2>/dev/null; done; echo iperfd-ok" >/dev/null 2>&1 || true
  if [ "$((PORT_BASE + n - 1))" -gt 5300 ]; then
    ssh_mnet "sudo -n iptables -C INPUT -p tcp --dport 5201:$((PORT_BASE + n - 1)) -j ACCEPT 2>/dev/null || sudo -n iptables -I INPUT -p tcp --dport 5201:$((PORT_BASE + n - 1)) -j ACCEPT; sudo -n iptables -C INPUT -p udp --dport 5201:$((PORT_BASE + n - 1)) -j ACCEPT 2>/dev/null || sudo -n iptables -I INPUT -p udp --dport 5201:$((PORT_BASE + n - 1)) -j ACCEPT; echo fw-ok" >/dev/null 2>&1 || true
  fi
  # 高レート時の受信溢れ対策 (bench.sh と同等)
  ssh_cli 'sudo -n sysctl -w net.core.rmem_max=67108864 net.core.rmem_default=67108864 >/dev/null; echo ok' >/dev/null 2>&1 || true
  ssh_mnet 'sudo -n sysctl -w net.core.wmem_max=67108864 net.core.wmem_default=67108864 net.ipv4.tcp_wmem="4096 131072 67108864" net.core.rmem_max=67108864 >/dev/null 2>&1; echo ok' >/dev/null 2>&1 || true
}

# 複雑な client 側処理はスクリプト配送→実行 (bench.sh の ship_common と同型)。
# 配送先は毎回一意化する (mix のように BG/FG 並走すると同名だと踏み合うため)。
run_on_cli() { # $1=script $2...=args
  local script="$1"; shift
  local f; f=$(mktemp /tmp/mc-run-XXXXXX.sh)
  printf '%s\n' "$script" | ssh_cli "cat > $f && chmod +x $f && $f $*; rm -f $f" 2>&1 | grep -vE 'fetching|Warning:' || true
}

MC_UP_ALIAS=$(cat <<'EOF'
#!/usr/bin/env bash
# $1=N: eth0 に secondary IP を付与し /tmp/mc-ips.txt (1行1IP) に記録
set -euo pipefail
N="$1"; BASE="172.31.250"
[ "$N" -le 250 ] || { echo "N<=$((250))まで (alias pool 枯渇)"; exit 1; }
# 使用中チェック (並列 ping sweep, 約3秒)。wait の終了状態は無視する
# (conflict 無し = 全 ping 失敗 = wait 非ゼロが正常系のため set -e 対策)。
conflict=$(for i in $(seq 1 "$N"); do (ping -c1 -W1 "$BASE.$i" >/dev/null 2>&1 && echo "$BASE.$i" || true) & done; wait || true)
[ -z "$conflict" ] || { echo "conflict (使用中): $conflict — down して掃除するか --l2 を使うこと"; exit 1; }
: > /tmp/mc-ips.txt
for i in $(seq 1 "$N"); do
  sudo -n ip addr add "$BASE.$i/12" dev eth0 2>/dev/null || true
  echo "$BASE.$i" >> /tmp/mc-ips.txt
done
echo "alias-up N=$N ($BASE.1-$BASE.$N on eth0)"
EOF
)

MC_UP_L2=$(cat <<'EOF'
#!/usr/bin/env bash
# $1=N: macvlan + DHCP で実リース取得。from-rule で復路を macvlan に戻す。
# 注意: client の system dhcpcd が mc* を自動管理するため直接 dhcpcd を叩かない。
#   (up 後に carrier up → daemon が Kea へ DISCOVER。ここでは lease を待つだけ)
set -euo pipefail
N="$1"
: > /tmp/mc-ips.txt
mkone() {
  local i="$1" dev="mc$i" ip="" s
  sudo -n ip link del "$dev" 2>/dev/null || true
  sudo -n ip link add link eth0 name "$dev" type macvlan mode bridge
  sudo -n ip link set "$dev" up
  # system dhcpcd の lease を最大 25s 待つ (Kea からの実リース)。
  # NOTE: grep をパイプに使うと pipefail+set -e で死ぬため awk で抽出する
  for s in $(seq 1 25); do
    ip=$(ip -4 -o addr show "$dev" 2>/dev/null | awk '/dynamic/ {print $4}' | cut -d/ -f1 | head -1)
    [ -n "$ip" ] && break
    sleep 1
  done
  if [ -z "$ip" ]; then
    ip="172.31.250.$((i + 1))"
    sudo -n ip addr add "$ip/12" dev "$dev" 2>/dev/null || true
    echo "  $dev: DHCP タイムアウト → static $ip (fallback)" >&2
  fi
  local tab=$((100 + i))
  sudo -n ip route replace default via 172.16.0.1 dev "$dev" table "$tab" 2>/dev/null || true
  sudo -n ip rule add from "$ip" table "$tab" 2>/dev/null || true
  echo "$ip" >> /tmp/mc-ips.txt
  echo "$dev $ip"
}
for i in $(seq 0 $((N - 1))); do mkone "$i" & done
wait || true
echo "l2-up done: $(wc -l < /tmp/mc-ips.txt)/$N addrs"
EOF
)

MC_DOWN=$(cat <<'EOF'
#!/usr/bin/env bash
# 仮想クライアント全掃除 (alias + l2 両対応)
set -euo pipefail
pkill -f 'iperf3 -c ' 2>/dev/null || true
pkill -f 'mc-trickle' 2>/dev/null || true
if [ -f /tmp/mc-ips.txt ]; then
  while read -r ip; do
    [ -n "$ip" ] || continue
    sudo -n ip rule del from "$ip" 2>/dev/null || true
    sudo -n ip addr del "$ip/12" dev eth0 2>/dev/null || true
  done < /tmp/mc-ips.txt
fi
for dev in $(ip -o link show 2>/dev/null | grep -oE 'mc[0-9]+' | sort -u || true); do
  tab="${dev#mc}"; tab=$((100 + tab))
  if command -v dhcpcd >/dev/null 2>&1; then sudo -n dhcpcd -k "$dev" >/dev/null 2>&1 || true; fi
  sudo -n ip link del "$dev" 2>/dev/null || true
  sudo -n ip route flush table "$tab" 2>/dev/null || true
done
rm -f /tmp/mc-ips.txt /tmp/mc-*.json /tmp/mc-*.log /tmp/dhcpcd-mc*.pid
echo "mc-down done"
EOF
)

do_status() {
  echo "== client: 仮想クライアント =="
  ssh_cli 'n=$(wc -l < /tmp/mc-ips.txt 2>/dev/null || echo 0); echo "addrs: $n"; head -5 /tmp/mc-ips.txt 2>/dev/null; ip -o link show 2>/dev/null | grep -c -oE "mc[0-9]+" | xargs echo "macvlan devs:"' 2>/dev/null | grep -vE 'fetching|Warning:'
  echo "== router: NAT/conntrack/neigh/lease/ECMP =="
  ssh_rtr 'echo -n "conntrack: "; cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null; echo -n "conntrack_max: "; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null; echo -n "neigh: "; ip neigh show 2>/dev/null | wc -l; echo -n "kea leases: "; sudo -n sh -c "cat /var/lib/private/kea/*leases* /var/lib/kea/*leases* 2>/dev/null | grep -c -E ^[0-9] || true" 2>/dev/null; echo -n "ECMP: "; ip route show default 2>/dev/null | head -2 | tr "\n" " "; echo' 2>/dev/null | grep -vE 'fetching|Warning:'
  echo "== router: mqvpn STATUS tail (path 行) =="
  ssh_rtr 'sudo journalctl -n 200 --no-pager -u mqvpn-0.service 2>/dev/null | grep -E "path[0-9]=eth" | tail -2' 2>/dev/null | grep -vE 'fetching|Warning:'
  echo "== mnet: iperfd =="
  ssh_mnet 'ss -tln 2>/dev/null | grep -c -E ":(52[0-9]{2}|6205) "' 2>/dev/null | grep -vE 'fetching|Warning:' | xargs echo "listen ports:"
  echo "== netem (WAN) =="
  ssh_rtr 'for d in eth1 eth3 eth4; do printf "  %-6s %s\n" "$d" "$(tc qdisc show dev $d 2>/dev/null | head -1 | grep -oE "(netem.*|fq_codel.*)" | cut -c1-60)"; done' 2>/dev/null | grep -vE 'fetching|Warning:'
}

need_ips() { # $1=N: /tmp/mc-ips.txt の行数確認
  local n="$1" have
  have=$(ssh_cli 'wc -l < /tmp/mc-ips.txt 2>/dev/null || echo 0' 2>/dev/null | grep -oE '[0-9]+' | tail -1)
  [ "${have:-0}" -ge "$n" ] || { echo "仮想クライアント不足 (have=${have:-0} need=$n)。先に '$0 up $n' を実行"; exit 1; }
}

snap_cpu() { # $1=rtr|srv $2=tag: /proc/stat の cpu 行を保存 (前後差で % 算出用)
  local ssh="ssh_rtr"; [ "$1" = "srv" ] && ssh="ssh_srv"
  $ssh "grep '^cpu ' /proc/stat | awk '{print \$2+\$3+\$4, \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9}' > /tmp/mc-cpu-$2" >/dev/null 2>&1 || true
}
cpu_pct() { # $1=rtr|srv $2=before $3=after
  local ssh="ssh_rtr"; [ "$1" = "srv" ] && ssh="ssh_srv"
  local b0=0 b1=0 t0=0 t1=1
  read -r b0 t0 < <($ssh "cat /tmp/mc-cpu-$2" 2>/dev/null | grep -oE '[0-9]+ [0-9]+' | tail -1) || true
  read -r b1 t1 < <($ssh "cat /tmp/mc-cpu-$3" 2>/dev/null | grep -oE '[0-9]+ [0-9]+' | tail -1) || true
  # NOTE: var=value オペランドは BEGIN から見えない awk があるため -v で渡す
  awk -v b0="$b0" -v b1="$b1" -v t0="$t0" -v t1="$t1" 'BEGIN{d=t1-t0; if(d<=0){print "?"} else {printf "%.0f%%", (b1-b0)*100/d}}' 2>/dev/null || echo "?"
}

MC_BULK=$(cat <<'EOF'
#!/usr/bin/env bash
# $1=TARGET $2=sec [$3=ipfile] [$4=down|up]: 各 IP から別ポートで 1フローずつ bulk
set -euo pipefail
TARGET="$1"; SEC="$2"; IPFILE="${3:-/tmp/mc-ips.txt}"; DIR="${4:-down}"; BASE=5201
FLAG="-R"; JQFIELD="sum_received"
[ "$DIR" = "up" ] && { FLAG=""; JQFIELD="sum_sent"; }
rm -f /tmp/mc-b-*.json /tmp/mc-b-*.err
i=0
while read -r ip; do
  [ -n "$ip" ] || continue
  p=$((BASE + i))
  (iperf3 -c "$TARGET" -p "$p" -B "$ip" $FLAG -t "$SEC" --json > /tmp/mc-b-$i.json 2>/tmp/mc-b-$i.err) &
  i=$((i + 1))
done < "$IPFILE"
wait || true
echo "flows done: $i ($DIR)"
ls /tmp/mc-b-*.json >/dev/null 2>&1 || { echo "no results (iperf 全失敗)"; exit 0; }
# per-client 分布 (min/p50/max + 合計)。単一 TOTAL 平均では見えない tail を見る
jq -s -r --arg f "$JQFIELD" '[.[] | .end[$f].bits_per_second // 0] | {n: length, total: (add/1e6), sorted: (sort)} |
  "n=\(.n) total=\(.total|floor)M min=\(.sorted[0]/1e6|floor)M p50=\(.sorted[.n/2|floor]/1e6|floor)M max=\(.sorted[-1]/1e6|floor)M zero=\([.sorted[]|select(.==0)]|length)"' /tmp/mc-b-*.json 2>/dev/null || true
EOF
)

do_bulk() {
  local n="${1:-70}" sec="${2:-20}" dir="${3:-down}"
  [ "$dir" = down ] || [ "$dir" = up ] || { echo "dir must be down|up"; exit 1; }
  need_ips "$n"; ensure_iperfd_mnet "$n"; wait_tunnels
  echo "== bulk: $n clients x 1flow $dir (${sec}s, srcIP 別) =="
  local i w snap
  snap() { if [ "$dir" = up ]; then tx_bytes "$1"; else rx_bytes "$1"; fi; }
  declare -A B0
  for w in "${rtr_wan[@]}"; do B0[$w]=$(snap "$w"); done
  local ct0 sct0
  ct0=$(ssh_rtr 'cat /proc/sys/net/netfilter/nf_conntrack_count' 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
  sct0=$(ssh_srv 'cat /proc/sys/net/netfilter/nf_conntrack_count' 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
  snap_cpu rtr pre; snap_cpu srv pre
  run_on_cli "$MC_BULK" "$TARGET" "$sec" /tmp/mc-ips.txt "$dir"
  snap_cpu rtr post; snap_cpu srv post
  local tot=0 mbps B1
  for w in "${rtr_wan[@]}"; do
    B1=$(snap "$w")
    mbps=$(( (${B1:-0} - ${B0[$w]:-0}) * 8 / (sec * 1000000) ))
    printf "  %-6s %8d Mbps\n" "$w" "$mbps"
    tot=$((tot + mbps))
  done
  echo "  TOTAL (tunnel-bound) = ${tot} Mbps"
  echo "  conntrack rtr: ${ct0:-?} -> $(ssh_rtr 'cat /proc/sys/net/netfilter/nf_conntrack_count' 2>/dev/null | grep -E '^[0-9]+$' | tail -1)  srv: ${sct0:-?} -> $(ssh_srv 'cat /proc/sys/net/netfilter/nf_conntrack_count' 2>/dev/null | grep -E '^[0-9]+$' | tail -1)"
  echo "  CPU rtr: $(cpu_pct rtr pre post)  srv: $(cpu_pct srv pre post)"
}

MC_TRICKLE=$(cat <<'EOF'
#!/usr/bin/env bash
# $1=TARGET $2=sec: 各仮想 IP から ping + DNS を細く長く (background 負荷)
set -euo pipefail
TARGET="$1"; SEC="$2"
i=0
while read -r ip; do
  [ -n "$ip" ] || continue
  (ping -I "$ip" -c $((SEC * 2)) -i 0.5 "$TARGET" > /tmp/mc-t-$i.log 2>&1;
   fails=0; for _ in $(seq 1 5); do dig @"172.16.0.1" +time=2 +tries=1 +short example.com > /dev/null 2>&1 || fails=$((fails+1)); done;
   echo "fails=$fails" >> /tmp/mc-t-$i.log) &
  i=$((i + 1))
done < /tmp/mc-ips.txt
wait || true
loss=$(grep -h -oE '[0-9.]+% packet loss' /tmp/mc-t-*.log 2>/dev/null | awk -F'%' '{print int($1)}' | sort -n | awk '{a[NR]=$1} END{if(NR==0){print "?"} else {printf "p50=%d%% max=%d%% (n=%d)", a[int(NR/2)+1], a[NR], NR}}' || true)
rtt=$(grep -h 'rtt min/avg/max' /tmp/mc-t-*.log 2>/dev/null | grep -oE '= [0-9.]+/[0-9.]+' | grep -oE '/[0-9.]+' | tr -d '/' | sort -n | awk '{a[NR]=$1} END{if(NR==0){print "?"} else {printf "avg p50=%.0fms max=%.0fms (n=%d)", a[int(NR/2)+1], a[NR], NR}}' || true)
dnfails=$(grep -h -oE 'fails=[0-9]+' /tmp/mc-t-*.log 2>/dev/null | grep -oE '[0-9]+$' | awk '{s+=$1; n++} END{printf "%d/%d queries failed", s, n*5}' || true)
echo "trickle: ping loss ${loss}; rtt ${rtt}; dns ${dnfails}"
EOF
)

do_mix() {
  local n="${1:-70}" k="${2:-5}" sec="${3:-30}" dir="${4:-down}"
  [ "$dir" = down ] || [ "$dir" = up ] || { echo "dir must be down|up"; exit 1; }
  [ "$k" -le "$n" ] || k="$n"
  need_ips "$n"; ensure_iperfd_mnet "$k"
  echo "== mix: trickle $n + burst $k x bulk $dir (${sec}s) =="
  # burst 用に先頭 K 行を切出し (trickle は全 N、bulk は K の別ファイルで競合なし)
  ssh_cli "head -$k /tmp/mc-ips.txt > /tmp/mc-burst.txt" >/dev/null 2>&1 || true
  run_on_cli "$MC_TRICKLE" "$TARGET" "$sec" &
  local TPID=$!
  sleep 2
  run_on_cli "$MC_BULK" "$TARGET" "$((sec - 4))" /tmp/mc-burst.txt "$dir"
  wait "$TPID" || true
  ssh_cli "rm -f /tmp/mc-burst.txt" >/dev/null 2>&1 || true
  echo "(trickle の loss/dns は burst 干渉下の値。単独時との差が体感劣化の目安)"
}

MC_DNS=$(cat <<'EOF'
#!/usr/bin/env bash
# $1=Q $2=mode(fixed|diverse) $3=N [$4=spread_ms]: N 台が各 Q 発を dig @172.16.0.1。
# spread>0 で各台の開始を 0〜spread ms に分散 (一斉性の影響分離用)。
# diverse はクエリ毎に別 QNAME (RANDOM 付きで negative cache も効かない)。
# per-query の Query time を集めて遅延分布を出す (成功率だけでなく遅さも見る)。
set -euo pipefail
Q="$1"; MODE="${2:-fixed}"; N="${3:-70}"; SPREAD="${4:-0}"
rm -f /tmp/mc-d-*.log /tmp/mc-d-*.times
i=0
while read -r ip; do
  [ -n "$ip" ] || continue
  [ "$i" -lt "$N" ] || break
  (d=$(awk -v i="$i" -v n="$N" -v s="$SPREAD" 'BEGIN{printf "%.3f", (n>1 ? i*s/(n-1) : 0)/1000}'); [ "$d" != "0.000" ] && sleep "$d"
   ok=0; t0=$(date +%s%N)
   for k in $(seq 1 "$Q"); do
     if [ "$MODE" = diverse ]; then qn="u${i}-${k}-${RANDOM}.example.com"; else qn="example.com"; fi
     ms=$(dig @172.16.0.1 +time=2 +tries=1 +stats "$qn" 2>&1 | grep -oE 'Query time: [0-9]+ msec' | grep -oE '[0-9]+' | head -1 || true)
     if [ -n "$ms" ]; then ok=$((ok+1)); echo "$ms" >> /tmp/mc-d-$i.times; else echo "TIMEOUT" >> /tmp/mc-d-$i.times; fi
   done
   t1=$(date +%s%N); echo "ok=$ok wall_ms=$(( (t1-t0)/1000000 ))" > /tmp/mc-d-$i.log) &
  i=$((i + 1))
done < /tmp/mc-ips.txt
wait || true
awk -F'[= ]' -v q="$Q" '/ok=/{ok+=$2; w+=$4; n++} END{if(n==0){print "no data"} else {printf "success=%.1f%% (%d/%d) avg_wall_per_client=%.0fms\n", ok/(n*q)*100, ok, n*q, w/n}}' /tmp/mc-d-*.log 2>/dev/null || true
grep -h -oE '^[0-9]+$' /tmp/mc-d-*.times 2>/dev/null | sort -n | awk '{a[NR]=$1} END{if(NR==0){print "latency: no samples"} else {printf "latency(ms): n=%d p50=%d p95=%d max=%d\n", NR, a[int(NR/2)+1], a[int(NR*0.95)+1], a[NR]}}' || true
echo "timeouts: $(grep -h -c TIMEOUT /tmp/mc-d-*.times 2>/dev/null | awk '{s+=$1} END{print s+0}')"
EOF
)

do_dns() {
  local n="${1:-70}" q="${2:-5}" mode="${3:-fixed}" spread="${4:-0}" round
  [ "$mode" = fixed ] || [ "$mode" = diverse ] || { echo "mode must be fixed|diverse"; exit 1; }
  need_ips "$n"
  echo "== dns burst ($mode, spread=${spread}ms): $n clients x $q queries @172.16.0.1 (round1/round2) =="
  local hztick; hztick=$(ssh_rtr 'getconf CLK_TCK 2>/dev/null || echo 100' 2>/dev/null | grep -oE '[0-9]+' | tail -1)
  hztick="${hztick:-100}"
  snap_cpu rtr pre
  local ub_pre t_pre; ub_pre=$(unbound_jiffies); t_pre=$(date +%s)
  for round in 1 2; do
    run_on_cli "$MC_DNS" "$q" "$mode" "$n" "$spread" | sed "s/^/round$round: /"
  done
  local ub_post t_post; ub_post=$(unbound_jiffies); t_post=$(date +%s)
  snap_cpu rtr post
  local wall=$((t_post - t_pre)); [ "$wall" -gt 0 ] || wall=1
  echo "unbound CPU: $(awk -v a="$ub_pre" -v b="$ub_post" -v w="$wall" -v h="$hztick" 'BEGIN{printf "%.0f%%core", (b-a)/w/h*100}')"
  echo "router CPU: $(cpu_pct rtr pre post)"
  echo "-- unbound (best-effort) --"
  ssh_rtr 'sudo -n unbound-control stats_noreset 2>/dev/null | grep -E "num.queries|unwanted|timeout" | head -5; sudo journalctl -n 50 --no-pager -u unbound.service 2>/dev/null | grep -ciE "error|drop|timeout" | xargs echo "unbound err lines:"' 2>/dev/null | grep -vE 'fetching|Warning:' | tail -6
}

unbound_jiffies() { # router の unbound プロセスの utime+stime (jiffies)
  ssh_rtr 'p=$(pgrep -x unbound 2>/dev/null | head -1); if [ -n "$p" ] && [ -r /proc/$p/stat ]; then awk "{print \$14+\$15}" /proc/$p/stat; else echo 0; fi' 2>/dev/null | grep -oE '[0-9]+' | tail -1
}

do_dhcp_storm() {
  local n="${1:-70}"
  echo "== dhcp-storm: $n 台同時 release/renew (l2) =="
  run_on_cli "$MC_UP_L2" "$n" | tail -2
  local since; since=$(ssh_rtr 'date "+%Y-%m-%d %H:%M:%S"' 2>/dev/null | grep -vE 'fetching|Warning:' | tail -1)
  time run_on_cli "$(cat <<'EOF'
#!/usr/bin/env bash
# system dhcpcd 経由で全台 release → renew (daemon は1つ。-k/-n で操作)
set -euo pipefail
for dev in $(ip -o link show 2>/dev/null | grep -oE 'mc[0-9]+' | sort -u || true); do
  (sudo -n dhcpcd -k "$dev" >/dev/null 2>&1 || true) &
done
wait || true
sleep 2
gone=0; total=0
for dev in $(ip -o link show 2>/dev/null | grep -oE 'mc[0-9]+' | sort -u || true); do
  total=$((total+1)); ip -4 -o addr show "$dev" 2>/dev/null | grep -q ' dynamic' || gone=$((gone+1))
done
echo "released(no dynamic addr): $gone/$total"
for dev in $(ip -o link show 2>/dev/null | grep -oE 'mc[0-9]+' | sort -u || true); do
  (sudo -n dhcpcd -n "$dev" >/dev/null 2>&1 || true) &
done
wait || true
for s in $(seq 1 25); do
  ok=0; total=0
  for dev in $(ip -o link show 2>/dev/null | grep -oE 'mc[0-9]+' | sort -u || true); do
    total=$((total+1)); ip -4 -o addr show "$dev" 2>/dev/null | grep -q ' dynamic' && ok=$((ok+1))
  done
  [ "$ok" -eq "$total" ] && break
  sleep 1
done
echo "renewed(dynamic addr back): $ok/$total"
EOF
)"
  echo "-- kea errors since $since --"
  ssh_rtr "sudo journalctl --since '$since' --no-pager -u kea-dhcp4-server.service 2>/dev/null | grep -ciE 'error|fail|drop|exhaust' | xargs echo 'kea err lines:'" 2>/dev/null | grep -vE 'fetching|Warning:' | tail -1
}

case "$CMD" in
  up)
    N="${1:-70}"; MODE="${2:-alias}"
    if [ "$MODE" = "--l2" ] || [ "$MODE" = "l2" ]; then
      run_on_cli "$MC_UP_L2" "$N"
    else
      run_on_cli "$MC_UP_ALIAS" "$N"
    fi
    do_status | head -8
    ;;
  down) run_on_cli "$MC_DOWN" ;;
  status) do_status ;;
  bulk) do_bulk "${1:-70}" "${2:-20}" "${3:-down}" ;;
  mix) do_mix "${1:-70}" "${2:-5}" "${3:-30}" "${4:-down}" ;;
  dns) do_dns "${1:-70}" "${2:-5}" "${3:-fixed}" "${4:-0}" ;;
  dhcp-storm) do_dhcp_storm "${1:-70}" ;;
  netem) do_netem "${1:-}" ;;
  *) echo "unknown: $CMD (use: up|down|status|bulk|mix|dns|dhcp-storm|netem)"; exit 1 ;;
esac
