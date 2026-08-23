#requires -Version 5.1
<#
  02-download-model.ps1 - Fetch GGUF weights. Resumable; the hf CLI handles that.

  -Model names match 03-start-server.ps1 exactly, so this works:

      pwsh scripts\02-download-model.ps1            # a3b, the default
      pwsh scripts\03-start-server.ps1              # a3b, the default

  Pick a different one with -Model and pass the same name to 03.
#>

param(
    [ValidateSet('a3b','qwen4b','bonsai27b','bonsai8b','qwen8b')]
    [string]$Model = 'a3b'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent

# winget/npm installs do not refresh PATH inside an already-open terminal.
# Pull the machine+user PATH in so a freshly installed tool is visible here.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')


# Keep this table in sync with $PROFILES in 03-start-server.ps1.
$CATALOG = @{
    a3b = @{
        Repo = 'unsloth/Qwen3.6-35B-A3B-GGUF'; Pattern = '*UD-IQ1_M*'
        Dir  = 'models-35b'; Size = '9.4 GB'
        Note = 'MoE, 35B total / 3B active. Best quality-per-resource on a 4GB GPU.'
    }
    qwen4b = @{
        Repo = 'unsloth/Qwen3-4B-Instruct-2507-GGUF'; Pattern = '*UD-Q4_K_XL*'
        Dir  = 'models'; Size = '2.4 GB'
        Note = 'Dense 4B. Small and quick to download; weaker on concepts and SQL.'
    }
    bonsai27b = @{
        Repo = 'prism-ml/Bonsai-27B-gguf'; Pattern = 'Bonsai-27B-Q1_0.gguf'
        Dir  = 'models-bonsai'; Size = '3.5 GB'
        Note = '1-bit 27B. Good concepts, but 3x slower than the 4B.'
    }
    bonsai8b = @{
        Repo = 'prism-ml/Bonsai-8B-gguf'; Pattern = 'Bonsai-8B-Q1_0.gguf'
        Dir  = 'models-bonsai8b'; Size = '1.1 GB'
        Note = '1-bit 8B. Fastest (fits entirely in VRAM) but least accurate.'
    }
    qwen8b = @{
        Repo = 'unsloth/Qwen3-8B-GGUF'; Pattern = '*UD-Q4_K_XL*'
        Dir  = 'models-8b'; Size = '4.8 GB'
        Note = 'Dense 8B. Native context is only 32768. Never benchmarked here.'
    }
}

$m = $CATALOG[$Model]
$Models = Join-Path $Root $m.Dir
New-Item -ItemType Directory -Force -Path $Models | Out-Null

if (-not (Get-Command hf -ErrorAction SilentlyContinue)) {
    Write-Host "Installing the huggingface_hub CLI..." -ForegroundColor Cyan
    & python -m pip install -U "huggingface_hub[cli]"
    if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
}

Write-Host ""
Write-Host ("model : {0}" -f $Model)        -ForegroundColor Cyan
Write-Host ("repo  : {0}" -f $m.Repo)       -ForegroundColor DarkGray
Write-Host ("size  : {0}" -f $m.Size)       -ForegroundColor DarkGray
Write-Host ("into  : {0}" -f $Models)       -ForegroundColor DarkGray
Write-Host ("note  : {0}" -f $m.Note)       -ForegroundColor DarkYellow
Write-Host ""

& hf download $m.Repo --include $m.Pattern --local-dir $Models
if ($LASTEXITCODE -ne 0) { throw "download failed" }

$files = Get-ChildItem $Models -Recurse -Filter '*.gguf'
if (-not $files) { throw "no .gguf files were downloaded" }

$totalGB = [math]::Round(($files | Measure-Object Length -Sum).Sum / 1GB, 2)
Write-Host "`nGot $($files.Count) file(s), $totalGB GB total:" -ForegroundColor Green
$files | ForEach-Object { Write-Host ("  {0,-58} {1,8:N2} GB" -f $_.Name, ($_.Length/1GB)) -ForegroundColor DarkGray }

if ($files.Count -gt 1) {
    Write-Host "`nNote: the weights are sharded. Point llama-server at *00001-of-*.gguf only;" -ForegroundColor Yellow
    Write-Host "it will find the rest by itself." -ForegroundColor Yellow
}

Write-Host "`nNext: pwsh scripts\03-start-server.ps1 -Model $Model" -ForegroundColor Green
