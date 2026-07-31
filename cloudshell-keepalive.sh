#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.0
SCRIPT_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh

if [[ "${1:-}" == "install" ]]; then
  TARGET="$HOME/.local/bin/cicytools"
  mkdir -p "$(dirname "$TARGET")"
  curl -fsSL "$SCRIPT_URL" -o "$TARGET"
  chmod +x "$TARGET"

  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sf "$TARGET" /usr/local/bin/cicytools
  fi

  if command -v cicytools >/dev/null 2>&1; then
    echo "installed=cicytools path=$(command -v cicytools)"
  else
    echo "installed=cicytools path=$TARGET"
    echo 'run: export PATH="$HOME/.local/bin:$PATH"'
  fi
  exit 0
fi

CICY_PID="$(pgrep -x cicy-code 2>/dev/null | head -n1 || true)"
CPU_CORES="$(nproc 2>/dev/null || echo unknown)"
CPU_USED="$(LC_ALL=C top -bn1 2>/dev/null | awk '/%Cpu|Cpu\(s\)/ {for (i=1; i<=NF; i++) if ($i ~ /id,?$/) {idle=$(i-1); gsub(/,/, "", idle); printf "%.1f%%", 100-idle; exit}}' || true)"
MEMORY="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || true)"
DISK="$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}' || true)"

if [[ -n "$CICY_PID" ]]; then
  echo "heartbeat=alive version=$VERSION cicy-code=running pid=$CICY_PID"
else
  echo "heartbeat=alive version=$VERSION cicy-code=stopped pid=none"
fi

echo "cpu=${CPU_USED:-unknown} cores=$CPU_CORES"
echo "memory=${MEMORY:-unknown}"
echo "disk=${DISK:-unknown} path=$HOME"
