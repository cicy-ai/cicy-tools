#!/usr/bin/env bash
set -euo pipefail

LAUNCHER_VERSION=1.7.0
CICY_CODE_UPDATER="${CICY_CODE_UPDATER:-/content/colab-cicy-code-update.sh}"
CICY_TOOLS_REPO="${CICY_TOOLS_REPO:-/content/cicy-tools-source}"
CICY_TOOLS_URL="${CICY_TOOLS_URL:-https://github.com/cicy-ai/cicy-tools.git}"
CONFIG_REPO_NAME="${CICY_CONFIG_GH_REPO:-}"
KNOWLEDGE_REPO_NAME="${CICY_KNOWLEDGE_GH_REPO:-}"
CICY_TEAM="${CICY_TEAM:-colab_w3c}"
CICY_LOG_FILE="${CICY_CODE_LOG:-/content/cicy-code.log}"
CICY_HUB_ORIGIN="${CICY_HUB_ORIGIN:-https://ws.cicy-ai.com}"
CICY_HUB_ORIGIN="${CICY_HUB_ORIGIN%/}"
CONTENT_DIR="${CONTENT_DIR:-/content}"
HUB_HOST_FILE="$CONTENT_DIR/cicy-hub-host"
CICY_PORT="${CICY_PORT:-${PORT:-8008}}"
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

for name in CICY_EMAIL CICY_HUB_TOKEN CICY_PROVIDERS_JSON; do
  if [[ -z "${!name:-}" ]]; then
    secret_value="$(read_colab_secret "$name")"
    if [[ -n "$secret_value" ]]; then
      printf -v "$name" '%s' "$secret_value"
      export "$name"
    fi
  fi
done
if [[ -z "${CICY_EMAIL:-}" ]]; then
  echo "missing Colab Secret or environment variable: CICY_EMAIL" >&2
  exit 1
fi
[[ -n "${CICY_HUB_TOKEN:-}" ]] || echo "CICY_HUB_TOKEN not set; a hub credential restored from the config repo must already be valid"
[[ "$CICY_HUB_ORIGIN" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || {
  echo "invalid CICY_HUB_ORIGIN: $CICY_HUB_ORIGIN" >&2
  exit 2
}

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
# The daemon reads mode/origin from cloud-device.json (written by
# enroll_hub_instance below); this env only keeps older launchers from
# defaulting to cicy-cloud.
export CICY_CLOUD_ORIGIN="$CICY_HUB_ORIGIN"
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
  cron sqlite3 openssh-server >/dev/null

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

# Older installers ran the config sync as root, which installed the cicy
# crontab into ROOT's crontab too (same jobs, HOME=/home/cicy). Two syncs a
# minute then fought over .git ownership. Remove that duplicate when found;
# the runtime user's crontab (installed above) is the only one that should run.
remove_stale_root_crontab() {
  local root_tab
  root_tab="$(sudo crontab -l 2>/dev/null || true)"
  if [[ "$root_tab" == *"$HOME/cicy-ai/bin/sync-cicy-ai-config.sh"* ]]; then
    echo "removing stale root crontab (duplicate of the $CICY_RUNTIME_USER crontab)"
    sudo crontab -r
  fi
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
      # This installer runs as root (Colab) with HOME=/home/cicy. Sync as the
      # runtime user, never as root: a root run leaves root-owned .git files
      # the user's cron cannot touch and installs the sync into ROOT's
      # crontab as a duplicate. Hand the checkout to the user first.
      sudo chown -R "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$destination"
      sudo -u "$CICY_RUNTIME_USER" -H env HOME="$HOME" PATH="$PATH" \
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
    if [[ -d "$destination" && -n "$(ls -A "$destination" 2>/dev/null)" ]]; then
      # A runtime that is already alive (or a config repo attached for the
      # first time) has live state here — hub credential, global.json,
      # data.db, histories. Never wipe it: clone beside it, adopt the
      # checkout (.git + tracked files, existing local files win), and let
      # the sync below push the merged state as the repository's next commit.
      echo "adopting existing $destination into the $kind repository (local files kept)"
      rm -rf "$destination.adopt-tmp"
      git clone --quiet --branch main --single-branch \
        "https://x-access-token:${token}@${repo#https://}" "$destination.adopt-tmp"
      cp -rn "$destination.adopt-tmp/." "$destination/"
      # cicy-code creates empty placeholders (db/crontab.txt …) on first start;
      # a tracked file with content must not lose to an empty local one.
      while IFS= read -r tracked; do
        if [[ -s "$destination.adopt-tmp/$tracked" && -e "$destination/$tracked" && ! -s "$destination/$tracked" ]]; then
          cp -f "$destination.adopt-tmp/$tracked" "$destination/$tracked"
        fi
      done < <(git -C "$destination.adopt-tmp" ls-files)
      rm -rf "$destination.adopt-tmp"
      if [[ "$destination" == "$HOME/cicy-ai" && -x "$destination/bin/sync-cicy-ai-config.sh" ]]; then
        sudo chown -R "$CICY_RUNTIME_USER:$CICY_RUNTIME_USER" "$destination"
        sudo -u "$CICY_RUNTIME_USER" -H env HOME="$HOME" PATH="$PATH" \
          "$destination/bin/sync-cicy-ai-config.sh" || echo "initial config sync failed; the cron sync will retry" >&2
      fi
    else
      rm -rf "$destination"
      git clone --quiet --branch main --single-branch \
        "https://x-access-token:${token}@${repo#https://}" "$destination"
    fi
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
# Without a config token nothing above creates $HOME/cicy-ai, yet the chown
# below (and cicy-code itself) expects the directory. Create it so a run
# without private repositories still reaches the launch step.
mkdir -p "$HOME/cicy-ai/db"
migrate_colab_workspace_paths

# enroll_hub_instance joins CiCy Hub directly (no cicy-cloud): a sponsor token
# of an instance the same owner already runs enrols this Colab through
# POST /api/enroll, and the returned credential is written as a hub-mode
# cloud-device.json BEFORE cicy-code starts, so the daemon boots straight onto
# the hub WebSocket and its built-in frpc. The instance id is reused across
# runs (same hub hostname) unless --reset-instance or a team change.
enroll_hub_instance() {
  local device_file="$1" team="$2" origin="$3" token="$4" instance_id="" bound_team="" bound_mode="" response="" new_token="" owner="" proxy_host="" saved_token="" tmp
  if [[ -f "$device_file" ]]; then
    bound_team="$(jq -r '.team_id // .teamId // empty' "$device_file" 2>/dev/null || true)"
    bound_mode="$(jq -r '.mode // empty' "$device_file" 2>/dev/null || true)"
    instance_id="$(jq -r '.instance_id // .instanceId // empty' "$device_file" 2>/dev/null || true)"
    if [[ "$RESET_CLOUD_INSTANCE" == "1" || "$bound_mode" != "hub" || ( -n "$bound_team" && "$bound_team" != "$team" ) ]]; then
      mv -f "$device_file" "$CONTENT_DIR/cloud-device.${bound_team:-unknown}.previous.json"
      echo "previous identity (team ${bound_team:-unknown}, mode ${bound_mode:-cloud}) moved aside; enrolling a fresh hub instance for team $team"
      instance_id=""
    else
      # A hub credential restored from the config repo is reused as long as the
      # hub still accepts it — same instance id, same hostname, no sponsor needed.
      saved_token="$(jq -r '.token // empty' "$device_file" 2>/dev/null || true)"
      if [[ -n "$saved_token" ]] && response="$(curl -fsS --max-time 20 "$origin/api/instances" -H "Authorization: Bearer $saved_token" 2>/dev/null)"; then
        proxy_host="$(jq -r --arg id "$instance_id" '.instances[]? | select(.instanceId==$id) | .proxyHost // empty' <<<"$response" | head -n 1)"
        [[ -n "$proxy_host" ]] || proxy_host="$(jq -r '.proxyHost // empty' <<<"$response")"
        if [[ -n "$proxy_host" ]]; then
          printf '%s' "$proxy_host" > "$HUB_HOST_FILE"
          echo "reusing saved hub credential: $proxy_host (instance ${instance_id:0:12}…)"
          return 0
        fi
      fi
      echo "saved hub credential is no longer accepted; re-enrolling"
    fi
  fi
  [[ -n "$token" ]] || {
    echo "no valid hub credential and CICY_HUB_TOKEN is not set; cannot enrol in CiCy Hub" >&2
    return 1
  }
  if [[ ! "$instance_id" =~ ^code-[A-Za-z0-9_-]{16,96}$ ]]; then
    instance_id="code-$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  response="$(curl -fsS --max-time 30 -X POST "$origin/api/enroll" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg id "$instance_id" --arg name "$team" '{instanceId:$id, name:$name, platform:"linux/colab"}')" 2>/dev/null)" || {
    echo "hub enrol failed at $origin/api/enroll (check CICY_HUB_TOKEN; name_taken means team $team is used by another instance)" >&2
    return 1
  }
  new_token="$(jq -r '.token // empty' <<<"$response")"
  owner="$(jq -r '.owner // empty' <<<"$response")"
  proxy_host="$(jq -r '.proxyHost // empty' <<<"$response")"
  [[ -n "$new_token" && -n "$proxy_host" ]] || {
    echo "hub enrol returned no credential: $(jq -c 'del(.token)' <<<"$response" 2>/dev/null || echo '?')" >&2
    return 1
  }
  mkdir -p "$(dirname "$device_file")"
  tmp="$device_file.tmp"
  jq -n --arg email "${owner:-$CICY_EMAIL}" --arg id "$instance_id" --arg team "$team" \
    --arg token "$new_token" --arg origin "$origin" \
    '{email:$email, instance_id:$id, team_id:$team, token:$token, cloud_origin:$origin, mode:"hub", frp:true, updated_at:(now|todate)}' > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$device_file"
  printf '%s' "$proxy_host" > "$HUB_HOST_FILE"
  echo "enrolled in CiCy Hub as $proxy_host (instance ${instance_id:0:12}…, owner ${owner:-?})"
}

echo "[3/6] restoring authentication"
rm -f "$HOME/cicy-ai/db/cft.json"
enroll_hub_instance "$HOME/cicy-ai/db/cloud-device.json" "$CICY_TEAM" "$CICY_HUB_ORIGIN" "${CICY_HUB_TOKEN:-}"
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
remove_stale_root_crontab

# sshd on :22 is what the built-in frpc forwards the hub's SSH port to
# (cicy-code asks for local_ssh=22); keys come from the hub's ssh-trust sync,
# so password logins stay off. Colab's own sshd (if any) sits on 2222.
echo "[4/6] starting sshd for the hub SSH port"
sudo sed -i -E 's/^#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -qE '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config >/dev/null
sudo mkdir -p /run/sshd
sudo service ssh restart >/dev/null 2>&1 || sudo service ssh start >/dev/null 2>&1 || echo "sshd did not start; hub SSH will not work" >&2

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
echo "[5/6] cicy-code $cicy_code_version will start with the hub credential (no cicy-cloud login)"
[[ -s "$HOME/cicy-ai/db/cloud-device.json" ]] || {
  echo "hub credential missing after enrol" >&2
  exit 1
}
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
: > "$runtime_args_file"  # no --cft: the hub domain (frp) is the only entry point
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
echo "[6/6] waiting for the hub domain (pid $cicy_pid)"
# restore_providers applies an optional CICY_PROVIDERS_JSON Colab Secret:
# base64 of {"items":[<provider entries as in global.json>], "defaults":{...}}
# through the daemon's providers API, so a recycled runtime gets its model
# keys back without anyone typing them.
restore_providers() {
  local api_token="$1" payload="" key="" status=""
  [[ -n "${CICY_PROVIDERS_JSON:-}" ]] || return 0
  payload="$(printf '%s' "$CICY_PROVIDERS_JSON" | base64 --decode 2>/dev/null || true)"
  jq -e '.items | type == "array"' <<<"$payload" >/dev/null 2>&1 || {
    echo "CICY_PROVIDERS_JSON is not base64 JSON with an items array; skipping provider restore" >&2
    return 0
  }
  while IFS= read -r item; do
    key="$(jq -r '.key // empty' <<<"$item")"
    [[ -n "$key" ]] || continue
    status="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 -X PUT "http://127.0.0.1:$CICY_PORT/api/providers/$key" \
      -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' --data-binary "$item")"
    if [[ "$status" == "404" ]]; then
      status="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 -X POST "http://127.0.0.1:$CICY_PORT/api/providers" \
        -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' --data-binary "$item")"
    fi
    echo "provider $key: HTTP $status"
  done < <(jq -c '.items[]' <<<"$payload")
  if jq -e '.defaults | type == "object"' <<<"$payload" >/dev/null 2>&1; then
    status="$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 -X PUT "http://127.0.0.1:$CICY_PORT/api/providers/defaults" \
      -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' --data-binary "$(jq -c '.defaults' <<<"$payload")")"
    echo "provider defaults: HTTP $status"
  fi
}

hub_domain_live() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$1/" 2>/dev/null || true)"
  [[ "$code" == "200" || "$code" == "401" || "$code" == "302" ]]
}

hub_host="$(cat "$HUB_HOST_FILE" 2>/dev/null || true)"
for _ in $(seq 1 120); do
  if ! kill -0 "$cicy_pid" 2>/dev/null; then
    print_cicy_startup_error
    exit 1
  fi
  api_token="$(jq -r '.api_token // empty' "$HOME/cicy-ai/global.json" 2>/dev/null || true)"
  if [[ -n "$api_token" && -n "$hub_host" ]] && hub_domain_live "$hub_host"; then
    printf '%s\n' "installed_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > /content/cicy-code.installed
    restore_providers "$api_token"
    # Hub hostnames do not take ?token=; the instance mints a one-time
    # signed-in link for itself through the hub's gateway grant.
    open_url="$(curl -s --noproxy '*' --max-time 20 -X POST "http://127.0.0.1:$CICY_PORT/api/im/cicy-cloud/open" \
      -H "Authorization: Bearer $api_token" -H 'Content-Type: application/json' -d '{}' | jq -r '.url // empty' 2>/dev/null || true)"
    echo "TOKEN=$api_token"
    echo "HUB_DOMAIN=https://$hub_host"
    echo "AGENT_ADDRESS=$CICY_TEAM.<agent>   # cicy-agent msg $CICY_TEAM.w-1001 …"
    if [[ -n "$open_url" ]]; then
      echo "OPEN_URL=$open_url   # one-time signed-in link; the desktop CiCy Hub list mints fresh ones"
    fi
    exit 0
  fi
  if (( _ % 5 == 0 )); then
    echo "  waiting $((_ * 2))s — latest log:"
    tail -n 5 "$CICY_LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
  fi
  sleep 2
done

echo "cicy-code is running, but the hub domain ${hub_host:-?} is not live yet (frp); check the log" >&2
echo "check: $CICY_LOG_FILE" >&2
exit 2
