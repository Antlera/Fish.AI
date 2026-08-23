#requires -Version 5.1
<#
  03-start-server.ps1 - Start the inference server. Keep it running in its own terminal.

  Five models are supported via -Model. Every number below was measured on the
  reference machine (RTX 2050 4GB VRAM / 13.7GB RAM), not estimated.

  Model      File      Ctx   VRAM       Resident   Speed       Eval (10 stats + 4 tool)
  ---------  --------  ----  ---------  ---------  ----------  ------------------------
  a3b (def)  9.36 GB   64K   1477 MiB    2.7 GB    14.9 tok/s  9/10 + 4/4   <== best
  qwen4b     2.37 GB   64K   3587 MiB    7.2 GB    12.6 tok/s  7/10 + 4/4
  bonsai27b  3.54 GB   32K   3825 MiB    5.9 GB     5.6 tok/s  8/10 + 4/4
  bonsai8b   1.08 GB   32K   3804 MiB    4.2 GB    52.3 tok/s  6/10 + 4/4   <== fast, inaccurate
  qwen8b     4.78 GB   32K   untested   untested   untested    untested

  --n-cpu-moe tuning for a3b (64K, median of 3 runs after warm-up).
  Filling VRAM buys very little:

    n-cpu-moe   VRAM        Free       Throughput
    ---------   ---------   --------   ----------
    99          2641 MiB    1325 MiB   15.1 tok/s   all experts on CPU
    37 (def)    3267 MiB     699 MiB   15.8 tok/s   +5%, keeps safe headroom
    34          3895 MiB      71 MiB   16.3 tok/s   +8%, one stray app away from OOM

  The bottleneck is not the expert weights: only 8 of 256 experts fire per token,
  and the attention layers were already on the GPU. Going from 2.6GB to 3.9GB of
  VRAM buys 8%.

  !! Always warm up before measuring throughput. The first run reports only
     6.8-8.1 tok/s while expert pages are still being faulted in. Treating that
     as the result leads to the wrong conclusion ("GPU offload made it slower").

  Why the 35B is the *cheapest* model here (counter-intuitive, worth remembering):
    - MoE + mmap: 256 experts, 8 active per token, so only ~2.7GB of the 9.36GB
      file is ever resident. Cold experts stay on disk. Dense models get no such
      discount - every token reads every weight.
    - Tiny KV cache: 2 KV heads, and only 10 of 40 layers use full attention
      (full_attention_interval = 4; the rest are linear/SSM). 64K of context costs
      0.7 GB. Qwen3-4B needs 5.12 GB for the same 64K.
    - --n-cpu-moe keeps experts in system RAM, so VRAM only holds attention layers.
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b',
    [int]$Ctx     = 0,      # 0  = use the model's default
    [int]$Ngl     = -1,     # -1 = use the model's default
    [int]$NCpuMoe = -1,     # -1 = use the model's default (MoE models only)
    [int]$Port    = 8080,
    [string]$KvType = 'q8_0'
)

$ErrorActionPreference = 'Stop'
$Root   = Split-Path $PSScriptRoot -Parent
$Server = Join-Path $Root 'bin\llama-server.exe'
if (-not (Test-Path $Server)) { throw "llama-server.exe not found. Run 01-install-llama.ps1 first." }

# Measured-optimal settings per model. The gotchas in Note are real; don't guess here.
$PROFILES = @{
    a3b = @{
        File    = 'models-35b\Qwen3.6-35B-A3B-UD-IQ1_M.gguf'
        Ctx     = 65536; Ngl = 99; NCpuMoe = 37; Reasoning = 'off'
        Note    = 'MoE. --n-cpu-moe keeps experts on CPU - that is what makes this fit. Thinking MUST be off.'
    }
    qwen4b = @{
        File    = 'models\Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf'
        Ctx     = 65536; Ngl = 15; NCpuMoe = 0; Reasoning = ''
        Note    = 'Dense - no expert layers to split. Higher -ngl will OOM. Native 262144 context.'
    }
    bonsai27b = @{
        File    = 'models-bonsai\Bonsai-27B-Q1_0.gguf'
        Ctx     = 32768; Ngl = 44; NCpuMoe = 0; Reasoning = 'off'
        Note    = '1-bit dense. Without --reasoning off it cannot even answer "1+1" (all output goes to reasoning_content). At 64K it needs 9.9GB and thrashes.'
    }
    bonsai8b = @{
        File    = 'models-bonsai8b\Bonsai-8B-Q1_0.gguf'
        Ctx     = 32768; Ngl = 99; NCpuMoe = 0; Reasoning = ''
        Note    = '1.08GB, all 36 layers fit in VRAM -> 52 tok/s. But 1-bit hurts small models badly: it called a dataset containing 47 outlier-free. Do not use it for audit work.'
    }
    qwen8b = @{
        File    = 'models-8b\Qwen3-8B-UD-Q4_K_XL.gguf'
        Ctx     = 32768; Ngl = 20; NCpuMoe = 0; Reasoning = ''
        Note    = 'Native context is only 32768; reaching 64K needs YaRN. -ngl 20 is a guess, never measured.'
    }
}

$p = $PROFILES[$Model]
$gguf = Join-Path $Root $p.File
if (-not (Test-Path $gguf)) {
    throw "Model file not found: $gguf`nRun: pwsh scripts\02-download-model.ps1 -Model $Model"
}

if ($Ctx -le 0)     { $Ctx = $p.Ctx }
if ($Ngl -lt 0)     { $Ngl = $p.Ngl }
if ($NCpuMoe -lt 0) { $NCpuMoe = $p.NCpuMoe }

$freeVram = try { [int]((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) -split "`n")[0].Trim() } catch { 0 }

Write-Host ""
Write-Host ("model      : {0}  ({1})" -f $Model, (Split-Path $gguf -Leaf)) -ForegroundColor Cyan
Write-Host ("context    : {0}" -f $Ctx)              -ForegroundColor DarkGray
Write-Host ("gpu layers : {0}" -f $Ngl)              -ForegroundColor DarkGray
if ($NCpuMoe -gt 0) {
    Write-Host ("n-cpu-moe  : {0}" -f $NCpuMoe)      -ForegroundColor DarkGray
}
Write-Host ("kv cache   : {0}" -f $KvType)           -ForegroundColor DarkGray
Write-Host ("free vram  : {0} MB" -f $freeVram)      -ForegroundColor DarkGray
Write-Host ("note       : {0}" -f $p.Note)           -ForegroundColor DarkYellow
Write-Host ""

$srvArgs = @(
    '-m', $gguf
    '-ngl', $Ngl
    '-c',  $Ctx
    '-fa', 'on'
    '--cache-type-k', $KvType
    '--cache-type-v', $KvType
    '--temp', '0.7', '--top-p', '0.8', '--top-k', '20'
    '--jinja'
    '--host', '127.0.0.1'
    '--port', $Port
    '--metrics'
)
if ($NCpuMoe -gt 0) { $srvArgs += @('--n-cpu-moe', $NCpuMoe) }
if ($p.Reasoning)   { $srvArgs += @('--reasoning', $p.Reasoning) }

Write-Host "starting..." -ForegroundColor Cyan
Write-Host "health check: http://127.0.0.1:$Port/health`n" -ForegroundColor Cyan

& $Server @srvArgs
