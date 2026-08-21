#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cicy-hot-update-argv.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] \
    || fail "$label: expected [$expected], got [$actual]"
}

proc_root="$TEST_ROOT/proc"
pid=4242
mkdir -p "$proc_root/$pid"
printf '%s\0' \
  /home/cicy/.local/bin/cicy-code \
  --cft \
  --team \
  'team with spaces' \
  '--label=a=b' \
  $'line one\nline two' \
  > "$proc_root/$pid/cmdline"

args_file="$TEST_ROOT/cicy-code.args"
CICY_PROC_ROOT="$proc_root" \
  bash "$ROOT/colab-cicy-code-hot-update.sh" --capture-argv "$pid" "$args_file"

actual=()
while IFS= read -r -d '' argument; do
  actual+=("$argument")
done < "$args_file"

assert_equal 5 "${#actual[@]}" "argument count"
assert_equal --cft "${actual[0]}" "argument 1"
assert_equal --team "${actual[1]}" "argument 2"
assert_equal 'team with spaces' "${actual[2]}" "argument 3"
assert_equal '--label=a=b' "${actual[3]}" "argument 4"
assert_equal $'line one\nline two' "${actual[4]}" "argument 5"

wrapper_pid=5252
mkdir -p "$proc_root/$wrapper_pid"
printf '%s\0' /usr/bin/stdbuf /home/cicy/.local/bin/cicy-code --cft \
  > "$proc_root/$wrapper_pid/cmdline"
rejected_file="$TEST_ROOT/rejected.args"
printf 'unchanged' > "$rejected_file"
if CICY_PROC_ROOT="$proc_root" \
  bash "$ROOT/colab-cicy-code-hot-update.sh" \
    --capture-argv "$wrapper_pid" "$rejected_file" 2>/dev/null; then
  fail "wrapper PID was accepted as cicy-code"
fi
assert_equal unchanged "$(cat "$rejected_file")" "rejected destination"

echo "PASS: hot updater preserves the original cicy-code argv"
