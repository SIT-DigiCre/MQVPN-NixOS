#!/usr/bin/env bash
set -euo pipefail

###########################################################
# MQVPN Server Setup for Ubuntu / Debian
#  - Builds patched mqvpn from source (xquic anti-amp fix)
#
# Usage:
#   sudo ./setup-server-ubuntu.sh install    # 新規インストール
#   sudo ./setup-server-ubuntu.sh upgrade    # バイナリのみ更新
#   sudo ./setup-server-ubuntu.sh reinstall  # 設定ごと再インストール
#
# Environment variables:
#   MQVPN_AUTH_KEY  MQVPN_PORT  MQVPN_SUBNET  MQVPN_TUN
#   MQVPN_LOG_LEVEL  MQVPN_VERSION  MQVPN_WAN_IF  INSTALL_PREFIX
###########################################################

MQVPN_VERSION="${MQVPN_VERSION:-0.13.1}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BUILD_DIR="/tmp/mqvpn-build-$$"

die() { echo "[!] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

trap 'rm -rf "$BUILD_DIR"' EXIT

# ── Usage ─────────────────────────────────────────────────
usage() {
  cat <<USAGE
Usage: $0 <command>

Commands:
  install     新規インストール（config / cert / service / firewall 全て）
  upgrade     バイナリのみ再ビルドして差し替え（設定保全）
  reinstall   設定ごと再インストール（完全初期化）

Options (environment variables):
  MQVPN_PORT=${MQVPN_PORT:-443}  MQVPN_SUBNET=${MQVPN_SUBNET:-192.168.0.0/24}
  MQVPN_AUTH_KEY  認証鍵（未指定時は自動生成）
  MQVPN_TUN=${MQVPN_TUN:-mqvpn0}
  MQVPN_LOG_LEVEL=${MQVPN_LOG_LEVEL:-info}
  MQVPN_WAN_IF    デフォルトゲートウェイIF（自動検出）
  MQVPN_VERSION=${MQVPN_VERSION:-0.13.1}
  INSTALL_PREFIX=${INSTALL_PREFIX:-/usr/local}
USAGE
  exit 1
}

MODE="${1:-}"
[ -z "$MODE" ] && usage
shift

case "$MODE" in
  install|upgrade|reinstall) ;;
  *) usage ;;
esac

# ── Preflight ──────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ] && [ "${SKIP_ROOT_CHECK:-false}" != "true" ]; then
  die "Run as root (or set SKIP_ROOT_CHECK=true)"
fi

[ "$MODE" = "install" ] && [ -f /etc/mqvpn/server.conf ] && \
  die "Already installed (use 'upgrade' to update binary, or 'reinstall' to wipe and start over)"

EXISTING_CONFIG=""
if [ -f /etc/mqvpn/server.conf ] && head -1 /etc/mqvpn/server.conf | grep -q '^{'; then
  EXISTING_CONFIG=json
fi

if [ -z "$EXISTING_CONFIG" ] && [ "$MODE" = "upgrade" ]; then
  die "No existing installation found. Run 'install' first."
fi

# ── Read existing config (for upgrade) ────────────────────
AUTH_KEY="${MQVPN_AUTH_KEY:-}"
PORT="${MQVPN_PORT:-443}"
SUBNET="${MQVPN_SUBNET:-192.168.0.0/24}"
TLS_CERT="${TLS_CERT:-/etc/mqvpn/server.crt}"
TLS_KEY="${TLS_KEY:-/etc/mqvpn/server.key}"
TUN_NAME="${MQVPN_TUN:-mqvpn0}"
LOG_LEVEL="${MQVPN_LOG_LEVEL:-info}"
WAN_IF="${MQVPN_WAN_IF:-}"
REINSTALL_AUTH_KEY=""

if [ "$EXISTING_CONFIG" = "json" ]; then
  read_json() { python3 -c "import json; print(json.load(open('/etc/mqvpn/server.conf')).get('$1',''))" 2>/dev/null || true; }
  AUTH_KEY="${AUTH_KEY:-$(read_json auth_key)}"
  PORT="${PORT:-$(read_json listen | sed 's/.*://' | grep -o '[0-9]*')}"
  PORT="${PORT:-443}"
  SUBNET="${SUBNET:-$(read_json subnet)}"
  SUBNET="${SUBNET:-192.168.0.0/24}"
  TLS_CERT="${TLS_CERT:-$(read_json tls_cert)}"
  TLS_CERT="${TLS_CERT:-/etc/mqvpn/server.crt}"
  TLS_KEY="${TLS_KEY:-$(read_json tls_key)}"
  TLS_KEY="${TLS_KEY:-/etc/mqvpn/server.key}"
  TUN_NAME="${TUN_NAME:-$(read_json tun_name)}"
  TUN_NAME="${TUN_NAME:-mqvpn0}"
  LOG_LEVEL="${LOG_LEVEL:-$(read_json log_level)}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
elif [ "$EXISTING_CONFIG" = "ini" ]; then
  parse_ini() { sed -n "/^\[$1\]/,/^\[/{ /^[[:space:]]*$2[[:space:]]*=/ { s/.*=[[:space:]]*//p; q } }" /etc/mqvpn/server.conf; }
  AUTH_KEY="${AUTH_KEY:-$(parse_ini Auth Key)}"
  PORT="${PORT:-$(parse_ini Interface Listen | sed 's/.*://')}"
  PORT="${PORT:-443}"
  SUBNET="${SUBNET:-$(parse_ini Interface Subnet)}"
  SUBNET="${SUBNET:-192.168.0.0/24}"
  TLS_CERT="${TLS_CERT:-$(parse_ini TLS Cert)}"
  TLS_CERT="${TLS_CERT:-/etc/mqvpn/server.crt}"
  TLS_KEY="${TLS_KEY:-$(parse_ini TLS Key)}"
  TLS_KEY="${TLS_KEY:-/etc/mqvpn/server.key}"
  TUN_NAME="${TUN_NAME:-$(parse_ini Interface TunName)}"
  TUN_NAME="${TUN_NAME:-mqvpn0}"
  LOG_LEVEL="${LOG_LEVEL:-$(parse_ini Interface LogLevel)}"
  LOG_LEVEL="${LOG_LEVEL:-info}"
fi

if [ "$MODE" = "reinstall" ] && [ -n "$AUTH_KEY" ]; then
  REINSTALL_AUTH_KEY="$AUTH_KEY"
fi

# ── Parameters ──────────────────────────────────────────────
[ -z "$WAN_IF" ] && WAN_IF="$(ip -4 route show default | awk '{print $5}' | head -1)"

# ── Build dependencies ─────────────────────────────────────
if ! command -v cmake &>/dev/null; then
  info "Installing build dependencies..."
  apt-get update -qq && apt-get install -y -qq \
    build-essential cmake libevent-dev libssl-dev perl git ca-certificates \
    curl pkg-config ninja-build
fi

# ── Clone & Patch ─────────────────────────────────────────
info "Cloning mqvpn v${MQVPN_VERSION}..."
git clone --recursive --branch "v${MQVPN_VERSION}" \
  "https://github.com/mp0rta/mqvpn.git" "$BUILD_DIR" 2>/dev/null || \
  die "Failed to clone mqvpn (check network / version tag)"

cd "$BUILD_DIR"

info "Applying xquic anti-amplification patch..."
XQUIC_FILE="third_party/xquic/src/transport/xqc_send_ctl.c"
[ -f "$XQUIC_FILE" ] || die "xquic source not found at $XQUIC_FILE"
sed -i \
  '/multipath => Before Path Active/,/check = XQC_TRUE/{
    s/if (path->path_state < XQC_PATH_STATE_ACTIVE)/if (!(conn->conn_flag \& XQC_CONN_FLAG_ADDR_VALIDATED) \&\& path->path_state < XQC_PATH_STATE_ACTIVE)/
  }' \
  "$XQUIC_FILE"
ok "Patch applied"

# ── Build BoringSSL ────────────────────────────────────────
info "Fetching BoringSSL..."
BSSL_DIR="$BUILD_DIR/third_party/xquic/third_party/boringssl"
rm -rf "$BSSL_DIR"
git clone --depth 1 "https://github.com/google/boringssl.git" "$BSSL_DIR" || \
  die "Failed to clone BoringSSL (check network)"

info "Building BoringSSL..."
BSSL_BUILD="$BSSL_DIR/build"
mkdir -p "$BSSL_BUILD"
cmake -S "$BSSL_DIR" -B "$BSSL_BUILD" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_FLAGS="-fPIC" \
  -DCMAKE_CXX_FLAGS="-fPIC" \
  -GNinja 2>/dev/null || cmake -S "$BSSL_DIR" -B "$BSSL_BUILD" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DCMAKE_CXX_FLAGS="-fPIC"
ninja -C "$BSSL_BUILD" ssl crypto 2>/dev/null || \
  make -C "$BSSL_BUILD" -j"$(nproc)" ssl crypto

# ── Build xquic ───────────────────────────────────────────
info "Building xquic..."
XQUIC_BUILD="$BUILD_DIR/third_party/xquic/build"
mkdir -p "$XQUIC_BUILD"
cmake -S "$BUILD_DIR/third_party/xquic" -B "$XQUIC_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DSSL_TYPE=boringssl \
  -DSSL_PATH="$BSSL_DIR" \
  -DXQC_ENABLE_BBR2=ON \
  -DXQC_ENABLE_UNLIMITED=ON
make -C "$XQUIC_BUILD" -j"$(nproc)"

# ── Build mqvpn ───────────────────────────────────────────
info "Building mqvpn..."
MQVPN_BUILD="$BUILD_DIR/build"
mkdir -p "$MQVPN_BUILD"
cmake -S "$BUILD_DIR" -B "$MQVPN_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXQUIC_BUILD_DIR="$XQUIC_BUILD"
make -C "$MQVPN_BUILD" -j"$(nproc)"

ok "Build complete!"

# ── Install binary ──────────────────────────────────────────
info "Installing binary to $INSTALL_PREFIX/bin/mqvpn..."
mkdir -p "$INSTALL_PREFIX/bin" "$INSTALL_PREFIX/lib"
cp "$MQVPN_BUILD/mqvpn" "$INSTALL_PREFIX/bin/mqvpn.new"
mv "$INSTALL_PREFIX/bin/mqvpn.new" "$INSTALL_PREFIX/bin/mqvpn"
for lib in "$MQVPN_BUILD/libmqvpn.so"*; do
  bn=$(basename "$lib")
  cp "$lib" "$INSTALL_PREFIX/lib/$bn.new"
  mv "$INSTALL_PREFIX/lib/$bn.new" "$INSTALL_PREFIX/lib/$bn"
done
bn=$(basename "$XQUIC_BUILD/libxquic.so")
cp "$XQUIC_BUILD/libxquic.so" "$INSTALL_PREFIX/lib/$bn.new"
mv "$INSTALL_PREFIX/lib/$bn.new" "$INSTALL_PREFIX/lib/$bn"
chmod 755 "$INSTALL_PREFIX/bin/mqvpn"
chmod 644 "$INSTALL_PREFIX/lib/"*.so*

if command -v patchelf &>/dev/null; then
  patchelf --set-rpath "$INSTALL_PREFIX/lib" "$INSTALL_PREFIX/bin/mqvpn"
fi
ldconfig 2>/dev/null || true

ok "Binary installed: $INSTALL_PREFIX/bin/mqvpn"

# ── upgrade はここで終わり ─────────────────────────────────
if [ "$MODE" = "upgrade" ]; then
  echo "  Run: sudo systemctl restart mqvpn-server"
  cat <<SUMMARY

  Binary updated: $INSTALL_PREFIX/bin/mqvpn
  Config preserved: /etc/mqvpn/server.conf
SUMMARY
  ok "Done"
  exit 0
fi

# ── install / reinstall: config / cert / service / firewall ─
if [ "$MODE" = "reinstall" ]; then
  systemctl stop mqvpn-server 2>/dev/null || true
  rm -f /etc/mqvpn/server.conf 2>/dev/null || true
  AUTH_KEY="${REINSTALL_AUTH_KEY:-$AUTH_KEY}"
fi

if [ -z "$AUTH_KEY" ]; then
  AUTH_KEY="$("$INSTALL_PREFIX/bin/mqvpn" --genkey 2>/dev/null || openssl rand -base64 32)"
  ok "Generated auth key: $AUTH_KEY"
fi

# Config
mkdir -p /etc/mqvpn
cat > /etc/mqvpn/server.conf <<CFG
{
  "mode": "server",
  "listen": "0.0.0.0:${PORT}",
  "subnet": "${SUBNET}",
  "tun_name": "${TUN_NAME}",
  "tls_cert": "${TLS_CERT}",
  "tls_key": "${TLS_KEY}",
  "auth_key": "${AUTH_KEY}",
  "log_level": "${LOG_LEVEL}",
  "max_clients": 64,
  "scheduler": "wlb",
  "hybrid": {
    "enabled": true,
    "tcp": "auto",
    "egress_allow": ["${SUBNET}"]
  }
}
CFG
chmod 600 /etc/mqvpn/server.conf

# TLS cert
if [ ! -f "$TLS_CERT" ] || [ ! -f "$TLS_KEY" ]; then
  info "Generating self-signed TLS certificate..."
  mkdir -p "$(dirname "$TLS_CERT")"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 365 -nodes -subj "/CN=mqvpn" 2>/dev/null
  chmod 600 "$TLS_KEY" "$TLS_CERT"
fi

# systemd service
cat > /etc/systemd/system/mqvpn-server.service <<UNIT
[Unit]
Description=MQVPN VPN Server
Documentation=https://github.com/mp0rta/mqvpn
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PREFIX/bin/mqvpn --config /etc/mqvpn/server.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

# sysctl
sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p /etc/sysctl.d
(echo "# MQVPN server"; echo "net.ipv4.ip_forward = 1") > /etc/sysctl.d/90-mqvpn.conf

# NAT
iptables -t nat -C POSTROUTING -o "$WAN_IF" -s "$SUBNET" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$WAN_IF" -s "$SUBNET" -j MASQUERADE
iptables -C FORWARD -i "$TUN_NAME" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$TUN_NAME" -j ACCEPT
iptables -C FORWARD -o "$TUN_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -o "$TUN_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT

# ── Summary ────────────────────────────────────────────────
systemctl enable mqvpn-server 2>/dev/null || true
systemctl start mqvpn-server 2>/dev/null || true

MY_IP="$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo '<your-ip>')"

cat <<SUMMARY

═══════════════════════════════════════════════════════════════
  MQVPN Server — ${MODE^} Complete
═══════════════════════════════════════════════════════════════

  Binary:       $INSTALL_PREFIX/bin/mqvpn
  Config:       /etc/mqvpn/server.conf
  TLS cert:     $TLS_CERT
  Auth key:     $AUTH_KEY
  Server addr:  ${MY_IP}:${PORT}
  Subnet:       $SUBNET

  Logs:         sudo journalctl -u mqvpn-server -f

  Client config (mqvpn-auth.json):
  {
    "server_addr": "${MY_IP}:${PORT}",
    "auth_key": "${AUTH_KEY}"
  }
═══════════════════════════════════════════════════════════════

ok "Done"
