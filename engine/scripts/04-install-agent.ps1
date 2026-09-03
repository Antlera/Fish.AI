#requires -Version 5.1
<#
  04-install-agent.ps1 - Install the agent runtime (OpenCode).

  Configuration is NOT written to ~\.config\opencode: it lives in
  app\workspace\opencode.json, which OpenCode picks up as project config because
  start.ps1 launches it with that directory as the working directory. That keeps
  Fish.AI from touching (or being broken by) whatever global OpenCode setup the
  user already has.

  This is the core install. The Snowflake integration is separate and optional:
  snowflake\scripts\01-install-mcp.ps1.

  Runs natively on Windows; WSL is not needed.
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # repo root

. (Join-Path $PSScriptRoot '_env.ps1')   # PATH refresh + portable node first

# 1.18.26 is the oldest version verified to honour the per-agent tool list (older ones
# still hand the model every built-in tool, which is what Fish.AI's config trims).
$MinVersion = [version]'1.18.26'
$have = $null
# Only count an install whose exe the launcher can actually find (see Find-OpenCodeExe).
if ((Get-Command opencode -ErrorAction SilentlyContinue) -and (Find-OpenCodeExe)) {
    try { $have = [version]((& opencode --version 2>$null) -replace '[^\d.].*$', '') } catch { $have = $null }
}
if ($have -and $have -ge $MinVersion) {
    Write-Host "already installed ($have)" -ForegroundColor DarkGray
} else {
    if ($have) { Write-Host "OpenCode $have is older than $MinVersion - upgrading..." -ForegroundColor Cyan }
    else       { Write-Host "Installing OpenCode..." -ForegroundColor Cyan }
    # With the portable Node in engine\node, `npm -g` lands in engine\node\node_modules.
    & npm install -g opencode-ai@latest --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) {
        Write-Host "npm failed, trying winget..." -ForegroundColor Yellow
        & winget install --id SST.opencode -e --accept-package-agreements --accept-source-agreements
    }
    . (Join-Path $PSScriptRoot '_env.ps1')
}
& opencode --version
if ($LASTEXITCODE -ne 0) { throw "OpenCode install failed. Reopen the terminal so PATH picks it up, then retry." }
$exe = Find-OpenCodeExe
if (-not $exe) { throw "opencode is on PATH but its opencode.exe could not be located - the launcher needs the real binary" }
Write-Host "binary: $exe" -ForegroundColor DarkGray

$cfg = Join-Path $Root 'app\workspace\opencode.json'
if (-not (Test-Path $cfg)) { throw "missing $cfg - the checkout is incomplete" }
Write-Host "config: $cfg" -ForegroundColor DarkGray

# A stale copy from an older Fish.AI version would silently take precedence for
# other projects and confuse debugging; tell the user it is there, do not touch it.
$global = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
if (Test-Path $global) {
    $txt = Get-Content $global -Raw -ErrorAction SilentlyContinue
    if ($txt -match 'llama\.cpp \(local\)') {
        Write-Host "note: $global still has the local provider from an older install." -ForegroundColor DarkYellow
        Write-Host "      Fish.AI no longer needs it; delete it if you use OpenCode for other things." -ForegroundColor DarkYellow
    }
}

Write-Host "`nAgent runtime ready. Next: .\start.ps1 from the repo root" -ForegroundColor Green
