#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${HOME:-/home/cicy}"
STORE="${CICY_CODE_STORE:-$HOME_DIR/.local/cicy-code}"
LOCAL_BIN="$HOME_DIR/.local/bin"
LINK="$LOCAL_BIN/cicy-code"
VERSIONS="$HOME_DIR/cicy-ai/runtime/versions.json"
NPM_OFFICIAL="${CICY_NPM_OFFICIAL:-https://registry.npmjs.org}"
NPM_CN="${CICY_NPM_MIRROR:-https://registry.npmmirror.com}"
GITHUB_RELEASE_BASE="${CICY_CODE_RELEASE_BASE:-https://github.com/cicy-ai/cicy-code/releases}"
want="${1:-latest}"

log() { printf '[cicy-code-update] %s\n' "$*"; }

pick_registry() {
  if [[ -n "${NPM_REGISTRY:-}" ]]; then printf '%s\n' "$NPM_REGISTRY"; return; fi
  if curl -fsS -m 3 --connect-timeout 3 -o /dev/null "$NPM_OFFICIAL/cicy-code"; then
    printf '%s\n' "$NPM_OFFICIAL"
  else
    printf '%s\n' "$NPM_CN"
  fi
}

resolve_version() {
  local registry="$1"
  local encoded_want response
  encoded_want="${want//\//%2F}"
  response="$(curl -fsSL --connect-timeout 5 --max-time 15 \
    "$registry/cicy-code/$encoded_want" 2>/dev/null || true)"
  [[ -n "$response" ]] || return 0
  printf '%s' "$response" | node -e '
    let input="";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(input).version || "")); } catch {}
    });
  ' 2>/dev/null
}

resolve_github_version() {
  local manifest
  if [[ "$want" == "latest" ]]; then
    manifest="$(curl -fsSL --connect-timeout 5 --max-time 20 \
      "$GITHUB_RELEASE_BASE/latest/download/manifest.json" 2>/dev/null || true)"
  else
    manifest="$(curl -fsSL --connect-timeout 5 --max-time 20 \
      "$GITHUB_RELEASE_BASE/download/v$want/manifest.json" 2>/dev/null || true)"
  fi
  [[ -n "$manifest" ]] || return 0
  printf '%s' "$manifest" | node -e '
    let input="";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try { process.stdout.write(String(JSON.parse(input).version || "")); } catch {}
    });
  ' 2>/dev/null
}

registry="$(pick_registry)"
if [[ "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]]; then
  version="$want"
else
  version="$(resolve_version "$registry" || true)"
  if [[ -z "$version" ]]; then
    alternate="$NPM_CN"
    [[ "$registry" == "$NPM_CN" ]] && alternate="$NPM_OFFICIAL"
    log "registry $registry unavailable; falling back to $alternate"
    version="$(resolve_version "$alternate" || true)"
    [[ -n "$version" ]] && registry="$alternate"
  fi
  if [[ -z "$version" ]]; then
    log "npm metadata unavailable; resolving from GitHub Release"
    version="$(resolve_github_version || true)"
  fi
fi
[[ -n "${version:-}" ]] || { log "could not resolve cicy-code@$want" >&2; exit 1; }

if [[ -n "${CICY_CODE_PLATFORM_PACKAGE:-}" ]]; then
  platform_package="$CICY_CODE_PLATFORM_PACKAGE"
else
  case "$(uname -m)" in
    x86_64|amd64) platform_package=cicy-code-linux-x64 ;;
    aarch64|arm64) platform_package=cicy-code-linux-arm64 ;;
    *) log "unsupported Colab architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi
case "$platform_package" in
  cicy-code-linux-x64) release_asset=cicy-code-linux-amd64 ;;
  cicy-code-linux-arm64) release_asset=cicy-code-linux-arm64 ;;
  cicy-code-darwin-x64) release_asset=cicy-code-darwin-amd64 ;;
  cicy-code-darwin-arm64) release_asset=cicy-code-darwin-arm64 ;;
  *) log "no GitHub Release asset mapping for $platform_package" >&2; exit 1 ;;
esac

version_dir="$STORE/$version"
native_target="$LOCAL_BIN/cicy-code-$version"
package_native="$version_dir/lib/node_modules/cicy-code/node_modules/$platform_package/cicy-code"

mkdir -p "$STORE" "$LOCAL_BIN" "$(dirname "$VERSIONS")"
if [[ ! -x "$native_target" && ( ! -x "$version_dir/bin/cicy-code" || ! -x "$package_native" ) ]]; then
  staging="$STORE/.staging-$version-$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  log "installing cicy-code $version from $registry"
  if npm install -g "cicy-code@$version" --prefix "$staging" --registry "$registry" \
      --fetch-retries=1 --fetch-timeout=30000 --fetch-retry-maxtimeout=15000 >/dev/null 2>&1 && \
      [[ -x "$staging/bin/cicy-code" ]] && \
      [[ -x "$staging/lib/node_modules/cicy-code/node_modules/$platform_package/cicy-code" ]]; then
    rm -rf "$version_dir"
    mv "$staging" "$version_dir"
  else
    log "npm package unavailable; downloading $release_asset from GitHub Release"
    rm -rf "$staging"
    native_staging="$native_target.staging-$$"
    curl -fsSL --show-error --retry 2 --connect-timeout 10 --max-time 180 \
      "$GITHUB_RELEASE_BASE/download/v$version/$release_asset" -o "$native_staging"
    chmod 0755 "$native_staging"
    "$native_staging" --version 2>/dev/null | grep -F "$version" >/dev/null || {
      log "GitHub Release runtime version verification failed" >&2
      rm -f "$native_staging"
      exit 1
    }
    mv "$native_staging" "$native_target"
  fi
fi

if [[ ! -x "$native_target" ]]; then
  native_staging="$native_target.staging-$$"
  cp "$package_native" "$native_staging"
  chmod 0755 "$native_staging"
  "$native_staging" --version | grep -F "$version" >/dev/null || {
    log "native runtime version verification failed" >&2
    rm -f "$native_staging"
    exit 1
  }
  mv "$native_staging" "$native_target"
fi

actual="$($native_target --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
[[ "$actual" == "$version" ]] || { log "expected $version but runtime reports ${actual:-unknown}" >&2; exit 1; }

if [[ "${CICY_CODE_SWITCH:-1}" == "0" ]]; then
  log "staged and verified $native_target (current symlink unchanged)"
  printf '%s\n' "$version"
  exit 0
fi

previous=""
if [[ -L "$LINK" ]]; then
  previous="$(readlink "$LINK" | sed -nE 's#.*cicy-code-([0-9]+\.[0-9]+\.[0-9]+.*)$#\1#p')"
fi
[[ "$previous" == "$version" ]] && previous="$(jq -r '."cicy-code".previous // empty' "$VERSIONS" 2>/dev/null || true)"
temporary_link="$LINK.tmp-$$"
ln -s "$native_target" "$temporary_link"
mv -f "$temporary_link" "$LINK"

versions_tmp="$VERSIONS.tmp-$$"
if [[ -s "$VERSIONS" ]] && jq -e . "$VERSIONS" >/dev/null 2>&1; then
  jq --arg current "$version" --arg previous "$previous" \
    '."cicy-code" = ((."cicy-code" // {}) + {current:$current,previous:$previous,switched_at:(now|todate)})' \
    "$VERSIONS" > "$versions_tmp"
else
  jq -n --arg current "$version" --arg previous "$previous" \
    '{"cicy-code":{current:$current,previous:$previous,switched_at:(now|todate)}}' > "$versions_tmp"
fi
mv "$versions_tmp" "$VERSIONS"

log "current -> $native_target"
printf '%s\n' "$version"
