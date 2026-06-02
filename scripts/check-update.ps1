<#
.SYNOPSIS
  Check whether a newer windows-llm-host version is available, and optionally apply it.

.DESCRIPTION
  Compares the locally installed version against a release channel:

    - stable     : the latest non-prerelease GitHub release (default).
    - prerelease : the latest release including prereleases.
    - main       : the rolling main branch (compares your checkout to origin/main).

  Repo release/version publishing is handled separately; if no releases exist yet, the
  stable/prerelease channels report "no releases found" and change nothing.

  Exit code is 10 when an update is available (and not applied), 0 otherwise, so the
  installer, a scheduled task, or a future GUI can act on it.

.PARAMETER Channel
  Which channel to check: stable (default), prerelease, or main.

.PARAMETER Update
  If an update is available, apply it by running install-or-update.ps1 for this checkout.

.PARAMETER Quiet
  Print nothing unless an update is available. Useful for login scripts.

.PARAMETER Json
  Emit a single machine-readable JSON object instead of human-readable text.

.EXAMPLE
  .\scripts\check-update.ps1
  .\scripts\check-update.ps1 -Channel prerelease
  .\scripts\check-update.ps1 -Update
  .\scripts\check-update.ps1 -Json
#>
[CmdletBinding()]
param(
  [ValidateSet('main', 'stable', 'prerelease')]
  [string]$Channel = 'stable',
  [string]$RepoSlug = 'CalebSargeant/windows-llm-host',
  [string]$InstallDir,
  [switch]$Update,
  [switch]$Quiet,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if (-not $InstallDir) {
  $InstallDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

. (Join-Path $PSScriptRoot "update-common.ps1")

$current = Get-LocalVersion -Root $InstallDir
$latest = $null
$updateAvailable = $false
$detail = ""

if ($Channel -eq 'main') {
  & git -C $InstallDir fetch origin main --quiet 2>$null
  $localSha = (& git -C $InstallDir rev-parse --short HEAD 2>$null)
  $remoteSha = (& git -C $InstallDir rev-parse --short origin/main 2>$null)
  if ($localSha) { $current = $localSha }
  $latest = $remoteSha
  if ($localSha -and $remoteSha -and ($localSha -ne $remoteSha)) {
    & git -C $InstallDir merge-base --is-ancestor HEAD origin/main 2>$null
    if ($LASTEXITCODE -eq 0) { $updateAvailable = $true }
  }
  if ($updateAvailable) {
    $detail = "Local checkout is behind origin/main ($localSha -> $remoteSha)."
  } else {
    $detail = "Up to date with origin/main."
  }
} else {
  $release = Get-LatestRelease -RepoSlug $RepoSlug -Channel $Channel
  if (-not $release) {
    $detail = "No GitHub releases found on channel '$Channel' (none published yet, offline, or rate-limited)."
  } else {
    $latest = $release.Tag
    if ((Compare-SemVer $current $latest) -lt 0) {
      $updateAvailable = $true
      $detail = "Update available: $current -> $latest"
    } else {
      $detail = "Up to date (installed $current, latest $latest)."
    }
  }
}

if ($Json) {
  [pscustomobject]@{
    channel         = $Channel
    current         = $current
    latest          = $latest
    updateAvailable = $updateAvailable
    detail          = $detail
  } | ConvertTo-Json -Compress
} elseif ($Quiet) {
  if ($updateAvailable) { Write-Host $detail }
} else {
  Write-Host "windows-llm-host update check (channel: $Channel)"
  Write-Host "  Installed: $current"
  if ($latest) { Write-Host "  Latest:    $latest" }
  Write-Host "  $detail"
  if ($updateAvailable -and -not $Update) {
    Write-Host ""
    Write-Host "Apply it with:"
    if ($Channel -eq 'main') {
      Write-Host "  .\scripts\install-or-update.ps1"
    } else {
      Write-Host "  .\scripts\install-or-update.ps1 -Channel $Channel"
    }
  }
}

$didUpdate = $false
if ($Update -and $updateAvailable) {
  Write-Host "Applying update on channel '$Channel'..."
  $installer = Join-Path $PSScriptRoot "install-or-update.ps1"
  if ($Channel -eq 'main') {
    & $installer -InstallDir $InstallDir -SkipUpdateCheck
  } else {
    & $installer -InstallDir $InstallDir -Channel $Channel -SkipUpdateCheck
  }
  $didUpdate = $true
}

if ($updateAvailable -and -not $didUpdate) { exit 10 } else { exit 0 }
