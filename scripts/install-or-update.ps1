[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "windows-llm-host"),
  [string]$RepoUrl = "https://github.com/CalebSargeant/windows-llm-host.git",
  [string]$Branch = "main",
  [string]$Model,
  [string]$Port,
  [switch]$Lan,
  [switch]$ForceReset,
  [switch]$SkipModelPull,
  [switch]$SkipSmokeTest,
  [switch]$NoFirewall
)

$ErrorActionPreference = "Stop"

function Assert-Command {
  param(
    [string]$Name,
    [string]$InstallHint
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is required. $InstallHint"
  }
}

function Invoke-Checked {
  param(
    [string]$Command,
    [string[]]$Arguments
  )

  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
  }
}

function Test-IsAdmin {
  if ($env:OS -ne "Windows_NT") {
    return $false
  }

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-ForDocker {
  param([int]$TimeoutSeconds = 180)

  if (& docker version --format "{{.Server.Version}}" 2>$null) {
    return
  }

  $dockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dockerDesktop) {
    Write-Host "Starting Docker Desktop..."
    Start-Process $dockerDesktop | Out-Null
  } else {
    Write-Host "Waiting for Docker to become available..."
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (& docker version --format "{{.Server.Version}}" 2>$null) {
      return
    }
  }

  throw "Docker is not running. Start Docker Desktop and run this command again."
}

function New-LlmHostApiKey {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Get-DotEnvValue {
  param(
    [string]$Path,
    [string]$Name,
    [string]$Default = ""
  )

  $envItem = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
  if ($envItem -and $envItem.Value) {
    return $envItem.Value
  }

  if (Test-Path $Path) {
    foreach ($line in Get-Content $Path) {
      if ($line -match "^\s*$([regex]::Escape($Name))=(.*)$") {
        return $matches[1].Trim().Trim('"')
      }
    }
  }

  return $Default
}

function Set-DotEnvValue {
  param(
    [string]$Path,
    [string]$Name,
    [string]$Value
  )

  $line = "$Name=$Value"
  $escaped = [regex]::Escape($Name)
  $content = if (Test-Path $Path) { Get-Content $Path -Raw } else { "" }

  if ($content -match "(?m)^\s*$escaped=") {
    $content = $content -replace "(?m)^\s*$escaped=.*$", $line
  } else {
    $content = $content.TrimEnd() + "`n$line`n"
  }

  Set-Content $Path $content -NoNewline -Encoding utf8
}

function Update-Repository {
  if (Test-Path $InstallDir) {
    if (-not (Test-Path (Join-Path $InstallDir ".git"))) {
      throw "$InstallDir already exists but is not a git checkout. Choose another -InstallDir or move it aside."
    }

    Write-Host "Updating existing checkout: $InstallDir"
    Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "fetch", "origin", $Branch, "--prune")

    $dirty = & git -C $InstallDir status --porcelain --untracked-files=no
    if ($dirty -and -not $ForceReset) {
      throw "Local changes found in $InstallDir. Commit them, remove them, or rerun with -ForceReset to discard local changes."
    }

    & git -C $InstallDir checkout $Branch
    if ($LASTEXITCODE -ne 0) {
      Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "checkout", "-B", $Branch, "origin/$Branch")
    }

    if ($ForceReset) {
      Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "reset", "--hard", "origin/$Branch")
    } else {
      Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "pull", "--ff-only", "origin", $Branch)
    }
  } else {
    Write-Host "Cloning $RepoUrl to $InstallDir"
    Invoke-Checked -Command "git" -Arguments @("clone", "--branch", $Branch, $RepoUrl, $InstallDir)
  }
}

Assert-Command -Name "git" -InstallHint "Install Git for Windows: https://git-scm.com/download/win"
Assert-Command -Name "docker" -InstallHint "Install Docker Desktop: https://www.docker.com/products/docker-desktop/"

Update-Repository
Set-Location $InstallDir

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
  Write-Host "Created .env"
}

$envFile = Join-Path $InstallDir ".env"
$currentKey = Get-DotEnvValue -Path $envFile -Name "LLM_HOST_API_KEY"
if (-not $currentKey) {
  $currentKey = New-LlmHostApiKey
  Set-DotEnvValue -Path $envFile -Name "LLM_HOST_API_KEY" -Value $currentKey
  Write-Host "Generated LLM_HOST_API_KEY in .env"
}

if ($Lan) {
  Set-DotEnvValue -Path $envFile -Name "API_BIND" -Value "0.0.0.0"
  $env:API_BIND = "0.0.0.0"
} else {
  $env:API_BIND = Get-DotEnvValue -Path $envFile -Name "API_BIND" -Default "127.0.0.1"
}

if ($Port) {
  Set-DotEnvValue -Path $envFile -Name "API_PORT" -Value $Port
  $env:API_PORT = $Port
}

if (-not $Model) {
  $Model = Get-DotEnvValue -Path $envFile -Name "DEFAULT_MODEL" -Default "qwen2.5-coder:7b-instruct-q4_K_M"
}

Wait-ForDocker

Write-Host "Pulling updated container images..."
Invoke-Checked -Command "docker" -Arguments @("compose", "pull", "--ignore-buildable")

Write-Host "Building local proxy image..."
Invoke-Checked -Command "docker" -Arguments @("compose", "build", "--pull", "api")

Write-Host "Starting windows-llm-host..."
$startArgs = @()
if ($Lan) {
  $startArgs += "-Lan"
}
if ($Port) {
  $startArgs += @("-Port", $Port)
}
& (Join-Path $InstallDir "scripts\start.ps1") @startArgs

if ($Lan -and -not $NoFirewall) {
  if (Test-IsAdmin) {
    & (Join-Path $InstallDir "scripts\allow-firewall.ps1")
  } else {
    Write-Host ""
    Write-Host "LAN mode is enabled, but this PowerShell session is not elevated."
    Write-Host "If other devices cannot connect, run this once from an elevated PowerShell:"
    Write-Host "$InstallDir\scripts\allow-firewall.ps1"
  }
}

if (-not $SkipModelPull) {
  & (Join-Path $InstallDir "scripts\pull-model.ps1") -Model $Model
}

if (-not $SkipSmokeTest) {
  & (Join-Path $InstallDir "scripts\smoke-test.ps1") -Model $Model
}

$bind = Get-DotEnvValue -Path $envFile -Name "API_BIND" -Default "127.0.0.1"
$displayHost = if ($bind -eq "0.0.0.0") { "<this-laptop-ip>" } else { $bind }
$displayPort = Get-DotEnvValue -Path $envFile -Name "API_PORT" -Default "11434"

Write-Host ""
Write-Host "windows-llm-host is up to date."
Write-Host "Install dir: $InstallDir"
Write-Host "Local health: http://localhost:$displayPort/health"
Write-Host "OpenAI base URL: http://$displayHost`:$displayPort/v1"
Write-Host "Native Ollama API: http://$displayHost`:$displayPort/api"
Write-Host "API key: stored in $envFile as LLM_HOST_API_KEY"
