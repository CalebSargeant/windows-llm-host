<#
.SYNOPSIS
  Recommend Ollama models for this machine's hardware.

.DESCRIPTION
  Detects system RAM and NVIDIA VRAM and suggests three models:

    - Fast daily : the largest general model that fits in VRAM (runs on the GPU).
    - Coding     : the best coding model for the available VRAM (may offload to CPU).
    - Max        : the largest model that fits in system RAM minus headroom - the
                   "use the whole machine" pick. On a big-RAM laptop this is a
                   70B-class model that runs on CPU/RAM: slow but maximally capable.

  VRAM governs speed (GPU-resident), RAM governs maximum capability (CPU/RAM offload).
  Footprints are approximate q4-ish on-disk sizes plus a little runtime overhead; treat
  the result as a starting point and confirm with .\benchmark-models.sh.

.PARAMETER Json
  Emit a machine-readable JSON object instead of human-readable text.

.PARAMETER TotalRamGb
  Override detected system RAM (GB). Mainly for testing.

.PARAMETER VramGb
  Override detected VRAM (GB). Use 0 to model a CPU-only machine.

.EXAMPLE
  .\scripts\recommend-model.ps1
  .\scripts\recommend-model.ps1 -Json
  .\scripts\recommend-model.ps1 -TotalRamGb 64 -VramGb 4
#>
[CmdletBinding()]
param(
  [switch]$Json,
  [double]$TotalRamGb = 0,
  [double]$VramGb = -1
)

$ErrorActionPreference = "Stop"

function Get-TotalRamGb {
  try {
    $bytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    if ($bytes) { return [math]::Round($bytes / 1GB, 1) }
  } catch {
    Write-Verbose "Win32_ComputerSystem unavailable: $($_.Exception.Message)"
  }

  # Non-Windows fallbacks (PowerShell 7 automatic vars; absent on Windows PowerShell 5.1).
  try {
    if (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) {
      if ($IsMacOS) {
        $bytes = & sysctl -n hw.memsize 2>$null
        if ($bytes) { return [math]::Round([double]$bytes / 1GB, 1) }
      } elseif ($IsLinux) {
        $line = Get-Content /proc/meminfo -ErrorAction Stop | Where-Object { $_ -match '^MemTotal:' }
        $kb = ($line -replace '\D', '')
        if ($kb) { return [math]::Round([double]$kb / 1MB, 1) }
      }
    }
  } catch {
    Write-Verbose "RAM fallback failed: $($_.Exception.Message)"
  }

  return 0
}

function Get-VramGb {
  try {
    $out = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
      $first = ($out | Select-Object -First 1).ToString().Trim()
      $mb = 0
      if ([int]::TryParse($first, [ref]$mb)) { return [math]::Round($mb / 1024, 1) }
    }
  } catch {
    Write-Verbose "nvidia-smi unavailable: $($_.Exception.Message)"
  }
  return 0
}

if ($TotalRamGb -le 0) { $TotalRamGb = Get-TotalRamGb }
if ($VramGb -lt 0) { $VramGb = Get-VramGb }

# Approximate runtime footprints (GB). Ascending within each list.
$generalTiers = @(
  [pscustomobject]@{ Model = "qwen3:1.7b-q8_0";   Gb = 2.2 }
  [pscustomobject]@{ Model = "qwen3:4b-instruct";  Gb = 3.5 }
  [pscustomobject]@{ Model = "qwen3:14b-q4_K_M";   Gb = 10 }
  [pscustomobject]@{ Model = "gpt-oss:20b";        Gb = 13 }
  [pscustomobject]@{ Model = "qwen3:30b-instruct"; Gb = 19 }
  [pscustomobject]@{ Model = "llama3.3:70b";       Gb = 43 }
  [pscustomobject]@{ Model = "qwen2.5:72b";        Gb = 47 }
)
$codingTiers = @(
  [pscustomobject]@{ Model = "qwen2.5-coder:7b-instruct-q4_K_M"; Gb = 5 }
  [pscustomobject]@{ Model = "qwen2.5-coder:32b";                Gb = 20 }
)

function Select-Largest {
  param([object[]]$Tiers, [double]$BudgetGb)
  $fit = $Tiers | Where-Object { $_.Gb -le $BudgetGb }
  if ($fit) { return ($fit | Select-Object -Last 1).Model }
  return $null
}

$ramHeadroom = [math]::Max(6, [math]::Round($TotalRamGb * 0.15))
$ramBudget = [math]::Max(0, $TotalRamGb - $ramHeadroom)
$vramBudget = [math]::Max(0, $VramGb - 0.5)

# Fast daily: largest general model that fits in VRAM. No usable GPU -> smallest general.
$daily = Select-Largest -Tiers $generalTiers -BudgetGb $vramBudget
if (-not $daily) { $daily = "qwen3:4b-instruct" }

# Coding: largest coding model that fits in VRAM; otherwise the 7B with partial CPU offload.
$coding = Select-Largest -Tiers $codingTiers -BudgetGb $vramBudget
$codingNote = ""
if (-not $coding) {
  $coding = "qwen2.5-coder:7b-instruct-q4_K_M"
  $codingNote = "fits VRAM only partially; expect some CPU/RAM offload"
}

# Max capability: largest model that fits in RAM minus headroom.
$max = Select-Largest -Tiers $generalTiers -BudgetGb $ramBudget
if (-not $max) { $max = $daily }

$maxIsBig = $generalTiers | Where-Object { $_.Model -eq $max -and $_.Gb -ge 30 }
$maxNote = if ($maxIsBig) { "runs mostly on CPU/RAM - slow but maximum capability" } else { "comfortable for this machine" }

if ($Json) {
  [pscustomobject]@{
    totalRamGb  = $TotalRamGb
    vramGb      = $VramGb
    ramHeadroom = $ramHeadroom
    daily       = $daily
    coding      = $coding
    max         = $max
  } | ConvertTo-Json -Compress
  return
}

Write-Host "Hardware-aware model recommendation"
Write-Host "  Detected RAM:  $TotalRamGb GB (reserving ~$ramHeadroom GB headroom)"
if ($VramGb -gt 0) {
  Write-Host "  Detected VRAM: $VramGb GB (NVIDIA)"
} else {
  Write-Host "  Detected VRAM: none/unknown - daily/coding picks assume CPU/RAM"
}
Write-Host ""
Write-Host "  Fast daily : $daily   (fits in VRAM, GPU-resident)"
Write-Host "  Coding     : $coding$(if ($codingNote) { "   ($codingNote)" })"
Write-Host "  Max        : $max   ($maxNote)"
Write-Host ""
Write-Host "Pull them with, e.g.:  .\scripts\pull-model.ps1 -Model $daily"
Write-Host "Benchmark before committing to a daily driver:  BENCH_PROFILE=max ./benchmark-models.sh"
