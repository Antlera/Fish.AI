#requires -Version 5.1
<#
  07-install-portable.ps1 - Python and/or Node.js without an installer.

  For machines where `winget install` is blocked by policy (managed corporate laptops,
  no admin rights): download the official portable builds and unpack them inside the
  Fish.AI directory. Nothing is registered with Windows, no PATH is changed on the
  system, no admin prompt - every Fish.AI script prepends these directories itself
  (see _env.ps1). Delete engine\python and engine\node to undo.

    Python  -> engine\python   python-build-standalone "install_only" build (astral-sh),
                               a complete CPython with pip, ~35 MB
    Node.js -> engine\node     nodejs.org win-x64 zip of the current LTS, ~30 MB

  00-preflight.ps1 -AutoInstall falls back to this automatically when winget fails.
  Run it by hand with -Python and/or -Node to force the portable versions.
#>

param(
    [switch]$Python,
    [switch]$Node,
    [string]$PythonSeries = '3.12',
    [string]$NodeMajor = '22'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_env.ps1')
$Engine = Join-Path $script:FishRoot 'engine'
$Tmp    = Join-Path $Engine '.tmp'
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest several times slower

if (-not $Python -and -not $Node) { $Python = $true; $Node = $true }

function Get-File([string]$Url, [string]$Out) {
    if (Test-Path $Out) { Write-Host "  already downloaded: $(Split-Path $Out -Leaf)" -ForegroundColor DarkGray; return }
    Write-Host "  downloading $Url" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -Headers @{ 'User-Agent' = 'fish-ai-setup' }
    Write-Host ("  {0:N1} MB" -f ((Get-Item $Out).Length / 1MB)) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ Python
if ($Python) {
    $dest = Join-Path $Engine 'python'
    Write-Host "Portable Python $PythonSeries -> $dest" -ForegroundColor Cyan
    if (Test-Path (Join-Path $dest 'python.exe')) {
        Write-Host "  already there: $(& (Join-Path $dest 'python.exe') --version)" -ForegroundColor DarkGray
    } else {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'fish-ai-setup' }
        $pattern = "^cpython-$([regex]::Escape($PythonSeries))\.\d+\+\d+-x86_64-pc-windows-msvc-install_only\.tar\.gz$"
        $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) { throw "no cpython-$PythonSeries windows install_only build in release $($rel.tag_name)" }
        $tgz = Join-Path $Tmp $asset.name
        Get-File $asset.browser_download_url $tgz
        # Windows 10+ ships bsdtar as tar.exe; the archive has one top-level folder "python"
        $stage = Join-Path $Tmp 'python-stage'
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        & tar -xzf $tgz -C $stage
        if ($LASTEXITCODE -ne 0) { throw "tar failed extracting $tgz" }
        $inner = Get-ChildItem $stage -Directory | Select-Object -First 1
        if (-not $inner -or -not (Test-Path (Join-Path $inner.FullName 'python.exe'))) { throw "unexpected archive layout in $stage" }
        Move-Item $inner.FullName $dest
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:Path = "$(Join-Path $dest 'Scripts');$dest;$env:Path"
    & python --version
    & python -m pip --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "portable python has no working pip" }
    Write-Host "  ok" -ForegroundColor Green
}

# ------------------------------------------------------------------ Node.js
if ($Node) {
    $dest = Join-Path $Engine 'node'
    Write-Host "Portable Node.js $NodeMajor.x -> $dest" -ForegroundColor Cyan
    if (Test-Path (Join-Path $dest 'node.exe')) {
        Write-Host "  already there: $(& (Join-Path $dest 'node.exe') --version)" -ForegroundColor DarkGray
    } else {
        $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -Headers @{ 'User-Agent' = 'fish-ai-setup' }
        $ver = $index | Where-Object { $_.version -like "v$NodeMajor.*" -and $_.files -contains 'win-x64-zip' } |
               Select-Object -First 1 -ExpandProperty version
        if (-not $ver) { throw "no Node $NodeMajor.x win-x64 zip listed at nodejs.org" }
        $zip = Join-Path $Tmp "node-$ver-win-x64.zip"
        Get-File "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip" $zip
        $stage = Join-Path $Tmp 'node-stage'
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $stage -Force
        $inner = Get-ChildItem $stage -Directory | Select-Object -First 1
        if (-not $inner -or -not (Test-Path (Join-Path $inner.FullName 'node.exe'))) { throw "unexpected archive layout in $stage" }
        Move-Item $inner.FullName $dest
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:Path = "$dest;$env:Path"
    & node --version
    # With the zip distribution, `npm -g` installs into engine\node\node_modules - self-contained.
    & npm --version | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "portable node has no working npm" }
    Write-Host "  ok" -ForegroundColor Green
}

Write-Host ""
Write-Host "Portable runtimes ready. Every Fish.AI script picks them up automatically." -ForegroundColor Green
