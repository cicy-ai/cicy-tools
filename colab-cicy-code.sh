#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.2
CONFIG_REPO=https://github.com/w3c-ai/cicy-ai-config-colab.git
KNOWLEDGE_REPO=https://github.com/w3c-ai/cicy-ai-knowledge.git
CICY_TEAM="${CICY_TEAM:-colab}"
CICY_LOG_FILE="${CICY_CODE_LOG:-/content/cicy-code.log}"

read_colab_secret() {
  python3 - "$1" <<'PY'
import sys

try:
    from google.colab import userdata
    value = userdata.get(sys.argv[1])
except Exception:
    value = None

if value:
    sys.stdout.write(value)
PY
}

for name in CICY_EMAIL CODEX_AUTH_B64 CICY_CONFIG_GH_TOKEN; do
  if [[ -z "${!name:-}" ]]; then
    secret_value="$(read_colab_secret "$name")"
    if [[ -n "$secret_value" ]]; then
      printf -v "$name" '%s' "$secret_value"
      export "$name"
    fi
  fi
  if [[ -z "${!name:-}" ]]; then
    echo "missing Colab Secret or environment variable: $name" >&2
    exit 1
  fi
done

export DEBIAN_FRONTEND=noninteractive
export DISPLAY=:1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/cicy-xdg-runtime}"
export CICY_CLOUD_ORIGIN="${CICY_CLOUD_ORIGIN:-https://cicy-ai.com}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

mkdir -p "$NPM_CONFIG_PREFIX/bin" "$XDG_RUNTIME_DIR" "$HOME/.codex" \
  "$HOME/.config/cicy-ai" "$HOME/logs" "$HOME/projects"
chmod 700 "$XDG_RUNTIME_DIR"

echo "[1/6] installing runtime dependencies"
sudo apt-get -qq update
sudo apt-get -qq install -y --no-install-recommends \
  ca-certificates curl git jq xvfb xfce4 xfce4-terminal dbus-x11 \
  x11-utils xdotool imagemagick tesseract-ocr python3-xlib \
  cron sqlite3 >/dev/null

if ! command -v node >/dev/null 2>&1 || \
   [[ "$(node -p 'Number(process.versions.node.split(`.`)[0])')" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo apt-get -qq install -y nodejs >/dev/null
fi

clone_private_repo() {
  local repo="$1" destination="$2"
  if [[ -d "$destination/.git" ]]; then
    git -C "$destination" fetch --quiet origin main
    git -C "$destination" checkout --quiet main
    git -C "$destination" pull --quiet --rebase origin main
  else
    case "$destination" in
      "$HOME/cicy-ai"|"$HOME/cicy-ai/knowledge") ;;
      *) echo "refusing unsafe clone destination: $destination" >&2; exit 1 ;;
    esac
    rm -rf "$destination"
    git -c 'credential.helper=!f() {
      echo username=x-access-token
      echo password=$CICY_CONFIG_GH_TOKEN
    }; f' clone --quiet --branch main --single-branch "$repo" "$destination"
  fi
  git -C "$destination" remote set-url origin \
    "https://x-access-token:${CICY_CONFIG_GH_TOKEN}@${repo#https://}"
  chmod 600 "$destination/.git/config"
}

echo "[2/6] restoring private config and knowledge"
clone_private_repo "$CONFIG_REPO" "$HOME/cicy-ai"
clone_private_repo "$KNOWLEDGE_REPO" "$HOME/cicy-ai/knowledge"

echo "[3/6] restoring authentication"
rm -f "$HOME/cicy-ai/db/cft.json"
printf '%s' "$CODEX_AUTH_B64" | base64 --decode > "$HOME/.codex/auth.json"
printf '%s' "$CICY_CONFIG_GH_TOKEN" > "$HOME/.config/cicy-ai/config-gh-token"
chmod 600 "$HOME/.codex/auth.json" "$HOME/.config/cicy-ai/config-gh-token"

sudo service cron start >/dev/null
if [[ -s "$HOME/cicy-ai/db/crontab.txt" ]]; then
  crontab "$HOME/cicy-ai/db/crontab.txt"
fi

echo "[4/6] starting virtual desktop"
if ! pgrep -f 'Xvfb :1' >/dev/null; then
  nohup Xvfb :1 -screen 0 1440x900x24 -nolisten tcp \
    > "$HOME/logs/xvfb.log" 2>&1 &
fi
for _ in $(seq 1 30); do
  xdpyinfo -display :1 >/dev/null 2>&1 && break
  sleep 1
done
xdpyinfo -display :1 >/dev/null

if ! pgrep -x xfce4-session >/dev/null; then
  nohup dbus-run-session -- env DISPLAY=:1 XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    startxfce4 > "$HOME/logs/xfce.log" 2>&1 &
fi
for _ in $(seq 1 60); do
  pgrep -x xfce4-session >/dev/null && pgrep -x xfwm4 >/dev/null && break
  sleep 1
done
pgrep -x xfce4-session >/dev/null
pgrep -x xfwm4 >/dev/null

echo "[5/6] stopping previous cicy-code and starting $VERSION"
if [[ -f /content/cicy-code.pid ]]; then
  old_pid="$(cat /content/cicy-code.pid 2>/dev/null || true)"
  old_command="$(ps -p "$old_pid" -o command= 2>/dev/null || true)"
  if [[ -n "$old_pid" && "$old_command" == *cicy-code* ]]; then
    kill -TERM "$old_pid" 2>/dev/null || true
  fi
fi
pkill -TERM -x cicy-code 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -x cicy-code >/dev/null || break
  sleep 0.1
done
pkill -KILL -x cicy-code 2>/dev/null || true
rm -f /content/cicy-code.pid

nohup stdbuf -oL -eL npx --yes cicy-code@latest \
  --email "$CICY_EMAIL" --team "$CICY_TEAM" --cft \
  > "$CICY_LOG_FILE" 2>&1 < /dev/null &
echo $! > /content/cicy-code.pid

cicy_pid="$(cat /content/cicy-code.pid)"
echo "[6/6] waiting for Quick Tunnel (pid $cicy_pid)"
for _ in $(seq 1 120); do
  if ! kill -0 "$cicy_pid" 2>/dev/null; then
    tail -n 100 "$CICY_LOG_FILE"
    exit 1
  fi
  cft_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CICY_LOG_FILE" | tail -n 1 || true)"
  api_token="$(jq -r '.api_token // empty' "$HOME/cicy-ai/global.json" 2>/dev/null || true)"
  if [[ -n "$cft_url" && -n "$api_token" ]]; then
    encoded_token="$(jq -rn --arg token "$api_token" '$token|@uri')"
    printf '%s\n' "installed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > /content/cicy-code.installed
    echo "OPEN_URL=${cft_url%/}/?token=$encoded_token"
    exit 0
  fi
  sleep 2
done

echo "cicy-code is running, but the Quick Tunnel URL is not ready" >&2
echo "check: $CICY_LOG_FILE" >&2
exit 2
