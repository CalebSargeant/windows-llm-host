[CmdletBinding()]
param(
  [string]$Model
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

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

if (-not $Model) {
  $Model = Get-DotEnvValue -Name "DEFAULT_MODEL" -Default "qwen3-coder:30b"
}

$bind = Get-DotEnvValue -Name "API_BIND" -Default "0.0.0.0"
$hostName = if ($bind -eq "0.0.0.0") { "localhost" } else { $bind }
$port = Get-DotEnvValue -Name "API_PORT" -Default "11434"
$apiKey = Get-DotEnvValue -Name "LLM_HOST_API_KEY"

$headers = @{
  "Content-Type" = "application/json"
}

if ($apiKey) {
  $headers["Authorization"] = "Bearer $apiKey"
}

$body = @{
  model = $Model
  stream = $false
  messages = @(
    @{
      role = "user"
      content = "Reply with exactly: windows-llm-host is online."
    }
  )
} | ConvertTo-Json -Depth 6

$uri = "http://$hostName`:$port/v1/chat/completions"
Write-Host "Testing $uri with model $Model"

$response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
$message = $response.choices[0].message.content

Write-Host ""
Write-Host $message
