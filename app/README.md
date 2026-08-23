# app/ - the Fish.AI web UI

Static page plus a thin Node server. Start it from the repo root with `.\start.ps1`;
this directory is not meant to be launched on its own.

## Processes it talks to

```
node server.mjs  :8090   this directory - serves public/ and proxies /api/* to :4096
opencode serve   :4096   agent runtime, working directory = app/workspace/
llama-server     :8080   inference
```

`server.mjs` is not redundant plumbing: same-origin removes CORS and EventSource
cross-origin problems, the status bar needs to poll two different backends without the
frontend knowing either address, and SSE must be forwarded chunk-by-chunk (it explicitly
disables every layer of buffering and pumps the reader by hand).

## Frontend layout

`public/index.html` - all styling. Colors are CSS variables under `:root` plus a
`prefers-color-scheme: dark` block. Retheming means editing only that.

`public/app.js` - three parts. Changing the UI normally only touches the first:

| Part | Functions | Role |
|---|---|---|
| Render | `addMessage` `ensureTool` `recordStat` `md` | builds DOM; change freely |
| Events | `connect` `handle` | subscribes to SSE, translates opencode events into render calls |
| Sync | `resync` | rebuilds the whole view from the server; all recovery lives here |

## Five things about the OpenCode API (learned the hard way)

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

## resync(): why recovery is one function

The browser should not be the only holder of state - the opencode server already has all
of it, so pulling it back is more reliable than patching up missed events. `resync()`
fetches `/message` and `/permission` and `/question` and rebuilds. It runs on:

- page load (session id is kept in `localStorage.fish.lastSession`)
- SSE reconnect (`onopen`, not the first time)
- tab becoming visible again (background tabs get their SSE throttled)
- generating but no event for 25 s (the stream died quietly; browsers do not always fire an error)

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
resync()              // manual resync
```

## Known, not fixed

- **tok/s in the status bar reads low.** It measures `step.started -> step.ended`, which
  includes the time you spent looking at a permission dialog. Reading llama-server's
  `/metrics` would be accurate.
- **First token takes 60-90 s.** Prefill on a 35B model plus the length of
  `workspace/AGENTS.md`. Not a bug.

## workspace/

The directory the agent can read - put your data files here. `workspace/AGENTS.md` holds
the behaviour rules; they are written against measured model weaknesses, so read the
numbers in there before deleting any of them.
