#requires -Version 5.1
<#
  05-verify.ps1 - Accept the inference server.

  It really only tests one thing, but that thing decides whether the agent works
  at all: when the model is handed a tools definition, does it return tool_calls
  or prose? Prose means the agent is completely unusable - and nothing errors out.
#>

param([int]$Port = 8080)

$ErrorActionPreference = 'Stop'
$base = "http://127.0.0.1:$Port"
$fail = $false

Write-Host "`n=== verifying inference server ===`n" -ForegroundColor Cyan

# --- 1. alive? ---
Write-Host ("{0,-30}" -f "health") -NoNewline
try {
    $h = Invoke-RestMethod "$base/health" -TimeoutSec 10
    Write-Host "PASS" -ForegroundColor Green -NoNewline; Write-Host "  $($h.status)" -ForegroundColor DarkGray
} catch {
    Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  server not up? run 03-start-server.ps1 first" -ForegroundColor Yellow
    exit 1
}

# --- 2. is the context really what we asked for? ---
Write-Host ("{0,-30}" -f "context >= 32768") -NoNewline
try {
    $props = Invoke-RestMethod "$base/props" -TimeoutSec 10
    $n = $props.default_generation_settings.n_ctx
    if (-not $n) { $n = $props.n_ctx }
    if ($n -ge 32768) {
        Write-Host "PASS" -ForegroundColor Green -NoNewline; Write-Host "  n_ctx=$n" -ForegroundColor DarkGray
    } else {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host "  n_ctx=$n - too small; OpenCode's tool calling will fail silently" -ForegroundColor Yellow
        $fail = $true
    }
} catch {
    Write-Host "WARN" -ForegroundColor Yellow -NoNewline; Write-Host "  /props unreadable; check n_ctx in the llama-server log" -ForegroundColor DarkGray
}

# --- 3. the one that matters: tool calling ---
Write-Host ("{0,-30}" -f "tool calling") -NoNewline
$body = @{
    model = 'local'
    messages = @(
        @{ role = 'user'; content = 'What tables exist in the PROD database? Use the tool.' }
    )
    tools = @(
        @{
            type = 'function'
            function = @{
                name = 'list_tables'
                description = 'List tables in a Snowflake database'
                parameters = @{
                    type = 'object'
                    properties = @{ database = @{ type = 'string'; description = 'database name' } }
                    required = @('database')
                }
            }
        }
    )
    tool_choice = 'auto'
    max_tokens = 256
} | ConvertTo-Json -Depth 12

try {
    $r = Invoke-RestMethod "$base/v1/chat/completions" -Method Post -Body $body `
             -ContentType 'application/json' -TimeoutSec 300
    $msg = $r.choices[0].message
    if ($msg.tool_calls -and $msg.tool_calls.Count -gt 0) {
        Write-Host "PASS" -ForegroundColor Green -NoNewline
        Write-Host "  called $($msg.tool_calls[0].function.name)" -ForegroundColor DarkGray
    } else {
        Write-Host "FAIL" -ForegroundColor Red
        Write-Host "  Model returned prose instead of tool_calls. The agent will not work." -ForegroundColor Yellow
        Write-Host "  content: $($msg.content)" -ForegroundColor DarkGray
        if ($msg.reasoning_content) {
            Write-Host "  reasoning_content is populated but content is empty -> thinking mode is on." -ForegroundColor DarkYellow
            Write-Host "  Restart with --reasoning off (03-start-server.ps1 does this for models that need it)." -ForegroundColor DarkYellow
        } else {
            Write-Host "  Check: (a) is --jinja set  (b) does this GGUF's chat template support tools" -ForegroundColor DarkYellow
        }
        $fail = $true
    }
} catch {
    Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    $fail = $true
}

# --- 4. rough throughput ---
# Warm-up matters: on an MoE the first run only reports 6-8 tok/s while expert
# pages are faulted in. Do one throwaway request before timing.
Write-Host ("{0,-30}" -f "throughput") -NoNewline
$warm = @{ model='local'; messages=@(@{role='user';content='Say OK.'}); max_tokens=16 } | ConvertTo-Json -Depth 8
$b2   = @{ model='local'; messages=@(@{role='user';content='Write a SQL query that counts rows in a table, and explain it briefly.'}); max_tokens=200 } | ConvertTo-Json -Depth 8
try {
    $null = Invoke-RestMethod "$base/v1/chat/completions" -Method Post -Body $warm -ContentType 'application/json' -TimeoutSec 600
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r2 = Invoke-RestMethod "$base/v1/chat/completions" -Method Post -Body $b2 -ContentType 'application/json' -TimeoutSec 600
    $sw.Stop()
    $tok = $r2.usage.completion_tokens
    $tps = [math]::Round($tok / $sw.Elapsed.TotalSeconds, 1)
    $color = if ($tps -ge 10) { 'Green' } else { 'Yellow' }
    Write-Host "$tps tok/s" -ForegroundColor $color -NoNewline
    Write-Host "  ($tok tokens / $([math]::Round($sw.Elapsed.TotalSeconds,1))s, after warm-up)" -ForegroundColor DarkGray
    if ($tps -lt 8) {
        Write-Host "  Slow. Check whether you are paging: Task Manager -> Performance -> Memory -> Committed." -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "SKIP" -ForegroundColor DarkGray
}

Write-Host ""
if ($fail) { Write-Host "Verification failed." -ForegroundColor Red; exit 1 }
Write-Host "Inference server OK. Next: run snowflake\01-guardrails.sql in Snowflake" -ForegroundColor Green
