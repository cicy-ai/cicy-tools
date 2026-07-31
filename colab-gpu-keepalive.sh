#!/usr/bin/env bash
set -euo pipefail

PY=/content/cicy-gpu-keepalive.py
PID=/content/cicy-gpu-keepalive.pid
URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.py

show_info() {
  local status="$1" process_id="$2" gpu memory disk
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
  else
    gpu="none"
  fi
  memory="$(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
  disk="$(df -h /content | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}')"
  echo "heartbeat=$status pid=$process_id gpu=[$gpu] cpu=$(nproc)cores memory=$memory disk=$disk log=/content/gpu-heartbeat.log"
}

if [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  show_info running "$(cat "$PID")"
  exit 0
fi

curl -fsSL "$URL" -o "$PY"
nohup python3 -u "$PY" >/content/gpu-heartbeat.stdout.log 2>&1 &
echo $! >"$PID"
show_info started "$!"
