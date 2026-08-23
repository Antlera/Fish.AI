#requires -Version 5.1
<#
  setup.ps1 - One-shot install for Fish.AI.

  Runs preflight, downloads llama.cpp and the model, installs the agent runtime.
  Safe to re-run: every step skips work that is already done.

  After this finishes, run:  .\start.ps1
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b',
    [switch]$SkipPreflight,
    # Preflight installs missing prerequisites (Python, Node) by default.
    # Pass this to have it only report them instead.
    [switch]$NoAutoInstall,
    # Snowflake is optional. Without it you still get local file analysis,
    # which is what most people want.
    [switch]$WithSnowflake
)

$ErrorActionPreference = 'Stop'
$Root    = $PSScriptRoot
$Scripts = Join-Path $Root 'engine\scripts'

function Step([string]$n) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host "  $n" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
}

# PATH is not refreshed inside a running terminal after winget installs something.
function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}
Sync-Path

if (-not $SkipPreflight) {
    Step "1/5  Preflight"
    & (Join-Path $Scripts '00-preflight.ps1') -AutoInstall:(-not $NoAutoInstall)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nPreflight failed. Fix the items above, or re-run with -SkipPreflight to ignore." -ForegroundColor Red
        exit 1
    }
    # Anything preflight installed landed in the machine/user PATH, not in this process.
    Sync-Path
} else {
    Write-Host "Skipping preflight (-SkipPreflight)" -ForegroundColor DarkGray
}

Step "2/5  llama.cpp (CUDA build)"
if (Test-Path (Join-Path $Root 'engine\bin\llama-server.exe')) {
    Write-Host "already installed, skipping" -ForegroundColor DarkGray
} else {
    & (Join-Path $Scripts '01-install-llama.ps1')
}

Step "3/5  Model weights ($Model)"
& (Join-Path $Scripts '02-download-model.ps1') -Model $Model

Step "4/5  Agent runtime (OpenCode + uv)"
& (Join-Path $Scripts '04-install-agent.ps1')
Sync-Path

Step "5/5  Web UI dependencies"
Push-Location (Join-Path $Root 'app')
try {
    if (Test-Path 'package.json') { & npm install --no-audit --no-fund | Out-Null }
    Write-Host "ok" -ForegroundColor Green
} finally { Pop-Location }

Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host "  Setup complete." -ForegroundColor Green
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host ""
Write-Host "  Start it with:   .\start.ps1" -ForegroundColor White
Write-Host ""
if ($WithSnowflake) {
    Write-Host "  Snowflake setup (optional, needs an account you administer):" -ForegroundColor Cyan
    Write-Host "    1. run snowflake\sql\01-guardrails.sql as ACCOUNTADMIN"
    Write-Host "    2. pwsh snowflake\tools\gen-keypair.ps1"
    Write-Host "    3. edit  $env:USERPROFILE\.snowflake\connections.toml"
    Write-Host "    4. python snowflake\tools\probe_snowflake.py"
    Write-Host ""
}
