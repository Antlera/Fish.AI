// Fish.AI - serves the web UI, reverse-proxies the opencode API, exposes the
// workspace directory to the browser, and warms the model up at startup.
//
// Why this layer exists instead of letting the browser talk to :4096 directly:
//   1. Same-origin: no CORS, no cross-origin EventSource problems
//   2. The status bar polls two backends (llama-server :8080 and opencode :4096);
//      the frontend should not need to know either address
//   3. SSE must be forwarded chunk by chunk - every layer of buffering is disabled below
//   4. Warm-up: one throwaway turn right after start makes the *user's* first message
//      fast, because llama-server keeps the KV cache of the shared system-prompt prefix
//      (measured: a new session reused 3104 of 3123 prompt tokens from cache)
//   5. Files: drag-and-drop into the workspace instead of hunting for the folder
import http from 'node:http'
import { readFile, stat, readdir, mkdir, rename, unlink } from 'node:fs/promises'
import { createWriteStream } from 'node:fs'
import { join, extname, normalize, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'

const ROOT      = fileURLToPath(new URL('./public/', import.meta.url))
const WORKSPACE = process.env.FISH_WORKSPACE ?? fileURLToPath(new URL('./workspace/', import.meta.url))
const PORT      = Number(process.env.FISH_PORT ?? 8090)
const OPENCODE  = process.env.OPENCODE_URL ?? 'http://127.0.0.1:4096'
const LLAMA     = process.env.LLAMA_URL    ?? 'http://127.0.0.1:8080'
const LOGS      = { llama: process.env.FISH_LLAMA_LOG, opencode: process.env.FISH_OPENCODE_LOG }
const MAX_UPLOAD = 2 * 1024 * 1024 * 1024   // 2 GB - local disk to local disk, no reason to be stingy

// Files the UI should not list as "your data": the agent rules and the runtime config.
const HIDDEN = new Set(['AGENTS.md', 'opencode.json', '.gitkeep'])

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',   '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',             '.png': 'image/png', '.ico': 'image/x-icon',
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log(new Date().toLocaleTimeString('en-GB'), ...a)

/* ---------------- opencode helper ---------------- */
async function oc(method, path, body) {
  const r = await fetch(OPENCODE + path, {
    method,
    headers: body !== undefined ? { 'content-type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15000),
  })
  if (!r.ok) throw new Error(`${method} ${path} -> ${r.status} ${(await r.text()).slice(0, 200)}`)
  const j = await r.json().catch(() => ({}))
  return j?.data !== undefined ? j.data : j
}

/* ---------------- status ---------------- */
// /props does not change while the server runs; ask once and remember.
let propsCache = null

/** Prometheus text -> { name: value } for the llamacpp: family only. */
function parseMetrics(text) {
  const out = {}
  for (const line of text.split('\n')) {
    if (!line.startsWith('llamacpp:')) continue
    const [k, v] = line.split(/\s+/)
    out[k.slice('llamacpp:'.length)] = Number(v)
  }
  return out
}

/** Status bar: fetch both backends' health at once; one being down must not hide the other. */
async function status() {
  const out = { llama: { up: false }, opencode: { up: false }, warm: warmView(), teams: teamsView(), workspace: WORKSPACE }
  const T = (ms) => ({ signal: AbortSignal.timeout(ms) })
  await Promise.all([
    (async () => {
      const h = await fetch(`${LLAMA}/health`, T(2500))
      if (!h.ok) return
      out.llama.up = true
      await Promise.all([
        (async () => {
          if (!propsCache) {
            const p = await (await fetch(`${LLAMA}/props`, T(2500))).json()
            const g = p.default_generation_settings ?? {}
            propsCache = {
              ctx:   g.n_ctx ?? p.n_ctx ?? null,
              model: (p.model_path ?? '').split(/[\\/]/).pop() || null,
            }
          }
          Object.assign(out.llama, propsCache)
        })().catch(() => {}),
        (async () => {
          const m = parseMetrics(await (await fetch(`${LLAMA}/metrics`, T(2500))).text())
          // Gauges: the speed of the most recent request. Far more honest than timing
          // step.started -> step.ended in the browser, which includes the time the
          // user spent staring at a permission dialog.
          out.llama.tps        = m.predicted_tokens_seconds ?? null
          out.llama.prefillTps = m.prompt_tokens_seconds ?? null
          out.llama.processing = (m.requests_processing ?? 0) > 0
          out.llama.cachedTokens = m.prompt_tokens_cached_total ?? null
          out.llama.promptTokens = m.prompt_tokens_total ?? null
        })().catch(() => {}),
      ])
    })().catch(() => {}),
    (async () => {
      const r = await fetch(`${OPENCODE}/api/health`, T(2500))
      out.opencode.up = r.ok
    })().catch(() => {}),
  ])
  return out
}

/* ---------------- warm-up ----------------
 * The first message on a cold 35B MoE takes ~2 minutes: expert weights are being paged
 * in from disk while a 4.5K-token system prompt is prefilled at ~70 tok/s. Nothing
 * about that prefix depends on the user's question, so do it now, once, while the user
 * is still opening the browser. llama-server keeps the KV cache and the user's first
 * real message only pays for its own few tokens.
 *
 * The warm-up session is deleted afterwards so it never shows up in history. If the
 * user sends a message while warm-up is still running, warm-up is cancelled: two
 * requests sharing the GPU would just make both slow. */
const warm = { state: 'pending', startedAt: null, endedAt: null, promptTokens: null, error: null, sessionID: null, cancelled: false }
let userPrompted = false

function warmView() {
  const { sessionID, cancelled, ...v } = warm
  return v
}

const WARM_PROMPT = 'This is a warm-up message from the launcher. Reply with the single word OK. Do not use any tool.'

// Everything below talks to opencode's v1 API (/session, /event, ...), exposed to the
// browser under /oc/. The v2 API (/api/...) does not hand MCP tools to the model in
// 1.18.x, and Fish.AI's Python kernel is an MCP server - so v1 it is, for the warm-up
// too: the cached prefix must be the one real prompts use.

async function warmup() {
  if (process.env.FISH_NO_WARMUP === '1') { warm.state = 'skipped'; return }
  warm.state = 'waiting'
  for (;;) {
    const s = await status()
    if (s.llama.up && s.opencode.up) break
    if (userPrompted) { warm.state = 'skipped'; return }
    await sleep(2000)
  }
  // The proxy is up but opencode may still be booting internally. The first session
  // after boot has been seen to get the default (global) config instead of the
  // project one, so touch the agent list first and give it a beat.
  await oc('GET', '/agent').catch(() => {})
  await sleep(2500)
  if (userPrompted) { warm.state = 'skipped'; return }

  warm.state = 'running'
  warm.startedAt = Date.now()
  log('warm-up: starting')
  // How many prompt tokens llama-server has processed so far; the delta after the
  // warm-up turn is exactly what is now sitting in its KV cache.
  const promptBefore = (await status()).llama.promptTokens ?? null
  let sid = null
  try {
    const s = await oc('POST', '/session', {})
    sid = s.id
    warm.sessionID = sid
    await oc('POST', `/session/${sid}/prompt_async`, { parts: [{ type: 'text', text: WARM_PROMPT }] })

    const deadline = Date.now() + 300_000
    let done = false
    while (Date.now() < deadline && !warm.cancelled) {
      await sleep(1500)
      const msgs = await oc('GET', `/session/${sid}/message`).catch(() => [])
      const a = [...(msgs || [])].reverse().find((m) => (m.info?.role ?? m.role) === 'assistant')
      if (a) {
        const info = a.info ?? a
        const parts = a.parts ?? a.content ?? []
        // Prefill is over the moment the first token or tool call shows up. The
        // finish flag is the clean signal; the others are fallbacks for a model
        // that decides to "help" by calling a tool despite being told not to.
        if (info.finish || parts.some((p) => p.type === 'tool' || (p.type === 'text' && p.text))) {
          done = true
          if (info.error) warm.error = info.error.message || info.error.data?.message || info.error.name || 'error'
          break
        }
      }
      const perms = await oc('GET', '/permission').catch(() => [])
      if ((Array.isArray(perms) ? perms : []).some((p) => p.sessionID === sid)) { done = true; break }
    }
    warm.state = warm.error ? 'failed' : done ? 'done' : warm.cancelled ? 'cancelled' : 'timeout'
    if (done && promptBefore != null) {
      const after = (await status()).llama.promptTokens
      if (after != null && after > promptBefore) warm.promptTokens = after - promptBefore
    }
  } catch (e) {
    warm.state = 'failed'
    warm.error = e.message
  } finally {
    warm.endedAt = Date.now()
    warm.sessionID = null
    if (sid) {
      await oc('POST', `/session/${sid}/abort`, {}).catch(() => {})
      await sleep(500)
      await oc('DELETE', `/session/${sid}`).catch(() => {})
    }
    const secs = ((warm.endedAt - warm.startedAt) / 1000).toFixed(0)
    log(`warm-up: ${warm.state} in ${secs}s` + (warm.promptTokens ? ` (${warm.promptTokens} prompt tokens now cached)` : '') + (warm.error ? ` - ${warm.error}` : ''))
  }
}

/* ---------------- keep Teams green ----------------
 * While the user reads a long answer nothing moves the mouse, and Teams flips to
 * "Away". The new Teams accepts `ms-teams.exe --set-presence-to-available` on its
 * command line (no admin rights needed), so we re-assert it every few minutes.
 * The exe is the App Execution Alias under %LOCALAPPDATA%\Microsoft\WindowsApps;
 * FISH_TEAMS_EXE overrides the path. Default on unless FISH_TEAMS_GREEN=0. */
const TEAMS_EXE = process.env.FISH_TEAMS_EXE ||
  join(process.env.LOCALAPPDATA || '', 'Microsoft', 'WindowsApps', 'ms-teams.exe')
const TEAMS_INTERVAL = Number(process.env.FISH_TEAMS_INTERVAL ?? 240) * 1000
const teams = { enabled: false, found: false, exe: TEAMS_EXE, intervalSec: TEAMS_INTERVAL / 1000,
                lastRun: null, runs: 0, error: null, timer: null }

function teamsView() {
  const { timer, ...v } = teams
  return v
}

function teamsPing() {
  if (!teams.found) return
  try {
    // `start` is what the PowerShell one-liner in the blog post does under the hood:
    // launch the alias detached, do not wait, no console window.
    const child = spawn('cmd.exe', ['/d', '/c', 'start', '""', `"${TEAMS_EXE}"`, '--set-presence-to-available'],
                        { detached: true, stdio: 'ignore', windowsHide: true, windowsVerbatimArguments: true })
    child.on('error', (e) => { teams.error = e.message })
    child.unref()
    teams.lastRun = Date.now()
    teams.runs++
    teams.error = null
  } catch (e) {
    teams.error = e.message
  }
}

async function teamsSet(enabled) {
  try { await stat(TEAMS_EXE); teams.found = true } catch { teams.found = false }
  if (teams.timer) { clearInterval(teams.timer); teams.timer = null }
  teams.enabled = enabled && teams.found
  if (teams.enabled) {
    teamsPing()
    teams.timer = setInterval(teamsPing, TEAMS_INTERVAL)
    log(`teams: keeping status green every ${teams.intervalSec}s`)
  } else if (enabled && !teams.found) {
    log(`teams: not found at ${TEAMS_EXE}, keep-green disabled`)
  } else {
    log('teams: keep-green off')
  }
  return teamsView()
}

/* ---------------- workspace files ---------------- */
const BAD_NAME = /[<>:"/\|?* -]/

function safeName(raw) {
  const name = basename(String(raw || '')).trim()
  if (!name || name === '.' || name === '..' || BAD_NAME.test(name)) return null
  return name
}

async function listFiles() {
  await mkdir(WORKSPACE, { recursive: true })
  const names = await readdir(WORKSPACE)
  const out = []
  for (const name of names) {
    if (name.startsWith('.') || HIDDEN.has(name)) continue
    try {
      const s = await stat(join(WORKSPACE, name))
      out.push({ name, size: s.size, mtime: s.mtimeMs, dir: s.isDirectory() })
    } catch { /* vanished between readdir and stat */ }
  }
  out.sort((a, b) => b.mtime - a.mtime)
  return out
}

/** Pick a free name: report.xlsx -> report (2).xlsx if it already exists. */
async function freeName(name) {
  const ext = extname(name)
  const stem = name.slice(0, name.length - ext.length)
  for (let i = 1; i < 1000; i++) {
    const cand = i === 1 ? name : `${stem} (${i})${ext}`
    try { await stat(join(WORKSPACE, cand)) } catch { return cand }
  }
  throw new Error('too many files with that name')
}

async function upload(req, res, url) {
  const name = safeName(url.searchParams.get('name'))
  if (!name) return json(res, 400, { error: 'bad file name' })
  const len = Number(req.headers['content-length'] ?? 0)
  if (len > MAX_UPLOAD) return json(res, 413, { error: 'file too large' })
  await mkdir(WORKSPACE, { recursive: true })
  const final = await freeName(name)
  const tmp = join(WORKSPACE, `.upload-${process.pid}-${Date.now()}.part`)
  try {
    await new Promise((resolve, reject) => {
      const ws = createWriteStream(tmp)
      req.on('error', reject)
      ws.on('error', reject)
      ws.on('finish', resolve)
      req.pipe(ws)
    })
    await rename(tmp, join(WORKSPACE, final))
  } catch (e) {
    await unlink(tmp).catch(() => {})
    return json(res, 500, { error: e.message })
  }
  const s = await stat(join(WORKSPACE, final))
  log(`upload: ${final} (${s.size < 10240 ? `${s.size} B` : `${(s.size / 1024).toFixed(0)} KB`})`)
  json(res, 200, { name: final, size: s.size, renamed: final !== name })
}

function openFolder() {
  // Windows only, and only ever the workspace directory - never a path from the request.
  const child = spawn('explorer.exe', [WORKSPACE], { detached: true, stdio: 'ignore' })
  child.on('error', () => {})
  child.unref()
}

/** Tail of a launcher log, for the "engine failed to start" banner. */
async function tailLog(which, lines = 40) {
  const p = LOGS[which]
  if (!p) return null
  const out = []
  for (const f of [p, `${p}.err`]) {
    try {
      const t = await readFile(f, 'utf8')
      if (t.trim()) out.push(...t.trimEnd().split('\n').slice(-lines))
    } catch { /* not written yet */ }
  }
  return out.slice(-lines).join('\n')
}

/* ---------------- proxy ---------------- */
/** Forward /api/* verbatim and /oc/* with the prefix stripped (opencode's v1 API).
 *  SSE is streamed through without buffering. */
async function proxy(req, res, url) {
  const upstreamPath = url.pathname.startsWith('/oc/') ? url.pathname.slice(3) : url.pathname
  const target = OPENCODE + upstreamPath + url.search
  const headers = {}
  for (const [k, v] of Object.entries(req.headers)) {
    if (!['host', 'connection', 'content-length'].includes(k)) headers[k] = v
  }

  let body
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const chunks = []
    for await (const c of req) chunks.push(c)
    body = Buffer.concat(chunks)
  }

  // A real user prompt going out: the warm-up must get out of the way.
  if (req.method === 'POST' && /^\/(api|oc)\/session\/[^/]+\/(prompt|prompt_async|message)$/.test(url.pathname)) {
    const sid = url.pathname.split('/')[3]
    if (sid !== warm.sessionID) {
      userPrompted = true
      if (warm.state === 'running') { warm.cancelled = true; log('warm-up: cancelled, user sent a message') }
    }
  }

  let up
  try {
    up = await fetch(target, { method: req.method, headers, body, redirect: 'manual' })
  } catch (e) {
    return json(res, 502, { error: `cannot reach opencode (${OPENCODE}): ${e.message}` })
  }

  const isSSE = (up.headers.get('content-type') ?? '').includes('text/event-stream')
  const out = {}
  up.headers.forEach((v, k) => {
    if (!['content-encoding', 'content-length', 'transfer-encoding', 'connection'].includes(k)) out[k] = v
  })
  if (isSSE) {
    out['cache-control'] = 'no-cache, no-transform'
    out['x-accel-buffering'] = 'no'
    res.socket?.setNoDelay(true)
    req.socket?.setTimeout(0)
  }
  res.writeHead(up.status, out)

  if (!up.body) return res.end()
  // Pump manually rather than pipe(): with SSE every chunk must flush immediately
  const reader = up.body.getReader()
  const abort = () => reader.cancel().catch(() => {})
  req.on('close', abort)
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      res.write(Buffer.from(value))
    }
  } catch { /* client disconnected */ }
  res.end()
}

/* ---------------- static ---------------- */
async function serveStatic(res, pathname) {
  const rel = normalize(pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, ''))
  if (rel.startsWith('..')) { res.writeHead(403).end('forbidden'); return }
  const file = join(ROOT, rel)
  try {
    const s = await stat(file)
    if (!s.isFile()) throw new Error('not a file')
    const buf = await readFile(file)
    res.writeHead(200, {
      'content-type': MIME[extname(file)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    })
    res.end(buf)
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
    res.end('404')
  }
}

function json(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(JSON.stringify(obj))
}

/* ---------------- server ---------------- */
http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)
  const p = url.pathname
  try {
    if (p === '/fish/status')                          return json(res, 200, await status())
    if (p === '/fish/files' && req.method === 'GET')   return json(res, 200, await listFiles())
    if (p === '/fish/upload' && req.method === 'POST') return await upload(req, res, url)
    if (p === '/fish/open-folder' && req.method === 'POST') { openFolder(); return json(res, 200, { ok: true }) }
    if (p === '/fish/teams' && req.method === 'GET') return json(res, 200, teamsView())
    if (p === '/fish/teams' && req.method === 'POST') {
      const chunks = []
      for await (const c of req) chunks.push(c)
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
      return json(res, 200, await teamsSet(body.enabled !== false))
    }
    if (p === '/fish/logs') {
      const which = url.searchParams.get('which') === 'opencode' ? 'opencode' : 'llama'
      return json(res, 200, { which, text: await tailLog(which) })
    }
    // v1-only endpoints the UI needs; opencode does not expose them under /api.
    if (/^\/fish\/session\/[^/]+$/.test(p) && (req.method === 'DELETE' || req.method === 'PATCH')) {
      const id = p.split('/')[3]
      if (req.method === 'DELETE') await oc('DELETE', `/session/${id}`)
      else {
        const chunks = []
        for await (const c of req) chunks.push(c)
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')
        // Only the title is ours to set; a client must not be able to loosen permissions.
        await oc('PATCH', `/session/${id}`, { title: String(body.title ?? '').slice(0, 120) })
      }
      return json(res, 200, { ok: true })
    }
    if (p.startsWith('/api/') || p.startsWith('/oc/')) return await proxy(req, res, url)
    return await serveStatic(res, p)
  } catch (e) {
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(`internal error: ${e.message}`)
  }
}).listen(PORT, '127.0.0.1', () => {
  log(`Fish.AI  ->  http://127.0.0.1:${PORT}`)
  log(`  opencode : ${OPENCODE}`)
  log(`  llama    : ${LLAMA}`)
  log(`  workspace: ${WORKSPACE}`)
  warmup().catch((e) => { warm.state = 'failed'; warm.error = e.message })
  teamsSet(process.env.FISH_TEAMS_GREEN !== '0').catch((e) => { teams.error = e.message })
})
