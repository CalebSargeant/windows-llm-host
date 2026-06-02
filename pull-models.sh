#!/usr/bin/env bash
# Pull Ollama models for this laptop profile.
#
# Usage:
#   ./pull-models.sh                         # maximum/heavy set
#   PROFILE=fast ./pull-models.sh            # smallest useful set
#   PROFILE=max ./pull-models.sh             # aggressive CPU/RAM/GPU set
#   ./pull-models.sh qwen3:4b-instruct       # explicit model list
#
# The script is idempotent: ollama pull skips layers already present.

set -euo pipefail

CONTAINER="${OLLAMA_CONTAINER:-windows-llm-host-ollama}"
PROFILE="${PROFILE:-max}"

FAST_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model|Very small Qwen3 model for quick local responses and smoke tests."
  "qwen3:4b-instruct|Best daily small model|Modern general model, small enough for limited-VRAM systems at modest context."
)

RECOMMENDED_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model|Very small Qwen3 model for quick local responses and smoke tests."
  "qwen3:4b-instruct|Best daily model|Good general reasoning for limited-VRAM systems without being painfully slow."
  "qwen2.5-coder:7b-instruct-q4_K_M|Best practical coding model|Strong code generation and debugging; may partially offload to CPU/RAM on modest GPUs."
  "qwen3:14b-q4_K_M|Stronger quality model|Higher quality than 4B/7B, but expects CPU/RAM participation and slower generation."
)

MAX_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model|Very small Qwen3 model for quick local responses and smoke tests."
  "qwen3:4b-instruct|Best daily model|Good general reasoning for limited-VRAM systems without being painfully slow."
  "qwen2.5-coder:7b-instruct-q4_K_M|Best practical coding model|Strong code generation and debugging; may partially offload to CPU/RAM on modest GPUs."
  "qwen3:14b-q4_K_M|Stronger quality model|Higher quality than 4B/7B, but expects CPU/RAM participation and slower generation."
  "gpt-oss:20b|Strong reasoning candidate|Large open-weight reasoning model; uses system RAM heavily and will be slower."
  "qwen3-coder:30b|Max quality coding mode|Best local coding candidate in this stack; 19 GB model, heavy CPU/RAM use, slow but capable."
  "qwen3:30b-instruct|Max quality general mode|Strong general Qwen3 model; 19 GB model, heavy CPU/RAM use, slow but capable."
)

CUSTOM_MODELS=()

if [ "$#" -gt 0 ]; then
  for model in "$@"; do
    CUSTOM_MODELS+=("${model}|Custom model|Requested on the command line.")
  done
  MODEL_ROWS=("${CUSTOM_MODELS[@]}")
else
  case "$PROFILE" in
    fast)
      MODEL_ROWS=("${FAST_MODELS[@]}")
      ;;
    recommended|daily)
      MODEL_ROWS=("${RECOMMENDED_MODELS[@]}")
      ;;
    max|heavy)
      MODEL_ROWS=("${MAX_MODELS[@]}")
      ;;
    *)
      echo "Unknown PROFILE='$PROFILE'. Use fast, recommended, or max." >&2
      exit 2
      ;;
  esac
fi

echo "Checking Ollama container: ${CONTAINER}"
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "ERROR: '${CONTAINER}' is not running. Run 'docker compose up -d' first." >&2
  exit 1
fi

echo ""
echo "Pull profile: ${PROFILE}"
echo "Target container: ${CONTAINER}"
echo ""

for row in "${MODEL_ROWS[@]}"; do
  IFS='|' read -r model label reason <<< "$row"
  echo "==> ${model}"
  echo "    ${label}: ${reason}"
  docker exec "$CONTAINER" ollama pull "$model"
  echo ""
done

echo "Available models:"
docker exec "$CONTAINER" ollama list
