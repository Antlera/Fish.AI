#requires -Version 5.1
<#
  start.ps1 - Start Fish.AI. One command, one terminal.

  Brings up three processes, all in the background, then waits:
    llama-server    :8080   local inference
    opencode serve  :4096   agent runtime
    node server.mjs :8090   web UI + warm-up

  The browser opens immediately - the page shows what is still loading - and the
  web server warms the model up as soon as inference is ready, so the first real
  message does not pay the cold-start prefill. Ctrl+C stops everything this
  script started. Logs go to logs\ in the repo.
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b',
    [int]$Port = 8090,
    [switch]$NoBrowser,
    # Skip the start-up warm-up turn (it costs one short generation).
    [switch]$NoWarmup,
    # Do not keep Microsoft Teams' status "Available" while Fish.AI runs
    # (on by default: it re-runs `ms-teams.exe --set-presence-to-available` every
    # 2.5-4.5 min at random and keeps the display on; the button in the page toggles it too).
    [switch]$NoTeamsGreen
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

# The agent runs python on this machine. On a Chinese/Japanese/Korean Windows the
# default codec is the ANSI codepage, so any non-ASCII byte in a data file makes
# open() throw UnicodeDecodeError. Every child process inherits this.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

$Logs = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $Logs | Out-Null
$ws = Join-Path $Root 'app\workspace'
New-Item -ItemType Directory -Force -Path $ws | Out-Null

# Whatever PowerShell is running this script is the one to run the helper in.
# Hard-coding 'pwsh' breaks on a stock Windows install, which only has 5.1.
$psExe = (Get-Process -Id $PID).Path

function Test-Port([int]$p, [string]$path) {
    try { $null = Invoke-WebRequest "http://127.0.0.1:$p$path" -TimeoutSec 2 -UseBasicParsing; $true }
    catch { $false }
}

function Show-Log([string]$log) {
    foreach ($f in @("$log.err", $log)) {
        if (Test-Path $f) {
            $tail = Get-Content $f -Tail 15 -ErrorAction SilentlyContinue | Where-Object { $_ }
            if ($tail) { $tail | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }; break }
        }
    }
}

$started = @()
function Stop-Started {
    foreach ($p in $script:started) {
        if ($p -and -not $p.HasExited) {
            Write-Host "stopping $($p.ProcessName) (pid $($p.Id))" -ForegroundColor DarkGray
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "  Fish.AI  starting  (model: $Model)" -ForegroundColor Cyan
Write-Host ""

try {
    # --- inference (background) ---
    $llamaLog = Join-Path $Logs 'llama-server.log'
    $llamaP = $null
    if (Test-Port 8080 '/health') {
        Write-Host ("  {0,-22} already running" -f 'inference :8080') -ForegroundColor DarkGray
    } else {
        $llamaP = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $llamaLog -RedirectStandardError "$llamaLog.err" `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
                            (Join-Path $Root 'engine\scripts\03-start-server.ps1'), '-Model', $Model)
        $started += $llamaP
    }

    # --- agent runtime (background) ---
    $ocLog = Join-Path $Logs 'opencode.log'
    $ocP = $null
    if (Test-Port 4096 '/api/health') {
        Write-Host ("  {0,-22} already running" -f 'agent     :4096') -ForegroundColor DarkGray
    } else {
        # `opencode` on PATH is an npm .cmd shim; Start-Process cannot launch it
        # ("%1 is not a valid Win32 application"). Use the real exe.
        $ocExe = Join-Path (& npm root -g) 'opencode-ai\bin\opencode.exe'
        if (-not (Test-Path $ocExe)) { throw "opencode not installed. Run .\setup.ps1 first." }
        if (-not (Test-Path (Join-Path $ws 'opencode.json'))) {
            throw "app\workspace\opencode.json is missing - it tells opencode to use the local model. Re-run .\setup.ps1 or git pull."
        }
        $ocP = Start-Process -FilePath $ocExe -PassThru -WindowStyle Hidden -WorkingDirectory $ws `
            -RedirectStandardOutput $ocLog -RedirectStandardError "$ocLog.err" `
            -ArgumentList @('serve','--port','4096')
        $started += $ocP
    }

    # --- web UI (background) ---
    $webLog = Join-Path $Logs 'web.log'
    $env:FISH_PORT         = $Port
    $env:FISH_WORKSPACE    = $ws
    $env:FISH_LLAMA_LOG    = $llamaLog
    $env:FISH_OPENCODE_LOG = $ocLog
    if ($NoWarmup) { $env:FISH_NO_WARMUP = '1' } else { Remove-Item Env:FISH_NO_WARMUP -ErrorAction SilentlyContinue }
    $env:FISH_TEAMS_GREEN = if ($NoTeamsGreen) { '0' } else { '1' }
    $nodeExe = (Get-Command node -ErrorAction Stop).Source
    $webP = Start-Process -FilePath $nodeExe -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $webLog -RedirectStandardError "$webLog.err" `
        -ArgumentList @((Join-Path $Root 'app\server.mjs'))
    $started += $webP
    Start-Sleep -Milliseconds 800
    if ($webP.HasExited) {
        Show-Log $webLog
        throw "web UI failed to start (is port $Port free?)"
    }

    $url = "http://127.0.0.1:$Port"
    if (-not $NoBrowser) { Start-Process $url }
    Write-Host "  Fish.AI  ->  $url" -ForegroundColor Cyan
    Write-Host "  (the page shows loading progress; Ctrl+C here stops everything)" -ForegroundColor DarkGray
    Write-Host ""

    # --- wait for the backends, reporting as they come up ---
    if ($llamaP) {
        Write-Host ("  {0,-22} " -f 'inference :8080') -NoNewline
        $ok = $false
        for ($i = 0; $i -lt 240; $i++) {
            if (Test-Port 8080 '/health') { $ok = $true; break }
            if ($llamaP.HasExited) { break }
            if ($i % 5 -eq 0) { Write-Host "." -NoNewline -ForegroundColor DarkGray }
            Start-Sleep -Seconds 1
        }
        if (-not $ok) {
            Write-Host " failed" -ForegroundColor Red
            Show-Log $llamaLog
            throw "llama-server did not start. Did you run .\setup.ps1 ?  Full log: $llamaLog"
        }
        Write-Host " ok" -ForegroundColor Green
        # Track llama-server itself, not just the wrapper - killing the wrapper does
        # not kill the child, and Process.Parent does not exist on PS 5.1.
        Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object { $started += $_ }
    }

    if ($ocP) {
        Write-Host ("  {0,-22} " -f 'agent     :4096') -NoNewline
        $ok = $false
        for ($i = 0; $i -lt 60; $i++) {
            if (Test-Port 4096 '/api/health') { $ok = $true; break }
            if ($ocP.HasExited) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ok) {
            Write-Host "failed" -ForegroundColor Red
            Show-Log $ocLog
            throw "opencode serve did not start. Full log: $ocLog"
        }
        Write-Host "ok" -ForegroundColor Green
    }

    Write-Host ("  {0,-22} ok" -f "web UI    :$Port") -ForegroundColor Green
    if (-not $NoWarmup) {
        Write-Host ""
        Write-Host "  Warming the model up (one throwaway turn, ~1 min on the 35B)." -ForegroundColor DarkGray
        Write-Host "  The page shows when it is done; the first real message is then fast." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Running. Ctrl+C to stop." -ForegroundColor Cyan

    # Block here. Ctrl+C throws, which lands in finally.
    Wait-Process -Id $webP.Id
    Write-Host ""
    Write-Host "web UI exited:" -ForegroundColor Yellow
    Show-Log $webLog
} finally {
    # Only shut down what this script started; leave anything that was already up.
    Stop-Started
}
