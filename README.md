# windows-llm-host

Local LLM stack for a Windows laptop with:

- NVIDIA RTX A2000 Laptop GPU, 4 GB dedicated VRAM
- Intel Iris Xe integrated graphics
- 64 GB system RAM
- Docker Desktop using the WSL2 backend

The setup optimizes for maximum local capability first, then makes it easy to use the laptop as a local API source from your own devices. Ollama runs inside Docker, Open WebUI gives you a browser UI, and a tiny API proxy exposes both Ollama's native API and Ollama's OpenAI-compatible `/v1` API.

It does not add moderation services, safety filters, prompt wrappers, or assistant-personality system prompts. It is normal local Ollama/Open WebUI usage with persistent local data. The proxy adds optional bearer-token authentication for LAN use.

## Quick Start

Run these commands from this directory:

```bash
docker compose up -d
./pull-models.sh
./smoke-test.sh
```

If your shell reports `Permission denied` for the scripts, run:

```bash
chmod +x pull-models.sh benchmark-models.sh smoke-test.sh
```

Then open:

- Open WebUI: <http://localhost:3000>
- windows-llm-host API proxy: <http://localhost:11434>

From Windows PowerShell, you can also run:

```powershell
.\scripts\bootstrap.ps1
```

For LAN API access from another device:

```powershell
.\scripts\bootstrap.ps1 -Lan
```

Run the firewall helper from an elevated PowerShell session if other LAN devices cannot reach the API:

```powershell
.\scripts\allow-firewall.ps1
```

Stop the stack without deleting models:

```bash
docker compose down
```

Delete downloaded models and Open WebUI data only when you really want to reset:

```bash
docker compose down -v
```

## What Changed

- The compose file is now named `docker-compose.yml`, so `docker compose up -d` works without `-f`.
- Ollama uses `gpus: all`, the direct Compose equivalent of `docker run --gpus all`.
- The windows-llm-host API proxy and Open WebUI ports bind to `127.0.0.1` by default for local-only exposure.
- Ollama is no longer published directly to the host; the proxy publishes native `/api/*` and OpenAI-compatible `/v1/*`.
- Set `LLM_HOST_API_KEY` to require a bearer token on every proxied API request.
- Ollama has a healthcheck, and Open WebUI waits for Ollama before starting.
- Open WebUI connects to Ollama through Docker networking at `http://ollama:11434`.
- Persistent volumes are kept: `ollama_data` and `webui_data`.
- Model pulling, smoke testing, and benchmarking are scripted.

## Prerequisites

### 1. NVIDIA Windows Driver

Install a current NVIDIA Windows driver that supports WSL2 CUDA/GPU-PV. The Studio Driver is usually a good choice for laptop development.

Check from Windows PowerShell:

```powershell
nvidia-smi
```

You should see the RTX A2000 Laptop GPU, driver version, CUDA version, memory usage, and running processes.

### 2. WSL2 GPU Support

Update WSL from Windows PowerShell:

```powershell
wsl --update
wsl --shutdown
```

Then start your WSL distro and check:

```bash
nvidia-smi
ls -l /dev/dxg
```

If `nvidia-smi` is missing inside WSL, first make sure it works on the Windows host. On WSL it is normally exposed through the Windows driver, not by installing a separate Linux display driver.

### 3. Docker Desktop GPU Passthrough

In Docker Desktop:

- Use the WSL2 backend.
- Enable integration with your WSL distro.
- Give Docker enough resources for heavy models. For this laptop, start with 48 GB memory, all available CPUs, and at least 8 GB swap.

Validate Docker GPU access:

```bash
docker run --rm --gpus all nvidia/cuda:12.5.0-base-ubuntu22.04 nvidia-smi
```

Validate inside this Ollama container after startup:

```bash
docker compose up -d
docker exec windows-llm-host-ollama nvidia-smi
docker exec windows-llm-host-ollama ollama list
```

If the container cannot see `nvidia-smi`, fix Docker Desktop GPU passthrough before benchmarking models.

## GPU Compose Notes

The old file used:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

Modern Docker Compose does support GPU device reservations through the Compose Deploy `devices` syntax, so it is not purely a Swarm-only setting anymore. However, for a single-machine laptop stack, the service-level syntax is clearer and maps directly to the Docker GPU request:

```yaml
gpus: all
```

This repo uses `gpus: all`. It requires Docker Compose 2.30.0 or newer. Check:

```bash
docker compose version
docker compose config
```

If `docker compose config` rejects `gpus`, upgrade Docker Desktop. As a temporary fallback, replace `gpus: all` with the old `deploy.resources.reservations.devices` block above.

References:

- Docker Compose `gpus`: <https://docs.docker.com/reference/compose-file/services/#gpus>
- Docker Compose deploy device reservations: <https://docs.docker.com/reference/compose-file/deploy/#devices>
- Docker Desktop GPU support on Windows/WSL2: <https://docs.docker.com/desktop/features/gpu/>
- Ollama Docker GPU docs: <https://docs.ollama.com/docker>

## Model Strategy

The hard limit is 4 GB VRAM. Small quantized models can run mostly on GPU. Larger models will spill into system RAM and use CPU heavily. That is expected. With 64 GB RAM, you can run stronger models, but generation can become slow.

Recommended defaults:

| Role | Model | Size | Why |
|---|---:|---:|---|
| Fastest model | `qwen3:1.7b-q8_0` | 2.2 GB | Fast sanity checks and quick answers. |
| Best daily model | `qwen3:4b-instruct` | 2.5 GB | Best balance for this 4 GB VRAM laptop. Modern general model, long context tag. |
| Best coding model | `qwen2.5-coder:7b-instruct-q4_K_M` | 4.7 GB | Strong practical code model. Likely partial GPU plus CPU/RAM on this GPU. |
| Highest quality but slower | `qwen3:14b-q4_K_M` | 9.3 GB | Better reasoning than small models, but it will lean on CPU/RAM. |
| Max quality / heavy coding | `qwen3-coder:30b` | 19 GB | Strongest coding candidate here. It will be slow and RAM heavy. |
| Max quality / heavy general | `qwen3:30b-instruct` | 19 GB | Stronger general model. Use when latency does not matter. |
| Strong reasoning candidate | `gpt-oss:20b` | large | Worth benchmarking against Qwen3 14B/30B for reasoning-heavy tasks. |

Useful Ollama model pages:

- Qwen3 tags: <https://ollama.com/library/qwen3/tags>
- Qwen2.5-Coder tags: <https://ollama.com/library/qwen2.5-coder/tags>
- Qwen3-Coder: <https://ollama.com/library/qwen3-coder>
- GPT-OSS with Ollama: <https://cookbook.openai.com/articles/gpt-oss/run-locally-ollama>

### Best Daily Model

Use `qwen3:4b-instruct`.

It is the best general default for this laptop because it is small enough to behave well with 4 GB VRAM, but much more capable than tiny models. It should be the first model you try in Open WebUI for normal chat, summarization, light coding, and analysis.

### Best Coding Model

Use `qwen2.5-coder:7b-instruct-q4_K_M`.

It is my recommended default model for API and coding use. It is larger than the GPU can fully hold once context/KV cache is included, but your 64 GB system RAM makes partial offload practical. Expect slower responses than the 4B model, but better code.

### Fastest Model

Use `qwen3:1.7b-q8_0`.

Use it for smoke tests, quick command generation, simple transformations, and low-latency automation where intelligence matters less.

### Highest Quality But Slower Model

Use `qwen3:14b-q4_K_M` first.

If you are willing to go heavier, benchmark `qwen3-coder:30b`, `qwen3:30b-instruct`, and `gpt-oss:20b`. These are not comfortable 4 GB VRAM models. They are included because you asked for maximum local capability and you have enough system RAM to try them.

## Pulling Models

Recommended set:

```bash
./pull-models.sh
```

Fast-only set:

```bash
PROFILE=fast ./pull-models.sh
```

Maximum quality/heavy set:

```bash
PROFILE=max ./pull-models.sh
```

Pull explicit models:

```bash
./pull-models.sh qwen3:4b-instruct qwen2.5-coder:7b-instruct-q4_K_M
```

`ollama pull` is idempotent. Re-running the script is safe.

## Benchmarking

Do not guess. Benchmark on your actual laptop:

```bash
./benchmark-models.sh
```

The benchmark and smoke-test scripts require Python 3 in the shell where you run them. On Ubuntu/WSL this is usually available as `python3`.

Fast profile:

```bash
BENCH_PROFILE=fast ./benchmark-models.sh
```

Heavy/max profile:

```bash
BENCH_PROFILE=max ./benchmark-models.sh
```

Custom list:

```bash
./benchmark-models.sh qwen3:4b-instruct qwen2.5-coder:7b-instruct-q4_K_M qwen3:14b-q4_K_M
```

Outputs are written to `benchmark-results/`:

- CSV with raw measurements
- Markdown recommendation table
- `benchmark-results/latest.md`

The benchmark captures:

- model load time
- total response time
- generated tokens/sec
- prompt tokens/sec
- Docker container memory
- sampled GPU utilization
- sampled GPU memory

## Smoke Test

After pulling at least one model:

```bash
./smoke-test.sh
```

Use a specific model:

```bash
MODEL=qwen3:4b-instruct ./smoke-test.sh
```

The smoke test starts the stack, checks Ollama health, lists installed models, sends a native Ollama API prompt, and prints response time plus tokens/sec.

## Maximum Performance Mode

This mode intentionally uses GPU, CPU, RAM, heat, and battery aggressively. Plug in the laptop and expect fan noise.

1. Set Windows power mode to Best performance.
2. In NVIDIA Control Panel, prefer maximum performance for Docker Desktop / WSL if available.
3. In Docker Desktop resources, allocate roughly:
   - CPUs: all or nearly all
   - Memory: 48 to 56 GB
   - Swap: 8 to 16 GB
4. Optional WSL config at `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=56GB
processors=20
swap=16GB
localhostForwarding=true
```

Apply WSL changes:

```powershell
wsl --shutdown
```

Then start again:

```bash
OLLAMA_KEEP_ALIVE=-1 \
OLLAMA_NUM_PARALLEL=1 \
OLLAMA_MAX_LOADED_MODELS=1 \
docker compose up -d

PROFILE=max ./pull-models.sh
BENCH_PROFILE=max ./benchmark-models.sh
```

Keep `OLLAMA_NUM_PARALLEL=1` for heavy models. Parallel requests can multiply memory pressure and make large models unusable on 4 GB VRAM.

## API Usage

The windows-llm-host API proxy is reachable from the Windows host at:

```text
http://localhost:11434
```

Open WebUI is reachable at:

```text
http://localhost:3000
```

Default API model recommendation:

```text
qwen2.5-coder:7b-instruct-q4_K_M
```

Use `qwen3:4b-instruct` if you want a faster daily default, and use `qwen3:14b-q4_K_M` or heavier models when quality matters more than latency.

If `LLM_HOST_API_KEY` is set, include it on API calls:

```bash
export LLM_HOST_API_KEY=your-key-here
curl http://localhost:11434/api/tags \
  -H "Authorization: Bearer ${LLM_HOST_API_KEY}"
```

### Ollama Native API: Generate

```bash
curl http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:7b-instruct-q4_K_M",
    "prompt": "Write a Python function that validates an IPv4 address.",
    "stream": false
  }'
```

### Ollama Native API: Chat

```bash
curl http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:7b-instruct-q4_K_M",
    "messages": [
      {"role": "user", "content": "Explain this Docker Compose GPU setting in one paragraph: gpus: all"}
    ],
    "stream": false
  }'
```

### Ollama OpenAI-Compatible API

The windows-llm-host API proxy forwards Ollama's OpenAI-compatible endpoint at `/v1/chat/completions`.

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:7b-instruct-q4_K_M",
    "messages": [
      {"role": "user", "content": "Write a compact Bash function that checks whether Docker is running."}
    ],
    "temperature": 0.2
  }'
```

### Open WebUI OpenAI-Compatible API

Open WebUI also exposes OpenAI-compatible chat through:

```text
http://localhost:3000/api/chat/completions
```

If `WEBUI_AUTH=false`, this is local-only but unauthenticated. If you set `WEBUI_AUTH=true`, create an API key in Open WebUI and call:

```bash
curl http://localhost:3000/api/chat/completions \
  -H "Authorization: Bearer YOUR_OPEN_WEBUI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen2.5-coder:7b-instruct-q4_K_M",
    "messages": [
      {"role": "user", "content": "Return a minimal docker compose healthcheck for a HTTP service."}
    ]
  }'
```

Open WebUI API docs:

- <https://docs.openwebui.com/reference/api-endpoints/>

### Python Native API Example

```python
import requests

model = "qwen2.5-coder:7b-instruct-q4_K_M"

response = requests.post(
    "http://localhost:11434/api/chat",
    json={
        "model": model,
        "messages": [
            {"role": "user", "content": "Write a small Python retry decorator."}
        ],
        "stream": False,
    },
    timeout=600,
)
response.raise_for_status()
print(response.json()["message"]["content"])
```

### Python OpenAI-Compatible Example

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11434/v1",
    api_key="ollama",
)

response = client.chat.completions.create(
    model="qwen2.5-coder:7b-instruct-q4_K_M",
    messages=[
        {"role": "user", "content": "Write a TypeScript debounce function."}
    ],
)

print(response.choices[0].message.content)
```

### Node.js Native API Example

```javascript
const model = "qwen2.5-coder:7b-instruct-q4_K_M";

const response = await fetch("http://localhost:11434/api/chat", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model,
    messages: [
      { role: "user", content: "Write a minimal Express health route." }
    ],
    stream: false
  })
});

if (!response.ok) {
  throw new Error(await response.text());
}

const data = await response.json();
console.log(data.message.content);
```

### Node.js OpenAI-Compatible Example

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:11434/v1",
  apiKey: "ollama"
});

const response = await client.chat.completions.create({
  model: "qwen2.5-coder:7b-instruct-q4_K_M",
  messages: [
    { role: "user", content: "Write a SQL query to find duplicate email addresses." }
  ]
});

console.log(response.choices[0].message.content);
```

### Calling From Another Docker Container

Containers on the same Compose network can call Ollama at:

```text
http://ollama:11434
```

They can also call the API proxy at:

```text
http://api:8080
```

Example service snippet:

```yaml
services:
  my-app:
    image: curlimages/curl:latest
    networks:
      - windows-llm-host-net
    command:
      - sh
      - -lc
      - |
        curl http://ollama:11434/api/generate \
          -H "Content-Type: application/json" \
          -d '{"model":"qwen3:4b-instruct","prompt":"Say ok","stream":false}'

networks:
  windows-llm-host-net:
    external: true
```

From a one-off container:

```bash
docker run --rm --network windows-llm-host-net curlimages/curl:latest \
  curl http://ollama:11434/api/tags
```

### Setting The Default Model For API Usage

The Ollama API does not have a global default model. Your API caller should set the model explicitly in each request.

Recommended app defaults:

```bash
export LOCAL_AI_BASE_URL=http://localhost:11434
export LOCAL_AI_MODEL=qwen2.5-coder:7b-instruct-q4_K_M
```

For Open WebUI startup defaults, set:

```bash
DEFAULT_MODEL=qwen2.5-coder:7b-instruct-q4_K_M docker compose up -d
```

This affects Open WebUI's default/pinned model list, not Ollama's native API behavior.

## Optional API Hardening

Default behavior is local-only:

```yaml
127.0.0.1:11434:8080
127.0.0.1:3000:8080
```

That means other machines on your LAN cannot call the API unless you opt in.

To expose the API proxy to your LAN with a bearer token:

```bash
LLM_HOST_API_KEY="$(openssl rand -base64 32)" \
API_BIND=0.0.0.0 \
docker compose up -d
```

From PowerShell:

```powershell
.\scripts\bootstrap.ps1 -Lan
```

Risk: LAN exposure lets other devices send prompts and consume CPU/GPU/RAM if they have the token. Do not expose this directly to the public internet.

Open WebUI remains localhost-only unless you also set `WEBUI_BIND=0.0.0.0`. If you expose Open WebUI, also set:

```bash
WEBUI_AUTH=true \
ENABLE_API_KEYS=true \
USER_PERMISSIONS_FEATURES_API_KEYS=true \
WEBUI_BIND=0.0.0.0 \
docker compose up -d
```

For access away from home, use a private network or VPN-style path such as Tailscale or WireGuard rather than opening this port on your router. If you still need a reverse proxy, keep authentication in front of it. Example Caddy concept:

```caddyfile
windows-llm-host.lan {
  bind 192.168.1.50
  basicauth {
    user JDJhJDE0JHVzZV9hX3JlYWxfaGFzaF9oZXJl
  }
  reverse_proxy 127.0.0.1:11434
}
```

This hardening is authentication and network control only. It does not add moderation, filtering, prompt rewriting, or behavioral restrictions.

## Troubleshooting

Check stack status:

```bash
docker compose ps
docker compose logs -f api
docker compose logs -f ollama
docker compose logs -f open-webui
```

Check GPU use while generating:

```bash
watch -n 0.5 nvidia-smi
```

If a model is too slow or fails to load:

- Reduce context length in your client or benchmark.
- Use `qwen3:4b-instruct` for daily use.
- Keep only one large model loaded with `OLLAMA_MAX_LOADED_MODELS=1`.
- Keep parallelism low with `OLLAMA_NUM_PARALLEL=1`.
- Make sure Docker Desktop has enough RAM and swap.

## Final Recommendation

Use `qwen2.5-coder:7b-instruct-q4_K_M` as the default API/coding model. It is the strongest practical coding model in the default pull set and takes advantage of your 64 GB RAM when the 4 GB GPU is not enough.

Use `qwen3:4b-instruct` as the default chat/daily model when you want faster local interaction.

Use `qwen3:14b-q4_K_M`, `qwen3-coder:30b`, `qwen3:30b-instruct`, and `gpt-oss:20b` only after benchmarking. They are included for maximum capability, not comfort.
