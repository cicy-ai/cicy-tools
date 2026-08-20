#!/usr/bin/env bash
set -euo pipefail

VERSION=2.3.1
MODE="${1:-status}"
TOOLS_REPO_URL="${CICY_TOOLS_REPO_URL:-https://github.com/cicy-ai/cicy-tools.git}"
TOOLS_DIR="${CICY_TOOLS_DIR:-${HOME:?HOME is required}/projects/cicy-tools}"

sync_tools_repo() {
  local tools_parent current_uid current_gid
  command -v git >/dev/null 2>&1 || {
    echo "cloudshell keepalive: git is required to install cicy-tools" >&2
    return 1
  }
  [[ -n "$TOOLS_DIR" && "$TOOLS_DIR" != / && "$TOOLS_DIR" != "$HOME" ]] || {
    echo "cloudshell keepalive: unsafe tools directory: $TOOLS_DIR" >&2
    return 1
  }
  tools_parent="$(dirname "$TOOLS_DIR")"
  current_uid="$(id -u)"
  current_gid="$(id -g)"
  mkdir -p "$tools_parent" 2>/dev/null || true
  if [[ ! -d "$tools_parent" || ! -w "$tools_parent" ]]; then
    case "$tools_parent" in
      "$HOME"/*)
        command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || {
          echo "cloudshell keepalive: $tools_parent is not writable and passwordless sudo is unavailable" >&2
          return 1
        }
        sudo install -d -m 0755 -o "$current_uid" -g "$current_gid" "$tools_parent"
        sudo chown "$current_uid:$current_gid" "$tools_parent"
        echo "repaired=tools-parent owner=$(id -un):$(id -gn) path=$tools_parent"
        ;;
      *)
        echo "cloudshell keepalive: tools parent is not writable: $tools_parent" >&2
        return 1
        ;;
    esac
  fi
  if [[ -d "$TOOLS_DIR/.git" ]] && [[ -n "$(find "$TOOLS_DIR" \! -user "$current_uid" -print -quit 2>/dev/null)" ]]; then
    case "$TOOLS_DIR" in
      "$HOME"/*)
        command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || {
          echo "cloudshell keepalive: $TOOLS_DIR has foreign ownership and passwordless sudo is unavailable" >&2
          return 1
        }
        sudo chown -R "$current_uid:$current_gid" "$TOOLS_DIR"
        echo "repaired=tools-repo owner=$(id -un):$(id -gn) path=$TOOLS_DIR"
        ;;
    esac
  fi
  if [[ -d "$TOOLS_DIR/.git" ]]; then
    git -C "$TOOLS_DIR" remote set-url origin "$TOOLS_REPO_URL"
    git -C "$TOOLS_DIR" pull --ff-only origin main
    echo "updated=cicy-tools path=$TOOLS_DIR commit=$(git -C "$TOOLS_DIR" rev-parse --short HEAD)"
    return 0
  fi
  if [[ -e "$TOOLS_DIR" && -n "$(find "$TOOLS_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "cloudshell keepalive: refusing to replace non-git directory: $TOOLS_DIR" >&2
    return 1
  fi
  git clone --depth 1 --branch main "$TOOLS_REPO_URL" "$TOOLS_DIR"
  echo "cloned=cicy-tools path=$TOOLS_DIR commit=$(git -C "$TOOLS_DIR" rev-parse --short HEAD)"
}

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

if [[ "$MODE" != clean ]]; then
  prepare_install_space
fi

disk_usage() {
  local path="$1"
  df -h "$path" 2>/dev/null | awk 'NR==2 {print "used=" $3 " total=" $2 " available=" $4 " usage=" $5}'
}

clean_cache_path() {
  local path="$1" size
  case "$path" in
    "$HOME"/*|/home/cicy/*) ;;
    *) echo "skip unsafe cleanup target: $path" >&2; return 1 ;;
  esac
  [[ "$path" != "$HOME" && "$path" != /home/cicy ]] || {
    echo "skip unsafe cleanup root: $path" >&2
    return 1
  }
  [[ -e "$path" ]] || return 0
  size="$(sudo du -sh "$path" 2>/dev/null | awk '{print $1}' || true)"
  sudo rm -rf -- "$path"
  echo "removed=${path} size=${size:-unknown}"
}

trim_log_file() {
  local path="$1" bytes before after tmp
  case "$path" in
    /home/cicy/logs/*) ;;
    *) echo "skip unsafe log target: $path" >&2; return 1 ;;
  esac
  [[ -f "$path" ]] || return 0
  bytes="$(sudo stat -c '%s' "$path" 2>/dev/null || printf '0')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  (( bytes > 20971520 )) || return 0
  before="$(sudo du -h "$path" 2>/dev/null | awk '{print $1}' || true)"
  tmp="$(sudo mktemp "/home/cicy/logs/.cicy-log-tail.XXXXXX")"
  sudo tail -c 20971520 "$path" | sudo tee "$tmp" >/dev/null
  sudo sh -c 'cat "$2" > "$1"' sh "$path" "$tmp"
  sudo rm -f -- "$tmp"
  after="$(sudo du -h "$path" 2>/dev/null | awk '{print $1}' || true)"
  echo "trimmed=${path} before=${before:-unknown} after=${after:-unknown}"
}

deep_clean() {
  local base path current_link current_process binary
  echo "before host_home=$HOME $(disk_usage "$HOME")"
  if [[ -d /home/cicy ]]; then
    echo "before runtime_home=/home/cicy $(disk_usage /home/cicy)"
  fi

  for base in "$HOME" /home/cicy; do
    [[ -d "$base" ]] || continue
    for path in \
      "$base/.npm/_cacache" \
      "$base/.npm/_logs" \
      "$base/.npm/_npx" \
      "$base/.nvm/.cache" \
      "$base/.cache/node-gyp" \
      "$base/.cache/pip" \
      "$base/.cache/pnpm" \
      "$base/.cache/uv" \
      "$base/.cache/yarn" \
      "$base/.cache/go-build" \
      "$base/.cache/golangci-lint" \
      "$base/.cache/typescript" \
      "$base/.cache/chromium" \
      "$base/.local/share/Trash/files" \
      "$base/.local/share/Trash/info" \
      "$base/.config/gcloud/logs" \
      "$base/.vscode-server/data/logs" \
      "$base/.vscode-server/data/CachedExtensionVSIXs"; do
      clean_cache_path "$path"
    done
  done

  current_link="$(readlink -f /home/cicy/.local/bin/cicy-code 2>/dev/null || true)"
  current_process="$(pgrep -u cicy -f 'cicy-code' 2>/dev/null | head -n1 || true)"
  if [[ -n "$current_process" ]]; then
    current_process="$(readlink -f "/proc/$current_process/exe" 2>/dev/null || true)"
  fi
  for binary in /home/cicy/.local/bin/cicy-code-*; do
    [[ -e "$binary" ]] || continue
    [[ "$binary" == "$current_link" || "$binary" == "$current_process" ]] && continue
    clean_cache_path "$binary"
  done

  if [[ -d /home/cicy/logs ]]; then
    while IFS= read -r -d '' path; do
      trim_log_file "$path"
    done < <(sudo find /home/cicy/logs -xdev -type f -name '*.log' -size +20M -print0 2>/dev/null)
  fi

  if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo apt-get clean
    echo "cleaned=apt-cache"
  fi

  echo "after host_home=$HOME $(disk_usage "$HOME")"
  if [[ -d /home/cicy ]]; then
    echo "after runtime_home=/home/cicy $(disk_usage /home/cicy)"
  fi
  echo "largest paths under $HOME:"
  sudo du -xhd1 "$HOME" 2>/dev/null | sort -h | tail -n 12 || true
  if [[ /home/cicy != "$HOME" && -d /home/cicy ]]; then
    echo "largest paths under /home/cicy:"
    sudo du -xhd1 /home/cicy 2>/dev/null | sort -h | tail -n 12 || true
  fi
}

if [[ "$MODE" == clean ]]; then
  deep_clean
  exit 0
fi

install_launcher() {
  local target="${HOME:?HOME is required}/.local/bin/cicy-cloudshell"
  [[ -n "$target" ]] || { echo "cloudshell keepalive: empty launcher path" >&2; return 1; }
  [[ -d "$TOOLS_DIR/.git" ]] || sync_tools_repo >&2
  mkdir -p "$(dirname "$target")"
  chmod +x "$TOOLS_DIR/cicy-cloudshell.sh"
  ln -sfn "$TOOLS_DIR/cicy-cloudshell.sh" "$target"
  printf '%s' "$target"
}

if [[ "$MODE" == install ]]; then
  sync_tools_repo
  target="${HOME:?HOME is required}/.local/bin/cicytools"
  [[ -n "$target" ]] || { echo "cloudshell keepalive: empty install path" >&2; exit 1; }
  mkdir -p "$(dirname "$target")"
  chmod +x "$TOOLS_DIR/cloudshell-keepalive.sh"
  ln -sfn "$TOOLS_DIR/cloudshell-keepalive.sh" "$target"
  launcher="$(install_launcher)"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo ln -sf "$target" /usr/local/bin/cicytools
    sudo ln -sf "$launcher" /usr/local/bin/cicy-cloudshell
  fi
  echo "installed=cicytools path=$target"
  echo "installed=cicy-cloudshell path=$launcher"
  echo "source=git repo=$TOOLS_REPO_URL path=$TOOLS_DIR"
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
