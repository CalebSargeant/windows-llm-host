# windows-llm-host

Host a local LLM API from a Windows laptop or desktop.

The setup optimizes for local capability first, then makes it easy to use the machine as an API source from your own devices. Ollama runs inside Docker, Open WebUI gives you a browser UI, and a tiny API proxy exposes both Ollama's native API and Ollama's OpenAI-compatible `/v1` API.

The API proxy is LAN-visible by default and protected with a generated bearer token. Open WebUI stays localhost-only unless you explicitly expose it. The stack does not add moderation services, safety filters, prompt wrappers, or assistant-personality system prompts.

## Quick Start

From Windows PowerShell, run this one command to install or update the local checkout, refresh Docker, start the stack, pull the default model, and run a smoke test:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CalebSargeant/windows-llm-host/main/scripts/install-or-update.ps1)))
```

That installs into `%USERPROFILE%\windows-llm-host` by default. It prints the generated `LLM_HOST_API_KEY` in the terminal and stores it in `.env`.

Run PowerShell as Administrator if you want the command to open the Windows Firewall rule automatically; otherwise it will tell you the one elevated firewall command to run if LAN devices cannot connect.

After the first setup, rerun the same command any time you want to update the local checkout and running containers.

The installer works in the stock Windows PowerShell that ships with Windows. PowerShell 7 is supported, but not required.

From an existing checkout on Windows, you can also run:

```powershell
.\scripts\bootstrap.ps1
```

For manual Docker Compose usage, create `.env` and set `LLM_HOST_API_KEY` first:

```bash
cp .env.example .env
# edit .env and set LLM_HOST_API_KEY before starting the LAN-visible API
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
- LAN API proxy: `http://<windows-machine-ip>:11434`

To force local-only API binding:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CalebSargeant/windows-llm-host/main/scripts/install-or-update.ps1))) -LocalOnly
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

## Updating and Versioning

The repo carries its version in the `VERSION` file. Re-running the install one-liner (or `.\scripts\install-or-update.ps1`) updates your checkout and containers in place while preserving `.env`, downloaded models, and Open WebUI/Ollama data. After an update it prints the installed version and tells you whether a newer GitHub release exists.

Check for updates without changing anything:

```powershell
.\scripts\check-update.ps1                 # compare against the latest stable release
.\scripts\check-update.ps1 -Channel main   # compare your checkout against origin/main
.\scripts\check-update.ps1 -Json           # machine-readable output for scripts/GUI
```

Apply an available update:

```powershell
.\scripts\check-update.ps1 -Update
```

Pick what the installer tracks with `-Channel`:

- `main` (default): the rolling `main` branch — newest changes, may be unreleased.
- `stable`: the latest tagged GitHub release.
- `prerelease`: the latest release including prereleases.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CalebSargeant/windows-llm-host/main/scripts/install-or-update.ps1))) -Channel stable
```

`check-update.ps1` exits with code `10` when an update is available and `0` otherwise, so you can wire it into a scheduled task or a future GUI. Until releases are published, the stable/prerelease channels simply report that none were found and change nothing.

## What Changed

- The compose file is now named `docker-compose.yml`, so `docker compose up -d` works without `-f`.
- Ollama uses `gpus: all`, the direct Compose equivalent of `docker run --gpus all`.
- The windows-llm-host API proxy binds to `0.0.0.0` by default for LAN access.
- Open WebUI binds to `127.0.0.1` by default for local-only browser access.
- Ollama is no longer published directly to the host; the proxy publishes native `/api/*` and OpenAI-compatible `/v1/*`.
- Set `LLM_HOST_API_KEY` to require a bearer token on every proxied API request.
- Ollama has a healthcheck, and Open WebUI waits for Ollama before starting.
- Open WebUI connects to Ollama through Docker networking at `http://ollama:11434`.
- Persistent volumes are kept: `ollama_data` and `webui_data`.
- Model pulling, smoke testing, and benchmarking are scripted.

## Prerequisites

### 1. NVIDIA Windows Driver

If you want GPU acceleration, install a current NVIDIA Windows driver that supports WSL2 CUDA/GPU-PV. The Studio Driver is usually a good choice for laptop development.

Check from Windows PowerShell:

```powershell
nvidia-smi
```

You should see your NVIDIA GPU, driver version, CUDA version, memory usage, and running processes.

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
- Give Docker enough CPU, memory, and swap for the model sizes you plan to run.

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

Model performance depends heavily on GPU VRAM, system RAM, context length, and quantization. Small quantized models can often run mostly on GPU. Larger models may spill into system RAM and use CPU heavily, which is expected but slower.

Recommended defaults:

| Role | Model | Size | Why |
|---|---:|---:|---|
| Fastest model | `qwen3:1.7b-q8_0` | 2.2 GB | Fast sanity checks and quick answers. |
| Best daily model | `qwen3:4b-instruct` | 2.5 GB | Good balance for limited-VRAM machines. Modern general model, long context tag. |
| Best coding model | `qwen2.5-coder:7b-instruct-q4_K_M` | 4.7 GB | Strong practical code model. May partially offload to CPU/RAM on modest GPUs. |
| Higher quality, slower | `qwen3:14b-q4_K_M` | 9.3 GB | Better reasoning than small models, but it will lean on CPU/RAM. |
| Strong reasoning candidate | `gpt-oss:20b` | ~13 GB | Worth benchmarking against Qwen3 14B/30B for reasoning-heavy tasks. |
| Heavy coding | `qwen3-coder:30b` | 19 GB | Strong 30B coding candidate. Slow and RAM heavy. |
| Heavy general | `qwen3:30b-instruct` | 19 GB | Stronger 30B general model. Use when latency does not matter. |
| Max coding | `qwen2.5-coder:32b` | ~20 GB | 32B coding model. Wants a big-RAM machine. |
| Max general (`max` ceiling) | `llama3.3:70b` | ~43 GB | 70B-class general model. Needs ~48 GB+ free RAM. Very slow on CPU, maximum local capability. |
| Extreme general (alt 70B) | `qwen2.5:72b` | ~47 GB | Alternative 70B-class general model. `extreme` profile only. |
| Extreme / experimental | `gpt-oss:120b` | ~65 GB | Will exceed 64 GB RAM and thrash swap. `extreme` profile, opt-in only. |

The `max` profile pulls everything up to the 70B-class `llama3.3:70b`, which fits in RAM on a 64 GB machine (it runs almost entirely on CPU/RAM, so it is slow but maximally capable). The `extreme` profile additionally pulls models that can exceed 64 GB RAM and thrash swap — only use it if you have the RAM and have read the warnings. Pick the largest model whose latency and RAM footprint your machine can tolerate; benchmark before committing to a daily driver.

Useful Ollama model pages:

- Qwen3 tags: <https://ollama.com/library/qwen3/tags>
- Qwen2.5-Coder tags: <https://ollama.com/library/qwen2.5-coder/tags>
- Qwen3-Coder: <https://ollama.com/library/qwen3-coder>
- GPT-OSS with Ollama: <https://cookbook.openai.com/articles/gpt-oss/run-locally-ollama>

### Best Daily Model

Use `qwen3:4b-instruct`.

It is the best general default when you want faster local interaction. It should be the first model you try in Open WebUI for normal chat, summarization, light coding, and analysis.

### Best Coding Model

Use `qwen2.5-coder:7b-instruct-q4_K_M`.

It is the recommended default model for API and coding use. Expect slower responses than the 4B model, but better code.

### Fastest Model

Use `qwen3:1.7b-q8_0`.

Use it for smoke tests, quick command generation, simple transformations, and low-latency automation where intelligence matters less.

### Highest Quality But Slower Model

Use `qwen3:14b-q4_K_M` first.

If you are willing to go heavier, benchmark `gpt-oss:20b`, `qwen3-coder:30b`, `qwen3:30b-instruct`, and `qwen2.5-coder:32b`. On a big-RAM machine (≈48 GB+ free) the `max` profile also pulls `llama3.3:70b` for maximum general capability, and the `extreme` profile adds `qwen2.5:72b` plus the experimental `gpt-oss:120b`. These are not comfortable small-machine models. They run mostly on CPU/RAM, so they are slow but maximally capable.

## Pulling Models

Recommended set:

```bash
./pull-models.sh
```

Fast-only set:

```bash
PROFILE=fast ./pull-models.sh
```

Maximum quality/heavy set (up to the 70B-class `llama3.3:70b`):

```bash
PROFILE=max ./pull-models.sh
```

Everything, including experimental models that may exceed 64 GB RAM and thrash swap:

```bash
PROFILE=extreme ./pull-models.sh
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

Heavy/max profile (up to 70B-class):

```bash
BENCH_PROFILE=max ./benchmark-models.sh
```

Extreme profile (includes models that may exceed 64 GB RAM):

```bash
BENCH_PROFILE=extreme ./benchmark-models.sh
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
   - Memory: enough for your largest planned model
   - Swap: enough headroom for larger models to spill without crashing
4. Optional WSL config at `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=<memory limit>
processors=<cpu count>
swap=<swap size>
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

Keep `OLLAMA_NUM_PARALLEL=1` for heavy models. Parallel requests can multiply memory pressure and make large models unusable on smaller machines.

## Game Mode (pause while gaming)

When you start a game, you usually want the GPU, CPU, RAM, and thermal headroom back. `scripts/game-mode-watcher.ps1` watches for a gaming/performance-sensitive state and pauses the Docker stack, then restores it when you are done.

Windows does not expose a reliable "Game Mode is active right now" API, so the watcher infers it from two signals:

- A full-screen foreground window that is not the Windows shell (how nearly every game presents).
- Any process you list in `GAME_MODE_PROCESSES` (game launchers or specific games).

It is fully opt-in. Nothing pauses your stack unless you run the watcher or install the scheduled task.

Run it in the foreground:

```powershell
.\scripts\game-mode-watcher.ps1
```

Install a background per-user Scheduled Task (no admin needed) that checks every couple of minutes and at logon:

```powershell
.\scripts\game-mode-watcher.ps1 -Install
```

Other commands:

```powershell
.\scripts\game-mode-watcher.ps1 -Status      # show detection state and whether the watcher paused the stack
.\scripts\game-mode-watcher.ps1 -Once -WhatIf # one check, dry run, no Docker changes
.\scripts\game-mode-watcher.ps1 -Uninstall   # remove the scheduled task
```

Configure behavior in `.env` (or with parameters):

| Setting | Default | Meaning |
|---|---|---|
| `GAME_MODE_ACTION` | `stop` | `stop` keeps containers (fast resume); `down` removes them but keeps models. |
| `GAME_MODE_RESTORE` | `true` | Restart the stack after the game exits. Set `false` to leave it down. |
| `GAME_MODE_USE_FULLSCREEN` | `true` | Treat any full-screen non-shell foreground window as a game. |
| `GAME_MODE_PROCESSES` | _(empty)_ | Comma-separated process names (no `.exe`) to always treat as games. |
| `GAME_MODE_POLL_SECONDS` | `15` | Seconds between checks in continuous mode (also the scheduled-task interval, min 60s). |
| `GAME_MODE_COOLDOWN_SECONDS` | `60` | How long the gaming state must stay clear before restoring. |

The watcher only restores a stack that *it* paused (tracked in `.game-mode-state`), so it will not restart a stack you stopped yourself. If you also use the full-screen signal, note that full-screen video players will look like a game; add real games to `GAME_MODE_PROCESSES` and set `GAME_MODE_USE_FULLSCREEN=false` if you prefer process-only detection.

## API Usage

The windows-llm-host API proxy is reachable from the Windows host at:

```text
http://localhost:11434
```

From another device on the same LAN, use:

```text
http://<windows-machine-ip>:11434
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

For LAN clients:

```bash
export LOCAL_AI_BASE_URL=http://<windows-machine-ip>:11434
export LOCAL_AI_MODEL=qwen2.5-coder:7b-instruct-q4_K_M
export LLM_HOST_API_KEY=your-generated-key
```

For Open WebUI startup defaults, set:

```bash
DEFAULT_MODEL=qwen2.5-coder:7b-instruct-q4_K_M docker compose up -d
```

This affects Open WebUI's default/pinned model list, not Ollama's native API behavior.

## Optional API Hardening

Default API behavior is LAN-visible with bearer-token authentication:

```yaml
0.0.0.0:11434:8080
127.0.0.1:3000:8080
```

The installer and bootstrap scripts generate `LLM_HOST_API_KEY` and print it in the terminal. To set a key manually:

```bash
LLM_HOST_API_KEY="$(openssl rand -base64 32)" \
API_BIND=0.0.0.0 \
docker compose up -d
```

To bind the API to localhost only:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/CalebSargeant/windows-llm-host/main/scripts/install-or-update.ps1))) -LocalOnly
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

Use `qwen2.5-coder:7b-instruct-q4_K_M` as the default API/coding model. It is the strongest practical coding model in the default pull set.

Use `qwen3:4b-instruct` as the default chat/daily model when you want faster local interaction.

Use `qwen3:14b-q4_K_M`, `gpt-oss:20b`, the 30B Qwen3 models, `qwen2.5-coder:32b`, and the 70B-class `llama3.3:70b` (`max` profile) only after benchmarking. The `extreme` profile (`qwen2.5:72b`, `gpt-oss:120b`) is opt-in and can exceed 64 GB RAM. These are included for maximum capability, not comfort.
