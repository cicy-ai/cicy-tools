#!/usr/bin/env bash
set -euo pipefail

VERSION=1.1.0
INTERVAL_SECONDS="${1:-0}"
PY=/content/cicy-gpu-keepalive.py
PID=/content/cicy-gpu-keepalive.pid
VERSION_FILE=/content/cicy-gpu-keepalive.version
URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.py

show_info() {
  local status="$1" process_id="$2" running_version="$3" gpu memory disk
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
  else
    gpu="none"
  fi
  memory="$(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
  disk="$(df -h /content | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}')"
  echo "heartbeat=$status version=$running_version interval=${INTERVAL_SECONDS}s pid=$process_id gpu=[$gpu] cpu=$(nproc)cores memory=$memory disk=$disk log=/content/gpu-heartbeat.log"
}

[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || { echo "interval must be seconds" >&2; exit 2; }

if [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  show_info running "$(cat "$PID")" "$(cat "$VERSION_FILE" 2>/dev/null || echo legacy)"
  exit 0
fi

curl -fsSL "$URL" -o "$PY"
nohup python3 -u "$PY" >/content/gpu-heartbeat.stdout.log 2>&1 &
echo $! >"$PID"
echo "$VERSION" >"$VERSION_FILE"
show_info started "$!" "$VERSION"
