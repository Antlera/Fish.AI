# _env.ps1 - dot-source this at the top of every Fish.AI script.
#
#   . (Join-Path $PSScriptRoot '_env.ps1')          # from engine\scripts\*.ps1
#   . (Join-Path $Root 'engine\scripts\_env.ps1')   # from the repo root scripts
#
# It does two things:
#   1. Pulls the machine + user PATH into this process, so a tool that winget just
#      installed is visible without reopening the terminal.
#   2. Puts Fish.AI's own portable Python and Node.js (engine\python, engine\node) in
#      front of everything else, if they exist. Those are what 07-install-portable.ps1
#      unpacks on machines where winget installs are blocked by policy; they must win
#      over whatever else is on the machine so every script and the agent itself use
#      the same interpreter.

$script:FishRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

$portable = @(
    (Join-Path $script:FishRoot 'engine\python\Scripts'),
    (Join-Path $script:FishRoot 'engine\python'),
    (Join-Path $script:FishRoot 'engine\node')
)
foreach ($p in $portable) {
    if (Test-Path $p) { $env:Path = "$p;$env:Path" }
}

# Python defaults to the ANSI codepage on non-English Windows; everything here is UTF-8.
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

# The real opencode.exe. `opencode` on PATH is an npm shim (.ps1/.cmd) that Start-Process
# cannot launch ("%1 is not a valid Win32 application"), so find the binary behind it:
# next to the shim, or under whatever `npm root -g` currently points at (the portable
# Node's own node_modules when engine\node is in use).
function Find-OpenCodeExe {
    $cands = @()
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $cands += Join-Path (Split-Path $cmd.Source -Parent) 'node_modules\opencode-ai\bin\opencode.exe' }
    try { $root = (& npm root -g 2>$null | Select-Object -Last 1); if ($root) { $cands += Join-Path $root 'opencode-ai\bin\opencode.exe' } } catch {}
    $cands += Join-Path $script:FishRoot 'engine\node\node_modules\opencode-ai\bin\opencode.exe'
    $cands += Join-Path $env:APPDATA 'npm\node_modules\opencode-ai\bin\opencode.exe'
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
