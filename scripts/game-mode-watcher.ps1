<#
.SYNOPSIS
  Pause the windows-llm-host Docker stack while a game / full-screen app is running,
  then restore it afterwards so Ollama and Open WebUI stop competing for GPU, CPU,
  RAM, and thermal headroom.

.DESCRIPTION
  Windows does not expose a clean "Game Mode is active right now" API. The active
  state of Game Mode is internal, so this watcher infers a gaming/performance-sensitive
  state from two reliable signals instead:

    1. A full-screen foreground window that is not the Windows shell (covers a whole
       monitor) - this is how virtually every game presents itself.
    2. A configured game/launcher process being present (GAME_MODE_PROCESSES).

  When a gaming state is detected the watcher stops the stack (docker compose stop by
  default, keeping containers and models). When the gaming state clears for a cooldown
  period it restores the stack. A marker file records that *this watcher* paused the
  stack, so it never restarts a stack you stopped yourself, and so -Once invocations
  from Task Scheduler stay idempotent.

  This is opt-in: nothing runs it unless you start it or install the scheduled task.

.PARAMETER Once
  Evaluate the current state a single time, act if needed, then exit. Ideal for a
  repeating Scheduled Task. Without -Once the script loops every -PollSeconds.

.PARAMETER PollSeconds
  Seconds between checks in continuous mode. Default from GAME_MODE_POLL_SECONDS or 15.

.PARAMETER CooldownSeconds
  How long the gaming state must stay clear before the stack is restored. Default from
  GAME_MODE_COOLDOWN_SECONDS or 60.

.PARAMETER Action
  How to pause: 'stop' keeps containers (fast resume), 'down' removes containers but
  keeps named volumes/models (slower resume). Default from GAME_MODE_ACTION or 'stop'.

.PARAMETER NoRestore
  Do not restart the stack after the gaming state clears. Default from
  GAME_MODE_RESTORE (NoRestore = GAME_MODE_RESTORE=false).

.PARAMETER GameProcess
  Extra process names (without .exe) to treat as games, in addition to GAME_MODE_PROCESSES.

.PARAMETER Install
  Register a per-user Scheduled Task that runs this watcher with -Once on a repeating
  interval (no admin required).

.PARAMETER Uninstall
  Remove the Scheduled Task created by -Install.

.PARAMETER Status
  Print current detection state and whether the watcher has paused the stack.

.EXAMPLE
  .\scripts\game-mode-watcher.ps1
  Run continuously in the foreground.

.EXAMPLE
  .\scripts\game-mode-watcher.ps1 -Install
  Install a background Scheduled Task that checks every couple of minutes.

.EXAMPLE
  .\scripts\game-mode-watcher.ps1 -Once -WhatIf
  Show what a single check would do without touching Docker.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [switch]$Once,
  [int]$PollSeconds,
  [int]$CooldownSeconds,
  [ValidateSet('stop', 'down')]
  [string]$Action,
  [switch]$NoRestore,
  [string[]]$GameProcess,
  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Status
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$MarkerFile = Join-Path $RepoRoot ".game-mode-state"
$TaskName = "windows-llm-host Game Mode Watcher"

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

function ConvertTo-Bool {
  param([string]$Value, [bool]$Default = $false)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
  return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

# Resolve effective settings: explicit parameters win, then .env, then built-in defaults.
if (-not $PollSeconds) { $PollSeconds = [int](Get-DotEnvValue -Name "GAME_MODE_POLL_SECONDS" -Default "15") }
if (-not $CooldownSeconds) { $CooldownSeconds = [int](Get-DotEnvValue -Name "GAME_MODE_COOLDOWN_SECONDS" -Default "60") }
if (-not $Action) { $Action = Get-DotEnvValue -Name "GAME_MODE_ACTION" -Default "stop" }
if ($Action -notin @("stop", "down")) { $Action = "stop" }

$restore = -not $NoRestore.IsPresent
if (-not $NoRestore.IsPresent) {
  $restore = ConvertTo-Bool (Get-DotEnvValue -Name "GAME_MODE_RESTORE" -Default "true") -Default $true
}

$useFullscreen = ConvertTo-Bool (Get-DotEnvValue -Name "GAME_MODE_USE_FULLSCREEN" -Default "true") -Default $true

$configuredProcesses = @()
$envProcesses = Get-DotEnvValue -Name "GAME_MODE_PROCESSES"
if ($envProcesses) {
  $configuredProcesses += ($envProcesses -split "[,;]") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if ($GameProcess) {
  $configuredProcesses += $GameProcess
}
# Normalise: strip any .exe and lower-case for comparison.
$configuredProcesses = $configuredProcesses |
  ForEach-Object { ($_ -replace "\.exe$", "").Trim().ToLowerInvariant() } |
  Where-Object { $_ } |
  Select-Object -Unique

# Foreground/full-screen detection lives in a tiny Win32 wrapper.
if (-not ("WinLlmHostFg" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class WinLlmHostFg {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
}

# Shell / desktop processes that legitimately own a full-screen foreground window.
$ShellProcessNames = @(
  "explorer", "shellexperiencehost", "searchhost", "searchui",
  "startmenuexperiencehost", "applicationframehost", "textinputhost",
  "lockapp", "logonui", "idle"
)

function Get-ForegroundInfo {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
  $hwnd = [WinLlmHostFg]::GetForegroundWindow()
  if ($hwnd -eq [IntPtr]::Zero) { return $null }

  $procId = [uint32]0
  [void][WinLlmHostFg]::GetWindowThreadProcessId($hwnd, [ref]$procId)
  $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue

  $rect = New-Object "WinLlmHostFg+RECT"
  if (-not [WinLlmHostFg]::GetWindowRect($hwnd, [ref]$rect)) { return $null }

  $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
  $bounds = $screen.Bounds
  # Window covers the monitor (allow a few px of slop for borders).
  $coversScreen = ($rect.Left -le $bounds.Left + 2) -and ($rect.Top -le $bounds.Top + 2) -and
                  ($rect.Right -ge $bounds.Right - 2) -and ($rect.Bottom -ge $bounds.Bottom - 2)

  return [pscustomobject]@{
    ProcessName  = if ($proc) { $proc.ProcessName.ToLowerInvariant() } else { "" }
    CoversScreen = [bool]$coversScreen
  }
}

function Test-Gaming {
  # Signal 1: a configured game/launcher process is running.
  if ($configuredProcesses.Count -gt 0) {
    $running = Get-Process -ErrorAction SilentlyContinue |
      ForEach-Object { $_.ProcessName.ToLowerInvariant() } |
      Where-Object { $configuredProcesses -contains $_ }
    if ($running) {
      return [pscustomobject]@{ Gaming = $true; Reason = "process: $($running | Select-Object -First 1 -Unique)" }
    }
  }

  # Signal 2: a full-screen foreground window that is not the Windows shell.
  if ($useFullscreen) {
    $fg = Get-ForegroundInfo
    if ($fg -and $fg.CoversScreen -and ($fg.ProcessName) -and ($ShellProcessNames -notcontains $fg.ProcessName)) {
      return [pscustomobject]@{ Gaming = $true; Reason = "fullscreen: $($fg.ProcessName)" }
    }
  }

  return [pscustomobject]@{ Gaming = $false; Reason = "" }
}

function Test-StackRunning {
  # -q + --status running is portable across Compose v2 versions and avoids relying on
  # Go-template --format support.
  $ids = & docker compose ps --status running -q 2>$null
  return [bool]($ids)
}

function Invoke-PauseStack {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param([string]$Reason)
  if ($PSCmdlet.ShouldProcess("windows-llm-host stack", "docker compose $Action ($Reason)")) {
    Write-Host "[$(Get-Date -Format o)] Gaming detected ($Reason). Pausing stack with 'docker compose $Action'."
    & docker compose $Action
    Set-Content -Path $MarkerFile -Value "paused-by-watcher action=$Action at=$(Get-Date -Format o)" -Encoding utf8
  }
}

function Invoke-RestoreStack {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param()
  if ($PSCmdlet.ShouldProcess("windows-llm-host stack", "restore after game")) {
    $restoreCmd = if ($Action -eq "down") { @("compose", "up", "-d") } else { @("compose", "start") }
    Write-Host "[$(Get-Date -Format o)] Gaming state cleared. Restoring stack with 'docker $($restoreCmd -join ' ')'."
    & docker @restoreCmd
    Remove-Item -Path $MarkerFile -ErrorAction SilentlyContinue
  }
}

function Test-PausedByWatcher {
  return (Test-Path $MarkerFile)
}

function Invoke-Check {
  <#
    One evaluation step. $script:clearSince tracks how long the gaming state has been
    clear in continuous mode; in -Once mode the marker file alone carries state across runs.
  #>
  $state = Test-Gaming
  $pausedByWatcher = Test-PausedByWatcher

  if ($state.Gaming) {
    $script:clearSince = $null
    if (-not $pausedByWatcher -and (Test-StackRunning)) {
      Invoke-PauseStack -Reason $state.Reason
    }
    return
  }

  # Not gaming.
  if (-not $pausedByWatcher) { return }
  if (-not $restore) { return }

  if ($Once) {
    # No persistent cooldown across one-shot runs; restore immediately when clear.
    Invoke-RestoreStack
    return
  }

  if (-not $script:clearSince) {
    $script:clearSince = Get-Date
    Write-Verbose "Gaming cleared; waiting ${CooldownSeconds}s before restoring."
    return
  }

  if (((Get-Date) - $script:clearSince).TotalSeconds -ge $CooldownSeconds) {
    Invoke-RestoreStack
    $script:clearSince = $null
  }
}

function Show-Status {
  $state = Test-Gaming
  Write-Host "windows-llm-host Game Mode watcher status"
  Write-Host "  Repo:              $RepoRoot"
  Write-Host "  Action on game:    docker compose $Action"
  Write-Host "  Restore after:     $restore (cooldown ${CooldownSeconds}s)"
  Write-Host "  Fullscreen signal: $useFullscreen"
  Write-Host "  Game processes:    $((($configuredProcesses) -join ', '))"
  Write-Host "  Gaming now:        $($state.Gaming)$(if ($state.Reason) { " ($($state.Reason))" })"
  Write-Host "  Stack running:     $(Test-StackRunning)"
  Write-Host "  Paused by watcher: $(Test-PausedByWatcher)"
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Write-Host "  Scheduled task:    $(if ($existing) { 'installed' } else { 'not installed' })"
}

function Install-WatcherTask {
  $scriptPath = $MyInvocation.MyCommand.Path
  if (-not $scriptPath) { $scriptPath = Join-Path $PSScriptRoot "game-mode-watcher.ps1" }

  if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw "Register-ScheduledTask is unavailable. Run the watcher continuously instead: .\scripts\game-mode-watcher.ps1"
  }

  $interval = [Math]::Max(60, $PollSeconds)
  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -Once"

  $trigger = New-ScheduledTaskTrigger -AtLogOn
  # Add a repetition so it keeps checking, not just once at logon.
  $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Seconds $interval) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  $trigger.Repetition = $repeatTrigger.Repetition

  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description "Pause the windows-llm-host Docker stack while a full-screen game is running." -Force | Out-Null

  Write-Host "Installed Scheduled Task '$TaskName' (checks every ${interval}s, runs at logon)."
  Write-Host "Remove it with: .\scripts\game-mode-watcher.ps1 -Uninstall"
}

function Uninstall-WatcherTask {
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed Scheduled Task '$TaskName'."
  } else {
    Write-Host "Scheduled Task '$TaskName' is not installed."
  }
  Remove-Item -Path $MarkerFile -ErrorAction SilentlyContinue
}

# --- Entry point ---------------------------------------------------------------
$script:clearSince = $null

if ($Status) { Show-Status; return }
if ($Install) { Install-WatcherTask; return }
if ($Uninstall) { Uninstall-WatcherTask; return }

if ($Once) {
  Invoke-Check
  return
}

Write-Host "windows-llm-host Game Mode watcher running. Action: docker compose $Action. Ctrl+C to stop."
Write-Host "Restore after game: $restore. Poll: ${PollSeconds}s. Cooldown: ${CooldownSeconds}s."
if ($configuredProcesses.Count -gt 0) {
  Write-Host "Watching game processes: $($configuredProcesses -join ', ')"
}

while ($true) {
  try {
    Invoke-Check
  } catch {
    Write-Warning "Check failed: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $PollSeconds
}
