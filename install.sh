#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <disk-device>"
  echo "Example: $0 /dev/sda"
  exit 1
fi

DISK="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# flake.nix のあるディレクトリを探す（独立コピー対応）
if [ -f "$SCRIPT_DIR/flake.nix" ]; then
  REPO_DIR="$SCRIPT_DIR"
elif [ -f "$SCRIPT_DIR/mqvpn-router/flake.nix" ]; then
  REPO_DIR="$SCRIPT_DIR/mqvpn-router"
else
  echo "Error: flake.nix not found. Ensure the repository is available."
  exit 1
fi

echo "=== MQVPN-Router Installer ==="
echo "Disk: $DISK"
echo "Repo: $REPO_DIR"
echo ""

if command -v git &>/dev/null && [ -d "$REPO_DIR/.git" ]; then
  echo "=== Updating repository (git pull) ==="
  git -C "$REPO_DIR" pull || echo "Warning: git pull failed, continuing with local files"
  echo ""
fi

echo "=== Running disko-install ==="
sudo disko-install \
    --flake "path:$REPO_DIR#mogami" \
  --disk main "$DISK"
