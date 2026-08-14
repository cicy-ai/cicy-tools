#!/usr/bin/env bash
set -euo pipefail

want="${1:-latest}"
repo_url="${CICY_TOOLS_URL:-https://github.com/cicy-ai/cicy-tools.git}"
work_dir="$(mktemp -d /content/cicy-code-update.XXXXXX)"

cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

[[ "$(id -u)" -eq 0 ]] || {
  echo "cicy-code update: this script must run with sudo/root" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  apt-get -qq update
  apt-get -qq install -y --no-install-recommends git ca-certificates curl >/dev/null
}

echo "[bootstrap] downloading current Colab updater"
git clone --quiet --depth 1 --branch main "$repo_url" "$work_dir/repo"

for file in colab-cicy-code-update.sh colab-cicy-code-hot-update.sh; do
  [[ -s "$work_dir/repo/$file" ]] || {
    echo "cicy-code update: repository is missing $file" >&2
    exit 1
  }
  install -m 0755 "$work_dir/repo/$file" "/content/$file"
done

echo "[bootstrap] installed update scripts"
exec /content/colab-cicy-code-hot-update.sh "$want"
