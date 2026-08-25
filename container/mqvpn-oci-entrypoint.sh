#!/bin/bash
# NOTE: イメージに /usr/bin/env は無いため shebang は /bin/bash を直接指す
#       (Docker Cmd も /bin/bash で起動するため実質的に同じ)
set -euo pipefail

CONF="${MQVPN_CONF:-/etc/mqvpn/server.conf}"
if [ ! -f "$CONF" ]; then
  echo "mqvpn-oci: no $CONF (mount the config)" >&2
  exit 1
fi

# インスタンスインデックスの決定。優先順: MQVPN_INSTANCE_IDX env > ホスト名末尾の数値。
# 注: network_mode: host ではコンテナのホスト名がホスト(VM)のもの (例: mogami-server)
# になりコンテナ名が取れない。また本イメージに hostname コマンドは無い。
# そのため host-net 運用では MQVPN_INSTANCE_IDX の設定が必須 (bridge ならホスト名から導出可)。
#   idx から導出: tun_name=mqvpn<idx> / listen=0.0.0.0:(443+idx) /
#   control_listen=127.0.0.1:(9090+idx*2) / exporter=(9091+idx*2) /
#   subnet=192.168.<idx>.0/24。明示的な MQVPN_* env があればそれが最優先。
_OCI_IDX="${MQVPN_INSTANCE_IDX:-}"
if [ -z "${_OCI_IDX}" ]; then
  _OCI_HN="$(cat /etc/hostname 2>/dev/null)"
  _OCI_TAIL="${_OCI_HN##*-}"
  if [ -n "${_OCI_TAIL}" ] && [ "${_OCI_TAIL}" != "${_OCI_HN}" ] && [[ "${_OCI_TAIL}" =~ ^[0-9]+$ ]]; then
    _OCI_IDX="${_OCI_TAIL}"
  fi
fi
if [ -z "${_OCI_IDX}" ]; then
  echo "mqvpn-oci: インスタンスインデックスを決定できません。MQVPN_INSTANCE_IDX を設定してください (host-net では必須)。" >&2
  echo "mqvpn-oci: bridge 運用の場合はコンテナ名を 'mqvpn-server-<idx>' 形式にすれば自動導出されます。" >&2
  exit 1
fi
if [ -z "${MQVPN_TUN_NAME:-}" ]; then
  MQVPN_TUN_NAME="mqvpn${_OCI_IDX}"
fi
if [ -z "${MQVPN_SUBNET:-}" ]; then
  MQVPN_SUBNET="192.168.${_OCI_IDX}.0/24"
fi
if [ -z "${MQVPN_LISTEN:-}" ]; then
  MQVPN_LISTEN="0.0.0.0:$((443 + _OCI_IDX))"
fi
if [ -z "${MQVPN_CONTROL_LISTEN:-}" ]; then
  MQVPN_CONTROL_LISTEN="127.0.0.1:$((9090 + _OCI_IDX * 2))"
fi
if [ -z "${MQVPN_EXPORTER_PORT:-}" ]; then
  MQVPN_EXPORTER_PORT="$((9091 + _OCI_IDX * 2))"
fi

# env 上書きは JSON config 専用 — INI と組み合わせると黙って crash loop に
# 落ちるため、JSON でなければ明示エラーで停止する
if [ -n "${MQVPN_SUBNET:-}" ] || [ -n "${MQVPN_TUN_NAME:-}" ] || [ -n "${MQVPN_LISTEN:-}" ] || [ -n "${MQVPN_CONTROL_LISTEN:-}" ]; then
  if ! jq -e . "$CONF" >/dev/null 2>&1; then
    echo "mqvpn-oci: MQVPN_SUBNET/MQVPN_TUN_NAME/MQVPN_LISTEN/MQVPN_CONTROL_LISTEN 上書きには JSON config が必要です (INI は非対応): $CONF" >&2
    echo "mqvpn-oci: config を JSON 形式に変換するか、上書き env を外してください" >&2
    exit 1
  fi
fi
if [ -n "${MQVPN_SUBNET:-}" ] || [ -n "${MQVPN_TUN_NAME:-}" ] || [ -n "${MQVPN_LISTEN:-}" ] || [ -n "${MQVPN_CONTROL_LISTEN:-}" ]; then
  mkdir -p /tmp
  jq --arg s "${MQVPN_SUBNET:-}" --arg t "${MQVPN_TUN_NAME:-}" \
     --arg l "${MQVPN_LISTEN:-}" --arg c "${MQVPN_CONTROL_LISTEN:-}" \
    '(.subnet |= if $s == "" then . else $s end)
     | (.tun_name |= if $t == "" then . else $t end)
     | (.listen |= if $l == "" then . else $l end)
     | (.control_listen |= if $c == "" then . else $c end)' \
    "$CONF" > /tmp/server.conf
  CONF=/tmp/server.conf
fi

echo "mqvpn-oci: nat setup $CONF"
mqvpn-server-nat.sh setup "$CONF"

# 制御 API は daemon のシングルスレッド内で処理され高負荷時に秒単位で劣化
# するため、exporter の timeout には余裕を持たせる。
# ログは stdout に出る (docker logs で scrape 失敗を確認できる)
# host-network 運用等で制御 API / exporter のポートをずらす場合は
# MQVPN_CONTROL_LISTEN / MQVPN_EXPORTER_PORT で上書きする。
EXPORTER_PORT="${MQVPN_EXPORTER_PORT:-9091}"
EXPORTER_CTL="${MQVPN_CONTROL_LISTEN:-127.0.0.1:9090}"
mqvpn-prometheus-exporter -web.listen-address=0.0.0.0:"$EXPORTER_PORT" \
  -mqvpn.address="$EXPORTER_CTL" -mqvpn.timeout=30s \
  -mqvpn.scrape-budget=25s &

fails=0
cleanup() {
  set +e
  pkill -f "mqvpn --config" 2>/dev/null
  mqvpn-server-nat.sh teardown "$CONF" 2>/dev/null
}
trap cleanup EXIT

while :; do
  echo "mqvpn-oci: starting $CONF"
  mqvpn --config "$CONF" &
  pid=$!
  set +e
  wait "$pid"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    fails=$((fails + 1))
  else
    fails=0
  fi
  if [ "$fails" -ge 10 ]; then
    echo "mqvpn-oci: $CONF failed 10 times in a row — exiting" >&2
    exit 1
  fi
  echo "mqvpn-oci: $CONF exited ($rc) — restarting in 5s" >&2
  sleep 5
done
