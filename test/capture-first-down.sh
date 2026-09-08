#!/usr/bin/env bash
# up.sh直後の初回DOWNをパケットレベルで捕まえる (tap全付属で保存)。
# 使い方: up.sh直後 (他に何も触らず):
#   nohup ./test/capture-first-down.sh 2>/dev/null &
#   ./test/trace-down.sh 6 300
#
# tcpdump要CAP_NET_RAWのためsudo -n使用 (失敗時はerr/起動echoに出る)。
set -uo pipefail

OUTDIR=${1:-/tmp/cap}
mkdir -p "$OUTDIR"

# 1インスタンスで複数tap並走 (起動オーバーヘッド抑止)。
sudo -n nix shell nixpkgs#tcpdump --command sh -c '
  tcpdump -ni tm-ext -s 0 -w "$1/tm-ext.pcap" "udp -l 1" >/dev/null 2>"$1/tm-ext.err" &
  tcpdump -ni ts-mq  -s 0 -w "$1/ts-mq.pcap"  "udp -l 1" >/dev/null 2>"$1/ts-mq.err"  &
  wait
' sh "$OUTDIR" &
P1=$!

sleep 1
echo "capturing on tm-ext + ts-mq ($P1) -> $OUTDIR"
echo "pcap: $(ls -l "$OUTDIR"/*.pcap 2>/dev/null | awk '{print $NF, $5"B"}' | tr '\n' ' ')"
echo "Ctrl-C で終了"
