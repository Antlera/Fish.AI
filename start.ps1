#requires -Version 5.1
<#
  start.ps1 - Start Fish.AI. One command, one terminal.

  Brings up three processes:
    llama-server    :8080   local inference (background)
    opencode serve  :4096   agent runtime  (background)
    node server.mjs :8090   web UI         (foreground - Ctrl+C stops everything)
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b',
    [int]$Port = 8090,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

function Test-Port([int]$p, [string]$path) {
    try { $null = Invoke-WebRequest "http://127.0.0.1:$p$path" -TimeoutSec 2 -UseBasicParsing; $true }
    catch { $false }
}

$started = @()

# --- inference ---
Write-Host ("{0,-30}" -f "inference  :8080") -NoNewline
if (Test-Port 8080 '/health') {
    Write-Host "already running" -ForegroundColor DarkGray
} else {
    $log = Join-Path $env:TEMP 'fish-llama.log'
    $p = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
         -ArgumentList @('-NoProfile','-File',
                         (Join-Path $Root 'engine\scripts\03-start-server.ps1'),
                         '-Model', $Model)
    $started += $p
    Write-Host "loading" -ForegroundColor Cyan -NoNewline
    $ok = $false
    for ($i = 0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 1
        if ($i % 5 -eq 0) { Write-Host "." -NoNewline -ForegroundColor DarkGray }
        if (Test-Port 8080 '/health') { $ok = $true; break }
        if ($p.HasExited) { break }
    }
    if ($ok) {
        Write-Host " ok" -ForegroundColor Green
        # Track llama-server itself, not just the pwsh wrapper - killing the wrapper
        # does not kill the child, and Process.Parent does not exist on PS 5.1.
        Get-Process llama-server -ErrorAction SilentlyContinue | ForEach-Object { $started += $_ }
    }
    else {
        Write-Host " failed" -ForegroundColor Red
        if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
        throw "llama-server did not start. Did you run .\setup.ps1 ?"
    }
}

# --- agent runtime ---
Write-Host ("{0,-30}" -f "agent      :4096") -NoNewline
if (Test-Port 4096 '/api/health') {
    Write-Host "already running" -ForegroundColor DarkGray
} else {
    $ws = Join-Path $Root 'app\workspace'
    New-Item -ItemType Directory -Force -Path $ws | Out-Null
    # `opencode` on PATH is an npm .cmd shim; Start-Process cannot launch it
    # ("%1 is not a valid Win32 application"). Use the real exe.
    $ocExe = Join-Path (& npm root -g) 'opencode-ai\bin\opencode.exe'
    if (-not (Test-Path $ocExe)) { throw "opencode not installed. Run .\setup.ps1 first." }
    $log = Join-Path $env:TEMP 'fish-opencode.log'
    $p = Start-Process -FilePath $ocExe -PassThru -WindowStyle Hidden -WorkingDirectory $ws `
         -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
         -ArgumentList @('serve','--port','4096')
    $started += $p
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if (Test-Port 4096 '/api/health') { $ok = $true; break } }
    if ($ok) { Write-Host "ok" -ForegroundColor Green }
    else {
        Write-Host "failed" -ForegroundColor Red
        if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 15 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
        throw "opencode serve did not start"
    }
}

# --- web UI (foreground) ---
Write-Host ""
Write-Host "  Fish.AI  ->  http://127.0.0.1:$Port" -ForegroundColor Cyan
Write-Host "  Ctrl+C to stop everything" -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port" }

$env:FISH_PORT = $Port
try {
    & node (Join-Path $Root 'app\server.mjs')
} finally {
    # Only shut down what this script started; leave anything that was already up.
    foreach ($p in $started) {
        if ($p -and -not $p.HasExited) {
            Write-Host "stopping $($p.ProcessName) (pid $($p.Id))..." -ForegroundColor DarkGray
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
