[CmdletBinding()]
param(
  [ValidateSet("max", "coding", "balanced", "fast")]
  [string]$Preference = "max",
  [switch]$Apply,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Convert-BytesToGb {
  param([double]$Bytes)
  if ($Bytes -le 0) {
    return 0
  }
  return [Math]::Round($Bytes / 1GB, 1)
}

function Get-SystemMemoryGb {
  try {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
      $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
      return Convert-BytesToGb -Bytes ([double]$computer.TotalPhysicalMemory)
    }
  }
  catch {
  }

  try {
    if (Get-Command free -ErrorAction SilentlyContinue) {
      $line = & free -b | Where-Object { $_ -match "^Mem:" } | Select-Object -First 1
      if ($line -match "^Mem:\s+(\d+)") {
        return Convert-BytesToGb -Bytes ([double]$matches[1])
      }
    }
  }
  catch {
  }

  return 0
}

function Get-CpuThreads {
  try {
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
      $processors = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop
      $threads = 0
      foreach ($processor in $processors) {
        $threads += [int]$processor.NumberOfLogicalProcessors
      }
      return $threads
    }
  }
  catch {
  }

  try {
    if (Get-Command nproc -ErrorAction SilentlyContinue) {
      return [int](& nproc)
    }
  }
  catch {
  }

  return 0
}

function Get-DockerMemoryGb {
  try {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      $raw = & docker info --format "{{.MemTotal}}" 2>$null
      if ($LASTEXITCODE -eq 0 -and $raw -match "^\d+$") {
        return Convert-BytesToGb -Bytes ([double]$raw)
      }
    }
  }
  catch {
  }

  return 0
}

function Get-NvidiaGpus {
  $gpus = @()

  try {
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
      $lines = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
      foreach ($line in $lines) {
        $parts = $line -split ","
        if ($parts.Count -ge 2) {
          $name = $parts[0].Trim()
          $memoryMbText = $parts[1].Trim()
          if ($memoryMbText -match "^\d+(\.\d+)?$") {
            $gpus += [pscustomobject]@{
              name = $name
              memory_gb = [Math]::Round(([double]$memoryMbText) / 1024, 1)
            }
          }
        }
      }
    }
  }
  catch {
  }

  return @($gpus | Sort-Object memory_gb -Descending)
}

function Set-DotEnvValue {
  param(
    [string]$Name,
    [string]$Value
  )

  $line = "$Name=$Value"
  $escaped = [regex]::Escape($Name)
  $content = if (Test-Path ".env") { Get-Content ".env" -Raw } else { "" }

  if ($content -match "(?m)^\s*$escaped=") {
    $content = $content -replace "(?m)^\s*$escaped=.*$", $line
  } else {
    $content = $content.TrimEnd() + "`n$line`n"
  }

  Set-Content ".env" $content -NoNewline -Encoding utf8
}

$systemRamGb = Get-SystemMemoryGb
$dockerRamGb = Get-DockerMemoryGb
$effectiveRamGb = $systemRamGb
if ($dockerRamGb -gt 0 -and ($effectiveRamGb -eq 0 -or $dockerRamGb -lt $effectiveRamGb)) {
  $effectiveRamGb = $dockerRamGb
}

$cpuThreads = Get-CpuThreads
$gpus = Get-NvidiaGpus
$primaryGpu = @($gpus | Select-Object -First 1)
$primaryGpuName = if ($primaryGpu.Count -gt 0) { $primaryGpu[0].name } else { "none detected" }
$vramGb = if ($primaryGpu.Count -gt 0) { [double]$primaryGpu[0].memory_gb } else { 0 }
$usableVramGb = [Math]::Max(0, $vramGb - 0.7)

$candidates = @(
  [pscustomobject]@{
    model = "qwen3:1.7b-q8_0"
    role = "fast"
    approx_size_gb = 2.2
    quality_score = 10
    coding_score = 1
    description = "Fast sanity checks and quick local answers."
  },
  [pscustomobject]@{
    model = "qwen3:4b-instruct"
    role = "daily"
    approx_size_gb = 2.5
    quality_score = 20
    coding_score = 2
    description = "Best small daily model; likely to stay responsive on limited VRAM."
  },
  [pscustomobject]@{
    model = "qwen2.5-coder:7b-instruct-q4_K_M"
    role = "coding"
    approx_size_gb = 4.7
    quality_score = 35
    coding_score = 35
    description = "Strong practical coding model; may split between GPU and system RAM."
  },
  [pscustomobject]@{
    model = "qwen3:14b-q4_K_M"
    role = "quality"
    approx_size_gb = 9.3
    quality_score = 45
    coding_score = 20
    description = "Heavier quality model; good first machine-bleed target."
  },
  [pscustomobject]@{
    model = "gpt-oss:20b"
    role = "reasoning"
    approx_size_gb = 13.0
    quality_score = 55
    coding_score = 25
    description = "Reasoning-heavy candidate; expect CPU/RAM participation."
  },
  [pscustomobject]@{
    model = "qwen3:30b-instruct"
    role = "max-general"
    approx_size_gb = 19.0
    quality_score = 70
    coding_score = 35
    description = "Largest general Qwen candidate in the default set."
  },
  [pscustomobject]@{
    model = "qwen3-coder:30b"
    role = "max-coding"
    approx_size_gb = 19.0
    quality_score = 75
    coding_score = 75
    description = "Largest coding candidate in the default set; slow but capable."
  },
  [pscustomobject]@{
    model = "qwen2.5-coder:32b"
    role = "max-coding"
    approx_size_gb = 20.0
    quality_score = 78
    coding_score = 85
    description = "32B coder; wants a big-RAM machine, strongest local coding here."
  },
  [pscustomobject]@{
    model = "llama3.3:70b"
    role = "max-general"
    approx_size_gb = 43.0
    quality_score = 90
    coding_score = 55
    description = "70B-class general model; runs on CPU/RAM, slow but maximum capability."
  },
  [pscustomobject]@{
    model = "qwen2.5:72b"
    role = "max-general"
    approx_size_gb = 47.0
    quality_score = 92
    coding_score = 60
    description = "Alternative 70B-class general model; very RAM-heavy. Needs a high Docker memory limit."
  }
)

$ranked = @()
foreach ($candidate in $candidates) {
  # ~1.4x covers q4 weights + KV cache + overhead; large models are RAM-bound, not
  # over-provisioned, so this keeps 70B-class models loadable on a big-RAM machine.
  $ramNeededGb = [Math]::Ceiling([Math]::Max(6, $candidate.approx_size_gb * 1.4))
  $comfortableRamGb = [Math]::Ceiling([Math]::Max(8, $candidate.approx_size_gb * 1.8))
  $gpuFit = $candidate.approx_size_gb -le $usableVramGb
  $loadable = $effectiveRamGb -eq 0 -or ($effectiveRamGb + 0.5) -ge $ramNeededGb
  $comfortable = $effectiveRamGb -eq 0 -or ($effectiveRamGb + 0.5) -ge $comfortableRamGb
  $mode = "not recommended"

  if ($loadable -and $gpuFit) {
    $mode = "mostly GPU"
  } elseif ($loadable -and $comfortable) {
    $mode = "RAM-heavy"
  } elseif ($loadable) {
    $mode = "borderline"
  }

  $ranked += [pscustomobject]@{
    model = $candidate.model
    role = $candidate.role
    approx_size_gb = $candidate.approx_size_gb
    ram_needed_gb = $ramNeededGb
    comfortable_ram_gb = $comfortableRamGb
    mostly_gpu = $gpuFit
    loadable = $loadable
    comfortable = $comfortable
    expected_mode = $mode
    quality_score = $candidate.quality_score
    coding_score = $candidate.coding_score
    description = $candidate.description
  }
}

$loadableModels = @($ranked | Where-Object { $_.loadable })
if ($loadableModels.Count -eq 0) {
  $loadableModels = @($ranked | Sort-Object approx_size_gb | Select-Object -First 1)
}

$fastModel = @($loadableModels | Where-Object { $_.role -in @("fast", "daily") } | Sort-Object quality_score -Descending | Select-Object -First 1)[0]
if (-not $fastModel) {
  $fastModel = @($loadableModels | Sort-Object approx_size_gb | Select-Object -First 1)[0]
}

$balancedModel = @($loadableModels | Where-Object { $_.model -eq "qwen2.5-coder:7b-instruct-q4_K_M" } | Select-Object -First 1)[0]
if (-not $balancedModel) {
  $balancedModel = $fastModel
}

$codingModel = @($loadableModels | Sort-Object coding_score, approx_size_gb -Descending | Select-Object -First 1)[0]
$maxModel = @($loadableModels | Sort-Object quality_score, coding_score, approx_size_gb -Descending | Select-Object -First 1)[0]

switch ($Preference) {
  "fast" { $selected = $fastModel }
  "balanced" { $selected = $balancedModel }
  "coding" { $selected = $codingModel }
  default { $selected = $maxModel }
}

$result = [pscustomobject]@{
  selected_model = $selected.model
  selected_role = $selected.role
  selected_expected_mode = $selected.expected_mode
  preference = $Preference
  fast_model = $fastModel.model
  balanced_model = $balancedModel.model
  max_coding_model = $codingModel.model
  max_model = $maxModel.model
  hardware = [pscustomobject]@{
    system_ram_gb = $systemRamGb
    docker_memory_gb = $dockerRamGb
    effective_ram_gb = $effectiveRamGb
    cpu_threads = $cpuThreads
    primary_gpu = $primaryGpuName
    primary_gpu_vram_gb = $vramGb
    usable_gpu_vram_gb = [Math]::Round($usableVramGb, 1)
  }
  candidates = $ranked
}

if ($Apply) {
  Set-DotEnvValue -Name "DEFAULT_MODEL" -Value $selected.model
  Set-DotEnvValue -Name "RECOMMENDED_FAST_MODEL" -Value $fastModel.model
  Set-DotEnvValue -Name "RECOMMENDED_BALANCED_MODEL" -Value $balancedModel.model
  Set-DotEnvValue -Name "RECOMMENDED_MAX_MODEL" -Value $maxModel.model

  if ($Preference -eq "max" -or $Preference -eq "coding") {
    Set-DotEnvValue -Name "OLLAMA_KEEP_ALIVE" -Value "-1"
    Set-DotEnvValue -Name "OLLAMA_NUM_PARALLEL" -Value "2"
    Set-DotEnvValue -Name "OLLAMA_MAX_LOADED_MODELS" -Value "1"
  } elseif ($Preference -eq "balanced") {
    Set-DotEnvValue -Name "OLLAMA_KEEP_ALIVE" -Value "30m"
    Set-DotEnvValue -Name "OLLAMA_NUM_PARALLEL" -Value "1"
    Set-DotEnvValue -Name "OLLAMA_MAX_LOADED_MODELS" -Value "1"
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  exit 0
}

Write-Host "Hardware"
Write-Host "  CPU threads: $cpuThreads"
Write-Host "  System RAM: $systemRamGb GB"
if ($dockerRamGb -gt 0) {
  Write-Host "  Docker memory: $dockerRamGb GB"
}
Write-Host "  Effective RAM for Docker: $effectiveRamGb GB"
Write-Host "  Primary NVIDIA GPU: $primaryGpuName"
Write-Host "  Primary NVIDIA VRAM: $vramGb GB"
Write-Host ""
Write-Host "Recommendations"
Write-Host "  Selected default ($Preference): $($selected.model) [$($selected.expected_mode)]"
Write-Host "  Fast model: $($fastModel.model)"
Write-Host "  Balanced model: $($balancedModel.model)"
Write-Host "  Max coding model: $($codingModel.model)"
Write-Host "  Max model: $($maxModel.model)"
Write-Host ""
Write-Host "Candidate table"
$ranked |
  Select-Object model, role, approx_size_gb, ram_needed_gb, mostly_gpu, loadable, expected_mode |
  Format-Table -AutoSize

if ($Apply) {
  Write-Host ""
  Write-Host "Updated .env DEFAULT_MODEL=$($selected.model)"
  if ($Preference -eq "max" -or $Preference -eq "coding") {
    Write-Host "Updated .env for heavy runtime defaults: OLLAMA_KEEP_ALIVE=-1, OLLAMA_NUM_PARALLEL=2"
  }
}
