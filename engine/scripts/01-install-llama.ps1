#requires -Version 5.1
<#
  01-install-llama.ps1 - Grab the official prebuilt CUDA llama.cpp binaries.

  Do not build from source on Windows: it needs the CUDA Toolkit plus MSVC,
  takes an hour minimum, and buys you nothing here.
#>

param(
    # 12.4 is the safe choice on older drivers. Pass '13.3' to try a newer build.
    [string]$CudaVersion = '12.4'
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Bin  = Join-Path $Root 'bin'
$Tmp  = Join-Path $Root '.tmp'

New-Item -ItemType Directory -Force -Path $Bin, $Tmp | Out-Null

# Do NOT use /releases/latest. This repo's "latest" points at a tag (v0.2.0) that
# ships no binaries at all, so the request succeeds and the install then fails with
# a confusing "no Windows CUDA package" error. The real builds live on bNNNNN tags.
Write-Host "Querying llama.cpp builds..." -ForegroundColor Cyan
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15' `
                              -Headers @{ 'User-Agent' = 'audit-agent-setup' }

$rel = $releases | Where-Object {
    $_.assets.name -match ("win-cuda-{0}-x64\.zip$" -f [regex]::Escape($CudaVersion))
} | Select-Object -First 1

if (-not $rel) {
    Write-Host "No win-cuda-$CudaVersion-x64 asset in the last 15 releases. Newest release has:" -ForegroundColor Red
    $releases[0].assets | ForEach-Object { Write-Host "  $($_.name)" }
    throw "Retry with a different -CudaVersion, or pick one manually at https://github.com/ggml-org/llama.cpp/releases"
}
Write-Host "  $($rel.tag_name)  (CUDA $CudaVersion)" -ForegroundColor DarkGray

$main   = $rel.assets | Where-Object { $_.name -like "llama-*-bin-win-cuda-$CudaVersion-x64.zip" } | Select-Object -First 1
$cudart = $rel.assets | Where-Object { $_.name -like "cudart-*-win-cuda-$CudaVersion-x64.zip" } | Select-Object -First 1
if (-not $cudart) {
    # The cudart bundle is occasionally attached to a different release; fall back.
    $cudart = ($releases | ForEach-Object { $_.assets } |
               Where-Object { $_.name -like "cudart-*-win-cuda-$CudaVersion-x64.zip" } | Select-Object -First 1)
}
if (-not $main) { throw "main binary package not found" }

foreach ($a in @($main, $cudart)) {
    if (-not $a) { continue }
    $zip = Join-Path $Tmp $a.name
    if (-not (Test-Path $zip)) {
        Write-Host "Downloading $($a.name)  ($([math]::Round($a.size/1MB,1)) MB)" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $a.browser_download_url -OutFile $zip
    }
    Write-Host "Extracting -> bin\" -ForegroundColor DarkGray
    Expand-Archive -Path $zip -DestinationPath $Bin -Force
}

# Some packages nest an extra directory; flatten the exe into bin\.
Get-ChildItem $Bin -Recurse -Filter 'llama-server.exe' | ForEach-Object {
    if ($_.DirectoryName -ne $Bin) {
        Copy-Item (Join-Path $_.DirectoryName '*') $Bin -Force -Recurse
    }
}

$server = Join-Path $Bin 'llama-server.exe'
if (-not (Test-Path $server)) { throw "llama-server.exe missing after extraction; check $Bin" }

Write-Host "`nVerifying..." -ForegroundColor Cyan
& $server --version
if ($LASTEXITCODE -ne 0) {
    throw "llama-server will not run. Almost always a missing CUDA runtime DLL - make sure the cudart zip was extracted too."
}

Write-Host "`nOK. Next: scripts\02-download-model.ps1" -ForegroundColor Green
