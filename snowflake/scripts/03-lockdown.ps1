#requires -Version 5.1
<#
  03-lockdown.ps1 - Optional. Observe and optionally restrict outbound traffic.

  !! This script can change Windows Firewall rules. Read it before running.
  By default it only observes; you must pass -Apply for it to write any rule.

  The point is to prove data is not flowing to third parties, rather than to
  trust a config file.
#>

param(
    [switch]$Apply,
    [string]$SnowflakeHost = ''   # e.g. myorg-myaccount.snowflakecomputing.com
)

$ErrorActionPreference = 'Stop'

if (-not $SnowflakeHost) {
    $conn = Join-Path $env:USERPROFILE '.snowflake\connections.toml'
    if (Test-Path $conn) {
        $acct = (Select-String -Path $conn -Pattern '^\s*account\s*=\s*"(.+)"').Matches.Groups[1].Value
        if ($acct -and $acct -ne 'REPLACE-ME') { $SnowflakeHost = "$acct.snowflakecomputing.com" }
    }
}
if (-not $SnowflakeHost) { throw "No Snowflake hostname available. Pass -SnowflakeHost." }

Write-Host "`nSnowflake endpoint: $SnowflakeHost" -ForegroundColor Cyan
$ips = (Resolve-DnsName $SnowflakeHost -Type A -ErrorAction SilentlyContinue).IPAddress
Write-Host "currently resolves to: $($ips -join ', ')" -ForegroundColor DarkGray
Write-Host "Note: Snowflake sits behind a CDN, so these IPs rotate. IP allowlists need refreshing." -ForegroundColor Yellow

# --- Observe: who is llama-server talking to? ---
Write-Host "`n--- llama-server outbound connections ---" -ForegroundColor Cyan
$llama = Get-Process llama-server -ErrorAction SilentlyContinue
if ($llama) {
    $conns = Get-NetTCPConnection -OwningProcess $llama.Id -ErrorAction SilentlyContinue |
             Where-Object { $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0','::') }
    if ($conns) {
        Write-Host "Outbound connections found - this should not happen; local inference needs no network:" -ForegroundColor Red
        $conns | Format-Table RemoteAddress, RemotePort, State -AutoSize
    } else {
        Write-Host "No outbound connections. Correct." -ForegroundColor Green
    }
} else {
    Write-Host "llama-server is not running, skipping" -ForegroundColor DarkGray
}

# --- Observe: who are the agent-side processes talking to? ---
Write-Host "`n--- agent-side outbound connections ---" -ForegroundColor Cyan
foreach ($n in @('opencode','node','uvx','python')) {
    Get-Process $n -ErrorAction SilentlyContinue | ForEach-Object {
        $procId = $_.Id
        Get-NetTCPConnection -OwningProcess $procId -ErrorAction SilentlyContinue |
          Where-Object { $_.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0','::') -and $_.State -eq 'Established' } |
          ForEach-Object {
              $host_ = try { (Resolve-DnsName $_.RemoteAddress -ErrorAction SilentlyContinue).NameHost } catch { '' }
              $isSf = $host_ -like '*snowflakecomputing*' -or $host_ -like '*amazonaws*' -or $host_ -like '*azure*'
              $c = if ($isSf) { 'DarkGray' } else { 'Yellow' }
              Write-Host ("  {0,-12} {1,-16} :{2,-6} {3}" -f $n, $_.RemoteAddress, $_.RemotePort, $host_) -ForegroundColor $c
          }
    }
}
Write-Host "`nYellow rows are worth a look: neither Snowflake nor localhost." -ForegroundColor DarkYellow
Write-Host "(npm/uvx update checks produce some; a persistent unknown connection does not.)" -ForegroundColor DarkGray

# --- Optional: actually write a firewall rule ---
if (-not $Apply) {
    Write-Host "`nObserve mode finished. Re-run with -Apply (as Administrator) to restrict egress." -ForegroundColor Cyan
    Write-Host "But think first: llama-server does not use the network anyway, so blocking it" -ForegroundColor DarkGray
    Write-Host "achieves little. The process worth restricting is the agent, and it needs" -ForegroundColor DarkGray
    Write-Host "normal access to the npm ecosystem. In most cases a Snowflake-side NETWORK POLICY" -ForegroundColor DarkGray
    Write-Host "(restricting the service account's source IPs) is more useful than a local firewall." -ForegroundColor DarkGray
    Write-Host "See section 5 of snowflake\01-guardrails.sql." -ForegroundColor DarkGray
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Administrator rights are required to change firewall rules" }

$Root = Split-Path $PSScriptRoot -Parent
$exe  = Join-Path $Root 'bin\llama-server.exe'

Write-Host "`nAbout to block ALL outbound traffic for llama-server.exe (it needs none)." -ForegroundColor Yellow
$ans = Read-Host "Continue? (yes/no)"
if ($ans -ne 'yes') { exit 0 }

New-NetFirewallRule -DisplayName 'Block llama-server outbound' `
                    -Direction Outbound -Program $exe -Action Block -Profile Any | Out-Null
Write-Host "Rule added. Undo with: Remove-NetFirewallRule -DisplayName 'Block llama-server outbound'" -ForegroundColor Green
