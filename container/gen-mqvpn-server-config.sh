#!/usr/bin/env bash
# gen-mqvpn-server-config.sh — MQVPN サーバー設定の自動生成
#
# 自己署名証明書 (EC P-256) + 認証キー (auth_key) + server.conf (JSON) を
# 指定ディレクトリに生成する。生成物は docker-compose がコンテナの /etc/mqvpn
# にマウントする前提 (container/docker-compose.yml の ./mqvpn-server-conf)。
#
# 使い方:
#   bash gen-mqvpn-server-config.sh [出力ディレクトリ]
#   既定: ./mqvpn-server-conf

set -euo pipefail

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

# 認証キー (32バイト → base64, mqvpn --genkey と同等。クライアントと共有)
AUTH_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '\n')

# server.conf (JSON)。コンテナ内では /etc/mqvpn にマウントされる前提。
cat > "$CONF_DIR/server.conf" <<EOF
{
  "mode": "server",
  "listen": "0.0.0.0:443",
  "subnet": "192.168.0.0/24",
  "tun_name": "mqvpn0",
  "cert_file": "/etc/mqvpn/server.crt",
  "key_file": "/etc/mqvpn/server.key",
  "auth_key": "$AUTH_KEY",
  "control_listen": "127.0.0.1:9090",
  "log_level": "info",
  "max_clients": 64,
  "scheduler": "wlb",
  "cc": "bbr",
  "reinjection": "off",
  "hybrid": { "enabled": false, "tcp": "auto", "tcp_max_flows": 2048 }
}
EOF

chmod 600 "$CONF_DIR/server.key" "$CONF_DIR/server.crt" "$CONF_DIR/server.conf"

echo "Generated config in: $CONF_DIR"
echo
echo "auth_key (share this with the client via mqvpn-auth.json):"
echo "  $AUTH_KEY"
