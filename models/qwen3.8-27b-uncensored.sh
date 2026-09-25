#!/usr/bin/env bash
# Qwen3.8-27B Uncensored (JonathanColetti GGUF, noMTP builds) on a Colab GPU.
# Served under the same model name as the official build, so agents keep working.
#
#   !curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/models/qwen3.8-27b-uncensored.sh | bash
#
# Extra arguments go to colab-llm.sh (e.g. --ctx 16384, --quant noMTP-Q4_K_M, --stop).
set -euo pipefail

REPO=JonathanColetti/Qwen3.8-27B-Uncensored-GGUF
PREFIX=Qwen3.8-27B-Uncensored
ALIAS=qwen3.8-27b

# min VRAM MiB : quant : ctx
TABLE=(
  "70000:noMTP-Q8_0:131072"
  "38000:noMTP-Q6_K:65536"
  "30000:noMTP-Q5_K_M:32768"
  "21000:noMTP-Q4_K_M:32768"
  "14500:noMTP-IQ2_M:32768"
  "11000:noMTP-IQ2_M:16384"
  "0:noMTP-IQ2_M:8192"
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
