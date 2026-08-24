#!/usr/bin/env bash
# 起動直後の DOWN (iperf -R) が 0/0 になる問題の層別トレース。
# up.sh 直後に (他に何も触らず) これを実行する:
#   ./test/trace-down.sh [sec] [rate]
# 各レグのバイト/UDP カウンタを before/after で取得し、差分を表示する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEC="${1:-8}"
RATE="${2:-400}"
TARGET="${BENCH_TARGET:-192.168.100.1}"

srv() { "$SCRIPT_DIR/ssh-server.sh" "$@" 2>/dev/null; }
rtr() { "$SCRIPT_DIR/ssh-router.sh" "$@" 2>/dev/null; }
cli() { "$SCRIPT_DIR/ssh-client.sh" "$@" 2>/dev/null; }
mnt() { "$SCRIPT_DIR/ssh-mnet.sh" "$@" 2>/dev/null; }

# サーバーコンテナ名を動的に解決 (mqvpn-server-N のハードコードを避ける)
SRV_CTR=$("$SCRIPT_DIR/ssh-server.sh" 'sudo docker ps --filter name=mqvpn-server --format "{{.Names}}" | head -1' 2>/dev/null | tr -d '\r')
SRV_CTR="${SRV_CTR:-mqvpn-server-0}"

# コンテナ内カウンタを 1 回の docker exec に集約して取得
CARG_CMD='ip -s link show eth0 | sed -n 4p | awk "{print \"carg veth_rx=\" \$1}"
ip -s link show mqvpn0 | sed -n 6p | awk "{print \"carg tun0_tx=\" \$1}"
cat /proc/sys/net/netfilter/nf_conntrack_count | awk "{print \"carg ct=\" \$1}"
awk "/^Udp:/{print}" /proc/net/snmp | tail -1 | awk "{print \"carg udp_in=\" \$2 \" noports=\" \$3 \" inerr=\" \$4}"'

# ノードごとの key=value 行の出力
snap() {
  local out="$1"
  {
    mnt 'set -e; N=$(awk "/^Udp:/{print}" /proc/net/snmp | tail -1); echo "mnet eth0_tx=$(ip -s link show eth0 | sed -n 6p | awk "{print $1}") udp_in=$(echo $N | awk "{print \$2}") noports=$(echo $N | awk "{print \$3}") inerr=$(echo $N | awk "{print \$4}") udp_out=$(echo $N | awk "{print \$5}")"'
    srv 'echo "vm eth2_rx=$(ip -s link show eth2 | sed -n 4p | awk "{print $1}")"'
    srv "sudo docker exec $SRV_CTR sh -c '$CARG_CMD'"
    rtr 'echo "rtr tun0_rx=$(ip -s link show mqvpn0 | sed -n 4p | awk "{print $1}") ct6205=$(grep -c 6205 /proc/net/nf_conntrack 2>/dev/null || echo 0)"; grep 6205 /proc/net/nf_conntrack 2>/dev/null | head -6'
    cli 'set -e; N=$(awk "/^Udp:/{print}" /proc/net/snmp | tail -1); echo "cli udp_in=$(echo $N | awk "{print \$2}") inerr=$(echo $N | awk "{print \$4}") rbuferr=$(echo $N | awk "{print \$6}")"'
  } > "$out" 2>/dev/null
}

echo "=== before ==="; snap /tmp/trace-before.txt; cat /tmp/trace-before.txt
echo ""
echo "=== running DOWN ${RATE}M ${SEC}s -> $TARGET ==="
cli "iperf3 -c ${TARGET} -p 6205 -u -R -b ${RATE}M -t ${SEC} -f m 2>&1" | tee /tmp/trace-iperf.txt
sleep 1
echo ""
echo "=== after ==="; snap /tmp/trace-after.txt; cat /tmp/trace-after.txt

echo ""
echo "=== DELTA (after - before) ==="
for NODE in mnet vm carg rtr cli; do
  B=$(grep "^$NODE " /tmp/trace-before.txt | head -1)
  A=$(grep "^$NODE " /tmp/trace-after.txt | head -1)
  D=""
  for K in $(echo "$A" | grep -oE "[a-z0-9_]+=[0-9]+" | cut -d= -f1); do
    BV=$(echo "$B" | grep -oE "$K=[0-9]+" | cut -d= -f2)
    AV=$(echo "$A" | grep -oE "$K=[0-9]+" | cut -d= -f2)
    D="$D $K+$((AV - BV))"
  done
  echo "$NODE:$D"
done
echo ""
echo "=== iperf (receiver) ==="
grep "receiver" /tmp/trace-iperf.txt