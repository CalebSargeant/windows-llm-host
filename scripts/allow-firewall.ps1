[CmdletBinding()]
param(
  [int]$Port = 0
)

$ErrorActionPreference = "Stop"

if ($Port -eq 0) {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
  $envFile = Join-Path $RepoRoot ".env"
  if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
      if ($line -match "^\s*API_PORT=(.*)$" -and $matches[1].Trim()) {
        $Port = [int]$matches[1].Trim().Trim('"')
      }
    }
  }
}

if ($Port -eq 0) {
  $Port = 11434
}

$ruleName = "windows-llm-host API ($Port)"

Write-Host "Adding Windows Firewall rule: $ruleName"
Write-Host "Run this script from an elevated PowerShell session if it fails."

& netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$Port
