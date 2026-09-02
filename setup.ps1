#requires -Version 5.1
<#
  setup.ps1 - One-shot install for Fish.AI.

  Runs preflight, downloads llama.cpp and the model, installs the agent runtime and
  the Python data stack, and puts a Fish.AI shortcut on the desktop.
  Safe to re-run: every step skips work that is already done.

  After this finishes, run:  .\start.ps1   (or double-click Fish.AI.cmd)
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b',
    [switch]$SkipPreflight,
    # Preflight installs missing prerequisites (Python, Node) by default.
    # Pass this to have it only report them instead.
    [switch]$NoAutoInstall,
    # Do not create the desktop shortcut.
    [switch]$NoShortcut,
    # Snowflake is optional. Without it you still get local file analysis,
    # which is what most people want.
    [switch]$WithSnowflake
)

$ErrorActionPreference = 'Stop'
$Root    = $PSScriptRoot
$Scripts = Join-Path $Root 'engine\scripts'
$env:PYTHONUTF8 = '1'

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

$sw = [Diagnostics.Stopwatch]::StartNew()

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

Step "4/5  Agent runtime (OpenCode)"
& (Join-Path $Scripts '04-install-agent.ps1')
Sync-Path

Step "5/5  Python data stack"
& (Join-Path $Scripts '06-install-pydeps.ps1')

# The web UI has no dependencies - plain Node, nothing to npm install.

if (-not $NoShortcut) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnk = Join-Path $desktop 'Fish.AI.lnk'
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $Root 'Fish.AI.cmd'
        $s.WorkingDirectory = $Root
        $s.Description = 'Fish.AI - ask questions about your data files, locally'
        $s.IconLocation = '%SystemRoot%\System32\imageres.dll,109'
        $s.Save()
        Write-Host "`nDesktop shortcut: $lnk" -ForegroundColor DarkGray
    } catch {
        Write-Host "`n(could not create the desktop shortcut: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

$mins = [math]::Round($sw.Elapsed.TotalMinutes, 1)
Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host "  Setup complete  ($mins min)" -ForegroundColor Green
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host ""
Write-Host "  Start it:   .\start.ps1        or double-click  Fish.AI.cmd" -ForegroundColor White
Write-Host "  Your data:  app\workspace\     (or just drag files into the page)" -ForegroundColor White
Write-Host ""
if ($WithSnowflake) {
    Write-Host "  Snowflake setup (optional, needs an account you administer):" -ForegroundColor Cyan
    Write-Host "    1. run snowflake\sql\01-guardrails.sql as ACCOUNTADMIN"
    Write-Host "    2. pwsh snowflake\tools\gen-keypair.ps1"
    Write-Host "    3. edit  $env:USERPROFILE\.snowflake\connections.toml"
    Write-Host "    4. python snowflake\tools\probe_snowflake.py"
    Write-Host ""
}
