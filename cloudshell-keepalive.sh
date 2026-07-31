#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.0
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
