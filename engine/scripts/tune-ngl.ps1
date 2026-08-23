#requires -Version 5.1
<#
  tune-ngl.ps1 - Find the largest -ngl that still fits in VRAM, for DENSE models.

  Dense models have no expert layers to split, so tune-ncpumoe.ps1 does not apply
  (that one is for the MoE model, a3b). Here we tune how many layers go on the GPU:
  each offloaded layer puts both its weights and its slice of the KV cache in VRAM.

  The big win on a 4GB card is getting the model ENTIRELY into VRAM - that removes
  all CPU<->GPU traffic and roughly doubles throughput. Measured:

      Qwen3-4B @64K, -ngl 15 (partial)  -> 12.6 tok/s
      Qwen3-4B @32K, -ngl 24 (partial)  -> 17.5 tok/s
      Qwen3-4B @16K, -ngl 99 (full GPU) -> 26.4 tok/s
      Bonsai-8B @32K, -ngl 99 (full GPU)-> 52.3 tok/s   (1-bit weights are only 1.08GB)

  So it is often worth trading context length for full residency.

  Usage: make sure 03-start-server.ps1 is NOT running, then run this.
#>

param(
    [int]$Ctx  = 32768,
    [int]$Port = 8099,
    [int]$Low  = 4,
    [int]$High = 36,
    [string]$ModelPath = ''
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path $PSScriptRoot -Parent
$Server = Join-Path $Root 'bin\llama-server.exe'

if (-not $ModelPath) { $ModelPath = Join-Path $Root 'models\Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf' }
if (-not (Test-Path $ModelPath)) { throw "model not found: $ModelPath (pass -ModelPath)" }

function Test-Ngl {
    param([int]$N)
    Write-Host ("  trying -ngl {0,-3} ... " -f $N) -NoNewline
    $log = Join-Path $env:TEMP "llama-tune-ngl-$N.log"
    $p = Start-Process -FilePath $Server -PassThru -WindowStyle Hidden `
         -RedirectStandardError $log -RedirectStandardOutput "$log.out" `
         -ArgumentList @('-m', $ModelPath, '-ngl', $N,
                         '-c', $Ctx, '-fa', 'on',
                         '--cache-type-k','q8_0','--cache-type-v','q8_0',
                         '--jinja','--host','127.0.0.1','--port',$Port)

    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        if ($p.HasExited) { break }
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 2; $ok = $true; break } catch {}
    }
    if ($ok) {
        # Loading is not enough - run a real request so compute buffers are allocated too.
        try {
            $b = @{ model='local'; messages=@(@{role='user';content='SELECT 1;'}); max_tokens=32 } | ConvertTo-Json -Depth 6
            $null = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
                        -Body $b -ContentType 'application/json' -TimeoutSec 120
        } catch { $ok = $false }
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 3 }

    if ($ok) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "OOM / failed to start" -ForegroundColor Red }
    return $ok
}

Write-Host "`nBinary-searching -ngl (ctx=$Ctx, ~1 min per probe)`n" -ForegroundColor Cyan

$best = 0
while ($Low -le $High) {
    $mid = [math]::Floor(($Low + $High) / 2)
    if (Test-Ngl -N $mid) { $best = $mid; $Low = $mid + 1 } else { $High = $mid - 1 }
}

if ($best -eq 0) {
    Write-Host "`nNot even one layer fits? Check what else is using VRAM (nvidia-smi)." -ForegroundColor Red
    exit 1
}
Write-Host "`nLargest workable: -ngl $best" -ForegroundColor Green
$safe = [math]::Max(1, $best - 2)
Write-Host "Recommended with headroom: -ngl $safe (browsers take a few hundred MB)" -ForegroundColor DarkYellow
Write-Host "Set it as the Ngl default in 03-start-server.ps1, or pass -Ngl $safe" -ForegroundColor DarkGray
