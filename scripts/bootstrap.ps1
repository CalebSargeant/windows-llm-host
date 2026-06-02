[CmdletBinding()]
param(
  [string]$Model,
  [switch]$Gpu,
  [switch]$Lan,
  [switch]$SkipPull
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function New-LlmHostApiKey {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
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

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env"
}

$currentKey = Get-DotEnvValue -Name "LLM_HOST_API_KEY"
if (-not $currentKey) {
  $newKey = New-LlmHostApiKey
  $envContent = Get-Content ".env" -Raw
  if ($envContent -match "(?m)^LLM_HOST_API_KEY=") {
    $envContent = $envContent -replace "(?m)^LLM_HOST_API_KEY=.*$", "LLM_HOST_API_KEY=$newKey"
  } else {
    $envContent = $envContent.TrimEnd() + "`nLLM_HOST_API_KEY=$newKey`n"
  }
  Set-Content ".env" $envContent -NoNewline -Encoding utf8
  Write-Host "Generated LLM_HOST_API_KEY in .env"
}

if (-not $Model) {
  $Model = Get-DotEnvValue -Name "DEFAULT_MODEL" -Default "qwen2.5-coder:7b-instruct-q4_K_M"
}

& (Join-Path $PSScriptRoot "start.ps1") -Gpu:$Gpu -Lan:$Lan -Build

if (-not $SkipPull) {
  & (Join-Path $PSScriptRoot "pull-model.ps1") -Model $Model
  & (Join-Path $PSScriptRoot "smoke-test.ps1") -Model $Model
}

Write-Host ""
Write-Host "windows-llm-host is ready."
Write-Host "Model: $Model"
Write-Host "API key: stored in .env as LLM_HOST_API_KEY"
