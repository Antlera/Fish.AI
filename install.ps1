#requires -Version 5.1
<#
  install.ps1 - Bootstrap Fish.AI from nothing, in one line:

      irm https://raw.githubusercontent.com/Antlera/Fish.AI/main/install.ps1 | iex

  Installs git if it is missing, clones (or updates) the repo into ~\Fish.AI,
  then runs setup.ps1, which takes care of everything else. Safe to re-run.

  Options are read from environment variables because `| iex` cannot take parameters:
      $env:FISH_DIR   = 'D:\Fish.AI'     where to put it     (default: ~\Fish.AI)
      $env:FISH_MODEL = 'bonsai8b'       which model         (default: a3b)
#>

$ErrorActionPreference = 'Stop'
$Repo = 'https://github.com/Antlera/Fish.AI.git'
$Dir  = if ($env:FISH_DIR)   { $env:FISH_DIR }   else { Join-Path $env:USERPROFILE 'Fish.AI' }
$Model = if ($env:FISH_MODEL) { $env:FISH_MODEL } else { 'a3b' }

function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}
Sync-Path

Write-Host ""
Write-Host "  Fish.AI installer" -ForegroundColor Cyan
Write-Host "  into : $Dir" -ForegroundColor DarkGray
Write-Host "  model: $Model" -ForegroundColor DarkGray
Write-Host ""

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "git is not installed - installing with winget..." -ForegroundColor Yellow
    & winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
    Sync-Path
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git still not found. Install it from https://git-scm.com/download/win, reopen the terminal, and run this again."
    }
}

if (Test-Path (Join-Path $Dir '.git')) {
    Write-Host "Existing install found - updating..." -ForegroundColor Cyan
    & git -C $Dir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Host "git pull failed; continuing with the existing files" -ForegroundColor DarkYellow }
} elseif (Test-Path $Dir) {
    throw "$Dir exists but is not a Fish.AI checkout. Set `$env:FISH_DIR to a different folder and re-run."
} else {
    Write-Host "Cloning..." -ForegroundColor Cyan
    & git clone --depth 1 $Repo $Dir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
}

# Scripts inside the checkout are unsigned; run them with a per-process policy so
# the user does not need to touch Set-ExecutionPolicy just to install.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'setup.ps1') -Model $Model
if ($LASTEXITCODE -ne 0) { throw "setup.ps1 failed (see above)" }

Write-Host ""
Write-Host "  Installed. Start it with the desktop shortcut, or:" -ForegroundColor Green
Write-Host "    cd `"$Dir`"; .\start.ps1" -ForegroundColor White
Write-Host ""
