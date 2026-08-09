#!/usr/bin/env bash
set -euo pipefail

VERSION=2.0.0
SCRIPT_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh
CLOUDSHELL_URL=https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh

install_launcher() {
  local target="$HOME/.local/bin/cicy-cloudshell"
  mkdir -p "$(dirname "$target")"
  curl -fsSL "${CLOUDSHELL_URL}?v=$(date +%s)" -o "$target"
  chmod +x "$target"
  printf '%s' "$target"
}

if [[ "${1:-}" == install ]]; then
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
  exit 0
fi

launcher="$HOME/.local/bin/cicy-cloudshell"
[[ -x "$launcher" ]] || launcher="$(install_launcher)"
pid="$(pgrep -u cicy -f 'cicy-code' 2>/dev/null | head -n1 || true)"
team="${CICY_TEAM:-cloudshell_w3c}"
cpu_cores="$(nproc 2>/dev/null || echo unknown)"
memory="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || true)"
disk="$(df -h /home/cicy 2>/dev/null | awk 'NR==2 {print $3 "/" $2 "(" $5 ")"}' || true)"

if [[ -n "$pid" ]]; then
  echo "heartbeat=alive version=$VERSION cicy-code=running pid=$pid team=$team"
  echo "user=$(ps -o user= -p "$pid" | xargs) home=/home/cicy"
else
  echo "heartbeat=alive version=$VERSION cicy-code=stopped pid=none team=$team"
  echo "user=cicy home=/home/cicy"
fi
echo "log=/home/cicy/logs/cicy-code.log"
echo "launcher=$launcher"
echo "cpu_cores=$cpu_cores memory=${memory:-unknown} disk=${disk:-unknown}"
