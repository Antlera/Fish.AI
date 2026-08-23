#requires -Version 5.1
<#
  06-install-pydeps.ps1 - Install the Python data stack the agent actually reaches for.

  Without this the agent's first instinct on any data file - `import pandas` - fails,
  and it burns a turn (about a minute on this hardware) discovering that.

  Core packages must install. Optional ones are best-effort: they cover other
  ecosystems' file formats and are not worth failing the whole setup over.

  Note that reading SAS / SPSS / Stata / R *data* needs none of those products
  installed - only a reader library. Running their *code* is out of scope.
#>

param(
    [switch]$SkipOptional
)

$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')

$core = @(
    'numpy'         # arrays, ddof-aware std
    'pandas'        # the default answer for tabular data
    'scipy'         # hypothesis tests, distributions
    'statsmodels'   # regression, time series
    'openpyxl'      # .xlsx
    'matplotlib'    # charts
    'tabulate'      # DataFrame.to_markdown(), renders well in the chat UI
)

$optional = @(
    'pyreadstat'    # SAS .sas7bdat, SPSS .sav, Stata .dta
    'pyreadr'       # R .rds / .RData
    'xlrd'          # legacy .xls
    'pyarrow'       # parquet / feather
)

function Show-Missing {
    param([string[]]$Names)
    $probe = @'
import importlib, sys
missing = [m for m in sys.argv[1:] if importlib.util.find_spec(m) is None]
print(",".join(missing))
'@
    $tmp = Join-Path $env:TEMP 'fish-probe.py'
    $probe | Set-Content $tmp -Encoding UTF8
    $out = (& python $tmp @Names) -join ''
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if ($out) { return $out -split ',' } else { return @() }
}

Write-Host "Checking the Python data stack..." -ForegroundColor Cyan
& python --version
if ($LASTEXITCODE -ne 0) { throw "python not found. Run 00-preflight.ps1 -AutoInstall first." }

$needCore = Show-Missing $core
if ($needCore.Count -eq 0) {
    Write-Host "  core packages already present" -ForegroundColor DarkGray
} else {
    Write-Host "  installing: $($needCore -join ', ')" -ForegroundColor Cyan
    & python -m pip install -q --upgrade $needCore
    if ($LASTEXITCODE -ne 0) { throw "pip failed installing the core data stack" }
}

if (-not $SkipOptional) {
    $needOpt = Show-Missing $optional
    if ($needOpt.Count -eq 0) {
        Write-Host "  optional packages already present" -ForegroundColor DarkGray
    } else {
        Write-Host "  installing (best effort): $($needOpt -join ', ')" -ForegroundColor Cyan
        foreach ($p in $needOpt) {
            & python -m pip install -q --upgrade $p 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    $p failed - skipping (only affects that file format)" -ForegroundColor DarkYellow
            }
        }
    }
}

Write-Host "`nFinal state:" -ForegroundColor Cyan
$all = $core + $optional
$still = Show-Missing $all
foreach ($m in $all) {
    if ($still -contains $m) { Write-Host ("  {0,-14} MISSING" -f $m) -ForegroundColor DarkYellow }
    else                     { Write-Host ("  {0,-14} ok"      -f $m) -ForegroundColor DarkGray }
}

$missingCore = $core | Where-Object { $still -contains $_ }
if ($missingCore) { throw "core packages still missing: $($missingCore -join ', ')" }
Write-Host "`nData stack ready." -ForegroundColor Green
