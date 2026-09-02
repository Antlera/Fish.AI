# app/ - the Fish.AI web UI

Static page plus a thin Node server. Start it from the repo root with `.\start.ps1`;
this directory is not meant to be launched on its own. There is nothing to `npm install`.

## Processes it talks to

```
node server.mjs  :8090   this directory - serves public/, proxies /oc/* and /api/* to :4096,
                         exposes workspace/ to the browser, warms the model up
opencode serve   :4096   agent runtime, working directory = app/workspace/
  └ fishkernel.py        MCP server it spawns: the agent's persistent Python session
llama-server     :8080   inference
```

**The UI uses OpenCode's v1 API** (`/session`, `/event`, `/permission`, `/question`),
reached through the `/oc/` prefix. The v2 API under `/api/` does not hand MCP or custom
tools to the model in 1.18.x (verified with a fake model endpoint that logs the tool
list), and the Python kernel is an MCP server. `/api/*` is still proxied for health
checks and diagnostics.

`server.mjs` is not redundant plumbing: same-origin removes CORS and EventSource
cross-origin problems, the status bar needs to poll two different backends without the
frontend knowing either address, and SSE must be forwarded chunk-by-chunk (it explicitly
disables every layer of buffering and pumps the reader by hand).

## What server.mjs adds on top of the proxy

| Endpoint | Purpose |
|---|---|
| `GET /fish/status` | both backends' health, model name, context size, live tok/s from llama's `/metrics`, warm-up state |
| `GET /fish/files` | list of `workspace/` (hides `AGENTS.md`, `opencode.json`, dotfiles) |
| `POST /fish/upload?name=` | raw body -> `workspace/<name>`; duplicates become `name (2).ext`; names are basename-only |
| `POST /fish/open-folder` | `explorer.exe workspace\` |
| `GET /fish/logs?which=llama\|opencode` | tail of the launcher logs, for the "engine failed" banner |
| `PATCH/DELETE /fish/session/:id` | v1 opencode endpoints (`PATCH /session`, `DELETE /session`) that are not under `/api` |

**Warm-up.** Right after both backends are up, `server.mjs` creates a session, sends one
throwaway prompt, waits for the first token, then interrupts and deletes the session.
The system prompt + tools + `AGENTS.md` prefix (about 4.5K tokens) is identical for every
session, and llama-server keeps its KV cache (`--cache-reuse 256` in
`03-start-server.ps1`), so the user's first real message only prefills its own few
tokens. Measured on the 35B: a new session reused ~4.3K of ~4.4K prompt tokens from
cache. If the user sends a message while the warm-up is still running, the warm-up is
cancelled rather than competing for the GPU. `-NoWarmup` on `start.ps1` disables it.

## Frontend layout

`public/index.html` - all styling. Colors are CSS variables under `:root` plus a
`prefers-color-scheme: dark` block. Retheming means editing only that.

`public/app.js` - render, events, sync, plus three panels. Changing the UI normally
only touches the first row:

| Part | Functions | Role |
|---|---|---|
| Render | `addMessage` `ensureTool` `recordStat` `md` `markDirty` | builds DOM; token deltas are batched into one `requestAnimationFrame` |
| Provenance | `harvestNumbers` `markProvenance` | every number in a finished answer is looked up in this session's tool outputs; misses get `mark.unv` |
| Status | `refreshStatus` `banner` `renderThinking` | engine/warm-up banner, "reading prompt 12s" indicator, tok/s, context bar |
| Files | `loadFiles` `uploadFiles` | file list, drag-and-drop anywhere on the page, click-to-insert filename |
| History | `showHistory` | switch to / delete previous sessions; first message becomes the title |
| Events | `connect` `handle` | subscribes to SSE, translates opencode events into render calls |
| Sync | `resync` | rebuilds the whole view from the server; all recovery lives here |

`md()` handles fenced code (also unclosed ones mid-stream), pipe tables
(`df.to_markdown()`), lists that survive blank lines between items, blockquotes, and
`$$` blocks (kept verbatim, not rendered).

## Eight things about the OpenCode API (learned the hard way)

**1. Only the v1 API gives the model MCP and custom tools.**
`POST /api/session/{id}/prompt` (v2) sends the built-in tools and nothing else, in
1.18.21 and 1.18.26 alike; `POST /session/{id}/prompt_async` (v1) sends `python_*`, custom
`.opencode/tools/*.ts`, and honours the agent's `tools` toggles. The two paths also emit
different events (`session.next.*` vs `message.part.*`) and store the same messages in
different shapes. The whole frontend is on v1 for this reason.

**2. The agent's `tools` toggles are only applied from 1.18.26.**
1.18.21 hands the model all twelve built-in tools regardless of config. Also, the very
first session after `opencode serve` starts has been seen to get the default config;
`server.mjs` touches `/agent` and waits before the warm-up session.

**3. Text deltas come as `message.part.delta` with `messageID` + `partID`.**
Key text bubbles on `${messageID}:${partID}`. `message.part.updated` carries the full
part (`text`, `tool`, `step-start`, `step-finish`); a text part with `time.end` is final.

**4. `session.idle` is the end of a turn on v1.** `message.updated` with a `finish`
other than `tool-calls` means the same thing; the UI accepts either.

**5. Permission and question are two separate mechanisms.**

| | permission | question |
|---|---|---|
| meaning | "may I run this command" | "I need you to choose something" |
| endpoint | `POST /session/{sid}/permissions/{id}` | `/question/{id}/reply` and `/reject` |
| body | `{response:"once"}` | `{answers:[["label",...]]}` |
| pending list | `GET /permission` (all sessions; filter by `sessionID`) | `GET /question` |

Implementing only permission means the agent hangs forever the first time it asks a
question, with nothing shown in the UI.

**6. Permission events usually have empty `metadata`.**
To show *what will run*, look up the tool call via `tool.callID` (v1) / `source.callID`
(v2). A permission dialog that does not show the command is pointless.

**7. Prefix caching hides context usage.**
`tokens.input` is only the *uncached* part - add `tokens.cache.read` to get real context
usage.

**8. Provider config is per project, not per environment.**
`OPENCODE_CONFIG` is honoured by `GET /config` but *not* by the provider registry that
actually makes the LLM call (it kept using the global file). `opencode.json` in the
working directory works. That is why the config lives in `workspace/`.

**Bonus: never start `opencode serve` from git-bash.** It inherits `SHELL=/usr/bin/bash`,
its bash tool then spawns a shell that does not exist on Windows, and every command
returns empty output - the model loops trying variations. `start.ps1` and the eval
runner start it from PowerShell / with `SHELL` removed.

## resync(): why recovery is one function

The browser should not be the only holder of state - the opencode server already has all
of it, so pulling it back is more reliable than patching up missed events. `resync()`
fetches `/message` and `/permission` and `/question` and rebuilds. It runs on:

- page load (session id is kept in `localStorage.fish.lastSession`)
- SSE reconnect (`onopen`, not the first time)
- tab becoming visible again (background tabs get their SSE throttled)
- generating but no event for 25 s and llama reports it is not processing (the stream
  died quietly; browsers do not always fire an error)

Two rules it must obey, both learned by breaking them:

- **It must restore `busy` too**, inferred from tool `state.status`, the last assistant
  message's `finish`, and any pending prompts. View-only restore leaves the send button
  clickable mid-turn, and disables the 25 s watchdog above, whose first line is
  `if (!state.busy) return`.
- **It must not rebuild a dialog the user is filling in.** Re-rendering a question wipes
  the checkboxes, submits an empty answer array, and the agent - told "Unanswered" -
  asks the same question again.

## Debugging

From the browser console:

```js
state.es.readyState   // 0 connecting / 1 open / 2 closed
state.evCount         // total events received; not increasing means the stream is dead
state.lastType        // last event type
state.status          // last /fish/status
resync()              // manual resync
```

Launcher logs: `logs\llama-server.log`, `logs\opencode.log`, `logs\web.log` in the repo
root (plus `.err` variants). The status pill's "看日志" button shows the same tails.

## workspace/

The directory the agent can read - put your data files here, or drag them onto the page.
`workspace/AGENTS.md` holds the behaviour rules; they are written against measured model
weaknesses, so read the numbers in there before deleting any of them.
`workspace/opencode.json` points the agent at the local llama-server and sets tool
permissions to "ask"; it is tracked in git.
