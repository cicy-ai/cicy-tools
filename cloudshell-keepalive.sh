#!/usr/bin/env bash
set -euo pipefail

VERSION=2.1.0
SCRIPT_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh
CLOUDSHELL_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh

install_launcher() {
  local target="$HOME/.local/bin/cicy-cloudshell"
  mkdir -p "$(dirname "$target")"
  curl -fsSL "${CLOUDSHELL_URL}?v=$(date +%s)" -o "$target"
  chmod +x "$target"
  printf '%s' "$target"
}

if [[ "${1:-install}" == install ]]; then
  target="$HOME/.local/bin/cicytools"
  mkdir -p "$(dirname "$target")"
  curl -fsSL "${SCRIPT_URL}?v=$(date +%s)" -o "$target"
  chmod +x "$target"
  launcher="$(install_launcher)"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sf "$target" /usr/local/bin/cicytools
    sudo ln -sf "$launcher" /usr/local/bin/cicy-cloudshell
  fi
  echo "installed=cicytools path=$target"
  echo "installed=cicy-cloudshell path=$launcher"
  echo "run: cicy-cloudshell"
  exit 0
fi

launcher="$HOME/.local/bin/cicy-cloudshell"
[[ -x "$launcher" ]] || launcher="$(install_launcher)"
pid="$(pgrep -u cicy -f 'cicy-code' 2>/dev/null | head -n1 || true)"
team="${CICY_TEAM:-cloudshell_w3c}"
cpu_cores="$(nproc 2>/dev/null || echo unknown)"
memory="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || true)"
disk="$(df -h /home/cicy 2>/dev/null | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}' || true)"
cicy_log=/home/cicy/logs/cicy-code.log
cicy_version=none
cicy_installed=no
login_status=missing
cicy_user=none

if [[ -f "$cicy_log" ]]; then
  if grep -Eqi 'CiCy Cloud connected|login successful|device is now bound' "$cicy_log"; then
    login_status=connected
  elif grep -Eqi 'login email sent|waiting for confirmation' "$cicy_log"; then
    login_status=pending
  elif grep -Eqi 'login.*(failed|expired|invalid)|authentication.*failed' "$cicy_log"; then
    login_status=failed
  else
    login_status=not-found
  fi
fi

if [[ -n "$pid" ]]; then
  cicy_installed=yes
  cicy_user="$(ps -o user= -p "$pid" | xargs)"
  cicy_exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  if [[ -n "$cicy_exe" && -x "$cicy_exe" ]]; then
    cicy_version="$(timeout 3 "$cicy_exe" --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  [[ -n "$cicy_version" ]] || cicy_version=unknown
  cicy_status=running
else
  cicy_status=stopped
fi

echo "heartbeat=alive version=$VERSION team=$team"
echo "gpu=[none] cpu=${cpu_cores}cores"
echo "memory=${memory:-unknown} disk=${disk:-unknown}"
echo "cicy-code=$cicy_status installed=$cicy_installed version=$cicy_version pid=${pid:-none} user=$cicy_user home=/home/cicy login_log=$login_status"
echo "cicy_log=$cicy_log"
echo "log=$cicy_log"
echo "launcher=$launcher"
echo "tail: sudo tail -f $cicy_log"
