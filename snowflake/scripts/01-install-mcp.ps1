#requires -Version 5.1
<#
  01-install-mcp.ps1 - Install the Snowflake MCP server and wire it into OpenCode.

  Optional. Only needed if you want the agent to query Snowflake; the local file
  workflow does not use any of this.

  The MCP block is merged into app\workspace\opencode.json - Fish.AI's project-level
  OpenCode config (it no longer writes ~\.config\opencode). OpenCode picks it up because
  start.ps1 runs the agent with app\workspace as its working directory.
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # repo root

# --- uv (runs snowflake-labs-mcp) ---
if (-not (Get-Command uvx -ErrorAction SilentlyContinue)) {
    Write-Host "Installing uv..." -ForegroundColor Cyan
    & winget install --id astral-sh.uv -e --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}
if (-not (Get-Command uvx -ErrorAction SilentlyContinue)) {
    throw "uvx still not on PATH. Reopen the terminal, or install manually: https://docs.astral.sh/uv/"
}

# --- Warm up so the first agent session does not time out downloading dependencies ---
# --python 3.11 is required: snowflake-labs-mcp needs Python >= 3.11 and uv resolves
# against whatever python is on PATH. With a 3.10 on PATH it fails with
# "No solution found when resolving tool dependencies" and never hints at the fix.
Write-Host "Warming up snowflake-labs-mcp (first run downloads a lot)..." -ForegroundColor Cyan
& uvx --python 3.11 snowflake-labs-mcp --help | Out-Null

# --- Config files ---
$sfDir  = Join-Path $env:USERPROFILE '.snowflake'
$cfgDir = Join-Path $env:USERPROFILE '.config\snowflake'
$ocFile = Join-Path $Root 'app\workspace\opencode.json'
New-Item -ItemType Directory -Force -Path $sfDir, $cfgDir | Out-Null

Copy-Item (Join-Path $Root 'snowflake\config\service_config.yaml') $cfgDir -Force
Write-Host "wrote $cfgDir\service_config.yaml" -ForegroundColor Green

$connTarget = Join-Path $sfDir 'connections.toml'
if (Test-Path $connTarget) {
    Write-Host "$connTarget already exists - not overwriting" -ForegroundColor Yellow
} else {
    Copy-Item (Join-Path $Root 'snowflake\config\connections.toml') $connTarget -Force
    Write-Host "wrote $connTarget" -ForegroundColor Green
    Write-Host "  !! You must fill in account / user - open that file and edit it" -ForegroundColor Yellow
}

# --- Merge the MCP block into the existing opencode.json ---
if (-not (Test-Path $ocFile)) { throw "$ocFile not found - the checkout is incomplete (git pull?)" }

$cfg = Get-Content $ocFile -Raw | ConvertFrom-Json
if ($cfg.mcp -and $cfg.mcp.snowflake) {
    Write-Host "mcp.snowflake already configured - leaving it alone" -ForegroundColor Yellow
} else {
    $mcpEntry = [ordered]@{
        type    = 'local'
        enabled = $true
        command = @(
            'uvx', '--python', '3.11', 'snowflake-labs-mcp',
            '--service-config-file', (Join-Path $cfgDir 'service_config.yaml').Replace('\','/'),
            '--connection-name', 'audit'
        )
        # service_config.yaml is UTF-8. On a non-UTF-8 Windows locale Python's open()
        # defaults to the ANSI codepage and PyYAML dies with UnicodeDecodeError -
        # and OpenCode reports MCP startup failures by silently omitting the tools.
        environment = @{ PYTHONUTF8 = '1' }
    }
    if (-not $cfg.mcp) {
        $cfg | Add-Member -NotePropertyName mcp -NotePropertyValue ([ordered]@{}) -Force
    }
    $cfg.mcp | Add-Member -NotePropertyName snowflake -NotePropertyValue $mcpEntry -Force
    $cfg | ConvertTo-Json -Depth 12 | Set-Content $ocFile -Encoding UTF8
    Write-Host "added mcp.snowflake to $ocFile" -ForegroundColor Green
}

Write-Host "`nNext:" -ForegroundColor Green
Write-Host "  1. run snowflake\sql\01-guardrails.sql in Snowflake as ACCOUNTADMIN"
Write-Host "  2. pwsh snowflake\tools\gen-keypair.ps1        generate keys, print the public key"
Write-Host "  3. edit $connTarget          set your account identifier"
Write-Host "  4. python snowflake\tools\probe_snowflake.py   must pass BOTH checks"
Write-Host "  5. pwsh snowflake\scripts\02-verify.ps1"
