[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:USERPROFILE "windows-llm-host"),
  [string]$RepoUrl = "https://github.com/CalebSargeant/windows-llm-host.git",
  [string]$Branch = "main",
  [ValidateSet('main', 'stable', 'prerelease')]
  [string]$Channel = "main",
  [string]$Model,
  [ValidateSet("max", "coding", "balanced", "fast")]
  [string]$ModelPreference = "max",
  [string]$Port,
  [switch]$Lan,
  [switch]$LocalOnly,
  [switch]$ForceReset,
  [switch]$SkipHardwareDetect,
  [switch]$SkipModelPull,
  [switch]$SkipSmokeTest,
  [switch]$NoFirewall,
  [switch]$SkipUpdateCheck
)

$RepoSlug = "CalebSargeant/windows-llm-host"

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

function Resolve-TargetRef {
  # 'main' tracks the rolling branch. 'stable'/'prerelease' resolve to a GitHub release
  # tag. Self-contained so it works when this script is run via the remote one-liner
  # before any checkout exists. Falls back to the branch when no release is found.
  if ($Channel -eq "main") {
    return [pscustomobject]@{ Kind = "branch"; Ref = $Branch }
  }

  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {
    Write-Verbose "Could not set TLS 1.2; continuing with the default protocol."
  }

  $headers = @{
    "Accept"               = "application/vnd.github+json"
    "User-Agent"           = "windows-llm-host-installer"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
  $token = $env:GH_TOKEN
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  if ($token) { $headers["Authorization"] = "Bearer $token" }

  $rel = $null
  try {
    if ($Channel -eq "stable") {
      $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers $headers -TimeoutSec 15
    } else {
      $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases?per_page=20" -Headers $headers -TimeoutSec 15
      $rel = $rels | Where-Object { -not $_.draft } | Select-Object -First 1
    }
  } catch {
    $rel = $null
  }

  if (-not $rel -or -not $rel.tag_name) {
    Write-Host "No GitHub release found for channel '$Channel'. Falling back to branch '$Branch'."
    return [pscustomobject]@{ Kind = "branch"; Ref = $Branch }
  }

  Write-Host "Channel '$Channel' resolves to release tag $($rel.tag_name)."
  return [pscustomobject]@{ Kind = "tag"; Ref = $rel.tag_name }
}

function Update-Repository {
  $target = Resolve-TargetRef
  $ref = $target.Ref

  if (Test-Path $InstallDir) {
    if (-not (Test-Path (Join-Path $InstallDir ".git"))) {
      throw "$InstallDir already exists but is not a git checkout. Choose another -InstallDir or move it aside."
    }

    Write-Host "Updating existing checkout: $InstallDir (channel: $Channel, ref: $ref)"
    Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "fetch", "origin", "--tags", "--prune")

    $dirty = & git -C $InstallDir status --porcelain --untracked-files=no
    if ($dirty -and -not $ForceReset) {
      throw "Local changes found in $InstallDir. Commit them, remove them, or rerun with -ForceReset to discard local changes."
    }

    if ($target.Kind -eq "branch") {
      & git -C $InstallDir checkout $ref
      if ($LASTEXITCODE -ne 0) {
        Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "checkout", "-B", $ref, "origin/$ref")
      }

      if ($ForceReset) {
        Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "reset", "--hard", "origin/$ref")
      } else {
        Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "pull", "--ff-only", "origin", $ref)
      }
    } else {
      # Release tag: check out the tag (detached HEAD).
      if ($ForceReset) {
        Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "checkout", "--force", "tags/$ref")
      } else {
        Invoke-Checked -Command "git" -Arguments @("-C", $InstallDir, "checkout", "tags/$ref")
      }
    }
  } else {
    Write-Host "Cloning $RepoUrl to $InstallDir (channel: $Channel, ref: $ref)"
    Invoke-Checked -Command "git" -Arguments @("clone", "--branch", $ref, $RepoUrl, $InstallDir)
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

if ($LocalOnly) {
  Set-DotEnvValue -Path $envFile -Name "API_BIND" -Value "127.0.0.1"
  $env:API_BIND = "127.0.0.1"
} else {
  Set-DotEnvValue -Path $envFile -Name "API_BIND" -Value "0.0.0.0"
  $env:API_BIND = "0.0.0.0"
}

if ($Port) {
  Set-DotEnvValue -Path $envFile -Name "API_PORT" -Value $Port
  $env:API_PORT = $Port
}

Wait-ForDocker

if (-not $Model -and -not $SkipHardwareDetect) {
  try {
    Write-Host "Detecting best local model for this hardware (preference: $ModelPreference)..."
    $detectOutput = & (Join-Path $InstallDir "scripts\detect-model.ps1") -Preference $ModelPreference -Apply -Json
    $detection = $detectOutput | ConvertFrom-Json
    $Model = $detection.selected_model
    Write-Host "Selected model: $Model [$($detection.selected_expected_mode)]"
    Write-Host "Fast fallback: $($detection.fast_model)"
    Write-Host "Balanced fallback: $($detection.balanced_model)"
  }
  catch {
    Write-Warning "Hardware model detection failed: $($_.Exception.Message)"
  }
}

if (-not $Model) {
  $Model = Get-DotEnvValue -Path $envFile -Name "DEFAULT_MODEL" -Default "qwen3-coder:30b"
}

Write-Host "Pulling updated container images..."
Invoke-Checked -Command "docker" -Arguments @("compose", "pull", "--ignore-buildable")

Write-Host "Building local proxy image..."
Invoke-Checked -Command "docker" -Arguments @("compose", "build", "--pull", "api")

Write-Host "Starting windows-llm-host..."
$startArgs = @()
if ($Port) {
  $startArgs += @("-Port", $Port)
}
& (Join-Path $InstallDir "scripts\start.ps1") @startArgs

if (-not $LocalOnly -and -not $NoFirewall) {
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

$bind = Get-DotEnvValue -Path $envFile -Name "API_BIND" -Default "0.0.0.0"
$displayHost = if ($bind -eq "0.0.0.0") { "<this-laptop-ip>" } else { $bind }
$displayPort = Get-DotEnvValue -Path $envFile -Name "API_PORT" -Default "11434"

$installedVersion = "unknown"
$commonLib = Join-Path $InstallDir "scripts\update-common.ps1"
if (Test-Path $commonLib) {
  . $commonLib
  $installedVersion = Get-LocalVersion -Root $InstallDir
}

Write-Host ""
Write-Host "windows-llm-host is up to date."
Write-Host "Install dir: $InstallDir"
Write-Host "Version: $installedVersion (channel: $Channel)"
Write-Host "Local health: http://localhost:$displayPort/health"
Write-Host "OpenAI base URL: http://$displayHost`:$displayPort/v1"
Write-Host "Native Ollama API: http://$displayHost`:$displayPort/api"
Write-Host "Model: $Model"
Write-Host "API key: $currentKey"
Write-Host "API key file: $envFile"

if (-not $SkipUpdateCheck -and (Test-Path $commonLib)) {
  try {
    $rel = Get-LatestRelease -RepoSlug $RepoSlug -Channel 'stable'
    if ($rel -and (Compare-SemVer $installedVersion $rel.Tag) -lt 0) {
      Write-Host ""
      Write-Host "A newer release is available: $installedVersion -> $($rel.Tag)"
      Write-Host "Release notes: $($rel.Url)"
      Write-Host "Update with: .\scripts\install-or-update.ps1 -Channel stable"
    }
  } catch {
    Write-Verbose "Update check skipped: $($_.Exception.Message)"
  }
}
