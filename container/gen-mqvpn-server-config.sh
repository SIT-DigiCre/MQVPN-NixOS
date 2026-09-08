#!/usr/bin/env bash
# server.conf (JSON) +自己署名証明書+auth_keyを指定dirに生成する。
# 生成物はcomposeがコンテナの/etc/mqvpnにマウントする前提。
#
# Usage: bash gen-mqvpn-server-config.sh [出力dir] (既定: ./mqvpn-server-conf)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${1:-./mqvpn-server-conf}"

if [ -e "$CONF_DIR/server.conf" ]; then
  echo "Error: $CONF_DIR/server.conf already exists (remove it first to regenerate)." >&2
  exit 1
fi

mkdir -p "$CONF_DIR"

CN="${MQVPN_SERVER_CN:-mqvpn-server}"

# 自己署名証明書 (EC P-256)
openssl ecparam -genkey -name prime256v1 -noout -out "$CONF_DIR/server.key"
openssl req -new -x509 -key "$CONF_DIR/server.key" -out "$CONF_DIR/server.crt" \
  -days 3650 -subj "/CN=$CN" \
  -addext "subjectAltName=DNS:$CN,IP:127.0.0.1"

# 認証キー: mqvpn-auth.jsonにあれば流用、無ければ生成して書き出す (server/client一致用)。
AUTH_JSON="${SCRIPT_DIR}/../mqvpn-auth.json"
if [ -f "$AUTH_JSON" ]; then
  AUTH_KEY=$(jq -r '.auth_key' "$AUTH_JSON")
fi
if [ -z "${AUTH_KEY:-}" ] || [ "$AUTH_KEY" = "null" ]; then
  AUTH_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
  echo "{\"server_addr\": \"\", \"auth_key\": \"$AUTH_KEY\"}" >"$AUTH_JSON"
  echo "Wrote new auth_key to $AUTH_JSON"
fi

# server.conf (JSON。マウント前提は冒頭参照)。
cat >"$CONF_DIR/server.conf" <<EOF
{
  "control_listen": "127.0.0.1:9090",
  "mode": "server",
  "listen": "0.0.0.0:443",
  "subnet": "192.168.0.0/24",
  "tun_name": "mqvpn0",
  "cert_file": "/etc/mqvpn/server.crt",
  "key_file": "/etc/mqvpn/server.key",
  "auth_key": "$AUTH_KEY",
  "log_level": "info",
  "max_clients": 64,
  "scheduler": "wlb",
  "cc": "bbr",
  "reinjection": "deadline",
  "reorder": {
    "enabled": "on",
    "max_wait_ms": 100,
    "cap_packets": 4096
  },
  "hybrid": {
    "enabled": false,
    "tcp": "auto",
    "tcp_max_flows": 2048
  }
}
EOF

chmod 600 "$CONF_DIR/server.key" "$CONF_DIR/server.crt" "$CONF_DIR/server.conf"

echo "Generated config in: $CONF_DIR"
echo
echo "auth_key (share this with the client via mqvpn-auth.json):"
echo "  $AUTH_KEY"
