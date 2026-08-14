#!/usr/bin/env bash
set -euo pipefail

LAUNCHER_VERSION=1.6.1
CICY_CODE_UPDATER="${CICY_CODE_UPDATER:-/content/colab-cicy-code-update.sh}"
CICY_TOOLS_REPO="${CICY_TOOLS_REPO:-/content/cicy-tools-source}"
CICY_TOOLS_URL="${CICY_TOOLS_URL:-https://github.com/cicy-ai/cicy-tools.git}"
CONFIG_REPO_NAME="${CICY_CONFIG_GH_REPO:-}"
KNOWLEDGE_REPO_NAME="${CICY_KNOWLEDGE_GH_REPO:-}"
CICY_TEAM="${CICY_TEAM:-colab_w3c}"
CICY_LOG_FILE="${CICY_CODE_LOG:-/content/cicy-code.log}"
RESET_CLOUD_INSTANCE="${CICY_RESET_CLOUD_INSTANCE:-0}"
ENABLE_PREVIEW=0
PREVIEW_DIST=/home/cicy/projects/cicy-code/app/dist

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      [[ $# -ge 2 ]] || { echo "--email requires a value" >&2; exit 2; }
      CICY_EMAIL="$2"
      shift 2
      ;;
    --team)
      [[ $# -ge 2 ]] || { echo "--team requires a value" >&2; exit 2; }
      CICY_TEAM="$2"
      shift 2
      ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo requires a value" >&2; exit 2; }
      CONFIG_REPO_NAME="$2"
      shift 2
      ;;
    --reset-instance)
      RESET_CLOUD_INSTANCE=1
      shift
      ;;
    --preview)
      ENABLE_PREVIEW=1
      shift
      ;;
    --help|-h)
      echo "usage: colab-cicy-code.sh [--email ADDRESS] [--team NAME] [--repo OWNER/NAME] [--reset-instance] [--preview]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ "$CICY_TEAM" =~ ^[A-Za-z0-9_.-]+$ ]] || {
  echo "invalid --team value: $CICY_TEAM" >&2
  exit 2
}

validate_repo_pair() {
  local kind="$1" token="$2" repo_name="$3"
  if [[ -n "$token" && -z "$repo_name" ]]; then
    echo "$kind token is set; the matching repository name is required" >&2
    exit 2
  fi
  if [[ -z "$token" && -n "$repo_name" ]]; then
    echo "$kind repository is set; the matching token is required" >&2
    exit 2
  fi
  if [[ -n "$repo_name" && ! "$repo_name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "invalid $kind repository name: $repo_name (expected owner/name)" >&2
    exit 2
  fi
}

validate_repo_pair config "${CICY_CONFIG_GH_TOKEN:-}" "$CONFIG_REPO_NAME"
if [[ -n "${CICY_KNOWLEDGE_GH_TOKEN:-}" && -z "$KNOWLEDGE_REPO_NAME" ]]; then
  KNOWLEDGE_REPO_NAME=w3c-ai/cicy-ai-knowledge
fi
if [[ -z "${CICY_KNOWLEDGE_GH_TOKEN:-}" && -n "$KNOWLEDGE_REPO_NAME" ]]; then
  echo "knowledge repository is set; the matching token is required" >&2
  exit 2
fi
if [[ -n "$KNOWLEDGE_REPO_NAME" && ! "$KNOWLEDGE_REPO_NAME" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "invalid knowledge repository name: $KNOWLEDGE_REPO_NAME (expected owner/name)" >&2
  exit 2
fi
[[ -z "${CICY_EMAIL:-}" || "$CICY_EMAIL" != *$'\n'* ]] || {
  echo "invalid --email value" >&2
  exit 2
}

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

for name in CICY_EMAIL; do
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

CICY_RUNTIME_USER=cicy
CICY_RUNTIME_HOME=/home/cicy
if ! id -u "$CICY_RUNTIME_USER" >/dev/null 2>&1; then
  sudo groupadd --system "$CICY_RUNTIME_USER" 2>/dev/null || true
  sudo useradd --create-home --home-dir "$CICY_RUNTIME_HOME" \
    --shell /bin/bash --gid "$CICY_RUNTIME_USER" "$CICY_RUNTIME_USER"
fi
sudo install -d -m755 -o "$CICY_RUNTIME_USER" -g "$CICY_RUNTIME_USER" "$CICY_RUNTIME_HOME"
echo 'cicy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-cicy >/dev/null
sudo chmod 440 /etc/sudoers.d/90-cicy
export HOME="$CICY_RUNTIME_HOME"
export USER="$CICY_RUNTIME_USER"
export LOGNAME="$CICY_RUNTIME_USER"

export DEBIAN_FRONTEND=noninteractive
export DISPLAY=:1
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/cicy-xdg-runtime}"
export CICY_CLOUD_ORIGIN="${CICY_CLOUD_ORIGIN:-https://cicy-ai.com}"
export NPM_CONFIG_PREFIX="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

mkdir -p "$NPM_CONFIG_PREFIX/bin" "$NPM_CONFIG_PREFIX/lib" \
  "$XDG_RUNTIME_DIR" "$HOME/.codex" "$HOME/.npm" "$HOME/.local/bin" \
  "$HOME/.config/cicy-ai" "$HOME/logs" "$HOME/projects"
chmod 700 "$XDG_RUNTIME_DIR"
sudo chown -R "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$HOME/.npm"
sudo chown "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$XDG_RUNTIME_DIR"

echo "[0/6] preparing update (current cicy-code remains online until switch)"

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

migrate_colab_workspace_paths() {
  local database="$HOME/cicy-ai/db/data.db" legacy_count
  [[ -f "$database" ]] || return 0
  legacy_count="$(sqlite3 "$database" \
    "SELECT count(*) FROM agent_config WHERE workspace LIKE '/home/runner/cicy-ai/workers/%' OR workspace LIKE '/root/cicy-ai/workers/%';")"
  [[ "$legacy_count" -gt 0 ]] || return 0
  echo "migrating $legacy_count agent workspace path(s) to /home/cicy"
  sqlite3 "$database" <<'SQL'
.bail on
.timeout 30000
PRAGMA wal_checkpoint(TRUNCATE);
BEGIN IMMEDIATE;
UPDATE agent_config
SET workspace = replace(replace(workspace, '/home/runner/cicy-ai/workers/', '/home/cicy/cicy-ai/workers/'), '/root/cicy-ai/workers/', '/home/cicy/cicy-ai/workers/'),
    updated_at = datetime('now')
WHERE workspace LIKE '/home/runner/cicy-ai/workers/%' OR workspace LIKE '/root/cicy-ai/workers/%';
COMMIT;
PRAGMA quick_check;
SQL
}

clone_private_repo() {
  local repo_name="$1" destination="$2" token="$3" kind="$4" sync_script_tmp
  local repo="https://github.com/${repo_name}.git"
  if [[ -z "$token" ]]; then
    if [[ -d "$destination" ]]; then
      echo "reusing $destination ($kind Git token not set; fetch skipped)"
    else
      echo "skipping $kind repository ($kind Git token not set)"
    fi
    return 0
  fi
  if [[ -d "$destination/.git" ]]; then
    # A Colab cell may be interrupted while git is rebasing. The next run must
    # recover that state before inspecting/committing the worktree; otherwise
    # every retry fails forever on the stale rebase-merge directory. Prefer a
    # normal abort. If Git cannot abort, quit the sequencer and attach the
    # current (already committed) detached HEAD to main so no local snapshot is
    # discarded.
    if [[ -d "$destination/.git/rebase-merge" || -d "$destination/.git/rebase-apply" ]]; then
      echo "recovering interrupted rebase in $destination"
      git -C "$destination" rebase --abort >/dev/null 2>&1 || true
      if [[ -d "$destination/.git/rebase-merge" || -d "$destination/.git/rebase-apply" ]]; then
        git -C "$destination" rebase --quit >/dev/null 2>&1 || true
      fi
      if [[ "$(git -C "$destination" symbolic-ref -q --short HEAD || true)" == "" ]]; then
        git -C "$destination" branch -f main HEAD
        git -C "$destination" checkout --quiet main
      fi
    fi
    git -C "$destination" remote set-url origin \
      "https://x-access-token:${token}@${repo#https://}"
    if [[ "$destination" == "$HOME/cicy-ai" && \
          -x "$destination/bin/sync-cicy-ai-config.sh" ]]; then
      # Bootstrap the conflict resolver itself before invoking it. A runtime
      # stuck with an older sync script cannot pull the commit that fixes that
      # script, so refresh this single tracked executable directly from the
      # selected team's origin first.
      git -C "$destination" fetch --quiet origin main
      sync_script_tmp="$destination/bin/.sync-cicy-ai-config.sh.tmp"
      git -C "$destination" show origin/main:bin/sync-cicy-ai-config.sh > "$sync_script_tmp"
      chmod 700 "$sync_script_tmp"
      mv -f "$sync_script_tmp" "$destination/bin/sync-cicy-ai-config.sh"
      echo "syncing Colab config through the locked sync script"
      "$destination/bin/sync-cicy-ai-config.sh"
      # The config sync script already commits, fetches, rebases and pushes.
      # Running another pull below creates a second, unlocked rebase window
      # that can race the one-minute cron sync.
      return 0
    fi
    if ! git -C "$destination" diff --quiet || \
       ! git -C "$destination" diff --cached --quiet || \
       [[ -n "$(git -C "$destination" ls-files --others --exclude-standard)" ]]; then
      echo "local changes must be synced before updating $destination" >&2
      exit 1
    fi
    git -C "$destination" fetch --quiet origin main
    git -C "$destination" checkout --quiet main
    git -C "$destination" pull --quiet --rebase origin main
  else
    case "$destination" in
      "$HOME/cicy-ai"|"$HOME/cicy-ai/knowledge") ;;
      *) echo "refusing unsafe clone destination: $destination" >&2; exit 1 ;;
    esac
    rm -rf "$destination"
    git clone --quiet --branch main --single-branch \
      "https://x-access-token:${token}@${repo#https://}" "$destination"
  fi
  git -C "$destination" remote set-url origin \
    "https://x-access-token:${token}@${repo#https://}"
  chmod 600 "$destination/.git/config"
}

echo "[2/6] restoring private config and knowledge"
# The installer itself runs as root while both persistent repositories are
# intentionally owned by the runtime user cicy. Git 2.35+ rejects that exact
# ownership boundary unless the explicit repositories are trusted. Never use
# safe.directory=*; limit the exception to these two known paths.
for safe_repo in "$HOME/cicy-ai" "$HOME/cicy-ai/knowledge"; do
  git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$safe_repo" \
    || git config --global --add safe.directory "$safe_repo"
done
clone_private_repo "$CONFIG_REPO_NAME" "$HOME/cicy-ai" "${CICY_CONFIG_GH_TOKEN:-}" config
clone_private_repo "$KNOWLEDGE_REPO_NAME" "$HOME/cicy-ai/knowledge" "${CICY_KNOWLEDGE_GH_TOKEN:-}" knowledge
migrate_colab_workspace_paths

echo "[3/6] restoring authentication"
rm -f "$HOME/cicy-ai/db/cft.json"
cloud_device_file="$HOME/cicy-ai/db/cloud-device.json"
if [[ -f "$cloud_device_file" ]]; then
  bound_team="$(jq -r '.team_id // .teamId // empty' "$cloud_device_file" 2>/dev/null || true)"
  if [[ "$RESET_CLOUD_INSTANCE" == "1" || ( -n "$bound_team" && "$bound_team" != "$CICY_TEAM" ) ]]; then
    cloud_device_backup="/content/cloud-device.${bound_team:-unknown}.previous.json"
    mv -f "$cloud_device_file" "$cloud_device_backup"
    if [[ "$RESET_CLOUD_INSTANCE" == "1" ]]; then
      echo "cloud instance reset requested; moved previous identity to $cloud_device_backup"
    else
      echo "cloud identity belongs to team $bound_team; moved it to $cloud_device_backup"
    fi
    echo "cicy-code will register a separate instance for team $CICY_TEAM"
  fi
fi
if [[ -n "${CODEX_AUTH_B64:-}" ]]; then
  printf '%s' "$CODEX_AUTH_B64" | base64 --decode > "$HOME/.codex/auth.json"
  chmod 600 "$HOME/.codex/auth.json"
else
  echo "CODEX_AUTH_B64 not set; keeping existing Codex authentication"
fi
if [[ -n "${CICY_CONFIG_GH_TOKEN:-}" ]]; then
  printf '%s' "$CICY_CONFIG_GH_TOKEN" > "$HOME/.config/cicy-ai/config-gh-token"
  printf '%s' "$CONFIG_REPO_NAME" > "$HOME/.config/cicy-ai/config-gh-repo"
  chmod 600 "$HOME/.config/cicy-ai/config-gh-token"
else
  echo "CICY_CONFIG_GH_TOKEN not set; private config Git sync is disabled"
fi
if [[ -n "${CICY_KNOWLEDGE_GH_TOKEN:-}" ]]; then
  printf '%s' "$CICY_KNOWLEDGE_GH_TOKEN" > "$HOME/.config/cicy-ai/knowledge-gh-token"
  printf '%s' "$KNOWLEDGE_REPO_NAME" > "$HOME/.config/cicy-ai/knowledge-gh-repo"
  chmod 600 "$HOME/.config/cicy-ai/knowledge-gh-token"
else
  echo "CICY_KNOWLEDGE_GH_TOKEN not set; private knowledge Git sync is disabled"
fi

sudo chown -R "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" \
  "$HOME/cicy-ai" "$HOME/.codex" "$HOME/.config" "$HOME/.local" \
  "$HOME/logs" "$HOME/projects" "$NPM_CONFIG_PREFIX"

sudo service cron start >/dev/null
if [[ -s "$HOME/cicy-ai/db/crontab.txt" ]]; then
  sudo -u "$CICY_RUNTIME_USER" crontab "$HOME/cicy-ai/db/crontab.txt"
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

ensure_cicy_code_updater() {
  if [[ ! -s "$CICY_CODE_UPDATER" ]]; then
    echo "installing missing cicy-code updater"
    if [[ -d "$CICY_TOOLS_REPO/.git" ]]; then
      git -C "$CICY_TOOLS_REPO" fetch --quiet --depth 1 origin main
    else
      rm -rf "$CICY_TOOLS_REPO"
      git clone --quiet --filter=blob:none --no-checkout --depth 1 \
        --branch main "$CICY_TOOLS_URL" "$CICY_TOOLS_REPO"
      git -C "$CICY_TOOLS_REPO" fetch --quiet --depth 1 origin main
    fi
    updater_tmp="$CICY_CODE_UPDATER.tmp-$$"
    git -C "$CICY_TOOLS_REPO" show FETCH_HEAD:colab-cicy-code-update.sh > "$updater_tmp"
    chmod 0755 "$updater_tmp"
    mv -f "$updater_tmp" "$CICY_CODE_UPDATER"
  fi
  chmod 0755 "$CICY_CODE_UPDATER"
  sudo -u "$CICY_RUNTIME_USER" test -x "$CICY_CODE_UPDATER" || {
    echo "cicy runtime user cannot execute updater: $CICY_CODE_UPDATER" >&2
    exit 1
  }
}
ensure_cicy_code_updater
echo "[5/6] installing/updating cicy-code (launcher $LAUNCHER_VERSION)"
sudo install -d -m 0755 -o "$CICY_RUNTIME_USER" -g "$CICY_RUNTIME_USER" "$HOME/.local/bin"
sudo touch "$CICY_LOG_FILE" /content/cicy-code.pid
sudo chown "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$CICY_LOG_FILE" /content/cicy-code.pid
print_cicy_startup_error() {
  echo "cicy-code failed to start; latest runtime log ($CICY_LOG_FILE):" >&2
  tail -n 100 "$CICY_LOG_FILE" 2>/dev/null \
    | sed -E \
        -e 's/(token=)[^&[:space:]]+/\1[REDACTED]/g' \
        -e 's/cicy_[A-Za-z0-9._-]+/[REDACTED]/g' \
        -e 's/(Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g' >&2 || true
}
cicy_code_version="$(sudo -u "$CICY_RUNTIME_USER" -H env \
  HOME="$CICY_RUNTIME_HOME" USER="$CICY_RUNTIME_USER" LOGNAME="$CICY_RUNTIME_USER" \
  PATH="$PATH" NPM_CONFIG_PREFIX="$NPM_CONFIG_PREFIX" CICY_CODE_SWITCH=0 \
  "$CICY_CODE_UPDATER" latest | tee /dev/stderr | tail -n 1)"
[[ "$cicy_code_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || {
  echo "cicy-code updater returned an invalid version: $cicy_code_version" >&2
  exit 1
}
echo "[5/6] authenticating cicy-code $cicy_code_version"
if [[ -x "$HOME/.local/cicy-code/$cicy_code_version/bin/cicy-code" ]]; then
  sudo -u "$CICY_RUNTIME_USER" -H env \
    HOME="$CICY_RUNTIME_HOME" USER="$CICY_RUNTIME_USER" LOGNAME="$CICY_RUNTIME_USER" \
    PATH="$PATH" CICY_CLOUD_ORIGIN="$CICY_CLOUD_ORIGIN" \
    "$HOME/.local/cicy-code/$cicy_code_version/bin/cicy-code" \
    --email "$CICY_EMAIL" --team "$CICY_TEAM" --version
elif [[ -s "$HOME/cicy-ai/db/cloud-device.json" ]]; then
  echo "npm launcher unavailable; reusing saved Cloud authentication"
else
  echo "npm launcher unavailable and no saved Cloud authentication exists" >&2
  exit 1
fi
echo "[5/6] switching runtime to cicy-code $cicy_code_version"
switched_version="$(sudo -u "$CICY_RUNTIME_USER" -H env \
  HOME="$CICY_RUNTIME_HOME" USER="$CICY_RUNTIME_USER" LOGNAME="$CICY_RUNTIME_USER" \
  PATH="$PATH" NPM_CONFIG_PREFIX="$NPM_CONFIG_PREFIX" \
  "$CICY_CODE_UPDATER" "$cicy_code_version" | tee /dev/stderr | tail -n 1)"
[[ "$switched_version" == "$cicy_code_version" ]] || {
  echo "cicy-code switch failed: expected $cicy_code_version, got $switched_version" >&2
  exit 1
}
echo "[5/6] restarting cicy-code"
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
echo "[5/6] starting cicy-code $cicy_code_version via $HOME/.local/bin/cicy-code"
unset CICY_PREVIEW_DIST
if [[ "$ENABLE_PREVIEW" == "1" ]]; then
  if [[ -d "$PREVIEW_DIST" ]]; then
    export CICY_PREVIEW_DIST="$PREVIEW_DIST"
    echo "[preview] CICY_PREVIEW_DIST=$CICY_PREVIEW_DIST"
  else
    echo "[preview] skipped; directory does not exist: $PREVIEW_DIST"
  fi
fi
runtime_args_file="$HOME/cicy-ai/runtime/cicy-code.args"
runtime_env_file="$HOME/cicy-ai/runtime/cicy-code.env"
mkdir -p "$(dirname "$runtime_args_file")"
printf '%s\0' --cft > "$runtime_args_file"
{
  printf 'CICY_EMAIL=%s\0' "$CICY_EMAIL"
  printf 'CICY_TEAM=%s\0' "$CICY_TEAM"
  printf 'CICY_CLOUD_ORIGIN=%s\0' "$CICY_CLOUD_ORIGIN"
  printf 'CICY_LOG_FILE=%s\0' "$CICY_LOG_FILE"
  [[ -n "${CICY_PREVIEW_DIST:-}" ]] && printf 'CICY_PREVIEW_DIST=%s\0' "$CICY_PREVIEW_DIST"
} > "$runtime_env_file"
chown "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$runtime_args_file"
chown "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$runtime_env_file"
chmod 0600 "$runtime_args_file" "$runtime_env_file"
preview_runtime_env=()
if [[ -n "${CICY_PREVIEW_DIST:-}" ]]; then
  preview_runtime_env+=("CICY_PREVIEW_DIST=$CICY_PREVIEW_DIST")
fi
sudo -u "$CICY_RUNTIME_USER" -H env \
  HOME="$CICY_RUNTIME_HOME" USER="$CICY_RUNTIME_USER" LOGNAME="$CICY_RUNTIME_USER" \
  DISPLAY="$DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  NPM_CONFIG_PREFIX="$NPM_CONFIG_PREFIX" PATH="$PATH" \
  CICY_EMAIL="$CICY_EMAIL" CICY_TEAM="$CICY_TEAM" \
  CICY_CLOUD_ORIGIN="$CICY_CLOUD_ORIGIN" CICY_LOG_FILE="$CICY_LOG_FILE" \
  "${preview_runtime_env[@]}" \
  bash -c 'saved_args=(); while IFS= read -r -d "" argument; do saved_args+=("$argument"); done < "$1"; nohup stdbuf -oL -eL "$HOME/.local/bin/cicy-code" "${saved_args[@]}" > "$CICY_LOG_FILE" 2>&1 < /dev/null & echo $!' \
  _ "$runtime_args_file" \
  > /content/cicy-code.pid

cicy_pid="$(cat /content/cicy-code.pid)"
for _ in $(seq 1 600); do
  pgrep -u "$CICY_RUNTIME_USER" -x cicy-code >/dev/null 2>&1 && break
  kill -0 "$cicy_pid" 2>/dev/null || break
  sleep 0.5
done
if ! pgrep -u "$CICY_RUNTIME_USER" -x cicy-code >/dev/null 2>&1; then
  if kill -0 "$cicy_pid" 2>/dev/null; then
    echo "cicy-code launcher is still running (pid $cicy_pid), but the server process did not appear" >&2
  else
    echo "cicy-code launcher exited before the server became ready (pid $cicy_pid)" >&2
  fi
  print_cicy_startup_error
  exit 1
fi
sudo -u "$CICY_RUNTIME_USER" sudo -n true
echo "cicy-code runtime user=$CICY_RUNTIME_USER home=$CICY_RUNTIME_HOME"
echo "[6/6] waiting for Quick Tunnel (pid $cicy_pid)"
resolve_fixed_domain() {
  local agent_command
  agent_command="$(command -v cicy-agent 2>/dev/null || true)"
  if [[ -z "$agent_command" ]]; then
    agent_command="$(find "$HOME/cicy-ai/skills" -path '*/cicy-agent/bin/cicy-agent' -type f -perm -u+x -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$agent_command" ]] || return 0
  timeout 10 "$agent_command" --json whoami 2>/dev/null \
    | jq -r '.data.proxyHost // empty' 2>/dev/null \
    | head -n 1
}

for _ in $(seq 1 120); do
  if ! kill -0 "$cicy_pid" 2>/dev/null; then
    print_cicy_startup_error
    exit 1
  fi
  cft_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$CICY_LOG_FILE" | tail -n 1 || true)"
  api_token="$(jq -r '.api_token // empty' "$HOME/cicy-ai/global.json" 2>/dev/null || true)"
  if [[ -n "$cft_url" && -n "$api_token" ]]; then
    encoded_token="$(jq -rn --arg token "$api_token" '$token|@uri')"
    printf '%s\n' "installed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > /content/cicy-code.installed
    fixed_host=""
    echo "waiting for fixed cicy-cloud domain..."
    for _ in $(seq 1 60); do
      fixed_host="$(resolve_fixed_domain || true)"
      [[ -n "$fixed_host" ]] && break
      sleep 2
    done
    echo "TOKEN=$api_token"
    echo "TUNNEL_URL=${cft_url%/}"
    if [[ -n "$fixed_host" ]]; then
      echo "FIXED_DOMAIN=https://$fixed_host"
      echo "FIXED_OPEN_URL=https://$fixed_host/?token=$encoded_token"
    else
      echo "FIXED_DOMAIN=pending"
    fi
    echo "OPEN_URL=${cft_url%/}/?token=$encoded_token"
    exit 0
  fi
  if (( _ % 5 == 0 )); then
    echo "  waiting $((_ * 2))s — latest log:"
    tail -n 5 "$CICY_LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
  fi
  sleep 2
done

echo "cicy-code is running, but the Quick Tunnel URL is not ready" >&2
echo "check: $CICY_LOG_FILE" >&2
exit 2
