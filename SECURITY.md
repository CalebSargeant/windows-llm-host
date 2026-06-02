# Security Policy

windows-llm-host is built for private LAN use.

Do not expose the proxy directly to the public internet. Keep `LLM_HOST_API_KEY` set, and prefer a private network or VPN-style tool for access away from home.

The proxy uses HTTP bearer-token authentication. It does not terminate TLS, manage users, rate-limit clients, or provide internet-facing hardening.

If the key leaks, replace `LLM_HOST_API_KEY` in `.env` and restart:

```powershell
.\scripts\start.ps1 -Build
```
