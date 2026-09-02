# Troubleshooting

Look up the symptom first. If something fails three times, stop and report the exact
error rather than trying variations.

**Where the logs are.** `start.ps1` writes `logs\llama-server.log`, `logs\opencode.log`
and `logs\web.log` (plus `.err` twins) in the repo root. The page's status banner has a
*看日志* button that shows the same tails, so you rarely need to open them by hand.

---

## The page says the engine is still starting, for minutes

The browser opens before the model is loaded on purpose; 20–60 s of "推理引擎正在把模型读进显存"
is normal. Past two minutes, click *看日志* (or read `logs\llama-server.log.err`). The usual
causes, in order:

1. **CUDA out of memory** - something else holds VRAM. `nvidia-smi`, close it, restart.
2. **Model file missing** - `engine\models-35b\*.gguf` is not there. Re-run `.\setup.ps1`;
   the download resumes.
3. **Port 8080 or 4096 is taken** by something else. `netstat -ano | findstr :8080`.

If the banner instead says *掉线* (dropped), a backend that was up has died - the log tail
has the reason, and `start.ps1` needs to be run again.

## The warm-up banner never turns green

`start.ps1` sends one throwaway message right after start so the first real message is
fast. It normally takes ~1 min on the 35B. If the banner says it failed, the first real
message simply pays the cold start itself (~2 min); nothing else is affected. Sending a
message while the warm-up is running cancels it, by design.

`.\start.ps1 -NoWarmup` skips it altogether.

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

## A message takes about 2 minutes

That is the cold start: the system prompt + `AGENTS.md` (~4.5K tokens) being prefilled
while the MoE expert weights are still paged in from disk. Measured on a freshly started
35B server:

```
prompt eval : 4521 tokens in 54 s  (~84 tok/s)   <- the system prompt + AGENTS.md
eval        :   75 tokens in  4 s  (~19 tok/s)
```

Normally the launcher's warm-up pays this before you do, and `llama-server` runs with
`--cache-reuse 256` so every later session reuses the cached prefix - measured first
token in a *new* session after warm-up: 2.7 s, with 4486 of 4524 prompt tokens served
from cache. You only see the 2-minute version if you sent a message before the warm-up
finished, or started with `-NoWarmup`.

A longer `AGENTS.md` directly lengthens the cold prefill. Restarting `llama-server`
empties the cache; the warm-up runs again on the next `start.ps1`.

## The agent runs `bash` with `python -c` instead of the Python tools

The Python kernel (`engine\tools\fishkernel.py`, an MCP server) is not connected, so the
model only has `bash`. Check, in order:

1. `python -c "import mcp"` in a terminal. `setup.ps1` installs the `mcp` package; if it
   is missing, `python -m pip install mcp`.
2. `opencode --version` is 1.18.26 or newer. Older versions ignore the per-agent tool
   list and hand the model every built-in tool. `.\setup.ps1` upgrades it.
3. `logs\opencode.log` for `mcp` errors. The kernel is started with the workspace as
   its working directory and the command `python ../../engine/tools/fishkernel.py`, so
   `python` must be on PATH for the agent process.

Also note that Fish.AI talks to OpenCode's **v1** API (`/session`, `/event`). The v2 API
(`/api/...`) in 1.18.x does not give MCP tools to the model at all - a UI that switches
back to it will silently lose the kernel.

## UnicodeDecodeError: 'gbk' codec can't decode byte ... (in the agent's Python)

On a Chinese/Japanese/Korean Windows, Python's `open()` defaults to the ANSI codepage.
`start.ps1` sets `PYTHONUTF8=1` for everything it launches, so this should not happen from
the normal launcher. If you started `opencode serve` by hand, set it in that terminal
first.

## Double-clicking Fish.AI.cmd flashes a window and disappears

The window stays open (with `pause`) whenever the script fails, so an instant close means
a very early failure: usually the `.cmd` was moved out of the repo folder. Keep the
desktop shortcut pointing at the checkout, or run `.\start.ps1` from a terminal to see the
error.

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
