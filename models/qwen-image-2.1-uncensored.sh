#!/usr/bin/env bash
# Qwen-Image-2.1 Uncensored (abenzerps GGUF) in ComfyUI on a cloud GPU (Colab / RunPod / any CUDA Linux).
#
#   !curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/models/qwen-image-2.1-uncensored.sh | bash
#   RunPod: … | COMFY_ROOT=/workspace/comfy bash -s -- --host 0.0.0.0
#
# Installs ComfyUI + leejet/ComfyUI-GGUF, downloads the uncensored diffusion GGUF (quant by
# VRAM), the int8 text encoder and the VAE, installs the official text-to-image and image-edit
# workflows rewired to those files, and starts ComfyUI. Idempotent.
set -euo pipefail

REPO=abenzerps/Qwen-Image-2.1-Uncensored-GGUF
ROOT="${COMFY_ROOT:-/content/comfy}"
HOST="${COMFY_HOST:-127.0.0.1}"
PORT="${COMFY_PORT:-18188}"
QUANT=auto
TE=auto
KEEP_LLM=0
STOP=0
EXTRA=()

usage() {
  cat <<EOF
qwen-image-2.1-uncensored.sh — ComfyUI + Qwen-Image-2.1 Uncensored

  --quant Q4_K_M|Q5_K_M|Q6_K|Q8_0|BF16   diffusion GGUF (default: by VRAM)
  --te int8|bf16     text encoder (default: bf16 only with >=40G VRAM)
  --host ADDR        listen address (default: $HOST)
  --port N           listen port (default: $PORT)
  --keep-llm         do not stop a running llama-server to free VRAM
  --lowvram          pass --lowvram to ComfyUI (use on OOM)
  --stop             stop ComfyUI
Env: COMFY_ROOT (default: $ROOT), HF_TOKEN (optional)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quant) QUANT="$2"; shift 2 ;;
    --te) TE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --keep-llm) KEEP_LLM=1; shift ;;
    --lowvram) EXTRA+=(--lowvram); shift ;;
    --stop) STOP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

APP="$ROOT/ComfyUI"
VENV="$ROOT/venv"
PID_FILE="$ROOT/comfyui.pid"
ARGS_FILE="$ROOT/comfyui.args"
LOG_FILE="$ROOT/comfyui.log"
mkdir -p "$ROOT"

log() { echo "[qwen-image] $*"; }
die() { echo "[qwen-image] ERROR: $*" >&2; exit 1; }

running_pid() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}
stop_comfy() {
  local pid
  if pid="$(running_pid)"; then
    log "stopping ComfyUI (pid $pid)"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}
if [[ "$STOP" == 1 ]]; then stop_comfy; exit 0; fi

# ── hardware ─────────────────────────────────────────────────────────────
[[ -d /usr/lib64-nvidia ]] && export LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1 \
  || die "no GPU. Switch the runtime to a GPU (Colab: Runtime → Change runtime type → T4)"
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
VRAM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc 0-9)"
RAM="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
log "gpu=$GPU vram=${VRAM}MiB ram=${RAM}MiB"

if [[ "$QUANT" == auto ]]; then
  if   (( VRAM >= 24000 )); then QUANT=Q8_0
  elif (( VRAM >= 14500 )); then QUANT=Q6_K
  elif (( VRAM >= 10000 )); then QUANT=Q5_K_M
  else QUANT=Q4_K_M
  fi
fi
if [[ "$TE" == auto ]]; then
  if (( VRAM >= 40000 && RAM >= 48000 )); then TE=bf16; else TE=int8; fi
fi
case "$TE" in
  int8) TE_FILE=qwen3vl_8b_int8_convrot.safetensors ;;
  bf16) TE_FILE=qwen3vl_8b_bf16.safetensors ;;
  *) die "--te must be int8 or bf16" ;;
esac
UNET_FILE="qwen-image-2.1-UC-$QUANT.gguf"
VAE_FILE=qwen_image_2.1_vae_bf16.safetensors
log "diffusion=$UNET_FILE text_encoder=$TE_FILE"

# ── ComfyUI + GGUF loader ────────────────────────────────────────────────
PY="$VENV/bin/python"
if [[ ! -d "$APP/.git" ]]; then
  log "cloning ComfyUI"
  git clone --quiet --depth 1 https://github.com/Comfy-Org/ComfyUI "$APP"
else
  git -C "$APP" pull --quiet --ff-only || log "ComfyUI update skipped"
fi
if [[ ! -d "$APP/custom_nodes/ComfyUI-GGUF/.git" ]]; then
  git clone --quiet --depth 1 https://github.com/leejet/ComfyUI-GGUF "$APP/custom_nodes/ComfyUI-GGUF"
else
  git -C "$APP/custom_nodes/ComfyUI-GGUF" pull --quiet --ff-only || true
fi
# uv builds the venv without ensurepip (missing on Colab) and installs fast.
python3 -m uv --version >/dev/null 2>&1 || python3 -m pip install -q uv
UV=(python3 -m uv)
if [[ ! -x "$PY" ]]; then
  # Reuse the host's CUDA torch (Colab / RunPod images ship one).
  "${UV[@]}" venv -q --system-site-packages "$VENV"
fi
if ! "$PY" -c 'import torch; assert torch.cuda.is_available()' 2>/dev/null; then
  log "installing CUDA torch"
  "${UV[@]}" pip install -q --python "$PY" torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
fi
log "installing ComfyUI requirements"
grep -viE '^(torch|torchvision|torchaudio)([<>=~ ]|$)' "$APP/requirements.txt" > "$ROOT/requirements.txt"
"${UV[@]}" pip install -q --python "$PY" -r "$ROOT/requirements.txt" -r "$APP/custom_nodes/ComfyUI-GGUF/requirements.txt"

# ── models ───────────────────────────────────────────────────────────────
hf_fetch() {
  local file="$1" dest="$2"
  [[ -s "$dest" && ! -f "$dest.part" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  log "downloading $file"
  local auth=()
  [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  touch "$dest.part"
  curl -fL --retry 10 --retry-delay 5 -C - "${auth[@]}" -o "$dest" \
    "https://huggingface.co/$REPO/resolve/main/$file"
  rm -f "$dest.part"
}
hf_fetch "$UNET_FILE" "$APP/models/diffusion_models/$UNET_FILE"
hf_fetch "text_encoders/$TE_FILE" "$APP/models/text_encoders/$TE_FILE"
hf_fetch "vae/$VAE_FILE" "$APP/models/vae/$VAE_FILE"

# ── workflows: official templates rewired to the GGUF files ──────────────
WF_DIR="$APP/user/default/workflows"
mkdir -p "$WF_DIR"
for t in t2i image_edit; do
  src="https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/image_qwen_image_2_1_$t.json"
  curl -fsSL --retry 3 "$src" -o "$ROOT/template_$t.json" || { log "workflow $t download failed"; continue; }
  "$PY" - "$ROOT/template_$t.json" "$WF_DIR/Qwen-Image-2.1-Uncensored-$t.json" "$UNET_FILE" "$TE_FILE" "$VAE_FILE" <<'PY'
import json, sys
src, dst, unet, te, vae = sys.argv[1:]
wf = json.load(open(src))
nodes = list(wf.get("nodes", []))
for sg in wf.get("definitions", {}).get("subgraphs", []):
    nodes += sg.get("nodes", [])
for n in nodes:
    t = n.get("type")
    if t == "UNETLoader":
        n["type"] = "UnetLoaderGGUF"
        n["widgets_values"] = [unet]
        n.setdefault("properties", {})["Node name for S&R"] = "UnetLoaderGGUF"
    elif t == "CLIPLoader":
        n["widgets_values"][0] = te
    elif t == "VAELoader":
        n["widgets_values"][0] = vae
    if t in ("UNETLoader", "UnetLoaderGGUF", "CLIPLoader", "VAELoader"):
        n.get("properties", {}).pop("models", None)  # no "missing model" download prompt
json.dump(wf, open(dst, "w"), ensure_ascii=False, indent=1)
PY
done
log "workflows: $WF_DIR"

# ── free the GPU from a local LLM (one GPU, one heavy job) ───────────────
FREE="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -dc 0-9)"
LLM_PID_FILE="${LLM_ROOT:-/content/llm}/llama-server.pid"
if (( FREE < 8000 )) && [[ "$KEEP_LLM" != 1 && -f "$LLM_PID_FILE" ]] && kill -0 "$(cat "$LLM_PID_FILE")" 2>/dev/null; then
  log "only ${FREE}MiB VRAM free — stopping llama-server (restart it with the models/ LLM script)"
  kill "$(cat "$LLM_PID_FILE")" 2>/dev/null || true
  rm -f "$LLM_PID_FILE"
  sleep 5
fi

# ── start ComfyUI ────────────────────────────────────────────────────────
ARGS=(main.py --listen "$HOST" --port "$PORT" --disable-auto-launch "${EXTRA[@]}")
WANT="$(printf '%s\n' "${ARGS[@]}")"
up() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; }

if pid="$(running_pid)" && [[ "$(cat "$ARGS_FILE" 2>/dev/null)" == "$WANT" ]] && up; then
  log "reusing running ComfyUI (pid $pid)"
else
  stop_comfy
  up && die "port $PORT is already in use; pass --port N"
  (cd "$APP" && exec setsid "$PY" "${ARGS[@]}") >"$LOG_FILE" 2>&1 </dev/null &
  echo $! > "$PID_FILE"
  printf '%s' "$WANT" > "$ARGS_FILE"
  log "starting ComfyUI (pid $(cat "$PID_FILE")), log $LOG_FILE"
  for i in $(seq 1 120); do
    up && break
    kill -0 "$(cat "$PID_FILE")" 2>/dev/null || { tail -n 30 "$LOG_FILE" >&2; die "ComfyUI exited"; }
    sleep 3
  done
  up || { tail -n 30 "$LOG_FILE" >&2; die "ComfyUI did not come up"; }
fi

# The rewired workflows need these node types; fail loudly if the loader is missing.
for node in UnetLoaderGGUF TextEncodeQwenImage21; do
  curl -fsS "http://127.0.0.1:$PORT/object_info/$node" | grep -q "\"$node\"" \
    || die "ComfyUI has no $node node (see $LOG_FILE)"
done
log "nodes ok: UnetLoaderGGUF, TextEncodeQwenImage21"

# ── signed-in link through CiCy Hub (when cicy-code runs here) ───────────
OPEN_URL=""
for f in /home/cicy/cicy-ai/global.json "$HOME/cicy-ai/global.json"; do
  [[ -r "$f" ]] || continue
  token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("api_token",""))' "$f")"
  [[ -n "$token" ]] || break
  OPEN_URL="$(curl -fsS --max-time 20 -X POST http://127.0.0.1:8008/api/im/cicy-cloud/open \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "{\"port\":$PORT}" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))' 2>/dev/null || true)"
  break
done

cat <<EOF
COMFYUI_LOCAL=http://127.0.0.1:$PORT
COMFYUI_OPEN_URL=${OPEN_URL:-"(no CiCy Hub here — expose port $PORT, e.g. RunPod HTTP port)"}
WORKFLOWS=Qwen-Image-2.1-Uncensored-t2i, Qwen-Image-2.1-Uncensored-image_edit   # Workflows panel in ComfyUI
MODEL=$UNET_FILE + $TE_FILE
LOG=$LOG_FILE
EOF
