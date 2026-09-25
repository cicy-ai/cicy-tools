#!/usr/bin/env bash
# Run a GGUF model (default: Qwen3.8-27B) on a Colab GPU with llama.cpp's
# llama-server and expose it as an OpenAI-compatible endpoint.
#
#   !curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-llm.sh | bash
#   !curl -fsSL …/colab-llm.sh | bash -s -- --quant UD-Q4_K_XL --ctx 16384
#
# Idempotent: a server already running with the same model and arguments is
# reused. The quant is picked from the GPU's VRAM unless --quant is given.
set -euo pipefail

VERSION=1.1.0
REPO="${LLM_REPO:-unsloth/Qwen3.8-27B-GGUF}"
PREFIX="${LLM_PREFIX:-Qwen3.8-27B}"
ALIAS="${LLM_ALIAS:-qwen3.8-27b}"
QUANT="${LLM_QUANT:-auto}"
CTX="${LLM_CTX:-auto}"
PORT="${LLM_PORT:-18090}"   # Colab itself listens on 8080
HOST="${LLM_HOST:-127.0.0.1}"
API_KEY="${LLM_API_KEY:-sk-colab-llm}"
LLAMA_TAG="${LLAMA_TAG:-latest}"
PROVIDER_KEY="${LLM_PROVIDER_KEY:-qwen_local}"
ROOT="${LLM_ROOT:-/content/llm}"
VISION=0
REGISTER=1
ALLOW_CPU=0
DOWNLOAD_ONLY=0
STOP=0
FIX_TEMPLATE=1

usage() {
  cat <<EOF
colab-llm.sh $VERSION — llama.cpp server for $REPO on Colab

  --quant NAME       quant tag, e.g. UD-Q3_K_XL, UD-Q4_K_XL (default: by VRAM)
  --ctx N            context size (default: by VRAM)
  --port N           listen port (default: $PORT)
  --host ADDR        listen address (default: $HOST)
  --repo OWNER/NAME  Hugging Face GGUF repo (default: $REPO)
  --prefix NAME      GGUF file prefix inside the repo (default: $PREFIX)
  --alias NAME       model name served by the API (default: $ALIAS)
  --vision           also load the mmproj (image input)
  --no-register      do not add the provider to the local cicy-code
  --cpu              allow running without a GPU (very slow)
  --download-only    fetch llama.cpp and the model, do not start
  --stop             stop the running server
  --no-template-fix  keep the model's chat template as shipped
Env: HF_TOKEN (optional, gated repos), LLM_API_KEY (default: $API_KEY)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quant) QUANT="$2"; shift 2 ;;
    --ctx) CTX="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --alias) ALIAS="$2"; shift 2 ;;
    --vision) VISION=1; shift ;;
    --no-register) REGISTER=0; shift ;;
    --cpu) ALLOW_CPU=1; shift ;;
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --stop) STOP=1; shift ;;
    --no-template-fix) FIX_TEMPLATE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

BIN_DIR="$ROOT/llama.cpp"
MODEL_DIR="$ROOT/models"
PID_FILE="$ROOT/llama-server.pid"
ARGS_FILE="$ROOT/llama-server.args"
LOG_FILE="$ROOT/llama-server.log"
mkdir -p "$ROOT" "$MODEL_DIR"

log() { echo "[colab-llm] $*"; }
die() { echo "[colab-llm] ERROR: $*" >&2; exit 1; }

running_pid() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

stop_server() {
  local pid
  if pid="$(running_pid)"; then
    log "stopping llama-server (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

if [[ "$STOP" == 1 ]]; then stop_server; exit 0; fi

# ── hardware ─────────────────────────────────────────────────────────────
# Colab keeps the driver libs in /usr/lib64-nvidia, which only the notebook
# kernel has on LD_LIBRARY_PATH (ssh / cron shells do not).
[[ -d /usr/lib64-nvidia ]] && export LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
VRAM_MIB=0
GPU_NAME=none
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || true)"
  VRAM_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc 0-9 || true)"
  VRAM_MIB="${VRAM_MIB:-0}"
fi
RAM_MIB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
log "gpu=$GPU_NAME vram=${VRAM_MIB}MiB ram=${RAM_MIB}MiB"
if [[ "$VRAM_MIB" -eq 0 && "$ALLOW_CPU" != 1 && "$DOWNLOAD_ONLY" != 1 ]]; then
  die "no GPU. Switch the runtime to T4/L4/A100 (Runtime → Change runtime type), or pass --cpu"
fi

# Quant/context by VRAM (27B dense; sizes include KV cache at q8_0).
#   T4 15G → UD-Q3_K_XL  8K     L4 22G → UD-Q4_K_XL 32K
#   A100 40G → UD-Q6_K_XL 64K   80G → UD-Q8_K_XL 128K
pick_by_vram() {
  local v="$1"
  if   (( v >= 70000 )); then echo "UD-Q8_K_XL 131072"
  elif (( v >= 38000 )); then echo "UD-Q6_K_XL 65536"
  elif (( v >= 30000 )); then echo "UD-Q5_K_XL 32768"
  elif (( v >= 21000 )); then echo "UD-Q4_K_XL 32768"
  elif (( v >= 14500 )); then echo "UD-Q3_K_XL 8192"
  elif (( v >= 11000 )); then echo "UD-Q2_K_XL 8192"
  elif (( v >=  7500 )); then echo "UD-IQ2_XXS 4096"
  else echo "UD-IQ1_M 4096"
  fi
}
read -r AUTO_QUANT AUTO_CTX <<<"$(pick_by_vram "$VRAM_MIB")"
if (( VRAM_MIB == 0 )); then
  # CPU: keep the weights inside RAM with room for the OS.
  if   (( RAM_MIB >= 30000 )); then AUTO_QUANT=UD-Q4_K_XL
  elif (( RAM_MIB >= 18000 )); then AUTO_QUANT=UD-Q3_K_XL
  else AUTO_QUANT=UD-IQ2_XXS
  fi
  AUTO_CTX=4096
fi
[[ "$QUANT" == auto ]] && QUANT="$AUTO_QUANT"
[[ "$CTX" == auto ]] && CTX="$AUTO_CTX"
MODEL_FILE="$PREFIX-$QUANT.gguf"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
log "model=$REPO/$MODEL_FILE ctx=$CTX"

# ── llama.cpp (prebuilt CUDA 12 build + its cudart/cublas) ───────────────
fetch() { curl -fL --retry 5 --retry-delay 3 -C - -o "$2" "$1"; }

install_llama() {
  local tag api asset cudart
  if [[ -x "$BIN_DIR/llama-server" ]]; then return 0; fi
  api="https://api.github.com/repos/ggml-org/llama.cpp/releases"
  if [[ "$LLAMA_TAG" == latest ]]; then
    tag="$(curl -fsSL "$api?per_page=10" | python3 -c '
import json,sys
for r in json.load(sys.stdin):
    if any("ubuntu-cuda-12" in a["name"] for a in r["assets"]):
        print(r["tag_name"]); break')"
  else
    tag="$LLAMA_TAG"
  fi
  [[ -n "$tag" ]] || die "could not resolve a llama.cpp release with a CUDA 12 Linux build"
  asset="llama-$tag-bin-ubuntu-cuda-12.8-x64.tar.gz"
  cudart="cudart-llama-$tag-bin-ubuntu-cuda-12.8-x64.tar.gz"
  log "installing llama.cpp $tag (CUDA 12.8)"
  local tmp="$ROOT/dl"
  mkdir -p "$tmp" "$BIN_DIR.new"
  fetch "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$asset" "$tmp/$asset"
  tar -xzf "$tmp/$asset" -C "$BIN_DIR.new" --strip-components=1
  if [[ "$VRAM_MIB" -gt 0 ]]; then
    fetch "https://github.com/ggml-org/llama.cpp/releases/download/$tag/$cudart" "$tmp/$cudart"
    tar -xzf "$tmp/$cudart" -C "$BIN_DIR.new" --strip-components=1
  fi
  echo "$tag" > "$BIN_DIR.new/TAG"
  rm -rf "$BIN_DIR" "$tmp"
  mv "$BIN_DIR.new" "$BIN_DIR"
}

# Fallback when the prebuilt kernels do not cover this GPU: build from source
# for exactly this compute capability (a few minutes on Colab).
build_llama() {
  local cc src="$ROOT/llama.cpp-src"
  cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d .)"
  log "building llama.cpp from source for sm_$cc"
  command -v cmake >/dev/null || pip -q install cmake
  rm -rf "$src"
  git clone --quiet --depth 1 https://github.com/ggml-org/llama.cpp "$src"
  cmake -S "$src" -B "$src/build" -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$cc" \
    -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$src/build" -j"$(nproc)" --target llama-server >/dev/null
  rm -rf "$BIN_DIR"
  mkdir -p "$BIN_DIR"
  cp -a "$src/build/bin/." "$BIN_DIR/"
  echo "source-sm_$cc" > "$BIN_DIR/TAG"
}

# ── model ────────────────────────────────────────────────────────────────
hf_fetch() {
  local file="$1" dest="$2" url
  [[ -s "$dest" && ! -f "$dest.part" ]] && return 0
  url="https://huggingface.co/$REPO/resolve/main/$file"
  log "downloading $file"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  touch "$dest.part"
  curl -fL --retry 10 --retry-delay 5 -C - "${auth[@]}" -o "$dest" "$url"
  rm -f "$dest.part"
}

install_llama
hf_fetch "$MODEL_FILE" "$MODEL_PATH"
MMPROJ_PATH=""
if [[ "$VISION" == 1 ]]; then
  MMPROJ_PATH="$MODEL_DIR/$PREFIX-mmproj-F16.gguf"
  hf_fetch "mmproj-F16.gguf" "$MMPROJ_PATH"
fi
df -h "$ROOT" | tail -1 | awk '{print "[colab-llm] disk: " $3 " used, " $4 " free"}'
if [[ "$DOWNLOAD_ONLY" == 1 ]]; then log "download complete"; exit 0; fi

# ── chat template ────────────────────────────────────────────────────────
# Qwen's template raises "System message must be at the beginning." when a
# system/developer message appears mid-conversation, which Claude Code and
# Codex both send. Render those as ordinary system turns instead.
TEMPLATE_PATH=""
patch_template() {
  local out="$ROOT/$PREFIX-$QUANT.chat-template.jinja"
  python3 -c 'import gguf' 2>/dev/null || pip -q install gguf >/dev/null 2>&1 || return 0
  python3 - "$MODEL_PATH" "$out" <<'PY' || return 0
import sys
from gguf import GGUFReader
field = GGUFReader(sys.argv[1]).fields.get("tokenizer.chat_template")
if field is None:
    sys.exit(1)
tpl = bytes(field.parts[field.data[0]]).decode("utf-8")
old = "{{- raise_exception('System message must be at the beginning.') }}"
if old not in tpl:
    sys.exit(1)
new = "{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}"
open(sys.argv[2], "w").write(tpl.replace(old, new))
PY
  TEMPLATE_PATH="$out"
  log "chat template patched: mid-conversation system messages allowed"
}
[[ "$FIX_TEMPLATE" == 1 ]] && patch_template

# ── server ───────────────────────────────────────────────────────────────
SERVER_ARGS=(
  -m "$MODEL_PATH" --alias "$ALIAS"
  --host "$HOST" --port "$PORT" --api-key "$API_KEY"
  -c "$CTX" -np 1 --jinja
)
if [[ "$VRAM_MIB" -gt 0 ]]; then
  # --fit spills layers to the CPU instead of failing when VRAM is short.
  SERVER_ARGS+=(-ngl auto -fa on -ctk q8_0 -ctv q8_0 --fit on --fit-target 512)
else
  SERVER_ARGS+=(-ngl 0 -t "$(nproc)")
fi
[[ -n "$MMPROJ_PATH" ]] && SERVER_ARGS+=(--mmproj "$MMPROJ_PATH")
[[ -n "$TEMPLATE_PATH" ]] && SERVER_ARGS+=(--chat-template-file "$TEMPLATE_PATH")

WANT="$(printf '%s\n' "$(cat "$BIN_DIR/TAG")" "${SERVER_ARGS[@]}")"
health() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }

start_server() {
  : > "$LOG_FILE"
  LD_LIBRARY_PATH="$BIN_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    nohup setsid "$BIN_DIR/llama-server" "${SERVER_ARGS[@]}" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  printf '%s' "$WANT" > "$ARGS_FILE"
  log "starting llama-server (pid $!), log $LOG_FILE"
  local i
  for i in $(seq 1 180); do
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || return 1
    health && return 0
    (( i % 10 == 0 )) && log "loading… $(tail -n 1 "$LOG_FILE" | cut -c1-120)"
    sleep 5
  done
  return 1
}

# One real completion proves the CUDA kernels run on this GPU.
smoke() {
  local out
  out="$(curl -sS --max-time 300 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$ALIAS\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with: ok\"}],\"chat_template_kwargs\":{\"enable_thinking\":false}}")" || return 1
  python3 -c 'import json,sys
try: print(json.loads(sys.argv[1])["choices"][0]["message"]["content"].strip())
except Exception: print(sys.argv[1][:300]); sys.exit(1)' "$out"
}

if pid="$(running_pid)" && [[ "$(cat "$ARGS_FILE" 2>/dev/null)" == "$WANT" ]] && health; then
  log "reusing running llama-server (pid $pid)"
else
  stop_server
  if health || ! python3 -c 'import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1])))' "$PORT" 2>/dev/null; then
    die "port $PORT is already in use; pass --port N"
  fi
  if ! start_server; then
    tail -n 30 "$LOG_FILE" >&2
    if [[ "$VRAM_MIB" -gt 0 ]] && grep -qiE "no kernel image|unsupported gpu architecture|invalid device function" "$LOG_FILE"; then
      stop_server; build_llama
      WANT="$(printf '%s\n' "$(cat "$BIN_DIR/TAG")" "${SERVER_ARGS[@]}")"
      start_server || { tail -n 30 "$LOG_FILE" >&2; die "llama-server failed to start"; }
    else
      die "llama-server failed to start (see $LOG_FILE)"
    fi
  fi
fi

if ! reply="$(smoke 2>&1)"; then
  if [[ "$VRAM_MIB" -gt 0 ]] && grep -qiE "no kernel image|invalid device function" "$LOG_FILE"; then
    stop_server; build_llama
    WANT="$(printf '%s\n' "$(cat "$BIN_DIR/TAG")" "${SERVER_ARGS[@]}")"
    start_server || die "llama-server failed to start after the source build"
    reply="$(smoke)" || die "smoke test failed (see $LOG_FILE)"
  else
    tail -n 20 "$LOG_FILE" >&2
    die "smoke test failed: $reply"
  fi
fi
log "smoke test reply: $reply"
OFFLOAD="$(grep -oE 'offloaded [0-9]+/[0-9]+ layers to GPU' "$LOG_FILE" | tail -1 || true)"
[[ -n "$OFFLOAD" ]] && log "$OFFLOAD"

# ── cicy-code provider ───────────────────────────────────────────────────
register_provider() {
  local gj="" token body code
  for f in /home/cicy/cicy-ai/global.json "$HOME/cicy-ai/global.json"; do
    [[ -r "$f" ]] && { gj="$f"; break; }
  done
  [[ -n "$gj" ]] || { log "cicy-code not found; skipping provider registration"; return 0; }
  token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("api_token",""))' "$gj")"
  [[ -n "$token" ]] || { log "no cicy-code api_token; skipping provider registration"; return 0; }
  body="$(python3 - "$PROVIDER_KEY" "$ALIAS" "$PORT" "$API_KEY" <<'PY'
import json, sys
key, alias, port, api_key = sys.argv[1:]
print(json.dumps({"key": key, "name": "Qwen (Colab llama.cpp)", "protocol": "openai",
                  "url": f"http://127.0.0.1:{port}", "apiKey": api_key,
                  "models": [alias], "defaultModel": alias}))
PY
)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST http://127.0.0.1:8008/api/providers \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body" || true)"
  if [[ "$code" == 409 ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X PUT "http://127.0.0.1:8008/api/providers/$PROVIDER_KEY" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$body" || true)"
  fi
  if [[ "$code" == 200 || "$code" == 201 ]]; then
    log "cicy-code provider '$PROVIDER_KEY' → model $ALIAS"
  else
    log "cicy-code provider registration skipped (HTTP $code)"
  fi
}
[[ "$REGISTER" == 1 ]] && register_provider

cat <<EOF
LLM_MODEL=$ALIAS ($MODEL_FILE, ctx $CTX)
LLM_BASE_URL=http://127.0.0.1:$PORT/v1
LLM_API_KEY=$API_KEY
LLM_WEBUI=http://127.0.0.1:$PORT   # llama.cpp chat UI (inside the runtime)
LLM_LOG=$LOG_FILE
EOF
