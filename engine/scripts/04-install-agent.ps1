#requires -Version 5.1
<#
  04-install-agent.ps1 - Install the agent runtime (OpenCode) and point it at the
  local inference server.

  This is the core install. The Snowflake integration is separate and optional:
  snowflake\scripts\01-install-mcp.ps1.

  Runs natively on Windows; WSL is not needed.
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # repo root

if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host "Installing OpenCode..." -ForegroundColor Cyan
    & npm install -g opencode-ai
    if ($LASTEXITCODE -ne 0) {
        Write-Host "npm failed, trying winget..." -ForegroundColor Yellow
        & winget install --id SST.opencode -e --accept-package-agreements --accept-source-agreements
    }
}
& opencode --version
if ($LASTEXITCODE -ne 0) { throw "OpenCode install failed. Reopen the terminal so PATH picks it up, then retry." }

$ocDir = Join-Path $env:USERPROFILE '.config\opencode'
New-Item -ItemType Directory -Force -Path $ocDir | Out-Null
$ocTarget = Join-Path $ocDir 'opencode.json'
$source   = Join-Path $Root 'engine\config\opencode.json'

if (Test-Path $ocTarget) {
    Write-Host "$ocTarget already exists - not overwriting." -ForegroundColor Yellow
    Write-Host "If the local provider is missing, merge it from $source by hand." -ForegroundColor DarkGray
} else {
    Copy-Item $source $ocTarget -Force
    Write-Host "wrote $ocTarget" -ForegroundColor Green
}

Write-Host "`nAgent runtime ready. Next: .\start.ps1 from the repo root" -ForegroundColor Green
