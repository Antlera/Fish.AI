#requires -Version 5.1
<#
  00-preflight.ps1 - Check the machine before installing anything.
  Anything that FAILs will stop the install; fix it first.

  The RAM threshold here is deliberately low. The default model (Qwen3.6-35B-A3B,
  UD-IQ1_M) is a 9.4GB file but only ~2.7GB is ever resident, because it is an MoE:
  256 experts, 8 active per token, and llama.cpp mmaps the file so cold experts
  stay on disk. Judging it by file size alone rules out machines that run it fine.
#>

$ErrorActionPreference = 'Continue'
$script:Failed = $false

function Check {
    param([string]$Name, [scriptblock]$Test, [string]$Hint = '')
    Write-Host ("{0,-34}" -f $Name) -NoNewline
    try {
        $r = & $Test
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
            $script:Failed = $true
        }
    } catch {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        if ($Hint) { Write-Host ("  -> " + $Hint) -ForegroundColor DarkYellow }
        $script:Failed = $true
    }
}

Write-Host "`n=== preflight ===`n" -ForegroundColor Cyan

Check "NVIDIA driver / nvidia-smi" {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return @{ ok = $false; detail = "nvidia-smi not found" } }
    $out = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    @{ ok = $true; detail = $out }
} "Install the official NVIDIA driver (not the one from Windows Update)"

Check "VRAM >= 3.5 GB" {
    $mb = [int]((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits) -split "`n")[0].Trim()
    @{ ok = ($mb -ge 3500); detail = "$mb MB" }
} "Below 3.5GB you must lower -c; the tuned parameters assume ~4GB"

Check "free VRAM >= 3.0 GB" {
    $mb = [int]((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -split "`n")[0].Trim()
    @{ ok = ($mb -ge 3000); detail = "$mb MB free" }
} "Close browsers with hardware acceleration and other GPU consumers"

Check "system RAM >= 12 GB" {
    $gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    if ($gb -ge 12)  { return @{ ok = $true;  detail = "$gb GB" } }
    if ($gb -ge 8)   { return @{ ok = $false; warn = $true; detail = "$gb GB - tight, expect paging" } }
    @{ ok = $false; detail = "$gb GB" }
} "Under 8GB, use -Model bonsai8b (1.1GB) or qwen4b (2.4GB)"

Check "free disk >= 25 GB" {
    $d = Get-PSDrive -Name ($PSScriptRoot.Substring(0,1))
    $gb = [math]::Round($d.Free / 1GB, 1)
    @{ ok = ($gb -ge 25); detail = "$gb GB free on $($d.Name):" }
} "Default model is 9.4GB plus ~1GB of llama.cpp binaries and download cache"

Check "CPU cores" {
    $n = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    @{ ok = ($n -ge 8); detail = "$n logical" }
} "Few cores noticeably slow down the CPU-side MoE expert compute"

Check "Python 3.10+" {
    $v = & python --version 2>&1
    if ($v -notmatch 'Python (\d+)\.(\d+)') { return @{ ok = $false; detail = "$v" } }
    $ok = ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 10)
    @{ ok = $ok; detail = "$v" }
} "winget install Python.Python.3.12"

Check "Node.js 18+" {
    $v = & node --version 2>&1
    if ($v -notmatch 'v(\d+)') { return @{ ok = $false; detail = "$v" } }
    @{ ok = ([int]$Matches[1] -ge 18); detail = "$v" }
} "winget install OpenJS.NodeJS.LTS - then REOPEN the terminal; PATH is not refreshed in the current one"

Check "winget available" {
    $null = & winget --version 2>&1
    @{ ok = ($LASTEXITCODE -eq 0); detail = (& winget --version) }
} "Update App Installer from the Microsoft Store"

Check "PowerShell execution policy" {
    $p = Get-ExecutionPolicy -Scope CurrentUser
    @{ ok = ($p -in @('RemoteSigned','Unrestricted','Bypass')); detail = "$p" }
} "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"

Write-Host ""
if ($script:Failed) {
    Write-Host "Preflight failed - fix the red items above before continuing." -ForegroundColor Red
    exit 1
} else {
    Write-Host "Preflight passed. Next: scripts\01-install-llama.ps1" -ForegroundColor Green
    exit 0
}
