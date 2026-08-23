#requires -Version 5.1
<#
  00-preflight.ps1 - Check the machine, and with -AutoInstall fix what can be fixed.

  Auto-installable (via winget): Python, Node.js, and the PowerShell execution policy.
  Not auto-installable: the NVIDIA driver (needs a reboot and the right variant for your
  card) and anything about how much RAM/VRAM/disk you have.

  The RAM threshold is deliberately low. The default model (Qwen3.6-35B-A3B, UD-IQ1_M) is
  a 9.4GB file but only ~2.7GB is ever resident: it is an MoE with 256 experts, 8 active
  per token, and llama.cpp mmaps the file so cold experts stay on disk. Judging it by file
  size alone rules out machines that run it fine.
#>

param(
    # Install missing prerequisites instead of just reporting them.
    [switch]$AutoInstall
)

$ErrorActionPreference = 'Continue'
$script:Failed = $false

# winget installs do not refresh PATH in an already-running process.
function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}
Sync-Path

function Invoke-Winget {
    param([string]$Id)
    Write-Host "installing $Id ..." -ForegroundColor Cyan -NoNewline
    $out = & winget install --id $Id -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    Sync-Path

    # Deliberately do NOT interpret winget's exit code or output text. Both are
    # localised and it returns non-zero for harmless cases such as "already installed,
    # no upgrade available" - on a non-English Windows that was being read as failure.
    # The source of truth is whether the tool works now, which the caller re-checks.
    if ($code -eq 0) {
        Write-Host " done" -ForegroundColor Green
    } else {
        Write-Host " winget exit $code - re-checking anyway" -ForegroundColor DarkYellow
        $out | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    return $true
}

<#
  Name  display name
  Test  scriptblock returning @{ ok=$bool; detail=''; warn=$bool }
  Fix   optional scriptblock returning $true if it fixed things; only run with -AutoInstall
  Hint  what to tell the user when it cannot be fixed automatically
#>
function Check {
    param([string]$Name, [scriptblock]$Test, [scriptblock]$Fix = $null, [string]$Hint = '')

    $run = {
        try { & $Test } catch { @{ ok = $false; detail = $_.Exception.Message } }
    }

    Write-Host ("{0,-34}" -f $Name) -NoNewline
    $r = & $run

    if (-not $r.ok -and -not $r.warn -and $Fix -and $AutoInstall) {
        Write-Host "MISSING" -ForegroundColor Yellow
        if (& $Fix) {
            $label = "  re-check: $Name"
            if ($label.Length -gt 33) { $label = $label.Substring(0, 33) }
            Write-Host ("{0,-34}" -f $label) -NoNewline
            $r = & $run
        }
    }

    if ($r.ok) {
        Write-Host "PASS" -ForegroundColor Green -NoNewline
        if ($r.detail) { Write-Host "  $($r.detail)" -ForegroundColor DarkGray } else { Write-Host "" }
    } elseif ($r.warn) {
        Write-Host "WARN" -ForegroundColor Yellow -NoNewline
        Write-Host "  $($r.detail)" -ForegroundColor DarkGray
        if ($Hint) { Write-Host ("  -> " + $Hint) -ForegroundColor DarkYellow }
    } else {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host "  $($r.detail)" -ForegroundColor Yellow
        if ($Hint) { Write-Host ("  -> " + $Hint) -ForegroundColor DarkYellow }
        if ($Fix -and -not $AutoInstall) {
            Write-Host "  -> or re-run with -AutoInstall to install it automatically" -ForegroundColor DarkYellow
        }
        $script:Failed = $true
    }
}

Write-Host "`n=== preflight ===" -ForegroundColor Cyan
if ($AutoInstall) { Write-Host "(auto-install enabled)`n" -ForegroundColor DarkGray } else { Write-Host "" }

Check "NVIDIA driver / nvidia-smi" {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return @{ ok = $false; detail = "nvidia-smi not found" } }
    $out = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    @{ ok = $true; detail = $out }
} $null "Install the official NVIDIA driver (not the one from Windows Update). Needs a reboot, so this one is not automated."

Check "VRAM >= 3.5 GB" {
    $mb = [int]((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) -split "`n")[0].Trim()
    @{ ok = ($mb -ge 3500); detail = "$mb MB" }
} $null "Below 3.5GB you must lower -c; the tuned parameters assume ~4GB"

Check "free VRAM >= 3.0 GB" {
    $mb = [int]((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -split "`n")[0].Trim()
    @{ ok = ($mb -ge 3000); detail = "$mb MB free" }
} $null "Close browsers with hardware acceleration and other GPU consumers. If Fish.AI is already running, that is expected."

Check "system RAM >= 12 GB" {
    $gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($gb -ge 12) { return @{ ok = $true;  detail = "$gb GB" } }
    if ($gb -ge 8)  { return @{ ok = $false; warn = $true; detail = "$gb GB - tight, expect paging" } }
    @{ ok = $false; detail = "$gb GB" }
} $null "Under 8GB use -Model bonsai8b (1.1GB) or qwen4b (2.4GB)"

Check "free disk >= 25 GB" {
    $d = Get-PSDrive -Name ($PSScriptRoot.Substring(0,1))
    $gb = [math]::Round($d.Free / 1GB, 1)
    @{ ok = ($gb -ge 25); detail = "$gb GB free on $($d.Name):" }
} $null "The default model is 9.4GB plus ~1GB of binaries and download cache"

Check "CPU cores" {
    $n = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    @{ ok = ($n -ge 8); detail = "$n logical" }
} $null "Few cores noticeably slow the CPU-side MoE expert compute"

Check "Python 3.10+" {
    $v = & python --version 2>&1
    if ($v -notmatch 'Python (\d+)\.(\d+)') { return @{ ok = $false; detail = "not found" } }
    $ok = ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10)
    @{ ok = $ok; detail = "$v" }
} { Invoke-Winget 'Python.Python.3.12' } "winget install Python.Python.3.12"

Check "Node.js 18+" {
    $v = & node --version 2>&1
    if ($v -notmatch 'v(\d+)') { return @{ ok = $false; detail = "not found" } }
    @{ ok = ([int]$Matches[1] -ge 18); detail = "$v" }
} { Invoke-Winget 'OpenJS.NodeJS.LTS' } "winget install OpenJS.NodeJS.LTS"

Check "winget available" {
    $null = & winget --version 2>&1
    @{ ok = ($LASTEXITCODE -eq 0); detail = (& winget --version) }
} $null "Update App Installer from the Microsoft Store"

Check "PowerShell execution policy" {
    $p = Get-ExecutionPolicy -Scope CurrentUser
    @{ ok = ($p -in @('RemoteSigned','Unrestricted','Bypass')); detail = "$p" }
} {
    try {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force -ErrorAction Stop
        Write-Host "set to RemoteSigned" -ForegroundColor Green
        $true
    } catch { Write-Host "could not change it: $($_.Exception.Message)" -ForegroundColor Red; $false }
} "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"

Write-Host ""
if ($script:Failed) {
    Write-Host "Preflight failed - fix the red items above before continuing." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Preflight passed." -ForegroundColor Green
    exit 0
}
