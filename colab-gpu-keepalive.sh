#!/usr/bin/env bash
set -euo pipefail

PY=/content/cicy-gpu-keepalive.py
PID=/content/cicy-gpu-keepalive.pid
URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.py

if [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  echo "GPU/CPU heartbeat already running (pid=$(cat "$PID"), log=/content/gpu-heartbeat.log)"
  exit 0
fi

curl -fsSL "$URL" -o "$PY"
nohup python3 -u "$PY" >/content/gpu-heartbeat.stdout.log 2>&1 &
echo $! >"$PID"
echo "GPU heartbeat started (pid=$!, log=/content/gpu-heartbeat.log)"
