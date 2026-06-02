[CmdletBinding()]
param(
  [switch]$Gpu,
  [switch]$Lan,
  [switch]$Build,
  [string]$Port
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env. Edit LLM_HOST_API_KEY before exposing this to a network."
}

function Get-DotEnvValue {
  param(
    [string]$Name,
    [string]$Default = ""
  )

  $envItem = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
  if ($envItem -and $envItem.Value) {
    return $envItem.Value
  }

  if (Test-Path ".env") {
    foreach ($line in Get-Content ".env") {
      if ($line -match "^\s*$([regex]::Escape($Name))=(.*)$") {
        return $matches[1].Trim().Trim('"')
      }
    }
  }

  return $Default
}

if ($Lan) {
  $env:API_BIND = "0.0.0.0"
}

if ($Port) {
  $env:API_PORT = $Port
}

$composeArgs = @("compose", "up", "-d")
if ($Build) {
  $composeArgs += "--build"
}

& docker @composeArgs

$bind = Get-DotEnvValue -Name "API_BIND" -Default "127.0.0.1"
$displayHost = if ($bind -eq "0.0.0.0") { "<this-laptop-ip>" } else { $bind }
$displayPort = Get-DotEnvValue -Name "API_PORT" -Default "11434"

Write-Host ""
Write-Host "windows-llm-host is starting."
Write-Host "Local health: http://localhost:$displayPort/health"
Write-Host "OpenAI base URL: http://$displayHost`:$displayPort/v1"
Write-Host "Native Ollama API: http://$displayHost`:$displayPort/api"

if ($Lan) {
  Write-Host ""
  Write-Host "LAN mode is enabled. Keep LLM_HOST_API_KEY set, and open the Windows firewall if needed:"
  Write-Host ".\scripts\allow-firewall.ps1"
}

if ($Gpu) {
  Write-Host ""
  Write-Host "GPU mode is already enabled by docker-compose.yml with gpus: all."
}
