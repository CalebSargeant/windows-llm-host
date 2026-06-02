<#
.SYNOPSIS
  Shared helpers for windows-llm-host version + GitHub release checks.

.DESCRIPTION
  Dot-source this from another script:

    . (Join-Path $PSScriptRoot 'update-common.ps1')

  It provides local version reading, GitHub release lookup, and semantic-version
  comparison. It performs no actions on its own.
#>

function Get-LocalVersion {
  param([string]$Root)

  $versionFile = Join-Path $Root "VERSION"
  if (Test-Path $versionFile) {
    $value = (Get-Content $versionFile -Raw).Trim()
    if ($value) { return $value }
  }

  # Fall back to the nearest git tag if VERSION is missing.
  $desc = & git -C $Root describe --tags --abbrev=0 2>$null
  if ($LASTEXITCODE -eq 0 -and $desc) { return $desc.Trim() }

  return "0.0.0"
}

function Get-GitHubHeaders {
  $headers = @{
    "Accept"               = "application/vnd.github+json"
    "User-Agent"           = "windows-llm-host-updater"
    "X-GitHub-Api-Version" = "2022-11-28"
  }

  $token = $env:GH_TOKEN
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  if ($token) { $headers["Authorization"] = "Bearer $token" }

  return $headers
}

function Get-LatestRelease {
  <#
    Returns an object with Tag/Name/Prerelease/Url for the latest release on the
    given channel, or $null when there are no releases (404), the call is rate-limited,
    or the network is unavailable. Callers must handle $null gracefully.
  #>
  param(
    [string]$RepoSlug,
    [ValidateSet('stable', 'prerelease')]
    [string]$Channel = 'stable'
  )

  # Windows PowerShell 5.1 can default to TLS 1.0; GitHub requires TLS 1.2+.
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {
    Write-Verbose "Could not set TLS 1.2; continuing with the default protocol."
  }

  $headers = Get-GitHubHeaders
  $rel = $null
  try {
    if ($Channel -eq 'stable') {
      $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/latest" -Headers $headers -TimeoutSec 15
    } else {
      $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases?per_page=20" -Headers $headers -TimeoutSec 15
      $rel = $rels | Where-Object { -not $_.draft } | Select-Object -First 1
    }
  } catch {
    return $null
  }

  if (-not $rel -or -not $rel.tag_name) { return $null }

  return [pscustomobject]@{
    Tag        = $rel.tag_name
    Name       = $rel.name
    Prerelease = [bool]$rel.prerelease
    Url        = $rel.html_url
  }
}

function ConvertTo-IntOrZero {
  param([string]$Value)
  $n = 0
  if ([int]::TryParse($Value, [ref]$n)) { return $n }
  return 0
}

function ConvertTo-SemVerParts {
  param([string]$Version)

  if ([string]::IsNullOrWhiteSpace($Version)) { return $null }

  $clean = $Version.Trim().TrimStart('v', 'V')
  $split = $clean -split '-', 2
  $nums = $split[0] -split '\.'

  $major = ConvertTo-IntOrZero $nums[0]
  $minor = 0
  if ($nums.Count -gt 1) { $minor = ConvertTo-IntOrZero $nums[1] }
  $patch = 0
  if ($nums.Count -gt 2) { $patch = ConvertTo-IntOrZero $nums[2] }
  $pre = ""
  if ($split.Count -gt 1) { $pre = $split[1] }

  return [pscustomobject]@{
    Major = $major
    Minor = $minor
    Patch = $patch
    Pre   = $pre
  }
}

function Compare-SemVer {
  # Returns -1 if A < B, 0 if equal, 1 if A > B. A prerelease ranks below its release.
  param([string]$A, [string]$B)

  $pa = ConvertTo-SemVerParts $A
  $pb = ConvertTo-SemVerParts $B
  if (-not $pa -and -not $pb) { return 0 }
  if (-not $pa) { return -1 }
  if (-not $pb) { return 1 }

  foreach ($field in 'Major', 'Minor', 'Patch') {
    if ($pa.$field -lt $pb.$field) { return -1 }
    if ($pa.$field -gt $pb.$field) { return 1 }
  }

  if ($pa.Pre -and -not $pb.Pre) { return -1 }
  if (-not $pa.Pre -and $pb.Pre) { return 1 }
  if ($pa.Pre -eq $pb.Pre) { return 0 }
  if ([string]::Compare($pa.Pre, $pb.Pre, $true) -lt 0) { return -1 } else { return 1 }
}
