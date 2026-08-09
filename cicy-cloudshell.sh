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
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git jq cron sqlite3 >/dev/null
if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 20 ]]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
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
sudo chmod 0600 "$CICY_HOME/.config/cicy-ai/"*-gh-token
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
sudo pkill -u cicy -x cicy-code 2>/dev/null || true
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
  bash -c 'nohup npx --yes cicy-code@latest --email "$CICY_START_EMAIL" --team "$CICY_START_TEAM" --cft >"$CICY_START_LOG" 2>&1 </dev/null &'

for _ in $(seq 1 60); do
  pgrep -u cicy -x cicy-code >/dev/null && break
  sleep 2
done
pgrep -u cicy -x cicy-code >/dev/null || {
  sudo tail -n 80 "$CODE_LOG" || true
  fail "cicy-code did not start; log=$CODE_LOG"
}

OPEN_URL=""
for _ in $(seq 1 60); do
  OPEN_URL="$(sudo sed -n 's/.*\(https:\/\/[^ ]*trycloudflare\.com\/?[^ ]*\).*/\1/p' "$CODE_LOG" | tail -n1)"
  [[ -n "$OPEN_URL" ]] && break
  sleep 2
done

ok "cicy-code running directly as $(ps -o user= -p "$(pgrep -u cicy -x cicy-code | head -n1)" | xargs)"
printf 'TEAM=%s\nHOME=%s\nLOG=%s\n' "$CICY_TEAM" "$CICY_HOME" "$CODE_LOG"
[[ -z "$OPEN_URL" ]] || printf 'OPEN_URL=%s\n' "$OPEN_URL"
[[ -n "$OPEN_URL" ]] || warn "tunnel URL is still pending; run: tail -f $CODE_LOG"
