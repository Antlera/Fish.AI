// Fish.AI - serves the web UI and reverse-proxies the opencode API.
//
// Why this layer exists instead of letting the browser talk to :4096 directly:
//   1. Same-origin: no CORS, no cross-origin EventSource problems
//   2. The status bar polls two backends (llama-server :8080 and opencode :4096);
//      the frontend should not need to know either address
//   3. SSE must be forwarded chunk by chunk - every layer of buffering is disabled below
import http from 'node:http'
import { Readable } from 'node:stream'
import { readFile, stat } from 'node:fs/promises'
import { join, extname, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT     = fileURLToPath(new URL('./public/', import.meta.url))
const PORT     = Number(process.env.FISH_PORT ?? 8090)
const OPENCODE = process.env.OPENCODE_URL ?? 'http://127.0.0.1:4096'
const LLAMA    = process.env.LLAMA_URL    ?? 'http://127.0.0.1:8080'

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',   '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',             '.png': 'image/png', '.ico': 'image/x-icon',
}

/** Status bar: fetch both backends' health at once; one being down must not hide the other. */
async function status() {
  const out = { llama: { up: false }, opencode: { up: false } }
  await Promise.all([
    (async () => {
      const h = await fetch(`${LLAMA}/health`, { signal: AbortSignal.timeout(2500) })
      if (!h.ok) return
      out.llama.up = true
      try {
        const p = await (await fetch(`${LLAMA}/props`, { signal: AbortSignal.timeout(2500) })).json()
        const g = p.default_generation_settings ?? {}
        out.llama.ctx   = g.n_ctx ?? p.n_ctx ?? null
        out.llama.model = (p.model_path ?? '').split(/[\\/]/).pop() || null
      } catch { /* /props being unreadable must not flip the up flag */ }
    })().catch(() => {}),
    (async () => {
      const r = await fetch(`${OPENCODE}/api/health`, { signal: AbortSignal.timeout(2500) })
      out.opencode.up = r.ok
    })().catch(() => {}),
  ])
  return out
}

/** Forward /api/* to opencode verbatim. SSE is streamed through without buffering. */
async function proxy(req, res, url) {
  const target = OPENCODE + url.pathname + url.search
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

  let up
  try {
    up = await fetch(target, { method: req.method, headers, body, redirect: 'manual' })
  } catch (e) {
    res.writeHead(502, { 'content-type': 'application/json; charset=utf-8' })
    return res.end(JSON.stringify({ error: `cannot reach opencode (${OPENCODE}): ${e.message}` }))
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

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`)
  try {
    if (url.pathname === '/fish/status') {
      res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      return res.end(JSON.stringify(await status()))
    }
    if (url.pathname.startsWith('/api/')) return await proxy(req, res, url)
    return await serveStatic(res, url.pathname)
  } catch (e) {
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(`internal error: ${e.message}`)
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Fish.AI for Elena  ->  http://127.0.0.1:${PORT}`)
  console.log(`  opencode: ${OPENCODE}`)
  console.log(`  llama   : ${LLAMA}`)
})
