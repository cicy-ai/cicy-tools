#!/usr/bin/env bash
set -euo pipefail

VERSION=2.1.3
SCRIPT_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh
CLOUDSHELL_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh

prepare_install_space() {
  local usage remaining
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || { echo "cloudshell keepalive: unsafe HOME=${HOME:-unset}" >&2; return 1; }
  usage="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5);print $5}')"
  if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage >= 95 )); then
    rm -rf \
      "$HOME/.npm/_cacache" \
      "$HOME/.npm/_logs" \
      "$HOME/.cache/node-gyp" \
      "$HOME/.cache/pip" \
      "$HOME/.cache/pnpm" \
      "$HOME/.cache/uv" \
      "$HOME/.cache/yarn"
  fi
  remaining="$(df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5);print $5}')"
  if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining >= 100 )); then
    echo "cloudshell keepalive: home remains 100% full; largest top-level paths:" >&2
    du -xhd1 "$HOME" 2>/dev/null | sort -h | tail -n 12 >&2 || true
    return 1
  fi
}

prepare_install_space

install_launcher() {
  local target="${HOME:?HOME is required}/.local/bin/cicy-cloudshell"
  [[ -n "$target" ]] || { echo "cloudshell keepalive: empty launcher path" >&2; return 1; }
  mkdir -p "$(dirname "$target")"
  curl -fsSL "${CLOUDSHELL_URL}?v=$(date +%s)" -o "$target"
  chmod +x "$target"
  printf '%s' "$target"
}

if [[ "${1:-status}" == install ]]; then
  target="${HOME:?HOME is required}/.local/bin/cicytools"
  [[ -n "$target" ]] || { echo "cloudshell keepalive: empty install path" >&2; exit 1; }
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
host_disk="$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print "used=" $3 " total=" $2 " usage=" $5}' || true)"
runtime_disk="$(df -h /home/cicy 2>/dev/null | awk 'NR==2 {print "used=" $3 " total=" $2 " usage=" $5}' || true)"
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
echo "memory=${memory:-unknown}"
echo "host_home=$HOME ${host_disk:-disk=unknown}"
echo "runtime_home=/home/cicy ${runtime_disk:-disk=unknown}"
echo "cicy-code=$cicy_status installed=$cicy_installed version=$cicy_version pid=${pid:-none} user=$cicy_user home=/home/cicy login_log=$login_status"
echo "cicy_log=$cicy_log"
echo "log=$cicy_log"
echo "launcher=$launcher"
echo "tail: sudo tail -f $cicy_log"
