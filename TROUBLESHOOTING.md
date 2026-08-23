# Troubleshooting

Look up the symptom first. If something fails three times, stop and report the exact
error rather than trying variations.

---

## The agent writes prose instead of calling tools

**The most common failure, and the hardest to notice.** Nothing errors; it just stops
doing work.

The cause is context overflow: the system prompt carrying the tool definitions got pushed
out of the window. Check, in order:

1. `curl http://127.0.0.1:8080/props` and confirm `n_ctx` is what you expect
2. Search the llama-server startup log for `n_ctx` - the command line asks for one value,
   but the model's `n_ctx_train` can cap it lower
3. Confirm `--jinja` is set. Without it, tool definitions are never injected into the
   chat template
4. Run `pwsh engine\scripts\05-verify.ps1`, which tests exactly this

Do not just "try again" - this failure is deterministic.

## Answers come back empty

The model is in thinking mode: everything goes to `reasoning_content` and `content` stays
empty. On a slow local model it can burn the entire token budget before producing an
answer - one test model needed >150 tokens of thinking to answer "what is 1+1".

`engine\scripts\03-start-server.ps1` passes `--reasoning off` for the models that need it.
If you are launching llama-server by hand, add it.

## A command "succeeds" but produces no output

On Windows, `python -c` with **embedded newlines** silently produces nothing and exits 0:

```
python -c "print(1+1)"                     ->  2         works
python -c "import x; print(...)"           ->  works     (one line, semicolons)
python -c "<newline> code <newline>"       ->  NO OUTPUT, exit code 0
```

The agent then assumes it ran and retries the same thing. `app/workspace/AGENTS.md`
tells it to use one-liners or write a `.py` file; if you hit this, that rule was
probably edited out.

## An unrelated-looking error appears before a script's own output

Something like:

```
Invoke-Expression: Missing '{' in configuration statement.
Checking the Python data stack...
```

That first line is from **your PowerShell profile**, not from Fish.AI. `pwsh script.ps1`
loads your profile before the script runs, so anything broken in there prints first and
looks like the script failed. A conda hook is the usual culprit:

```powershell
(& "conda.exe" "shell.powershell" "hook") | Out-String | ?{$_} | Invoke-Expression
```

The script itself is usually running fine - notice its own output follows. To confirm,
run it without your profile:

```powershell
pwsh -NoProfile engine\scripts\06-install-pydeps.ps1
```

Check which profile is responsible with `$PROFILE | Format-List *`.

## llama-server exits immediately with no error

Missing CUDA runtime DLLs. `01-install-llama.ps1` extracts two zips - the main build and
`cudart`. Confirm `engine\bin\` contains `cudart64_*.dll` and `cublas64_*.dll`.

## CUDA out of memory, but the budget says it should fit

1. Confirm both `--cache-type-k q8_0` and `--cache-type-v q8_0` are set. Missing one is
   enough to overflow
2. `nvidia-smi` - check what else is holding VRAM
3. Drop `-c` to get a working baseline, then raise it
4. For MoE models, raise `--n-cpu-moe` (toward 99) to push more layers back to the CPU.
   For dense models, lower `-ngl`

## Generation is only a few tok/s

1. **Warm up first.** On an MoE the first run reports 6-8 tok/s while expert pages are
   still being faulted in. Measure the second or third run
2. Task Manager -> Performance -> Memory: if *Committed* exceeds physical RAM you are paging
3. Close other memory-heavy applications, or switch to a smaller model
4. Laptops: confirm the power mode is not set to power-saving. CPU throttling hits
   MoE expert compute hard

## The first message takes about 2 minutes

Expected, and worth knowing before you assume it hung. Measured on a freshly started
35B server:

```
prompt eval : 4521 tokens in 63.5 s  (~70 tok/s)   <- the system prompt + AGENTS.md
eval        :   75 tokens in  4.0 s  (~19 tok/s)
```

Prefill is slow while the MoE expert weights are still being paged in from disk. Later
messages in the same session reuse those pages and are much faster. Generation itself
runs at ~15 tok/s throughout.

A longer `AGENTS.md` directly lengthens that first prefill.

---

# Snowflake-specific

## MCP server will not start / no Snowflake tools in OpenCode

OpenCode reports MCP startup failures by silently omitting the tools. Run it by hand to
see the error:

```powershell
$env:PYTHONUTF8 = '1'
uvx --python 3.11 snowflake-labs-mcp `
  --service-config-file "$env:USERPROFILE\.config\snowflake\service_config.yaml" `
  --connection-name audit
```

`--python 3.11` is not optional: snowflake-labs-mcp requires Python >= 3.11, and uv
resolves against whatever python is on PATH. With a 3.10 present it fails with
`No solution found when resolving tool dependencies`.

Other common causes: `account` is still `REPLACE-ME`; the private key path uses
backslashes; `uvx` is not on PATH (reopen the terminal after installing uv).

## UnicodeDecodeError: 'gbk' codec can't decode byte ...

On a non-UTF-8 Windows locale, Python's `open()` defaults to the ANSI codepage, and
`service_config.yaml` is UTF-8. Set `PYTHONUTF8=1` for the MCP process -
`01-install-mcp.ps1` puts it in `mcp.snowflake.environment` for you.

## JWT token is invalid

The public key was never registered, or the wrong one was. Re-run
`snowflake\tools\gen-keypair.ps1`, run the `ALTER USER ... SET RSA_PUBLIC_KEY` it prints
verbatim, then:

```sql
DESC USER SVC_AUDIT_AGENT;   -- RSA_PUBLIC_KEY_FP should have a value
```

The account identifier is `<orgname>-<account_name>`, without `.snowflakecomputing.com`.

## probe_snowflake.py: the "writes are rejected" check FAILS

**Stop and do not use the agent.** The role has too much privilege. Re-check
`snowflake/sql/01-guardrails.sql`, especially that no `OWNERSHIP` grant or a database
role carrying write access slipped in.

```sql
SHOW GRANTS TO ROLE AUDIT_AGENT;   -- expect only USAGE and SELECT
```

## Data Metric Functions require Enterprise Edition

DMFs need Enterprise or above. The fallback (dbt tests or Soda Core, same architecture)
is described at the end of `snowflake/sql/02-dmf-examples.sql`.

Also: changes to a DMF schedule take about 10 minutes to take effect.

## Credit spend is higher than expected

Every query is tagged, so you can attribute it:

```sql
SELECT query_text, warehouse_size, total_elapsed_time/1000 AS sec,
       credits_attributed_compute
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE  query_tag = 'local-audit-agent'
  AND  start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER  BY credits_attributed_compute DESC
LIMIT  20;
```

If you see repeated full scans, forbid that pattern in `snowflake/AGENTS.md`.
`STATEMENT_TIMEOUT` and the resource monitor are backstops, not the fix.
(ACCOUNT_USAGE lags by up to 3 hours.)

## The model writes invalid Snowflake SQL

Small models have seen far less Snowflake dialect than Postgres. Paste the target table's
DDL into `snowflake/AGENTS.md` and require `EXPLAIN` before execution - EXPLAIN does not
start a warehouse, so iterating is free. There is a dialect cheat sheet in that file.
