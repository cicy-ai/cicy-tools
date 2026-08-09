#!/usr/bin/env bash
set -euo pipefail

VERSION=1.1.0
SCRIPT_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh
CLOUDSHELL_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh

install_cloudshell_launcher() {
  local target="$HOME/.local/bin/cicy-cloudshell"
  mkdir -p "$(dirname "$target")"
  curl -fsSL "${CLOUDSHELL_URL}?v=$(date +%s)" -o "$target"
  chmod +x "$target"
  printf '%s' "$target"
}

if [[ "${1:-}" == "install" ]]; then
  TARGET="$HOME/.local/bin/cicytools"
  mkdir -p "$(dirname "$TARGET")"
  curl -fsSL "${SCRIPT_URL}?v=$(date +%s)" -o "$TARGET"
  chmod +x "$TARGET"
  CLOUDSHELL_TARGET="$(install_cloudshell_launcher)"

  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sf "$TARGET" /usr/local/bin/cicytools
  fi

  if command -v cicytools >/dev/null 2>&1; then
    echo "installed=cicytools path=$(command -v cicytools)"
  else
    echo "installed=cicytools path=$TARGET"
    echo 'run: export PATH="$HOME/.local/bin:$PATH"'
  fi
  echo "installed=cicy-cloudshell path=$CLOUDSHELL_TARGET"
  echo "run: cicy-cloudshell"
  exit 0
fi

CLOUDSHELL_TARGET="$HOME/.local/bin/cicy-cloudshell"
if [[ ! -x "$CLOUDSHELL_TARGET" ]]; then
  CLOUDSHELL_TARGET="$(install_cloudshell_launcher)"
fi

CONTAINER_NAME="${CICY_CONTAINER_NAME:-cicy}"
CICY_RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
CICY_PID="$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || true)"
CICY_TEAM="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | sed -n 's/^CICY_CLOUD_TEAM_ID=//p' | tail -n1 || true)"
CPU_CORES="$(nproc 2>/dev/null || echo unknown)"
CPU_USED="$(LC_ALL=C top -bn1 2>/dev/null | awk '/%Cpu|Cpu\(s\)/ {for (i=1; i<=NF; i++) if ($i ~ /id,?$/) {idle=$(i-1); gsub(/,/, "", idle); printf "%.1f%%", 100-idle; exit}}' || true)"
MEMORY="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || true)"
DISK="$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}' || true)"

if [[ "$CICY_RUNNING" == "true" ]]; then
  echo "heartbeat=alive version=$VERSION cicy-code=running pid=${CICY_PID:-unknown} team=${CICY_TEAM:-unknown}"
else
  echo "heartbeat=alive version=$VERSION cicy-code=stopped pid=none team=${CICY_TEAM:-cloudshell_w3c}"
fi

echo "launcher=$CLOUDSHELL_TARGET"
echo "cpu=${CPU_USED:-unknown} cores=$CPU_CORES"
echo "memory=${MEMORY:-unknown}"
echo "disk=${DISK:-unknown} path=$HOME"
