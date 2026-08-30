#!/usr/bin/env bash
# The installer must never run the config sync as root, and must purge the
# root crontab an older installer left behind (a duplicate of cicy's).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cicy-root-crontab.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$ROOT/colab-cicy-code.sh" || fail "colab-cicy-code.sh does not parse"

# 1. the bootstrap sync is invoked through sudo -u "$CICY_RUNTIME_USER", never bare.
grep -qE 'sudo -u "\$CICY_RUNTIME_USER" -H env HOME="\$HOME" PATH="\$PATH" \\$' "$ROOT/colab-cicy-code.sh" \
  || fail "bootstrap sync is not run as the runtime user"
# a bare "$destination/bin/sync-cicy-ai-config.sh" line is only acceptable as
# the continuation of the sudo line right above it.
if awk 'prev !~ /\\$/ && $0 ~ /^[[:space:]]*"\$destination\/bin\/sync-cicy-ai-config.sh"[[:space:]]*$/ { bad=1 } { prev=$0 } END { exit bad ? 0 : 1 }' "$ROOT/colab-cicy-code.sh"; then
  fail "bootstrap sync is still invoked directly (as root)"
fi

# 2. remove_stale_root_crontab: exercise it with a fake sudo/crontab.
mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/bin/sudo" <<'STUB'
#!/usr/bin/env bash
# fake sudo: run the command directly
exec "$@"
STUB
cat > "$TEST_ROOT/bin/crontab" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -l) cat "$FAKE_ROOT_TAB" ;;
  -r) echo removed > "$FAKE_ROOT_TAB.removed" ;;
esac
STUB
chmod +x "$TEST_ROOT/bin/sudo" "$TEST_ROOT/bin/crontab"
export FAKE_ROOT_TAB="$TEST_ROOT/root.tab"

run_helper() {
  HOME=/home/cicy CICY_RUNTIME_USER=cicy PATH="$TEST_ROOT/bin:$PATH" bash -c "
    $(sed -n '/^remove_stale_root_crontab() {/,/^}/p' "$ROOT/colab-cicy-code.sh")
    remove_stale_root_crontab"
}

printf '* * * * * /home/cicy/cicy-ai/bin/sync-cicy-ai-config.sh >> /home/cicy/logs/x.log 2>&1\n' > "$FAKE_ROOT_TAB"
rm -f "$FAKE_ROOT_TAB.removed"
run_helper >/dev/null
[[ -f "$FAKE_ROOT_TAB.removed" ]] || fail "stale root crontab with the sync job was not removed"

printf '0 3 * * * /usr/local/bin/something-else\n' > "$FAKE_ROOT_TAB"
rm -f "$FAKE_ROOT_TAB.removed"
run_helper >/dev/null
[[ ! -f "$FAKE_ROOT_TAB.removed" ]] || fail "an unrelated root crontab was removed"

echo "PASS: root-crontab-test"
