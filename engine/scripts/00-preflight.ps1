#requires -Version 5.1
<#
  00-preflight.ps1 - Check the machine, and with -AutoInstall fix what can be fixed.

  Auto-installable: Python and Node.js. First via winget; if that is blocked (managed
  corporate machines return an error code and install nothing) they are unpacked as
  portable builds inside engine\ by 07-install-portable.ps1 - no admin, no installer.
  Not auto-installable: the NVIDIA driver (needs a reboot and the right variant for your
  card) and anything about how much RAM/VRAM/disk you have.

  The RAM threshold is deliberately low. The default model (Qwen3.6-35B-A3B, UD-IQ1_M) is
  a 9.4GB file but only ~2.7GB is ever resident: it is an MoE with 256 experts, 8 active
  per token, and llama.cpp mmaps the file so cold experts stay on disk. Judging it by file
  size alone rules out machines that run it fine.
#>

param(
    # Install missing prerequisites instead of just reporting them.
    [switch]$AutoInstall,
    # Skip winget and go straight to the portable builds (managed machines).
    [switch]$Portable
)

$ErrorActionPreference = 'Continue'
$script:Failed = $false
. (Join-Path $PSScriptRoot '_env.ps1')
$Portable7 = Join-Path $PSScriptRoot '07-install-portable.ps1'

function Sync-Env { . (Join-Path $PSScriptRoot '_env.ps1') }

function Invoke-Winget {
    param([string]$Id)
    Write-Host "installing $Id via winget ..." -ForegroundColor Cyan -NoNewline
    $out = & winget install --id $Id -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    Sync-Env

    # Deliberately do NOT interpret winget's exit code or output text. Both are
    # localised and it returns non-zero for harmless cases such as "already installed,
    # no upgrade available" - on a non-English Windows that was being read as failure.
    # The source of truth is whether the tool works now, which the caller re-checks.
    if ($code -eq 0) {
        Write-Host " done" -ForegroundColor Green
    } else {
        Write-Host (" winget exit {0} (0x{1:X8}) - re-checking anyway" -f $code, ($code -band 0xFFFFFFFF)) -ForegroundColor DarkYellow
        $out | Where-Object { "$_".Trim() } | Select-Object -Last 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    return $true
}

# Fix for Python / Node: winget, then the portable build if winget did not deliver.
function Install-Runtime {
    param([string]$WingetId, [string]$PortableSwitch, [scriptblock]$Works)
    if (-not $Portable -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $null = Invoke-Winget $WingetId
        if (& $Works) { return $true }
        Write-Host "  winget did not deliver a working install (blocked by policy?) - using the portable build" -ForegroundColor DarkYellow
    }
    Write-Host "  portable install ..." -ForegroundColor Cyan
    $splat = @{ $PortableSwitch = $true }
    & $Portable7 @splat
    Sync-Env
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
if ($AutoInstall) { Write-Host "(auto-install enabled$(if ($Portable) { ', portable builds' }))`n" -ForegroundColor DarkGray } else { Write-Host "" }

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
    # A warning, not a failure: this is about what is running *right now* (a browser,
    # or Fish.AI itself during a re-run of setup), not about the machine.
    @{ ok = ($mb -ge 3000); warn = ($mb -lt 3000); detail = "$mb MB free" }
} $null "Close browsers with hardware acceleration and other GPU consumers before starting. If Fish.AI is already running, that is expected."

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
    # Fewer cores means slower, not broken - do not block the install over it.
    @{ ok = ($n -ge 8); warn = ($n -lt 8); detail = "$n logical" }
} $null "Few cores noticeably slow the CPU-side MoE expert compute; expect lower tok/s"

$pythonWorks = {
    $v = & python --version 2>&1
    ($v -match 'Python 3\.(\d+)') -and ([int]$Matches[1] -ge 10)
}
Check "Python 3.10+" {
    $v = & python --version 2>&1
    if ($v -notmatch 'Python (\d+)\.(\d+)') { return @{ ok = $false; detail = "not found" } }
    $ok = ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10)
    $where = (Get-Command python -ErrorAction SilentlyContinue).Source
    @{ ok = $ok; detail = "$v  ($where)" }
} { Install-Runtime 'Python.Python.3.12' 'Python' $pythonWorks } "winget install Python.Python.3.12, or pwsh engine\scripts\07-install-portable.ps1 -Python (no admin needed)"

$nodeWorks = {
    $v = & node --version 2>&1
    ($v -match '^v(\d+)') -and ([int]$Matches[1] -ge 18)
}
Check "Node.js 18+" {
    $v = & node --version 2>&1
    if ($v -notmatch 'v(\d+)') { return @{ ok = $false; detail = "not found" } }
    $where = (Get-Command node -ErrorAction SilentlyContinue).Source
    @{ ok = ([int]$Matches[1] -ge 18); detail = "$v  ($where)" }
} { Install-Runtime 'OpenJS.NodeJS.LTS' 'Node' $nodeWorks } "winget install OpenJS.NodeJS.LTS, or pwsh engine\scripts\07-install-portable.ps1 -Node (no admin needed)"

Check "winget available" {
    $null = & winget --version 2>&1
    # Only a convenience: without it the portable builds are used instead.
    @{ ok = ($LASTEXITCODE -eq 0); warn = ($LASTEXITCODE -ne 0); detail = $(if ($LASTEXITCODE -eq 0) { (& winget --version) } else { 'not available - portable builds will be used' }) }
} $null "Optional. Update App Installer from the Microsoft Store if you want winget."

Check "PowerShell execution policy" {
    # This script is itself a .ps1 that is running, so scripts are not blocked outright.
    # The launchers (Fish.AI.cmd, install.ps1) pass -ExecutionPolicy Bypass per process,
    # which is all that is needed. Only warn when a Group Policy pins the policy, so the
    # user knows why `.\start.ps1` typed by hand might be refused while the .cmd works.
    $eff = Get-ExecutionPolicy
    $pol = Get-ExecutionPolicy -List
    $managed = ($pol | Where-Object { $_.Scope -in 'MachinePolicy','UserPolicy' -and $_.ExecutionPolicy -ne 'Undefined' })
    if ($eff -in 'RemoteSigned','Unrestricted','Bypass') { return @{ ok = $true; detail = "$eff" } }
    if ($managed) { return @{ ok = $false; warn = $true; detail = "$eff (set by Group Policy, cannot be changed here)" } }
    @{ ok = $false; warn = $true; detail = "$eff" }
} $null "Use Fish.AI.cmd / Setup.cmd (they bypass it per process), or: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"

Write-Host ""
if ($script:Failed) {
    Write-Host "Preflight failed - fix the red items above before continuing." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Preflight passed." -ForegroundColor Green
    exit 0
}
