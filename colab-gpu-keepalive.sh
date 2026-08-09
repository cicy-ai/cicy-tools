#!/usr/bin/env bash
set -euo pipefail

VERSION=1.3.7
INTERVAL_SECONDS="${1:-30}"
PY=/content/cicy-gpu-keepalive.py
PID=/content/cicy-gpu-keepalive.pid
VERSION_FILE=/content/cicy-gpu-keepalive.version
INTERVAL_FILE=/content/cicy-gpu-keepalive.interval
TOOLS_REPO=/content/cicy-tools-source
TOOLS_URL=https://github.com/cicy-ai/cicy-tools.git
PY_SOURCE=colab-gpu-keepalive.py
INSTALLER=/content/colab-cicy-code.sh
INSTALLER_SOURCE=colab-cicy-code.sh
LAUNCHER=/content/colab-cicy-code.py
LAUNCHER_SOURCE=colab-cicy-code.py

update_tools() {
  if [[ -d "$TOOLS_REPO/.git" ]]; then
    git -C "$TOOLS_REPO" fetch --quiet --depth 1 origin main
  else
    git clone --quiet --filter=blob:none --no-checkout --depth 1 \
      --branch main "$TOOLS_URL" "$TOOLS_REPO"
    git -C "$TOOLS_REPO" fetch --quiet --depth 1 origin main
  fi
}

stage_tool() {
  local source="$1" destination="$2"
  git -C "$TOOLS_REPO" show "FETCH_HEAD:$source" > "$destination.tmp"
  chmod "$3" "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
}

show_info() {
  local status="$1" process_id="$2" running_version="$3" gpu memory disk installer_status cicy_pid cicy_status cicy_installed cicy_version cicy_exe cicy_cached_exe package_json login_status cicy_log
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
  else
    gpu="none"
  fi
  memory="$(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
  disk="$(df -h /content | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}')"
  echo "heartbeat=$status version=$running_version interval=${INTERVAL_SECONDS}s pid=$process_id"
  echo "gpu=[$gpu] cpu=$(nproc)cores"
  echo "memory=$memory disk=$disk"
  installer_status="missing"
  [[ -s "$INSTALLER" && -x "$INSTALLER" && -s "$LAUNCHER" ]] && installer_status="ready"
  echo "installer=$installer_status shell=$INSTALLER launcher=$LAUNCHER"

  cicy_pid="$(pgrep -x cicy-code 2>/dev/null | head -n1 || true)"
  cicy_status="stopped"
  cicy_installed="no"
  cicy_version="none"
  if [[ -n "$cicy_pid" ]]; then
    cicy_status="running"
    cicy_installed="yes"
    cicy_exe="$(readlink -f "/proc/$cicy_pid/exe" 2>/dev/null || true)"
    if [[ -n "$cicy_exe" && -x "$cicy_exe" ]]; then
      cicy_version="$(timeout 3 "$cicy_exe" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    fi
    [[ -n "$cicy_version" ]] || cicy_version="unknown"
  elif command -v cicy-code >/dev/null 2>&1; then
    cicy_installed="yes"
    cicy_exe="$(command -v cicy-code)"
  else
    cicy_cached_exe="$(find "$HOME/.npm/_npx" -path '*/node_modules/cicy-code-linux-*/cicy-code' -type f -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "$cicy_cached_exe" || -f /content/cicy-code.installed ]]; then
      cicy_installed="yes"
      cicy_exe="$cicy_cached_exe"
    fi
  fi

  if [[ "$cicy_installed" == "yes" && "$cicy_version" == "none" && -n "${cicy_exe:-}" ]]; then
    package_json="$(dirname "$cicy_exe")/package.json"
    if [[ -f "$package_json" ]]; then
      cicy_version="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$package_json" | head -n1)"
    fi
    [[ -n "$cicy_version" ]] || cicy_version="unknown"
  fi

  cicy_log="${CICY_CODE_LOG:-/content/cicy-code.log}"
  if [[ ! -f "$cicy_log" && -f "$HOME/logs/cicy-code.log" ]]; then
    cicy_log="$HOME/logs/cicy-code.log"
  fi
  login_status="missing"
  if [[ -f "$cicy_log" ]]; then
    if grep -Eqi "CiCy Cloud connected|login successful|device is now bound" "$cicy_log"; then
      login_status="connected"
    elif grep -Eqi "login email sent|waiting for confirmation" "$cicy_log"; then
      login_status="pending"
    elif grep -Eqi "login.*(failed|expired|invalid)|authentication.*failed" "$cicy_log"; then
      login_status="failed"
    else
      login_status="not-found"
    fi
  fi
  echo "cicy-code=$cicy_status installed=$cicy_installed version=$cicy_version pid=${cicy_pid:-none} login_log=$login_status"
  echo "cicy_log=$cicy_log"
  echo "log=/content/gpu-heartbeat.log"
  echo "!tail -f /content/gpu-heartbeat.log"
}

[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || { echo "interval must be seconds" >&2; exit 2; }

# Download but never execute the installer. A shallow Git fetch avoids the
# unauthenticated GitHub Contents API rate limit and stale Raw CDN responses.
update_tools
stage_tool "$INSTALLER_SOURCE" "$INSTALLER" 700
stage_tool "$LAUNCHER_SOURCE" "$LAUNCHER" 600

if [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; then
  running_version="$(cat "$VERSION_FILE" 2>/dev/null || echo legacy)"
  running_interval="$(cat "$INTERVAL_FILE" 2>/dev/null || echo legacy)"
  if [[ "$running_version" == "$VERSION" && "$running_interval" == "$INTERVAL_SECONDS" ]]; then
    show_info running "$(cat "$PID")" "$running_version"
    exit 0
  fi
  kill "$(cat "$PID")" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$(cat "$PID")" 2>/dev/null || break
    sleep 0.1
  done
fi

stage_tool "$PY_SOURCE" "$PY" 600
nohup python3 -u "$PY" "$INTERVAL_SECONDS" >/content/gpu-heartbeat.stdout.log 2>&1 &
echo $! >"$PID"
echo "$VERSION" >"$VERSION_FILE"
echo "$INTERVAL_SECONDS" >"$INTERVAL_FILE"
show_info started "$!" "$VERSION"
