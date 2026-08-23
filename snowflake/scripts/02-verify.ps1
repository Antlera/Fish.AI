#requires -Version 5.1
<#
  02-verify.ps1 - End-to-end check: can the agent actually reach Snowflake through MCP?

  Each piece passing on its own does not mean the chain works. The usual failure is
  the MCP server not starting (uvx not found, wrong connections.toml path), and
  OpenCode says nothing about it - the Snowflake tools are simply absent.
#>

$ErrorActionPreference = 'Stop'
$fail = $false

function Say([string]$n, [bool]$ok, [string]$d='', [string]$hint='') {
    Write-Host ("{0,-34}" -f $n) -NoNewline
    if ($ok) { Write-Host "PASS" -ForegroundColor Green -NoNewline; Write-Host "  $d" -ForegroundColor DarkGray }
    else {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  $d" -ForegroundColor Yellow
        if ($hint) { Write-Host "  -> $hint" -ForegroundColor DarkYellow }
        $script:fail = $true
    }
}

Write-Host "`n=== end-to-end verification ===`n" -ForegroundColor Cyan

# 1. inference server
try { $null = Invoke-RestMethod 'http://127.0.0.1:8080/health' -TimeoutSec 5; Say "inference server up" $true }
catch { Say "inference server up" $false "cannot reach :8080" "run 03-start-server.ps1 in another terminal"; exit 1 }

# 2. can the MCP server start on its own
Write-Host ("{0,-34}" -f "MCP server starts") -NoNewline
$cfg = Join-Path $env:USERPROFILE '.config\snowflake\service_config.yaml'
# service_config.yaml is UTF-8. On a non-UTF-8 Windows locale Python's open()
# defaults to the ANSI codepage and PyYAML dies with UnicodeDecodeError.
# opencode.json sets the same variable for the MCP process.
$env:PYTHONUTF8 = '1'
$log = Join-Path $env:TEMP 'mcp-probe.log'
$p = Start-Process -FilePath 'uvx' -PassThru -WindowStyle Hidden `
     -RedirectStandardError $log -RedirectStandardOutput "$log.out" `
     -ArgumentList @('--python','3.11','snowflake-labs-mcp','--service-config-file',$cfg,'--connection-name','audit')
Start-Sleep -Seconds 12
if (-not $p.HasExited) {
    Stop-Process -Id $p.Id -Force
    Write-Host "PASS" -ForegroundColor Green -NoNewline; Write-Host "  process alive" -ForegroundColor DarkGray
} else {
    Write-Host "FAIL" -ForegroundColor Red
    Write-Host "  --- stderr ---" -ForegroundColor DarkGray
    if (Test-Path $log) { Get-Content $log -Tail 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
    Write-Host "  -> Common causes: account still REPLACE-ME; wrong private key path;" -ForegroundColor DarkYellow
    Write-Host "     or UnicodeDecodeError 'gbk', which means PYTHONUTF8 did not take effect" -ForegroundColor DarkYellow
    $fail = $true
}

# 2b. is connections.toml actually filled in?
#     The check above only proves a process survived 12 seconds - it passes just as
#     happily with account=REPLACE-ME. The real gate is tools\probe_snowflake.py;
#     this catches the false green early.
Write-Host ("{0,-34}" -f "connections.toml filled in") -NoNewline
$conn = Join-Path $env:USERPROFILE '.snowflake\connections.toml'
if (-not (Test-Path $conn)) {
    Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  $conn not found" -ForegroundColor Yellow; $fail = $true
} elseif ((Get-Content $conn -Raw) -match 'REPLACE-ME') {
    Write-Host "FAIL" -ForegroundColor Red -NoNewline
    Write-Host "  account is still REPLACE-ME" -ForegroundColor Yellow
    Write-Host "  -> Until this passes, 'MCP server starts' above does NOT mean Snowflake is reachable" -ForegroundColor DarkYellow
    $fail = $true
} else {
    Write-Host "PASS" -ForegroundColor Green
}

# 3. does OpenCode know about this MCP server
Write-Host ("{0,-34}" -f "OpenCode config valid") -NoNewline
$oc = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
if (-not (Test-Path $oc)) {
    Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  $oc not found" -ForegroundColor Yellow; $fail = $true
} else {
    try {
        $j = Get-Content $oc -Raw | ConvertFrom-Json
        $hasMcp  = $null -ne $j.mcp.snowflake
        $hasProv = $null -ne $j.provider.local
        $tpl = (Get-Content $oc -Raw) -match '\{\{'
        if ($tpl) {
            Write-Host "FAIL" -ForegroundColor Red -NoNewline
            Write-Host "  unreplaced {{...}} placeholder" -ForegroundColor Yellow; $fail = $true
        } elseif ($hasMcp -and $hasProv) {
            Write-Host "PASS" -ForegroundColor Green
        } else {
            Write-Host "FAIL" -ForegroundColor Red -NoNewline
            Write-Host "  missing provider.local or mcp.snowflake" -ForegroundColor Yellow; $fail = $true
        }
    } catch {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  invalid JSON" -ForegroundColor Yellow; $fail = $true
    }
}

# 4. AGENTS.md present
Say "AGENTS.md present" (Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'AGENTS.md')) `
    "" "copy AGENTS.md into your actual audit working directory - OpenCode reads it from there"

Write-Host ""
if ($fail) { Write-Host "End-to-end verification failed." -ForegroundColor Red; exit 1 }

Write-Host "Local side OK. The real Snowflake gate is: python tools\probe_snowflake.py" -ForegroundColor Green
Write-Host "(connection works AND writes are rejected - both must pass). Then:" -ForegroundColor Green
Write-Host ""
Write-Host "  cd <your audit working directory>     # put a copy of AGENTS.md there" -ForegroundColor DarkGray
Write-Host "  opencode" -ForegroundColor DarkGray
Write-Host ""
Write-Host "A good first prompt:" -ForegroundColor Cyan
Write-Host '  List the tables in PROD, pick the three largest, and show me their columns' -ForegroundColor White
Write-Host '  and types. Do not SELECT any data rows.' -ForegroundColor White
