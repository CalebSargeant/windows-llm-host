#!/usr/bin/env bash
# Basic end-to-end test for the local Ollama + Open WebUI stack.

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
MODEL="${MODEL:-}"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "ERROR: Python 3 is required for JSON parsing." >&2
  exit 1
fi

echo "Starting stack..."
docker compose up -d

echo "Checking Ollama health at ${OLLAMA_URL}..."
for _ in $(seq 1 60); do
  if curl -fsS "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "${OLLAMA_URL}/api/tags" >/dev/null

export OLLAMA_URL MODEL
"$PYTHON_BIN" - <<'PY'
import json
import os
import time
import urllib.request

ollama_url = os.environ["OLLAMA_URL"].rstrip("/")
requested_model = os.environ.get("MODEL", "").strip()


def get_json(path):
    with urllib.request.urlopen(f"{ollama_url}{path}", timeout=30) as res:
        return json.loads(res.read().decode("utf-8"))


def post_json(path, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{ollama_url}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as res:
        return json.loads(res.read().decode("utf-8"))


tags = get_json("/api/tags")
models = [m.get("name", "") for m in tags.get("models", []) if m.get("name")]

print("Available models:")
if models:
    for model in models:
        print(f"  - {model}")
else:
    raise SystemExit("No models are installed. Run ./pull-models.sh first.")

preferred = [
    "qwen2.5-coder:7b-instruct-q4_K_M",
    "qwen3:4b-instruct",
    "qwen3:1.7b-q8_0",
]

model = requested_model
if not model:
    model = next((candidate for candidate in preferred if candidate in models), models[0])

print(f"\nSending smoke prompt to: {model}")
start = time.perf_counter()
response = post_json(
    "/api/generate",
    {
        "model": model,
        "prompt": "Reply with exactly: local ai smoke test ok",
        "stream": False,
        "options": {"num_predict": 32, "temperature": 0},
    },
)
elapsed = time.perf_counter() - start
text = response.get("response", "").strip()
eval_count = response.get("eval_count") or 0
eval_duration = response.get("eval_duration") or 0
tok_s = eval_count / (eval_duration / 1_000_000_000) if eval_duration else 0

print(f"Response time: {elapsed:.2f}s")
print(f"Model used: {model}")
print(f"Generated tokens/sec: {tok_s:.2f}")
print(f"Response: {text}")
PY
