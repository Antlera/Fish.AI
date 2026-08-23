#requires -Version 5.1
<#
  tune-ncpumoe.ps1 - Find the smallest workable --n-cpu-moe for an MoE model.

  --n-cpu-moe N keeps the expert layers of N blocks on the CPU. Smaller N means
  more expert layers on the GPU, which is faster - until VRAM runs out.

  Reality check before you spend 15 minutes here: on the reference machine
  (RTX 2050 4GB, a3b model) the entire range only spans 15.1 -> 16.3 tok/s.

      n-cpu-moe 99  ->  2641 MiB VRAM, 15.1 tok/s
      n-cpu-moe 37  ->  3267 MiB VRAM, 15.8 tok/s   <- shipped default
      n-cpu-moe 34  ->  3895 MiB VRAM, 16.3 tok/s   <- only 71 MiB headroom left

  Only 8 of 256 experts fire per token, so the expert weights are not the
  bottleneck. Filling VRAM buys ~8% and leaves nothing for anything else.

  This script is only meaningful for MoE models (a3b). For dense models use
  tune-ngl.ps1 instead.

  Usage: make sure 03-start-server.ps1 is NOT running, then run this.
#>

param(
    [int]$Ctx  = 65536,
    [int]$Port = 8099,          # different port so it cannot clash with the live server
    [int]$Low  = 20,
    [int]$High = 99,
    [string]$ModelPath = ''
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path $PSScriptRoot -Parent
$Server = Join-Path $Root 'bin\llama-server.exe'

if (-not $ModelPath) { $ModelPath = Join-Path $Root 'models-35b\Qwen3.6-35B-A3B-UD-IQ1_M.gguf' }
if (-not (Test-Path $ModelPath)) { throw "model not found: $ModelPath (pass -ModelPath)" }

function Test-N {
    param([int]$N)
    Write-Host ("  trying --n-cpu-moe {0,-3} ... " -f $N) -NoNewline
    $log = Join-Path $env:TEMP "llama-tune-moe-$N.log"
    $p = Start-Process -FilePath $Server -PassThru -WindowStyle Hidden `
         -RedirectStandardError $log -RedirectStandardOutput "$log.out" `
         -ArgumentList @('-m', $ModelPath, '--n-cpu-moe', $N, '-ngl', 99,
                         '-c', $Ctx, '-fa', 'on',
                         '--cache-type-k','q8_0','--cache-type-v','q8_0',
                         '--jinja','--reasoning','off','--host','127.0.0.1','--port',$Port)

    $ok = $false
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { break }
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2; $ok = $true; break } catch {}
    }
    if ($ok) {
        # Loading is not enough - run a real request so the compute buffers get allocated too.
        try {
            $b = @{ model='local'; messages=@(@{role='user';content='SELECT 1;'}); max_tokens=32 } | ConvertTo-Json -Depth 6
            $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
                        -Body $b -ContentType 'application/json' -TimeoutSec 300
        } catch { $ok = $false }
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 3 }

    if ($ok) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "OOM / failed to start" -ForegroundColor Red }
    return $ok
}

Write-Host "`nBinary-searching --n-cpu-moe (ctx=$Ctx, 1-3 min per probe)`n" -ForegroundColor Cyan

$best = $High
while ($Low -le $High) {
    $mid = [math]::Floor(($Low + $High) / 2)
    if (Test-N -N $mid) { $best = $mid; $High = $mid - 1 } else { $Low = $mid + 1 }
}

Write-Host "`nLowest workable: --n-cpu-moe $best" -ForegroundColor Green
Write-Host "Recommended with headroom: $($best + 3) (browsers and other apps take VRAM too)" -ForegroundColor DarkYellow
Write-Host "Set it as the NCpuMoe default in 03-start-server.ps1, or pass -NCpuMoe $($best + 3)" -ForegroundColor DarkGray
