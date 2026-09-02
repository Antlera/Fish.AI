# app/ - the Fish.AI web UI

Static page plus a thin Node server. Start it from the repo root with `.\start.ps1`;
this directory is not meant to be launched on its own. There is nothing to `npm install`.

## Processes it talks to

```
node server.mjs  :8090   this directory - serves public/, proxies /api/* to :4096,
                         exposes workspace/ to the browser, warms the model up
opencode serve   :4096   agent runtime, working directory = app/workspace/
llama-server     :8080   inference
```

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
| Status | `refreshStatus` `banner` `renderThinking` | engine/warm-up banner, "reading prompt 12s" indicator, tok/s, context bar |
| Files | `loadFiles` `uploadFiles` | file list, drag-and-drop anywhere on the page, click-to-insert filename |
| History | `showHistory` | switch to / delete previous sessions; first message becomes the title |
| Events | `connect` `handle` | subscribes to SSE, translates opencode events into render calls |
| Sync | `resync` | rebuilds the whole view from the server; all recovery lives here |

`md()` handles fenced code (also unclosed ones mid-stream), pipe tables
(`df.to_markdown()`), lists that survive blank lines between items, blockquotes, and
`$$` blocks (kept verbatim, not rendered).

## Six things about the OpenCode API (learned the hard way)

**1. Token deltas are only on the global event stream.**
`/api/session/{id}/event` emits `text.started` and `text.ended` and nothing in between.
Subscribe to `/api/event` and filter by `sessionID`.

**2. `session.idle` is never emitted.**
Only `session.next.step.ended` arrives. If you unlock the send button on `session.idle`
alone it stays disabled forever and the second message can never be sent. Unlock based on
`step.ended`'s `finish` field - if it contains `tool`, more steps are coming, stay busy.

**3. `textID` is not globally unique.**
It is per-message and is `text-0` on every turn. Key your map on
`assistantMessageID + textID`, or turn two's text appends into turn one's bubble.

**4. Permission and question are two separate mechanisms.**

| | permission | question |
|---|---|---|
| meaning | "may I run this command" | "I need you to choose something" |
| endpoint | `/permission/{id}/reply` | `/question/{id}/reply` and `/reject` |
| body | `{reply:"once"}` | `{answers:[["label",...]]}` |

Implementing only permission means the agent hangs forever the first time it asks a
question, with nothing shown in the UI.

**5. Permission events usually have empty `metadata`.**
To show *what will run*, look up the tool call via `source.callID`. A permission dialog
that does not show the command is pointless.

**6. History and the event stream name the same fields differently.**
A tool part from `GET /message` has `id` / `name` / `state.error = {type,message}`; the
same thing on the event stream is `callID` / `tool` / a string. `restoreTool()` accepts
both. Also: with prefix caching, `tokens.input` on `step.ended` is only the *uncached*
part - add `tokens.cache.read` to get real context usage.

**7. Provider config is per project, not per environment.**
`OPENCODE_CONFIG` is honoured by `GET /config` but *not* by the provider registry that
actually makes the LLM call (it kept using the global file). `opencode.json` in the
working directory works. That is why the config lives in `workspace/`.

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
