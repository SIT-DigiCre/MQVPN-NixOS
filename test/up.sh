#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/stop-mogami-lab.sh" 2>/dev/null || true
"$SCRIPT_DIR/build-mogami-lab.sh"

echo ""
echo "=== Lab is UP (各 VM は自分のビルド完了と同時に起動) ==="
echo "  Router PID : $(cat /tmp/mqvpn-mogami.pid 2>/dev/null || echo '?')   (log: /tmp/mqvpn-mogami.log)"
echo "  Server PID : $(cat /tmp/mqvpn-server.pid 2>/dev/null || echo '?')   (log: /tmp/mqvpn-server.log)"
echo "  Client PID : $(cat /tmp/mqvpn-client.pid 2>/dev/null || echo '?')   (log: /tmp/mqvpn-client.log)"
echo "  Mnet   PID : $(cat /tmp/mqvpn-mnet.pid 2>/dev/null || echo '?')     (log: /tmp/mqvpn-mnet.log)"
echo ""
echo "  SSH Router    : ./test/ssh-router.sh"
echo "  SSH Server    : ./test/ssh-server.sh"
echo "  SSH Client    : ./test/ssh-client.sh"
echo "  SSH Mnet      : ./test/ssh-mnet.sh"
echo "  Follow logs   : tail -f /tmp/mqvpn-server.log"
echo "  Stop lab      : ./test/stop-mogami-lab.sh"
