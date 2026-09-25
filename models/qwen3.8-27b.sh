#!/usr/bin/env bash
# Qwen3.8-27B (official, unsloth GGUF) on a Colab GPU.
#
#   !curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/models/qwen3.8-27b.sh | bash
#
# Extra arguments go to colab-llm.sh (e.g. --ctx 16384, --quant UD-Q4_K_XL, --stop).
set -euo pipefail

REPO=unsloth/Qwen3.8-27B-GGUF
PREFIX=Qwen3.8-27B
ALIAS=qwen3.8-27b

# min VRAM MiB : quant : ctx
TABLE=(
  "70000:UD-Q8_K_XL:131072"
  "38000:UD-Q6_K_XL:65536"
  "30000:UD-Q5_K_XL:32768"
  "21000:UD-Q4_K_XL:32768"
  "14500:UD-Q3_K_XL:32768"
  "11000:UD-Q2_K_XL:16384"
  "0:UD-IQ2_XXS:8192"
)

[[ -d /usr/lib64-nvidia ]] && export LD_LIBRARY_PATH="/usr/lib64-nvidia${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
VRAM=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  VRAM="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -dc 0-9)"
fi
for row in "${TABLE[@]}"; do
  IFS=: read -r min QUANT CTX <<<"$row"
  (( ${VRAM:-0} >= min )) && break
done

ENGINE="${LLM_ENGINE_URL:-https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-llm.sh}"
curl -fsSL "$ENGINE" | bash -s -- --repo "$REPO" --prefix "$PREFIX" --alias "$ALIAS" \
  --quant "$QUANT" --ctx "$CTX" "$@"
