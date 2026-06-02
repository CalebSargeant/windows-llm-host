#!/usr/bin/env bash
# Pull and benchmark candidate Ollama models with a repeatable prompt.
#
# Usage:
#   ./benchmark-models.sh
#   BENCH_PROFILE=max ./benchmark-models.sh
#   ./benchmark-models.sh qwen3:4b-instruct qwen2.5-coder:7b-instruct-q4_K_M

set -euo pipefail

CONTAINER="${OLLAMA_CONTAINER:-windows-llm-host-ollama}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
LLM_HOST_API_KEY="${LLM_HOST_API_KEY:-}"
BENCH_PROFILE="${BENCH_PROFILE:-recommended}"
NUM_PREDICT="${NUM_PREDICT:-220}"
NUM_CTX="${NUM_CTX:-4096}"
RESULT_DIR="${RESULT_DIR:-benchmark-results}"
PROMPT="${PROMPT:-You are helping evaluate a local coding model. In Python, write a function that parses a list of web server log lines, returns the top 3 IP addresses by request count, ignores malformed lines, and include a brief explanation of edge cases.}"

FAST_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model"
  "qwen3:4b-instruct|Best daily small model"
)

RECOMMENDED_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model"
  "qwen3:4b-instruct|Best daily model"
  "qwen2.5-coder:7b-instruct-q4_K_M|Best practical coding model"
  "qwen3:14b-q4_K_M|Stronger quality model"
)

MAX_MODELS=(
  "qwen3:1.7b-q8_0|Fastest model"
  "qwen3:4b-instruct|Best daily model"
  "qwen2.5-coder:7b-instruct-q4_K_M|Best practical coding model"
  "qwen3:14b-q4_K_M|Stronger quality model"
  "gpt-oss:20b|Strong reasoning candidate"
  "qwen3-coder:30b|Max quality coding mode"
  "qwen3:30b-instruct|Max quality general mode"
)

CUSTOM_MODELS=()

if [ "$#" -gt 0 ]; then
  for model in "$@"; do
    CUSTOM_MODELS+=("${model}|Custom candidate")
  done
  MODEL_ROWS=("${CUSTOM_MODELS[@]}")
else
  case "$BENCH_PROFILE" in
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
      echo "Unknown BENCH_PROFILE='$BENCH_PROFILE'. Use fast, recommended, or max." >&2
      exit 2
      ;;
  esac
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "ERROR: Python 3 is required for JSON parsing and benchmark output." >&2
  exit 1
fi

echo "Starting stack..."
docker compose up -d

echo "Waiting for Ollama at ${OLLAMA_URL}..."
AUTH_CURL_ARGS=()
if [ -n "$LLM_HOST_API_KEY" ]; then
  AUTH_CURL_ARGS=(-H "Authorization: Bearer ${LLM_HOST_API_KEY}")
fi

for _ in $(seq 1 60); do
  if curl -fsS "${AUTH_CURL_ARGS[@]}" "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "${AUTH_CURL_ARGS[@]}" "${OLLAMA_URL}/api/tags" >/dev/null

echo "Pulling benchmark candidates..."
for row in "${MODEL_ROWS[@]}"; do
  IFS='|' read -r model label <<< "$row"
  echo "==> ${model} (${label})"
  docker exec "$CONTAINER" ollama pull "$model"
done

BENCH_ROWS="$(printf '%s\n' "${MODEL_ROWS[@]}")"
export BENCH_ROWS CONTAINER OLLAMA_URL LLM_HOST_API_KEY NUM_PREDICT NUM_CTX RESULT_DIR PROMPT

"$PYTHON_BIN" - <<'PY'
import csv
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

container = os.environ["CONTAINER"]
ollama_url = os.environ["OLLAMA_URL"].rstrip("/")
llm_host_api_key = os.environ.get("LLM_HOST_API_KEY", "").strip()
rows = [line.split("|", 1) for line in os.environ["BENCH_ROWS"].splitlines() if line.strip()]
num_predict = int(os.environ["NUM_PREDICT"])
num_ctx = int(os.environ["NUM_CTX"])
prompt = os.environ["PROMPT"]
result_dir = Path(os.environ["RESULT_DIR"])
result_dir.mkdir(parents=True, exist_ok=True)
stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
csv_path = result_dir / f"ollama-benchmark-{stamp}.csv"
md_path = result_dir / f"ollama-benchmark-{stamp}.md"
latest_md = result_dir / "latest.md"


def run_cmd(cmd, timeout=20):
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)
        if proc.returncode == 0:
            return proc.stdout.strip()
    except Exception:
        return ""
    return ""


def post_json(path, payload, timeout=1800):
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if llm_host_api_key:
        headers["Authorization"] = f"Bearer {llm_host_api_key}"
    req = urllib.request.Request(
        f"{ollama_url}{path}",
        data=data,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as res:
        return json.loads(res.read().decode("utf-8"))


def docker_mem():
    return run_cmd(["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", container], timeout=10)


def parse_gpu_sample(text):
    samples = []
    for line in text.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 2:
            continue
        try:
            samples.append({"util": int(parts[0]), "mem": int(parts[1])})
        except ValueError:
            continue
    return samples


def gpu_sample():
    query = [
        "nvidia-smi",
        "--query-gpu=utilization.gpu,memory.used",
        "--format=csv,noheader,nounits",
    ]
    text = run_cmd(["docker", "exec", container, *query], timeout=5)
    if not text:
        text = run_cmd(query, timeout=5)
    return parse_gpu_sample(text)


def benchmark(model, label):
    run_cmd(["docker", "exec", container, "ollama", "stop", model], timeout=30)
    time.sleep(2)

    mem_before = docker_mem()
    samples = []
    stop_event = threading.Event()

    def monitor():
        while not stop_event.is_set():
            samples.extend(gpu_sample())
            time.sleep(0.25)

    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    start = time.perf_counter()
    error = ""
    data = {}
    try:
        data = post_json(
            "/api/generate",
            {
                "model": model,
                "prompt": prompt,
                "stream": False,
                "keep_alive": "0s",
                "options": {
                    "temperature": 0.1,
                    "num_predict": num_predict,
                    "num_ctx": num_ctx,
                },
            },
        )
    except urllib.error.HTTPError as exc:
        error = f"HTTP {exc.code}: {exc.read().decode('utf-8', errors='replace')[:200]}"
    except Exception as exc:
        error = str(exc)
    wall_s = time.perf_counter() - start
    stop_event.set()
    thread.join(timeout=2)
    mem_after = docker_mem()

    eval_count = int(data.get("eval_count") or 0)
    eval_duration_ns = int(data.get("eval_duration") or 0)
    prompt_eval_count = int(data.get("prompt_eval_count") or 0)
    prompt_eval_duration_ns = int(data.get("prompt_eval_duration") or 0)
    load_duration_ns = int(data.get("load_duration") or 0)
    total_duration_ns = int(data.get("total_duration") or 0)
    eval_tps = eval_count / (eval_duration_ns / 1_000_000_000) if eval_duration_ns else 0.0
    prompt_tps = prompt_eval_count / (prompt_eval_duration_ns / 1_000_000_000) if prompt_eval_duration_ns else 0.0
    peak_gpu_util = max([s["util"] for s in samples], default=0)
    peak_gpu_mem = max([s["mem"] for s in samples], default=0)
    gpu_used = "yes" if peak_gpu_util > 0 or peak_gpu_mem > 256 else "unknown/no"

    return {
        "role": label,
        "model": model,
        "eval_tokens": eval_count,
        "tokens_per_sec": round(eval_tps, 2),
        "prompt_tokens_per_sec": round(prompt_tps, 2),
        "load_sec": round(load_duration_ns / 1_000_000_000, 2),
        "total_sec_api": round(total_duration_ns / 1_000_000_000, 2),
        "wall_sec": round(wall_s, 2),
        "docker_mem_before": mem_before,
        "docker_mem_after": mem_after,
        "peak_gpu_util_pct": peak_gpu_util,
        "peak_gpu_mem_mb": peak_gpu_mem,
        "gpu_used": gpu_used,
        "error": error,
    }


results = []
for model, label in rows:
    print(f"\nBenchmarking {model} ({label})")
    result = benchmark(model, label)
    results.append(result)
    if result["error"]:
        print(f"  error: {result['error']}")
    else:
        print(
            f"  {result['tokens_per_sec']} tok/s, load {result['load_sec']}s, "
            f"GPU {result['gpu_used']} peak {result['peak_gpu_mem_mb']} MB"
        )

fieldnames = [
    "role",
    "model",
    "eval_tokens",
    "tokens_per_sec",
    "prompt_tokens_per_sec",
    "load_sec",
    "total_sec_api",
    "wall_sec",
    "docker_mem_before",
    "docker_mem_after",
    "peak_gpu_util_pct",
    "peak_gpu_mem_mb",
    "gpu_used",
    "error",
]

with csv_path.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(results)

def md_table(results):
    lines = [
        "| Role | Model | tok/s | load s | wall s | Docker mem after | GPU peak | GPU used |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for r in results:
        tok = "ERR" if r["error"] else r["tokens_per_sec"]
        lines.append(
            f"| {r['role']} | `{r['model']}` | {tok} | {r['load_sec']} | "
            f"{r['wall_sec']} | {r['docker_mem_after']} | "
            f"{r['peak_gpu_util_pct']}% / {r['peak_gpu_mem_mb']} MB | {r['gpu_used']} |"
        )
    return "\n".join(lines)

preferred = None
for candidate in ("qwen2.5-coder:7b-instruct-q4_K_M", "qwen3:4b-instruct", "qwen3:14b-q4_K_M"):
    for r in results:
        if r["model"] == candidate and not r["error"]:
            preferred = candidate
            break
    if preferred:
        break

heavy = None
for candidate in ("qwen3-coder:30b", "qwen3:30b-instruct", "gpt-oss:20b"):
    for r in results:
        if r["model"] == candidate and not r["error"]:
            heavy = candidate
            break
    if heavy:
        break

md = [
    f"# Ollama Benchmark {stamp}",
    "",
    f"Prompt tokens are generated with num_ctx={num_ctx}, num_predict={num_predict}.",
    "",
    md_table(results),
    "",
    "## Recommendation Notes",
    "",
    f"- Default API model from this run: `{preferred or 'none'}`.",
    f"- Heavy quality candidate from this run: `{heavy or 'not tested'}`.",
    "- Treat tok/s as a usability signal, not a quality score. Pick the largest model whose latency you can tolerate.",
    "- GPU used is sampled through nvidia-smi. If it says unknown/no, check Docker GPU passthrough before trusting the speed result.",
    "",
    f"CSV: `{csv_path.name}`",
]

for path in (md_path, latest_md):
    path.write_text("\n".join(md) + "\n", encoding="utf-8")

print(f"\nWrote {csv_path}")
print(f"Wrote {md_path}")
print(f"Wrote {latest_md}")
PY
