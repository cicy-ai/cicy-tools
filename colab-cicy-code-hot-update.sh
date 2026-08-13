#!/usr/bin/env bash
set -euo pipefail

RUNTIME_USER="${CICY_RUNTIME_USER:-cicy}"
RUNTIME_HOME="${CICY_RUNTIME_HOME:-/home/cicy}"
UPDATER="${CICY_CODE_UPDATER:-/content/colab-cicy-code-update.sh}"
LOG_FILE="${CICY_CODE_LOG:-/content/cicy-code.log}"
PID_FILE="${CICY_CODE_PID_FILE:-/content/cicy-code.pid}"
want="${1:-latest}"

[[ "$(id -u)" -eq 0 ]] || { echo "run this Colab updater as root" >&2; exit 1; }
id -u "$RUNTIME_USER" >/dev/null 2>&1 || { echo "runtime user does not exist: $RUNTIME_USER" >&2; exit 1; }
[[ -s "$UPDATER" ]] || { echo "missing updater: $UPDATER (run the keepalive cell first)" >&2; exit 1; }
chmod 0755 "$UPDATER"
install -d -m 0755 -o "$RUNTIME_USER" -g "$RUNTIME_USER" "$RUNTIME_HOME/.local/bin"
touch "$LOG_FILE" "$PID_FILE"
chown "$RUNTIME_USER:$RUNTIME_USER" "$LOG_FILE" "$PID_FILE"

echo "[1/3] staging and verifying cicy-code $want"
version="$(sudo -u "$RUNTIME_USER" -H env \
  HOME="$RUNTIME_HOME" USER="$RUNTIME_USER" LOGNAME="$RUNTIME_USER" \
  PATH="$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  CICY_CODE_SWITCH=0 "$UPDATER" "$want" | tee /dev/stderr | tail -n 1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "invalid staged version: $version" >&2; exit 1; }

echo "[2/3] switching symlink to cicy-code $version"
switched="$(sudo -u "$RUNTIME_USER" -H env \
  HOME="$RUNTIME_HOME" USER="$RUNTIME_USER" LOGNAME="$RUNTIME_USER" \
  PATH="$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  "$UPDATER" "$version" | tee /dev/stderr | tail -n 1)"
[[ "$switched" == "$version" ]] || { echo "runtime switch failed" >&2; exit 1; }

echo "[3/3] restarting through $RUNTIME_HOME/.local/bin/cicy-code"
if [[ -s "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -TERM "$old_pid" 2>/dev/null || true
fi
pkill -TERM -u "$RUNTIME_USER" -x cicy-code 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null || break
  sleep 0.1
done
pkill -KILL -u "$RUNTIME_USER" -x cicy-code 2>/dev/null || true

sudo -u "$RUNTIME_USER" -H env \
  HOME="$RUNTIME_HOME" USER="$RUNTIME_USER" LOGNAME="$RUNTIME_USER" \
  DISPLAY="${DISPLAY:-:1}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/cicy-xdg-runtime}" \
  PATH="$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  bash -c 'nohup stdbuf -oL -eL "$HOME/.local/bin/cicy-code" --cft > "$1" 2>&1 < /dev/null & echo $!' \
  _ "$LOG_FILE" > "$PID_FILE"

new_pid="$(cat "$PID_FILE")"
for _ in $(seq 1 120); do
  pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null && break
  kill -0 "$new_pid" 2>/dev/null || break
  sleep 0.5
done
if ! pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null; then
  echo "cicy-code failed to restart; latest log:" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi

running="$($RUNTIME_HOME/.local/bin/cicy-code --version 2>/dev/null | tail -n 1)"
echo "updated=$version running=$running pid=$new_pid"
echo "log=$LOG_FILE"
