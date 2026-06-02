[CmdletBinding()]
param(
  [string]$Model,
  [int]$Parallel = 2,
  [int]$Requests = 6,
  [int]$NumPredict = 700,
  [int]$NumCtx = 8192,
  [switch]$Pull,
  [switch]$MaxMode,
  [string]$Prompt,
  [string]$ResultDir = "stress-results"
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

function Set-DotEnvValues {
  param(
    [hashtable]$Values
  )

  $lines = @()
  if (Test-Path ".env") {
    $lines = Get-Content ".env"
  }

  $seen = @{}
  $output = New-Object System.Collections.Generic.List[string]

  foreach ($line in $lines) {
    $replaced = $false
    foreach ($key in $Values.Keys) {
      if ($line -match "^\s*$([regex]::Escape($key))=") {
        $output.Add("$key=$($Values[$key])")
        $seen[$key] = $true
        $replaced = $true
        break
      }
    }

    if (-not $replaced) {
      $output.Add($line)
    }
  }

  foreach ($key in $Values.Keys) {
    if (-not $seen.ContainsKey($key)) {
      $output.Add("$key=$($Values[$key])")
    }
  }

  Set-Content -Path ".env" -Value $output -Encoding ASCII
}

if (-not $Model) {
  $Model = Get-DotEnvValue -Name "DEFAULT_MODEL" -Default "qwen3-coder:30b"
}

if (-not $Prompt) {
  $Prompt = @"
You are stress testing local LLM inference. Build a production-grade TypeScript REST API for a small incident-management system.

Include:
- data models
- validation helpers
- request handlers
- authentication middleware
- pagination
- realistic tests
- deployment notes
- performance tradeoffs

Write enough code and explanation to keep generating until the token limit is reached.
"@
}

if ($Parallel -lt 1) {
  throw "-Parallel must be at least 1."
}

if ($Requests -lt 1) {
  throw "-Requests must be at least 1."
}

if ($MaxMode) {
  Write-Host "Enabling max mode in .env: OLLAMA_KEEP_ALIVE=-1, OLLAMA_NUM_PARALLEL=$Parallel, OLLAMA_MAX_LOADED_MODELS=1"
  Set-DotEnvValues @{
    OLLAMA_KEEP_ALIVE = "-1"
    OLLAMA_NUM_PARALLEL = "$Parallel"
    OLLAMA_MAX_LOADED_MODELS = "1"
  }
}

Write-Host "Starting Docker stack..."
& docker compose up -d

if ($Pull) {
  Write-Host "Pulling model: $Model"
  & docker compose exec ollama ollama pull $Model
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

$uri = "http://$hostName`:$port/api/generate"

Write-Host "Waiting for API at http://$hostName`:$port/api/tags..."
$tagsUri = "http://$hostName`:$port/api/tags"
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
  try {
    Invoke-RestMethod -Uri $tagsUri -Method Get -Headers $headers -TimeoutSec 10 | Out-Null
    $ready = $true
    break
  }
  catch {
    Start-Sleep -Seconds 2
  }
}

if (-not $ready) {
  throw "API did not become ready at $tagsUri."
}

if (-not (Test-Path $ResultDir)) {
  New-Item -ItemType Directory -Path $ResultDir | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$samplePath = Join-Path $ResultDir "stress-samples-$stamp.csv"
$resultPath = Join-Path $ResultDir "stress-results-$stamp.csv"

Set-Content -Path $samplePath -Value "timestamp,gpu_util_pct,gpu_mem_mb,gpu_power_w,gpu_temp_c,docker_cpu_pct,docker_mem_usage" -Encoding ASCII

$monitor = Start-Job -ArgumentList $samplePath -ScriptBlock {
  param($Path)

  while ($true) {
    $timestamp = (Get-Date).ToString("o")
    $gpuParts = @("", "", "", "")
    $dockerParts = @("", "")

    try {
      $gpu = & nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw,temperature.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1
      if ($gpu) {
        $parsedGpu = $gpu -split "," | ForEach-Object { $_.Trim() }
        for ($i = 0; $i -lt [Math]::Min($parsedGpu.Count, 4); $i++) {
          $gpuParts[$i] = $parsedGpu[$i]
        }
      }
    }
    catch {
    }

    try {
      $docker = & docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" windows-llm-host-ollama 2>$null | Select-Object -First 1
      if ($docker) {
        $parsedDocker = $docker -split "," | ForEach-Object { $_.Trim() }
        for ($i = 0; $i -lt [Math]::Min($parsedDocker.Count, 2); $i++) {
          $dockerParts[$i] = $parsedDocker[$i]
        }
      }
    }
    catch {
    }

    Add-Content -Path $Path -Value "$timestamp,$($gpuParts[0]),$($gpuParts[1]),$($gpuParts[2]),$($gpuParts[3]),$($dockerParts[0]),`"$($dockerParts[1])`""
    Start-Sleep -Milliseconds 500
  }
}

$jobs = @()
$results = @()

try {
  Write-Host ""
  Write-Host "Stress testing $Model"
  Write-Host "Requests: $Requests | Parallel: $Parallel | num_predict: $NumPredict | num_ctx: $NumCtx"
  Write-Host "Sampling GPU and Docker stats to $samplePath"
  Write-Host ""

  for ($i = 1; $i -le $Requests; $i++) {
    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $Parallel) {
      $done = $jobs | Where-Object { $_.State -ne "Running" -and -not $_.HasMoreData }
      foreach ($job in $done) {
        $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
      }
      Start-Sleep -Milliseconds 250
    }

    $jobs += Start-Job -ArgumentList $i, $uri, $headers, $Model, $Prompt, $NumPredict, $NumCtx -ScriptBlock {
      param($RequestId, $Uri, $Headers, $ModelName, $PromptText, $PredictCount, $ContextSize)

      $body = @{
        model = $ModelName
        prompt = $PromptText
        stream = $false
        keep_alive = "-1"
        options = @{
          temperature = 0.2
          num_predict = $PredictCount
          num_ctx = $ContextSize
        }
      } | ConvertTo-Json -Depth 8

      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $body -TimeoutSec 1800
        $sw.Stop()

        $evalCount = [int64]($response.eval_count)
        $evalDuration = [int64]($response.eval_duration)
        $promptEvalCount = [int64]($response.prompt_eval_count)
        $promptEvalDuration = [int64]($response.prompt_eval_duration)
        $tokensPerSecond = 0
        $promptTokensPerSecond = 0

        if ($evalDuration -gt 0) {
          $tokensPerSecond = [Math]::Round($evalCount / ($evalDuration / 1000000000), 2)
        }

        if ($promptEvalDuration -gt 0) {
          $promptTokensPerSecond = [Math]::Round($promptEvalCount / ($promptEvalDuration / 1000000000), 2)
        }

        [pscustomobject]@{
          request_id = $RequestId
          model = $ModelName
          wall_sec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
          eval_tokens = $evalCount
          tokens_per_sec = $tokensPerSecond
          prompt_tokens = $promptEvalCount
          prompt_tokens_per_sec = $promptTokensPerSecond
          total_duration_sec = [Math]::Round(([int64]($response.total_duration)) / 1000000000, 2)
          load_duration_sec = [Math]::Round(([int64]($response.load_duration)) / 1000000000, 2)
          error = ""
        }
      }
      catch {
        $sw.Stop()
        [pscustomobject]@{
          request_id = $RequestId
          model = $ModelName
          wall_sec = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
          eval_tokens = 0
          tokens_per_sec = 0
          prompt_tokens = 0
          prompt_tokens_per_sec = 0
          total_duration_sec = 0
          load_duration_sec = 0
          error = $_.Exception.Message
        }
      }
    }

    Write-Host "Queued request $i"
  }

  while (($jobs | Where-Object { $_.State -eq "Running" }).Count -gt 0) {
    Start-Sleep -Seconds 1
  }

  foreach ($job in $jobs) {
    $results += Receive-Job $job
    Remove-Job $job
  }
}
finally {
  Stop-Job $monitor -ErrorAction SilentlyContinue
  Remove-Job $monitor -Force -ErrorAction SilentlyContinue
}

$results |
  Sort-Object request_id |
  Export-Csv -Path $resultPath -NoTypeInformation -Encoding ASCII

$ok = @($results | Where-Object { -not $_.error })
$totalTokens = 0
$avgTps = 0

if (@($ok).Count -gt 0) {
  $totalTokens = ($ok | Measure-Object -Property eval_tokens -Sum).Sum
  $avgTps = [Math]::Round(($ok | Measure-Object -Property tokens_per_sec -Average).Average, 2)
}

$peakGpuUtil = ""
$peakGpuMem = ""
try {
  $samples = Import-Csv $samplePath
  $numericGpuUtil = $samples | Where-Object { $_.gpu_util_pct -match "^\d+(\.\d+)?$" }
  $numericGpuMem = $samples | Where-Object { $_.gpu_mem_mb -match "^\d+(\.\d+)?$" }
  if ($numericGpuUtil) {
    $peakGpuUtil = ($numericGpuUtil | Measure-Object -Property gpu_util_pct -Maximum).Maximum
  }
  if ($numericGpuMem) {
    $peakGpuMem = ($numericGpuMem | Measure-Object -Property gpu_mem_mb -Maximum).Maximum
  }
}
catch {
}

Write-Host ""
Write-Host "Stress test complete."
Write-Host "Results: $resultPath"
Write-Host "Samples: $samplePath"
Write-Host "Successful requests: $(@($ok).Count)/$Requests"
Write-Host "Generated tokens: $totalTokens"
Write-Host "Average per-request generation speed: $avgTps tok/s"
if ($peakGpuUtil -ne "") {
  Write-Host "Peak NVIDIA utilization sample: $peakGpuUtil%"
}
if ($peakGpuMem -ne "") {
  Write-Host "Peak NVIDIA memory sample: $peakGpuMem MB"
}
Write-Host ""
Write-Host "Task Manager tip: the default GPU graphs often show 3D/video engines. Change one graph to CUDA or Compute_0 while this script is running."
