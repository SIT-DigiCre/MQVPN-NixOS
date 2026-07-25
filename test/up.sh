#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/stop-mogami-lab.sh" 2>/dev/null || true
"$SCRIPT_DIR/build-mogami-lab.sh"

echo "=== Starting router VM (background) ==="
nohup "$SCRIPT_DIR/start-mogami-router.sh" > /tmp/mqvpn-router.log 2>&1 &
ROUTER_PID=$!

echo "=== Starting server VM (background) ==="
nohup "$SCRIPT_DIR/start-mogami-server.sh" > /tmp/mqvpn-server.log 2>&1 &
SERVER_PID=$!

echo "=== Starting client VM (background) ==="
nohup "$SCRIPT_DIR/start-mogami-client.sh" > /tmp/mqvpn-client.log 2>&1 &
CLIENT_PID=$!

echo ""
echo "=== Lab is UP ==="
echo "  Router PID : $ROUTER_PID  (log: /tmp/mqvpn-router.log)"
echo "  Server PID : $SERVER_PID  (log: /tmp/mqvpn-server.log)"
echo "  Client PID : $CLIENT_PID  (log: /tmp/mqvpn-client.log)"
echo ""
echo "  SSH Router    : ./test/ssh-router.sh"
echo "  SSH Server    : ./test/ssh-server.sh"
echo "  SSH Client    : ./test/ssh-client.sh"
echo "  Follow logs   : tail -f /tmp/mqvpn-router.log"
echo "  Stop lab      : ./test/stop-mogami-lab.sh"
