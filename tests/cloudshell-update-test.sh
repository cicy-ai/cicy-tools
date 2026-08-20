#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cicytools-update.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local expected="$1" file="$2"
  grep -Fqx -- "$expected" "$file" || fail "missing line: $expected"
}

run_update() {
  local version="$1" case_dir="$TEST_ROOT/$2"
  local host_home="$case_dir/host" runtime_home="$case_dir/runtime"
  local tools_dir="$case_dir/tools" fake_bin="$case_dir/bin" record

  mkdir -p "$host_home" "$runtime_home" "$tools_dir" "$fake_bin"
  cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  chmod +x "$fake_bin/sudo"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tools_dir/colab-cicy-code-update.sh"
  cat > "$tools_dir/colab-cicy-code-hot-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'version=%s\n' "${1:-latest}"
  printf 'runtime_user=%s\n' "$CICY_RUNTIME_USER"
  printf 'runtime_home=%s\n' "$CICY_RUNTIME_HOME"
  printf 'updater=%s\n' "$CICY_CODE_UPDATER"
  printf 'log=%s\n' "$CICY_CODE_LOG"
  printf 'pid=%s\n' "$CICY_CODE_PID_FILE"
  printf 'args=%s\n' "$CICY_CODE_ARGS_FILE"
  printf 'env=%s\n' "$CICY_CODE_ENV_FILE"
} > "$CICY_CODE_LOG"
EOF
  chmod +x "$tools_dir/colab-cicy-code-update.sh" "$tools_dir/colab-cicy-code-hot-update.sh"

  HOME="$host_home" \
  CICY_TOOLS_DIR="$tools_dir" \
  CICY_RUNTIME_USER="$(id -un)" \
  CICY_RUNTIME_HOME="$runtime_home" \
  PATH="$fake_bin:$PATH" \
    bash "$ROOT/cloudshell-keepalive.sh" update "$version"

  record="$runtime_home/logs/cicy-code.log"
  [[ -s "$record" ]] || fail "update command did not invoke the hot updater"
  assert_line "version=$version" "$record"
  assert_line "runtime_user=$(id -un)" "$record"
  assert_line "runtime_home=$runtime_home" "$record"
  assert_line "updater=$runtime_home/.local/libexec/cicy-code-update.sh" "$record"
  assert_line "log=$runtime_home/logs/cicy-code.log" "$record"
  assert_line "pid=$runtime_home/logs/cicy-code.pid" "$record"
  assert_line "args=$runtime_home/cicy-ai/runtime/cicy-code.args" "$record"
  assert_line "env=$runtime_home/cicy-ai/runtime/cicy-code.env" "$record"
  [[ -x "$runtime_home/.local/libexec/cicy-code-update.sh" ]] \
    || fail "version updater was not installed"
  [[ -x "$runtime_home/.local/libexec/cicy-code-hot-update.sh" ]] \
    || fail "hot updater was not installed"
}

run_update latest default
run_update 2.3.999 explicit

echo "PASS: cicytools update delegates latest and explicit versions"
