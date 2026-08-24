#!/usr/bin/env bash
# up.sh 直後の初回 DOWN をパケットレベルで捕まえる。
# ホストの tap (tm-ext: serverVM<->mnet / ts-mq: router<->serverVM) を全付属で保存。
# 使い方: up.sh 直後 (他に何も触らず):
#   nohup ./test/capture-first-down.sh 2>/dev/null &
#   ./test/trace-down.sh 6 300
#
# tcpdump は CAP_NET_RAW (raw socket 取得) が必要。一般ユーザーには無いため
# パスワード無し sudo (sudo -n) を使う。sudo が使えない/失敗する場合は
# $OUTDIR/*.err か起動直後の echo にエラーが出る (空 pcap で黙らない)。
set -uo pipefail

OUTDIR=${1:-/tmp/cap}
mkdir -p "$OUTDIR"

# nix shell は ephemeral (ホスト環境を汚さない)。1 インスタンスで複数 tap を
# 並走させ、起動オーバーヘッドを抑える。
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
