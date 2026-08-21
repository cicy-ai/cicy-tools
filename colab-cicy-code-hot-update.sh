#!/usr/bin/env bash
set -euo pipefail

RUNTIME_USER="${CICY_RUNTIME_USER:-cicy}"
RUNTIME_HOME="${CICY_RUNTIME_HOME:-/home/cicy}"
UPDATER="${CICY_CODE_UPDATER:-/content/colab-cicy-code-update.sh}"
LOG_FILE="${CICY_CODE_LOG:-/content/cicy-code.log}"
PID_FILE="${CICY_CODE_PID_FILE:-/content/cicy-code.pid}"
ARGS_FILE="${CICY_CODE_ARGS_FILE:-$RUNTIME_HOME/cicy-ai/runtime/cicy-code.args}"
ENV_FILE="${CICY_CODE_ENV_FILE:-$RUNTIME_HOME/cicy-ai/runtime/cicy-code.env}"
PREVIEW_DIST="${CICY_PREVIEW_DIST_PATH:-$RUNTIME_HOME/projects/cicy-code/app/dist}"
PROC_ROOT="${CICY_PROC_ROOT:-/proc}"
want=latest
restart_current=0
enable_preview=0

is_cicy_code_pid() {
  local pid="$1" executable=""
  [[ "$pid" =~ ^[0-9]+$ && -r "$PROC_ROOT/$pid/cmdline" ]] || return 1
  IFS= read -r -d '' executable < "$PROC_ROOT/$pid/cmdline" || return 1
  [[ "$(basename "$executable")" == cicy-code* ]]
}

capture_process_argv() {
  local pid="$1" destination="$2" argument temporary i
  local -a process_argv=()
  is_cicy_code_pid "$pid" || return 1
  while IFS= read -r -d '' argument; do
    process_argv+=("$argument")
  done < "$PROC_ROOT/$pid/cmdline"
  [[ ${#process_argv[@]} -gt 0 ]] || return 1

  temporary="$destination.tmp.$$"
  : > "$temporary"
  for ((i=1; i<${#process_argv[@]}; i++)); do
    printf '%s\0' "${process_argv[i]}" >> "$temporary"
  done
  chmod 0600 "$temporary"
  mv -f "$temporary" "$destination"
}

find_cicy_code_pid() {
  local candidate=""
  if [[ -s "$PID_FILE" ]]; then
    candidate="$(cat "$PID_FILE" 2>/dev/null || true)"
    if is_cicy_code_pid "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  while IFS= read -r candidate; do
    if is_cicy_code_pid "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(pgrep -u "$RUNTIME_USER" -x cicy-code 2>/dev/null || true)
  return 1
}

if [[ "${1:-}" == --capture-argv ]]; then
  [[ $# -eq 3 ]] || {
    echo "usage: colab-cicy-code-hot-update.sh --capture-argv PID OUTPUT" >&2
    exit 2
  }
  capture_process_argv "$2" "$3"
  exit $?
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-current)
      restart_current=1
      shift
      ;;
    --preview)
      enable_preview=1
      shift
      ;;
    --help|-h)
      echo "usage: colab-cicy-code-hot-update.sh [VERSION|latest] [--restart-current] [--preview]"
      exit 0
      ;;
    --*)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
    *)
      want="$1"
      shift
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "run this Colab updater as root" >&2; exit 1; }
id -u "$RUNTIME_USER" >/dev/null 2>&1 || { echo "runtime user does not exist: $RUNTIME_USER" >&2; exit 1; }
if [[ "$restart_current" != "1" ]]; then
  [[ -s "$UPDATER" ]] || { echo "missing updater: $UPDATER (run the keepalive cell first)" >&2; exit 1; }
  chmod 0755 "$UPDATER"
fi
install -d -m 0755 -o "$RUNTIME_USER" -g "$RUNTIME_USER" "$RUNTIME_HOME/.local/bin"
install -d -m 0755 -o "$RUNTIME_USER" -g "$RUNTIME_USER" "$(dirname "$ARGS_FILE")"
touch "$LOG_FILE" "$PID_FILE"
chown "$RUNTIME_USER:$RUNTIME_USER" "$LOG_FILE" "$PID_FILE"

current_version=""
if [[ -x "$RUNTIME_HOME/.local/bin/cicy-code" ]]; then
  current_version="$(sudo -u "$RUNTIME_USER" -H \
    "$RUNTIME_HOME/.local/bin/cicy-code" --version 2>/dev/null \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
fi
if [[ "$restart_current" == "1" ]]; then
  [[ -n "$current_version" ]] || {
    echo "installed cicy-code runtime is missing: $RUNTIME_HOME/.local/bin/cicy-code" >&2
    exit 1
  }
  version="$current_version"
  echo "[restart] using installed cicy-code $version; npm install and version switch skipped"
else
  echo "[1/3] staging and verifying cicy-code $want"
  version="$(sudo -u "$RUNTIME_USER" -H env \
    HOME="$RUNTIME_HOME" USER="$RUNTIME_USER" LOGNAME="$RUNTIME_USER" \
    PATH="$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    CICY_CODE_SWITCH=0 "$UPDATER" "$want" | tee /dev/stderr | tail -n 1)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "invalid staged version: $version" >&2; exit 1; }

  if [[ -n "$current_version" ]]; then
    newest="$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -n 1)"
    if [[ "$current_version" == "$version" || "$newest" == "$current_version" ]]; then
      echo "already up to date: current=$current_version target=$version (no switch, no restart)"
      exit 0
    fi
  fi

fi

old_pid="$(find_cicy_code_pid || true)"

# Preserve the exact argv of the running native process. The executable itself
# is replaced by the stable symlink; every argument after argv[0] is retained.
if [[ -n "$old_pid" ]]; then
  capture_process_argv "$old_pid" "$ARGS_FILE" || {
    echo "could not capture argv from cicy-code pid $old_pid; update aborted before switch" >&2
    exit 1
  }
  chown "$RUNTIME_USER:$RUNTIME_USER" "$ARGS_FILE"
fi

if [[ "$restart_current" != "1" ]]; then
  echo "[2/3] switching symlink to cicy-code $version"
  switched="$(sudo -u "$RUNTIME_USER" -H env \
    HOME="$RUNTIME_HOME" USER="$RUNTIME_USER" LOGNAME="$RUNTIME_USER" \
    PATH="$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
    "$UPDATER" "$version" | tee /dev/stderr | tail -n 1)"
  [[ "$switched" == "$version" ]] || { echo "runtime switch failed" >&2; exit 1; }
fi

# The Colab launcher supplies the instance identity through environment
# variables, not argv. Preserve the required non-secret runtime values as well
# or a hot restart can come back as a different/offline Cloud instance while
# the native process itself still looks healthy.
declare -A saved_env=()
read_runtime_env() {
  local source_file="$1" entry key value
  [[ -r "$source_file" ]] || return 0
  while IFS= read -r -d '' entry; do
    key="${entry%%=*}"
    value="${entry#*=}"
    case "$key" in
      CICY_EMAIL|CICY_TEAM|CICY_CLOUD_ORIGIN|CICY_LOG_FILE|CICY_PREVIEW_DIST)
        saved_env["$key"]="$value"
        ;;
    esac
  done < "$source_file"
}
read_runtime_env "$ENV_FILE"
if [[ -n "$old_pid" && -r "$PROC_ROOT/$old_pid/environ" ]]; then
  read_runtime_env "$PROC_ROOT/$old_pid/environ"
fi
for key in CICY_EMAIL CICY_TEAM CICY_CLOUD_ORIGIN CICY_LOG_FILE; do
  if [[ ! -v "saved_env[$key]" && -n "${!key:-}" ]]; then
    saved_env["$key"]="${!key}"
  fi
done
if [[ "$enable_preview" == "1" ]]; then
  if [[ -d "$PREVIEW_DIST" ]]; then
    saved_env[CICY_PREVIEW_DIST]="$PREVIEW_DIST"
    echo "[preview] CICY_PREVIEW_DIST=$PREVIEW_DIST"
  else
    unset 'saved_env[CICY_PREVIEW_DIST]'
    echo "[preview] skipped; directory does not exist: $PREVIEW_DIST"
  fi
fi
if [[ ${#saved_env[@]} -gt 0 ]]; then
  : > "$ENV_FILE.tmp"
  for key in CICY_EMAIL CICY_TEAM CICY_CLOUD_ORIGIN CICY_LOG_FILE CICY_PREVIEW_DIST; do
    [[ -v "saved_env[$key]" ]] && printf '%s=%s\0' "$key" "${saved_env[$key]}" >> "$ENV_FILE.tmp"
  done
  chown "$RUNTIME_USER:$RUNTIME_USER" "$ENV_FILE.tmp"
  chmod 0600 "$ENV_FILE.tmp"
  mv -f "$ENV_FILE.tmp" "$ENV_FILE"
fi
if [[ ! -s "$ARGS_FILE" ]]; then
  printf '%s\0' --cft > "$ARGS_FILE"
  chown "$RUNTIME_USER:$RUNTIME_USER" "$ARGS_FILE"
  chmod 0600 "$ARGS_FILE"
fi

if [[ "$restart_current" == "1" ]]; then
  echo "[restart] starting through $RUNTIME_HOME/.local/bin/cicy-code with preserved arguments"
else
  echo "[3/3] restarting through $RUNTIME_HOME/.local/bin/cicy-code with preserved arguments"
fi
[[ "$old_pid" =~ ^[0-9]+$ ]] && kill -TERM "$old_pid" 2>/dev/null || true
pkill -TERM -u "$RUNTIME_USER" -x cicy-code 2>/dev/null || true
for _ in $(seq 1 50); do
  pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null || break
  sleep 0.1
done
pkill -KILL -u "$RUNTIME_USER" -x cicy-code 2>/dev/null || true

runtime_env=(
  "HOME=$RUNTIME_HOME" "USER=$RUNTIME_USER" "LOGNAME=$RUNTIME_USER"
  "DISPLAY=${DISPLAY:-:1}" "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/cicy-xdg-runtime}"
  "PATH=$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
)
for key in CICY_EMAIL CICY_TEAM CICY_CLOUD_ORIGIN CICY_LOG_FILE CICY_PREVIEW_DIST; do
  [[ -v "saved_env[$key]" ]] && runtime_env+=("$key=${saved_env[$key]}")
done

sudo -u "$RUNTIME_USER" -H env "${runtime_env[@]}" \
  bash -c 'saved_args=(); while IFS= read -r -d "" argument; do saved_args+=("$argument"); done < "$2"; nohup stdbuf -oL -eL "$HOME/.local/bin/cicy-code" "${saved_args[@]}" > "$1" 2>&1 < /dev/null & echo $!' \
  _ "$LOG_FILE" "$ARGS_FILE" > "$PID_FILE"

new_pid="$(cat "$PID_FILE")"
for _ in $(seq 1 120); do
  pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null && break
  kill -0 "$new_pid" 2>/dev/null || break
  sleep 0.5
done
if ! pgrep -u "$RUNTIME_USER" -x cicy-code >/dev/null; then
  echo "cicy-code failed to restart; latest log:" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi

# A live PID is not sufficient: the stable cicy-ai.com proxy returns 502 until
# the replacement process has created and reported its new Quick Tunnel.
cft_url=""
for _ in $(seq 1 180); do
  cft_url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$cft_url" ]] && break
  kill -0 "$new_pid" 2>/dev/null || break
  sleep 1
done
if [[ -z "$cft_url" ]]; then
  echo "cicy-code restarted but Quick Tunnel did not become ready; latest log:" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi

resolve_fixed_domain() {
  local agent_command agent_env
  agent_command="$(command -v cicy-agent 2>/dev/null || true)"
  if [[ -z "$agent_command" && -x "$RUNTIME_HOME/.local/bin/cicy-agent" ]]; then
    agent_command="$RUNTIME_HOME/.local/bin/cicy-agent"
  fi
  if [[ -z "$agent_command" ]]; then
    agent_command="$(find "$RUNTIME_HOME/cicy-ai/skills" -path '*/cicy-agent/bin/cicy-agent' -type f -perm -u+x -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$agent_command" ]] || return 0
  agent_env=(
    "HOME=$RUNTIME_HOME" "USER=$RUNTIME_USER" "LOGNAME=$RUNTIME_USER"
    "PATH=$RUNTIME_HOME/.local/bin:$RUNTIME_HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"
  )
  if [[ -v 'saved_env[CICY_CLOUD_ORIGIN]' ]]; then
    agent_env+=("CICY_CLOUD_ORIGIN=${saved_env[CICY_CLOUD_ORIGIN]}")
  fi
  sudo -u "$RUNTIME_USER" -H env "${agent_env[@]}" \
    timeout 10 "$agent_command" --json whoami 2>/dev/null \
    | jq -r '.data.proxyHost // empty' 2>/dev/null \
    | head -n 1
}

running="$($RUNTIME_HOME/.local/bin/cicy-code --version 2>/dev/null | tail -n 1)"
if [[ "$restart_current" == "1" ]]; then
  echo "restarted=$version running=$running pid=$new_pid"
else
  echo "updated=$version running=$running pid=$new_pid"
fi
api_token="$(jq -r '.api_token // empty' "$RUNTIME_HOME/cicy-ai/global.json" 2>/dev/null || true)"
if [[ -n "$api_token" ]]; then
  encoded_token="$(jq -rn --arg token "$api_token" '$token|@uri')"
  fixed_host=""
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
else
  echo "TUNNEL_URL=${cft_url%/}"
  echo "OPEN_URL=pending (api token unavailable)"
fi
echo "log=$LOG_FILE"
