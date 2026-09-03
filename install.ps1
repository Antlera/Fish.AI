#requires -Version 5.1
<#
  install.ps1 - Bootstrap Fish.AI from nothing, in one line:

      irm https://raw.githubusercontent.com/Antlera/Fish.AI/main/install.ps1 | iex

  Fetches the code into ~\Fish.AI, then runs setup.ps1, which takes care of everything
  else. Safe to re-run: an existing install is updated in place (your data files in
  app\workspace, the model weights and the binaries are never touched).

  Two ways to fetch the code:
    git   - clone, later updates are `git pull`. Used when git is present (it is
            installed via winget if missing and winget works).
    zip   - download GitHub's archive over plain HTTPS and unpack it. No git needed.
            Used automatically when git is unavailable, or on request.

  Options are read from environment variables because `| iex` cannot take parameters:
      $env:FISH_DIR          = 'D:\Fish.AI'   where to put it        (default: ~\Fish.AI)
      $env:FISH_MODEL        = 'bonsai8b'     which model            (default: a3b)
      $env:FISH_NO_GIT       = '1'            force the zip download even if git exists
      $env:FISH_INSTALL_ONLY = '1'            fetch/update the code, do not run setup.ps1
#>

$ErrorActionPreference = 'Stop'
$Repo    = 'Antlera/Fish.AI'
$Branch  = 'main'
$GitUrl  = "https://github.com/$Repo.git"
$ZipUrl  = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$Dir     = if ($env:FISH_DIR)   { $env:FISH_DIR }   else { Join-Path $env:USERPROFILE 'Fish.AI' }
$Model   = if ($env:FISH_MODEL) { $env:FISH_MODEL } else { 'a3b' }
$NoGit   = $env:FISH_NO_GIT -eq '1'
$OnlyGet = $env:FISH_INSTALL_ONLY -eq '1'

# Older Windows PowerShell 5.1 builds default to TLS 1.0 and cannot talk to GitHub.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
}
Sync-Path

Write-Host ""
Write-Host "  Fish.AI installer" -ForegroundColor Cyan
Write-Host "  into : $Dir" -ForegroundColor DarkGray
Write-Host "  model: $Model" -ForegroundColor DarkGray

# ---------------------------------------------------------------- how to fetch
$haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
$isGitCheckout = Test-Path (Join-Path $Dir '.git')

if ($isGitCheckout -and -not $haveGit -and -not $NoGit) {
    # A clone that can no longer be pulled; the zip overlay updates it just as well.
    Write-Host "  note : this is a git checkout but git is not installed - updating from the zip archive" -ForegroundColor DarkYellow
}

$useGit = -not $NoGit -and ($haveGit -or -not $isGitCheckout)
if ($useGit -and -not $haveGit) {
    Write-Host "  git is not installed - trying winget..." -ForegroundColor Yellow
    $null = & winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
    Sync-Path
    $haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $haveGit) {
        Write-Host "  could not install git - falling back to the zip download (no git needed)" -ForegroundColor DarkYellow
        $useGit = $false
    }
}
Write-Host ("  via  : {0}" -f $(if ($useGit) { 'git' } else { 'zip download' })) -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------- fetch
if ($useGit) {
    if ($isGitCheckout) {
        Write-Host "Existing install found - updating (git pull)..." -ForegroundColor Cyan
        & git -C $Dir pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Host "git pull failed; continuing with the existing files" -ForegroundColor DarkYellow }
    } elseif (Test-Path (Join-Path $Dir 'setup.ps1')) {
        Write-Host "Existing zip install found - updating from the zip archive..." -ForegroundColor Cyan
        $useGit = $false
    } elseif ((Test-Path $Dir) -and (Get-ChildItem $Dir -Force | Select-Object -First 1)) {
        throw "$Dir exists but is not a Fish.AI install. Set `$env:FISH_DIR to a different folder and re-run."
    } else {
        Write-Host "Cloning..." -ForegroundColor Cyan
        & git clone --depth 1 --branch $Branch $GitUrl $Dir
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

if (-not $useGit) {
    if ((Test-Path $Dir) -and -not (Test-Path (Join-Path $Dir 'setup.ps1')) -and (Get-ChildItem $Dir -Force | Select-Object -First 1)) {
        throw "$Dir exists but is not a Fish.AI install. Set `$env:FISH_DIR to a different folder and re-run."
    }
    $tmp = Join-Path $env:TEMP ("fishai-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $zip = "$tmp.zip"
    Write-Host "Downloading $ZipUrl ..." -ForegroundColor Cyan
    # Invoke-WebRequest shows a progress bar that makes downloads several times slower on 5.1.
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    Write-Host ("  {0:N1} MB" -f ((Get-Item $zip).Length / 1MB)) -ForegroundColor DarkGray
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    # The archive has one top-level folder, "Fish.AI-main"
    $src = Get-ChildItem $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'setup.ps1'))) { throw "unexpected archive layout under $tmp" }

    $updating = Test-Path (Join-Path $Dir 'setup.ps1')
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    # Overlay: tracked files are overwritten with the new version; anything the archive
    # does not contain (your data files, models, binaries, logs) is left exactly as it is.
    Copy-Item -Path (Join-Path $src.FullName '*') -Destination $Dir -Recurse -Force
    Remove-Item $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ($(if ($updating) { "Updated $Dir from the archive." } else { "Unpacked into $Dir." })) -ForegroundColor Green
}

if ($OnlyGet) {
    Write-Host ""
    Write-Host "  Code is in $Dir (FISH_INSTALL_ONLY set - setup.ps1 not run)." -ForegroundColor Green
    Write-Host ""
    return
}

# ---------------------------------------------------------------- setup
# Scripts inside the checkout are unsigned; run them with a per-process policy so
# the user does not need to touch Set-ExecutionPolicy just to install.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'setup.ps1') -Model $Model
if ($LASTEXITCODE -ne 0) { throw "setup.ps1 failed (see above)" }

Write-Host ""
Write-Host "  Installed. Start it with the desktop shortcut, or:" -ForegroundColor Green
Write-Host "    cd `"$Dir`"; .\start.ps1" -ForegroundColor White
Write-Host ""
