#!/usr/bin/env bash
# Run cicy-code directly on Google Cloud Shell as user cicy (no Docker).
set -Eeuo pipefail

VERSION=2.3.0
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
TOOLS_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
CICY_CODE_UPDATER_SOURCE="$TOOLS_DIR/colab-cicy-code-update.sh"

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "  \033[31m✗\033[0m failed at line %s\n" "$LINENO" >&2' ERR

home_usage_percent() {
  df -P "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

repair_host_npm_and_space() {
  local before after npmrc tmp prefix profile
  [[ -n "${HOME:-}" && "$HOME" != "/" ]] || fail "refusing host cleanup with unsafe HOME=${HOME:-unset}"
  before="$(home_usage_percent || true)"
  if [[ "$before" =~ ^[0-9]+$ ]] && (( before >= 95 )); then
    warn "Cloud Shell home is ${before}% full; removing only rebuildable caches"
    rm -rf \
      "$HOME/.npm/_cacache" \
      "$HOME/.npm/_logs" \
      "$HOME/.cache/node-gyp" \
      "$HOME/.cache/pip" \
      "$HOME/.cache/pnpm" \
      "$HOME/.cache/uv" \
      "$HOME/.cache/yarn"
    sudo apt-get clean >/dev/null 2>&1 || true
  fi

  unset NPM_CONFIG_PREFIX npm_config_prefix PREFIX
  npmrc="$HOME/.npmrc"
  if [[ -f "$npmrc" ]]; then
    prefix="$(awk -F= '/^[[:space:]]*prefix[[:space:]]*=/{sub(/^[^=]*=/,"");gsub(/^[[:space:]]+|[[:space:]]+$/,"");print;exit}' "$npmrc")"
    if [[ "$prefix" == "$HOME/.npm-global" ]]; then
      tmp="$(mktemp /tmp/cicy-cloudshell-npmrc.XXXXXX)"
      awk '!/^[[:space:]]*prefix[[:space:]]*=/' "$npmrc" >"$tmp"
      command cp "$tmp" "$npmrc"
      rm -f "$tmp"
      ok "removed legacy npm prefix from $npmrc"
    fi
  fi
  for profile in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    [[ -f "$profile" ]] || continue
    if grep -Eq '^[[:space:]]*(export[[:space:]]+)?(NPM_CONFIG_PREFIX|npm_config_prefix)=.*\.npm-global' "$profile"; then
      tmp="$(mktemp /tmp/cicy-cloudshell-profile.XXXXXX)"
      awk '!/^[[:space:]]*(export[[:space:]]+)?(NPM_CONFIG_PREFIX|npm_config_prefix)=.*\.npm-global/' "$profile" >"$tmp"
      command cp "$tmp" "$profile"
      rm -f "$tmp"
      ok "removed legacy npm prefix export from $profile"
    fi
  done

  if command -v nvm >/dev/null 2>&1; then
    nvm use --delete-prefix "$(nvm current 2>/dev/null || printf 'node')" --silent >/dev/null 2>&1 || true
  fi
  after="$(home_usage_percent || true)"
  if [[ "$after" =~ ^[0-9]+$ ]] && (( after >= 99 )); then
    printf 'Cloud Shell home remains %s%% full after safe cache cleanup. Largest top-level paths:\n' "$after" >&2
    du -xhd1 "$HOME" 2>/dev/null | sort -h | tail -n 12 >&2 || true
    fail "free at least 300 MB in $HOME, then run cicy-cloudshell again"
  fi
  ok "host preflight version=$VERSION home_usage=${after:-unknown}% npm_prefix=clean"
}

repair_host_npm_and_space

CONFIG="${CICY_CONFIG:-$HOME/config.ini}"
[[ -f "$CONFIG" ]] || fail "missing config: $CONFIG"
set -a
# shellcheck disable=SC1090
. "$CONFIG"
set +a
unset NPM_CONFIG_PREFIX npm_config_prefix PREFIX

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
CICY_CODE_UPDATER="$CICY_HOME/.local/libexec/cicy-code-update.sh"
RUNTIME_ARGS_FILE="$CICY_AI/runtime/cicy-code.args"
RUNTIME_ENV_FILE="$CICY_AI/runtime/cicy-code.env"

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
RUNTIME_NODE_MAJOR="$(sudo -u cicy -H env PATH=/usr/local/bin:/usr/bin:/bin node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')"
if [[ ! "$RUNTIME_NODE_MAJOR" =~ ^[0-9]+$ ]] || (( RUNTIME_NODE_MAJOR < 20 )); then
  curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - >/dev/null
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null
fi
RUNTIME_NODE_VERSION="$(sudo -u cicy -H env PATH=/usr/local/bin:/usr/bin:/bin node --version)"
RUNTIME_NPM_VERSION="$(sudo -u cicy -H env PATH=/usr/local/bin:/usr/bin:/bin npm --version)"
ok "runtime node=$RUNTIME_NODE_VERSION npm=$RUNTIME_NPM_VERSION"
[[ -s "$CICY_CODE_UPDATER_SOURCE" ]] || fail "missing cicy-code updater: $CICY_CODE_UPDATER_SOURCE"
sudo install -d -m 0755 -o cicy -g cicy "$CICY_HOME/.local/bin" "$CICY_HOME/.local/libexec"
sudo install -m 0755 -o cicy -g cicy "$CICY_CODE_UPDATER_SOURCE" "$CICY_CODE_UPDATER"

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
  AUTH_TMP="$(mktemp)"
  if ! printf '%s' "$CODEX_AUTH_B64" | base64 --decode >"$AUTH_TMP" 2>/dev/null \
    || ! iconv -f UTF-8 -t UTF-8 "$AUTH_TMP" >/dev/null 2>&1 \
    || ! jq empty "$AUTH_TMP" >/dev/null 2>&1; then
    rm -f "$AUTH_TMP"
    fail "CODEX_AUTH_B64 does not decode to valid UTF-8 JSON; existing auth.json was not overwritten"
  fi
  sudo install -m 0600 -o cicy -g cicy "$AUTH_TMP" "$CICY_HOME/.codex/auth.json"
  rm -f "$AUTH_TMP"
fi
sudo chown -R cicy:cicy "$CICY_HOME"
sudo chmod 0600 \
  "$CICY_HOME/.config/cicy-ai/config-gh-token" \
  "$CICY_HOME/.config/cicy-ai/knowledge-gh-token"
[[ ! -f "$CICY_HOME/.codex/auth.json" ]] || sudo chmod 0600 "$CICY_HOME/.codex/auth.json"
ok "config=$CICY_CONFIG_GH_REPO knowledge=$CICY_KNOWLEDGE_GH_REPO"

log "crontab"
CRONTAB_FILE="$CICY_AI/crontab.txt"
[[ -s "$CRONTAB_FILE" ]] || CRONTAB_FILE="$CICY_AI/db/crontab.txt"
if [[ -s "$CRONTAB_FILE" ]]; then
  sudo -u cicy crontab "$CRONTAB_FILE"
  if ! pgrep -x cron >/dev/null 2>&1 && ! pgrep -x crond >/dev/null 2>&1; then
    sudo service cron start >/dev/null 2>&1 \
      || sudo /usr/sbin/cron \
      || sudo /usr/sbin/crond
  fi
  if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
    ok "installed=$CRONTAB_FILE daemon=running"
  else
    fail "crontab installed but cron daemon did not start"
  fi
else
  warn "no crontab.txt or db/crontab.txt under $CICY_AI"
fi

log "versioned cicy-code runtime"
CICY_RUNTIME_PATH="$CICY_HOME/.local/bin:$CICY_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
CICY_CODE_VERSION="$(sudo -u cicy -H env \
  HOME="$CICY_HOME" USER=cicy LOGNAME=cicy \
  PATH="$CICY_RUNTIME_PATH" NPM_CONFIG_PREFIX="$CICY_HOME/.npm-global" CICY_CODE_SWITCH=0 \
  "$CICY_CODE_UPDATER" latest | tee /dev/stderr | tail -n 1)"
[[ "$CICY_CODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
  || fail "cicy-code updater returned an invalid version: $CICY_CODE_VERSION"
ok "staged and verified cicy-code $CICY_CODE_VERSION"

NPM_LAUNCHER="$CICY_HOME/.local/cicy-code/$CICY_CODE_VERSION/bin/cicy-code"
if [[ -x "$NPM_LAUNCHER" ]]; then
  sudo -u cicy -H env \
    HOME="$CICY_HOME" USER=cicy LOGNAME=cicy PATH="$CICY_RUNTIME_PATH" \
    CICY_CLOUD_ORIGIN="${CICY_CLOUD_ORIGIN:-}" \
    "$NPM_LAUNCHER" --email "$CICY_EMAIL" --team "$CICY_TEAM" --version
elif [[ -s "$CICY_AI/db/cloud-device.json" ]]; then
  ok "npm launcher unavailable; reusing saved Cloud authentication"
else
  fail "npm launcher unavailable and no saved Cloud authentication exists"
fi

SWITCHED_VERSION="$(sudo -u cicy -H env \
  HOME="$CICY_HOME" USER=cicy LOGNAME=cicy \
  PATH="$CICY_RUNTIME_PATH" NPM_CONFIG_PREFIX="$CICY_HOME/.npm-global" \
  "$CICY_CODE_UPDATER" "$CICY_CODE_VERSION" | tee /dev/stderr | tail -n 1)"
[[ "$SWITCHED_VERSION" == "$CICY_CODE_VERSION" ]] \
  || fail "cicy-code switch failed: expected $CICY_CODE_VERSION, got $SWITCHED_VERSION"
ok "current -> $CICY_HOME/.local/bin/cicy-code-$CICY_CODE_VERSION"

sudo install -d -m 0755 -o cicy -g cicy "$(dirname "$RUNTIME_ARGS_FILE")"
sudo install -m 0600 -o cicy -g cicy /dev/null "$RUNTIME_ARGS_FILE"
sudo install -m 0600 -o cicy -g cicy /dev/null "$RUNTIME_ENV_FILE"
printf '%s\0' --cft | sudo tee "$RUNTIME_ARGS_FILE" >/dev/null
{
  printf 'CICY_EMAIL=%s\0' "$CICY_EMAIL"
  printf 'CICY_TEAM=%s\0' "$CICY_TEAM"
  printf 'CICY_CONFIG_GH_TOKEN=%s\0' "$CICY_CONFIG_GH_TOKEN"
  printf 'CICY_KNOWLEDGE_GH_TOKEN=%s\0' "$CICY_KNOWLEDGE_GH_TOKEN"
  printf 'CICY_LOG_FILE=%s\0' "$CODE_LOG"
  if [[ -n "${CICY_CLOUD_ORIGIN:-}" ]]; then
    printf 'CICY_CLOUD_ORIGIN=%s\0' "$CICY_CLOUD_ORIGIN"
  fi
} | sudo tee "$RUNTIME_ENV_FILE" >/dev/null
sudo chown cicy:cicy "$RUNTIME_ARGS_FILE" "$RUNTIME_ENV_FILE"
sudo chmod 0600 "$RUNTIME_ARGS_FILE" "$RUNTIME_ENV_FILE"

OLD_PID="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && sudo kill -0 "$OLD_PID" 2>/dev/null; then
  sudo kill -TERM "$OLD_PID" 2>/dev/null || true
fi
sudo pkill -TERM -u cicy -x cicy-code 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -u cicy -x cicy-code >/dev/null || break
  sleep 0.1
done
sudo pkill -KILL -u cicy -x cicy-code 2>/dev/null || true
# Remove the legacy npx launcher only after the versioned native runtime is ready.
sudo pkill -TERM -u cicy -f 'npx.*cicy-code|npm exec.*cicy-code' 2>/dev/null || true

sudo touch "$CODE_LOG" "$PID_FILE"
sudo chown cicy:cicy "$CODE_LOG" "$PID_FILE"
sudo -u cicy -H env \
  HOME="$CICY_HOME" USER=cicy LOGNAME=cicy \
  PATH="$CICY_RUNTIME_PATH" \
  NPM_CONFIG_PREFIX="$CICY_HOME/.npm-global" \
  CICY_EMAIL="$CICY_EMAIL" \
  CICY_TEAM="$CICY_TEAM" \
  CICY_CONFIG_GH_TOKEN="$CICY_CONFIG_GH_TOKEN" \
  CICY_KNOWLEDGE_GH_TOKEN="$CICY_KNOWLEDGE_GH_TOKEN" \
  CICY_CLOUD_ORIGIN="${CICY_CLOUD_ORIGIN:-}" \
  CICY_LOG_FILE="$CODE_LOG" \
  CICY_START_LOG="$CODE_LOG" \
  CICY_START_ARGS_FILE="$RUNTIME_ARGS_FILE" \
  CICY_START_PID_FILE="$PID_FILE" \
  bash -c 'saved_args=(); while IFS= read -r -d "" argument; do saved_args+=("$argument"); done < "$CICY_START_ARGS_FILE"; nohup stdbuf -oL -eL "$HOME/.local/bin/cicy-code" "${saved_args[@]}" > "$CICY_START_LOG" 2>&1 < /dev/null & echo $! > "$CICY_START_PID_FILE"'

START_PID="$(sudo cat "$PID_FILE" 2>/dev/null || true)"
[[ "$START_PID" =~ ^[0-9]+$ ]] || fail "could not record startup pid"
for _ in $(seq 1 120); do
  pgrep -u cicy -x cicy-code >/dev/null && break
  sudo kill -0 "$START_PID" 2>/dev/null || break
  sleep 0.5
done
if ! pgrep -u cicy -x cicy-code >/dev/null; then
  sudo tail -n 80 "$CODE_LOG" || true
  fail "cicy-code exited during startup; log=$CODE_LOG"
fi
ok "started cicy-code $CICY_CODE_VERSION pid=$START_PID via $CICY_HOME/.local/bin/cicy-code"

TUNNEL_URL=""
for _ in $(seq 1 150); do
  TUNNEL_URL="$(sudo grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CODE_LOG" | tail -n1 || true)"
  [[ -n "$TUNNEL_URL" ]] && break
  if (( _ % 5 == 0 )); then
    echo "  waiting $((_ * 2))s — latest log:"
    sudo tail -n 5 "$CODE_LOG" 2>/dev/null | sed 's/^/    /' || true
  fi
  if ! sudo kill -0 "$START_PID" 2>/dev/null && ! pgrep -u cicy -x cicy-code >/dev/null; then
    sudo tail -n 80 "$CODE_LOG" || true
    fail "cicy-code exited before tunnel was ready; log=$CODE_LOG"
  fi
  sleep 2
done

RUNTIME_PID="$(pgrep -u cicy -x cicy-code | head -n1 || printf '%s' "$START_PID")"
ok "cicy-code running directly as $(ps -o user= -p "$RUNTIME_PID" | xargs) pid=$RUNTIME_PID"
printf 'TEAM=%s\nHOME=%s\nLOG=%s\n' "$CICY_TEAM" "$CICY_HOME" "$CODE_LOG"
if [[ -n "$TUNNEL_URL" ]]; then
  API_TOKEN="$(sudo -u cicy jq -r '.api_token // empty' "$CICY_AI/global.json" 2>/dev/null || true)"
  ENCODED_TOKEN="$(jq -rn --arg token "$API_TOKEN" '$token|@uri')"
  FIXED_HOST=""
  echo "waiting for fixed cicy-cloud domain..."
  for fixed_try in $(seq 1 90); do
    AGENT_BIN="$(sudo -u cicy -H env PATH="$CICY_HOME/.local/bin:$CICY_HOME/cicy-ai/bin:/usr/local/bin:/usr/bin:/bin" bash -c 'command -v cicy-agent 2>/dev/null || find "$HOME/cicy-ai" -path "*/cicy-agent/bin/cicy-agent" -type f -perm -u+x -print -quit 2>/dev/null' || true)"
    if [[ -n "$AGENT_BIN" ]]; then
      FIXED_HOST="$(sudo -u cicy -H timeout 5 "$AGENT_BIN" --json whoami 2>/dev/null | jq -r '.data.proxyHost // empty' | head -n1 || true)"
    fi
    [[ -n "$FIXED_HOST" ]] && break
    if (( fixed_try % 5 == 0 )); then
      echo "  fixed domain pending $((fixed_try * 2))s"
    fi
    sleep 2
  done
  printf 'TOKEN=%s\nTUNNEL_URL=%s\n' "$API_TOKEN" "$TUNNEL_URL"
  if [[ -n "$FIXED_HOST" ]]; then
    printf 'FIXED_DOMAIN=https://%s\nFIXED_OPEN_URL=https://%s/?token=%s\n' "$FIXED_HOST" "$FIXED_HOST" "$ENCODED_TOKEN"
  else
    printf 'FIXED_DOMAIN=unavailable\n' >&2
    warn "fixed domain was not registered after 180s; log=$CODE_LOG"
  fi
  printf 'OPEN_URL=%s/?token=%s\n' "$TUNNEL_URL" "$ENCODED_TOKEN"
else
  warn "tunnel URL is still pending; run: tail -f $CODE_LOG"
fi
