<div align="center">

*Designed, Developed, Devoted — for Elena* 🐑

# 🐟 Fish.AI

**Ask questions about your data files. It writes and runs code to verify every number.**

Runs entirely on your machine — no API keys, no cloud, your data never leaves the box.

[📦 Install](#-install) · [🚀 Quick Start](#-quick-start) · [📊 Benchmarks](#-benchmarks) · [🧩 How It Works](#-how-it-works) · [❄️ Snowflake](#️-snowflake-optional) · [🔧 Troubleshooting](#-troubleshooting)

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Windows-0078D4)
![Python](https://img.shields.io/badge/python-3.10%2B-3776AB)
![Node](https://img.shields.io/badge/node-18%2B-339933)
![Local](https://img.shields.io/badge/inference-100%25%20local-0d7d94)

</div>

---

```
You:      What's in demo.xlsx?

Fish.AI:  [reads the file]
          Sheet "Employees", 5 columns x 6 rows: ID, name, department, salary, hire date.

You:      Any outliers in the salary column?

Fish.AI:  [runs Python]
          n=5  mean=11260  sd=1240  Q1=10500  Q3=12000
          fences [8250, 14250] -> no outliers
```

Every number above came out of a Python process you can inspect — not out of the model.
That is the whole design: **the model decides what to compute, Python does the computing.**

---

## ✨ Highlights

- 📂 **Drag a file onto the page** — Excel, CSV, JSON, text, parquet, SPSS/SAS/Stata. It writes the parsing code itself, nothing to upload anywhere.
- 🧮 **Code-verified statistics** — every number traces back to a snippet you can re-run.
- 📋 **Audit trail** — a side panel keeps every command it ran and every output.
- 🔒 **Asks before it acts** — no command runs without your approval; the dialog shows the exact command.
- 💬 **Asks you back** — when a request is ambiguous it pops a multiple-choice question.
- ⚡ **Warm from the start** — the launcher pre-fills the model's prompt once, so the first real question answers in seconds instead of two minutes.
- 🖱️ **One line to install, one click to run** — or `.\setup.ps1` then `.\start.ps1` if you prefer a terminal.

## 📦 Install

**You need:** Windows 10/11 · an NVIDIA GPU with 4 GB+ VRAM and its driver · 12 GB+ RAM · 25 GB free disk

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/Antlera/Fish.AI/main/install.ps1 | iex
```

That is the whole install. It clones the repo into `~\Fish.AI` (installing git first if
needed) and runs `setup.ps1`, which installs **Python and Node.js via winget if they are
missing**, then fetches llama.cpp, the model weights, the agent runtime and the Python
data stack, and puts a **Fish.AI** shortcut on your desktop. Everything is re-runnable
and skips whatever is already done. Expect 10–30 minutes, most of it the 9.4 GB download.

The one thing it will not install for you is the NVIDIA driver — that needs a reboot and
the right variant for your card, so it stays manual.

<details>
<summary>Other ways to install</summary>

Already cloned? Run `.\setup.ps1`, or double-click `Setup.cmd` — the `.cmd` wrappers run
with a per-process execution policy, so no `Set-ExecutionPolicy` is needed.

```powershell
git clone https://github.com/Antlera/Fish.AI.git
cd Fish.AI
.\setup.ps1
```

Options for `setup.ps1` (or as environment variables for the one-liner, e.g.
`$env:FISH_MODEL='bonsai8b'` before `irm ... | iex`):

| | |
|---|---|
| `-Model bonsai8b` | smaller machine: 1.1 GB, much faster, noticeably less accurate |
| `-NoAutoInstall` | report missing prerequisites instead of installing them |
| `-NoShortcut` | do not create the desktop shortcut |
| `$env:FISH_DIR` | one-liner only: where to clone (default `~\Fish.AI`) |

Fish.AI does not touch `~\.config\opencode`. Its agent config lives in
`app\workspace\opencode.json`, so an existing OpenCode setup is left alone.
</details>

## 🚀 Quick Start

Double-click the **Fish.AI** desktop shortcut (or `Fish.AI.cmd`, or run `.\start.ps1`).

The browser opens right away at <http://127.0.0.1:8090> and shows what is still loading.
The model takes 20–60 s to load, then the launcher **warms it up** for about a minute —
a banner tells you when it is done. After that, the first question answers in seconds.
`Ctrl+C` in the terminal (or closing it) stops everything.

**Getting data in:** drag files onto the page, click 📎, or use *打开文件夹* to open
`app\workspace\` — that is the directory the agent can read.

> Sent a message before the warm-up finished? It works, but that message pays the cold
> start itself: ~2 minutes on the 35B model. Everything after it is fast either way.

## 📊 Benchmarks

**Why code-verified.** Local models get statistics *concepts* right and *arithmetic* wrong.
Measured on the default model with a 10-question stats set:

| Task | Result |
|---|---|
| Choose the right test for a skewed small sample | ✅ |
| Explain what a p-value is — and isn't | ✅ |
| Recognise Simpson's paradox | ✅ |
| Write a correct NULL-rate SQL query | ✅ |
| Compute mean / median / sd **in its head** | ❌ |
| Compute the same thing **via Python** | ✅ |

So Fish.AI always routes numbers through code.

**Models.** Swap with `-Model` on either script. Measured on an RTX 2050 (4 GB) / 13.7 GB RAM laptop:

| `-Model` | Download | Resident RAM | VRAM | Speed | Eval |
|---|---|---|---|---|---|
| **`a3b`** *(default)* | 9.4 GB | **2.7 GB** | **1477 MiB** | 15 tok/s | **9/10** |
| `qwen4b` | 2.4 GB | 7.2 GB | 3587 MiB | 13 tok/s | 7/10 |
| `bonsai27b` | 3.5 GB | 5.9 GB | 3825 MiB | 6 tok/s | 8/10 |
| `bonsai8b` | 1.1 GB | 4.2 GB | 3804 MiB | **52 tok/s** | 6/10 |

The default is a 35B mixture-of-experts. Counter-intuitively it is the **cheapest** option
here: 8 of its 256 experts fire per token and llama.cpp mmaps the file, so only ~2.7 GB is
ever resident. Its KV cache is tiny too — 2 KV heads and only 10 of 40 layers use full
attention, so 64K of context costs 0.7 GB where a 4B dense model needs 5.1 GB.

`bonsai8b` is genuinely fast but called a dataset containing an obvious outlier
"outlier-free" during testing. Use it for quick chatting, not for analysis you rely on.

**Warm-up.** The agent's system prompt plus `AGENTS.md` is ~4.5K tokens and identical for
every session. Measured on the 35B, same machine:

| | Prefill | First token |
|---|---|---|
| Cold (first message ever) | 4521 tokens in 54 s | ~1–2 min |
| New session after warm-up | 38 tokens (4486 served from cache) | **2.7 s** |

The launcher does the cold turn itself while you are still opening the browser, and
`llama-server` runs with `--cache-reuse 256` so later sessions reuse that prefix.

## 🧩 How It Works

```
┌────────────┐     ┌──────────────┐     ┌────────────────┐
│  Browser   │────▶│  server.mjs  │────▶│ opencode serve │
│   :8090    │◀────│ static + SSE │◀────│     :4096      │
│ drag&drop  │     │ files, warm  │     └───────┬────────┘
└────────────┘     └──────────────┘             │
                                   ┌────────────┴─────────────┐
                                   ▼                          ▼
                          ┌────────────────┐        ┌──────────────────┐
                          │  llama-server  │        │  bash / python   │
                          │     :8080      │        │  on your machine │
                          └────────────────┘        └──────────────────┘
```

The agent runtime is [OpenCode](https://github.com/sst/opencode); inference is
[llama.cpp](https://github.com/ggml-org/llama.cpp). Fish.AI is the web layer plus the
behaviour rules in [`app/workspace/AGENTS.md`](app/workspace/AGENTS.md), which are written
against measured model weaknesses — always compute in Python, never skip the derivation,
never invent a term you are unsure of.

Because the agent runs `bash` directly on your machine (not in a sandbox), it can answer
questions about files already on disk without any upload — and that is exactly why every
command needs approval first.

## ❄️ Snowflake (optional · 🚧 TODO)

> **Not enabled by default, and not yet verified end-to-end.** `setup.ps1` does not touch
> it and the default OpenCode config contains no MCP entry — installing Fish.AI gets you
> the local-file workflow and nothing else.

[`snowflake/`](snowflake/) sketches a read-only Snowflake audit setup: dedicated warehouse,
monthly credit cap, a role with only `USAGE` and `SELECT`, key-pair auth, and a probe that
fails if writes are *not* rejected.

| Piece | Status |
|---|---|
| SQL guardrails, DMF examples | written, **never run against a live account** |
| Key-pair generation | works |
| MCP server install + OpenCode wiring | works up to the connection attempt |
| `probe_snowflake.py` acceptance test | **never passed — needs a real account** |
| Agent → MCP → Snowflake round trip | **untested** |

Treat it as a starting point, not a finished feature. See
[`snowflake/README.md`](snowflake/README.md).

## 🔧 Troubleshooting

| Symptom | Cause |
|---|---|
| Page says the engine is still starting after 2+ minutes | Click *看日志* in the banner, or read `logs\llama-server.log.err`. Usually CUDA out of memory: close GPU-heavy apps. |
| A message takes ~2 minutes | It was sent before the warm-up finished (or with `-NoWarmup`). One-off; later messages are fast. |
| Agent writes prose instead of using tools | Context overflow — tool definitions fell out of the window. Start a new session. |
| A command "succeeded" with no output | On Windows, `python -c` with embedded newlines silently produces nothing. Use one line, or write a `.py` file. |
| Answers come back empty | Thinking mode is on. `03-start-server.ps1` passes `--reasoning off` for models that need it. |
| `UnicodeDecodeError: 'gbk'` while reading a file | `start.ps1` sets `PYTHONUTF8=1` for the agent; if you launched things by hand, set it yourself. |

Full list by symptom: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 📁 Layout

```
install.ps1            one-line bootstrap: git clone + setup
setup.ps1  Setup.cmd   one-shot install (Setup.cmd = double-click version)
start.ps1  Fish.AI.cmd one-shot run     (Fish.AI.cmd = double-click version)
app/                   web UI + API proxy + file API + warm-up   -> app/README.md
  workspace/           your data files; AGENTS.md = agent rules; opencode.json = agent config
engine/                llama.cpp, model downloads
  scripts/             numbered install/verify steps, runnable individually
logs/                  runtime logs from start.ps1 (git-ignored)
snowflake/             optional read-only Snowflake auditing  -> snowflake/README.md
```

## 🙏 Built On

[OpenCode](https://github.com/sst/opencode) · [llama.cpp](https://github.com/ggml-org/llama.cpp) · [Qwen3.6](https://huggingface.co/Qwen) · [Unsloth GGUF quants](https://huggingface.co/unsloth)

## License

MIT
