[CmdletBinding()]
param(
  [string]$Model
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if (-not $Model) {
  $Model = "qwen3-coder:30b"
  if (Test-Path ".env") {
    foreach ($line in Get-Content ".env") {
      if ($line -match "^\s*DEFAULT_MODEL=(.*)$" -and $matches[1].Trim()) {
        $Model = $matches[1].Trim().Trim('"')
      }
    }
  }
}

Write-Host "Pulling model: $Model"
& docker compose exec ollama ollama pull $Model
