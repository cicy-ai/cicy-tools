#!/usr/bin/env bash
# Run cicy-code directly on Google Cloud Shell as user cicy (no Docker).
set -Eeuo pipefail

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "  \033[31m✗\033[0m failed at line %s\n" "$LINENO" >&2' ERR

CONFIG="${CICY_CONFIG:-$HOME/config.ini}"
[[ -f "$CONFIG" ]] || fail "missing config: $CONFIG"
set -a
# shellcheck disable=SC1090
. "$CONFIG"
set +a

: "${CICY_EMAIL:?CICY_EMAIL is required}"
: "${CICY_CONFIG_GH_TOKEN:?CICY_CONFIG_GH_TOKEN is required}"
CICY_TEAM="${CICY_TEAM:-cloudshell_w3c}"
CICY_CONFIG_GH_REPO="${CICY_CONFIG_GH_REPO:-w3c-ai/cicy-ai-config-cloudshell}"
CICY_KNOWLEDGE_GH_REPO="${CICY_KNOWLEDGE_GH_REPO:-w3c-ai/cicy-ai-knowledge}"
CICY_KNOWLEDGE_GH_TOKEN="${CICY_KNOWLEDGE_GH_TOKEN:-$CICY_CONFIG_GH_TOKEN}"

CICY_HOME=/home/cicy
CICY_AI="$CICY_HOME/cicy-ai"
LOG_DIR="$CICY_HOME/logs"
CODE_LOG="$LOG_DIR/cicy-code.log"
PID_FILE="$LOG_DIR/cicy-code.pid"

log "host runtime user"
if ! id cicy >/dev/null 2>&1; then
  sudo groupadd cicy 2>/dev/null || true
  sudo useradd -m -d "$CICY_HOME" -s /bin/bash -g cicy cicy
fi
sudo usermod -d "$CICY_HOME" -s /bin/bash cicy
sudo install -d -o cicy -g cicy "$CICY_HOME" "$CICY_HOME/projects" "$LOG_DIR"
printf '%s\n' 'cicy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-cicy >/dev/null
sudo chmod 0440 /etc/sudoers.d/90-cicy
sudo -u cicy sudo -n true
ok "user=cicy home=$CICY_HOME sudo=NOPASSWD"

log "runtime dependencies"
mkdir -p "$HOME/.cloudshell"
touch "$HOME/.cloudshell/no-apt-get-warning"
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git jq cron sqlite3 >/dev/null
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
fi
ok "node=$(node --version) npm=$(npm --version)"

git_auth() {
  local token="$1"; shift
  sudo -u cicy -H env GH_TOKEN="$token" git -c 'credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f' "$@"
}

restore_repo() {
  local repo="$1" token="$2" target="$3"
  if [[ -d "$target/.git" ]]; then
    git_auth "$token" -C "$target" remote set-url origin "https://github.com/${repo}.git"
    git_auth "$token" -C "$target" fetch origin main
  else
    if [[ -e "$target" ]] && [[ -n "$(sudo find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      sudo mv "$target" "${target}.backup.$(date +%s)"
    else
      sudo rm -rf "$target"
    fi
    git_auth "$token" clone --branch main --single-branch "https://github.com/${repo}.git" "$target"
  fi
}

log "private config and shared knowledge"
restore_repo "$CICY_CONFIG_GH_REPO" "$CICY_CONFIG_GH_TOKEN" "$CICY_AI"
restore_repo "$CICY_KNOWLEDGE_GH_REPO" "$CICY_KNOWLEDGE_GH_TOKEN" "$CICY_AI/knowledge"
sudo install -d -m 0700 -o cicy -g cicy "$CICY_HOME/.config/cicy-ai" "$CICY_HOME/.codex" "$CICY_HOME/.npm-global"
printf '%s' "$CICY_CONFIG_GH_TOKEN" | sudo tee "$CICY_HOME/.config/cicy-ai/config-gh-token" >/dev/null
printf '%s' "$CICY_KNOWLEDGE_GH_TOKEN" | sudo tee "$CICY_HOME/.config/cicy-ai/knowledge-gh-token" >/dev/null
if [[ -n "${CODEX_AUTH_B64:-}" ]]; then
  printf '%s' "$CODEX_AUTH_B64" | base64 --decode | sudo tee "$CICY_HOME/.codex/auth.json" >/dev/null
fi
sudo chown -R cicy:cicy "$CICY_HOME"
sudo chmod 0600 \
  "$CICY_HOME/.config/cicy-ai/config-gh-token" \
  "$CICY_HOME/.config/cicy-ai/knowledge-gh-token"
[[ ! -f "$CICY_HOME/.codex/auth.json" ]] || sudo chmod 0600 "$CICY_HOME/.codex/auth.json"
ok "config=$CICY_CONFIG_GH_REPO knowledge=$CICY_KNOWLEDGE_GH_REPO"

log "crontab"
if [[ -s "$CICY_AI/crontab.txt" ]]; then
  sudo -u cicy crontab "$CICY_AI/crontab.txt"
  sudo service cron start >/dev/null 2>&1 || sudo systemctl start cron >/dev/null 2>&1 || true
  ok "installed for cicy"
else
  warn "no $CICY_AI/crontab.txt"
fi

log "direct cicy-code process"
sudo pkill -u cicy -f 'cicy-code' 2>/dev/null || true
sleep 1
sudo -u cicy -H env \
  HOME="$CICY_HOME" \
  PATH="$CICY_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  NPM_CONFIG_PREFIX="$CICY_HOME/.npm-global" \
  CICY_CONFIG_GH_TOKEN="$CICY_CONFIG_GH_TOKEN" \
  CICY_KNOWLEDGE_GH_TOKEN="$CICY_KNOWLEDGE_GH_TOKEN" \
  CICY_START_EMAIL="$CICY_EMAIL" \
  CICY_START_TEAM="$CICY_TEAM" \
  CICY_START_LOG="$CODE_LOG" \
  CICY_START_PID_FILE="$PID_FILE" \
  bash -c 'cd "$HOME" && nohup npx --yes cicy-code@latest --email "$CICY_START_EMAIL" --team "$CICY_START_TEAM" --cft >"$CICY_START_LOG" 2>&1 </dev/null & echo $! >"$CICY_START_PID_FILE"'

START_PID="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
[[ "$START_PID" =~ ^[0-9]+$ ]] || fail "could not record startup pid"
sleep 2
if ! sudo kill -0 "$START_PID" 2>/dev/null && ! pgrep -u cicy -f 'cicy-code' >/dev/null; then
  sudo tail -n 80 "$CODE_LOG" || true
  fail "cicy-code exited during startup; log=$CODE_LOG"
fi
ok "started pid=$START_PID; waiting for tunnel"

TUNNEL_URL=""
for _ in $(seq 1 150); do
  TUNNEL_URL="$(sudo grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CODE_LOG" | tail -n1 || true)"
  [[ -n "$TUNNEL_URL" ]] && break
  if (( _ % 5 == 0 )); then
    echo "  waiting $((_ * 2))s — latest log:"
    sudo tail -n 5 "$CODE_LOG" 2>/dev/null | sed 's/^/    /' || true
  fi
  if ! sudo kill -0 "$START_PID" 2>/dev/null && ! pgrep -u cicy -f 'cicy-code' >/dev/null; then
    sudo tail -n 80 "$CODE_LOG" || true
    fail "cicy-code exited before tunnel was ready; log=$CODE_LOG"
  fi
  sleep 2
done

RUNTIME_PID="$(pgrep -u cicy -f 'cicy-code' | head -n1 || printf '%s' "$START_PID")"
ok "cicy-code running directly as $(ps -o user= -p "$RUNTIME_PID" | xargs) pid=$RUNTIME_PID"
printf 'TEAM=%s\nHOME=%s\nLOG=%s\n' "$CICY_TEAM" "$CICY_HOME" "$CODE_LOG"
if [[ -n "$TUNNEL_URL" ]]; then
  API_TOKEN="$(sudo -u cicy jq -r '.api_token // empty' "$CICY_AI/global.json" 2>/dev/null || true)"
  ENCODED_TOKEN="$(jq -rn --arg token "$API_TOKEN" '$token|@uri')"
  FIXED_HOST=""
  AGENT_BIN="$(sudo -u cicy -H bash -lc 'command -v cicy-agent 2>/dev/null || find "$HOME/cicy-ai/skills" -path "*/cicy-agent/bin/cicy-agent" -type f -perm -u+x -print -quit 2>/dev/null' || true)"
  if [[ -n "$AGENT_BIN" ]]; then
    FIXED_HOST="$(sudo -u cicy -H timeout 10 "$AGENT_BIN" --json whoami 2>/dev/null | jq -r '.data.proxyHost // empty' | head -n1 || true)"
  fi
  printf 'TOKEN=%s\nTUNNEL_URL=%s\n' "$API_TOKEN" "$TUNNEL_URL"
  if [[ -n "$FIXED_HOST" ]]; then
    printf 'FIXED_DOMAIN=https://%s\nFIXED_OPEN_URL=https://%s/?token=%s\n' "$FIXED_HOST" "$FIXED_HOST" "$ENCODED_TOKEN"
  else
    printf 'FIXED_DOMAIN=pending\n'
  fi
  printf 'OPEN_URL=%s/?token=%s\n' "$TUNNEL_URL" "$ENCODED_TOKEN"
else
  warn "tunnel URL is still pending; run: tail -f $CODE_LOG"
fi
