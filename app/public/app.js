/* Fish.AI for Elena —— 前端逻辑
 *
 * 和 opencode 的对接要点(踩过的坑,别改回去):
 *   1. token 级增量只在【全局】事件流 /api/event 上,session 级的
 *      /api/session/{id}/event 只给 text.started / text.ended。
 *      所以这里订阅全局流,再按 sessionID 过滤。
 *   2. POST /prompt 是异步的,立刻返回 message id,输出全靠 SSE。
 *   3. 所有 REST 响应都包在 {"data": ...} 里。
 *
 * 结构:渲染(addMessage/ensureTool/recordStat/md) → 事件(connect/handle) → 同步(resync)。
 * 另外三块是这一版加的:状态横幅(引擎启动/预热)、文件面板(拖拽上传)、历史会话。
 */

const $ = (id) => document.getElementById(id)
const api = async (path, body, method) => {
  const r = await fetch(path, {
    method: method || (body !== undefined ? 'POST' : 'GET'),
    headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (!r.ok) throw new Error(`${method || 'GET'} ${path} -> ${r.status} ${await r.text()}`)
  const j = await r.json().catch(() => ({}))
  return j.data !== undefined ? j.data : j
}

const state = {
  sessionID: null,
  busy: false,
  phase: '',          // '' | 'prefill' | 'gen' | 'tool' ——生成中提示用
  turnStart: 0,       // 这一轮开始的时间,生成中提示显示已用秒数
  turnsSent: 0,       // 本页发出的消息数,第一条要提示"冷启动会慢"
  sessionTurns: 0,    // 当前会话里的用户消息数,第一条拿来当会话标题
  ctxWindow: null,
  texts: new Map(),   // textKey -> {el, raw, dirty}
  tools: new Map(),   // callID -> {el, name, argsRaw, input}
  stepStart: null,
  statCount: 0,
  status: null,       // 最近一次 /fish/status
  everUp: false,      // 引擎是否曾经就绪过——区分"还在启动"和"掉线了"
  files: [],
  es: null,          // EventSource,诊断用
  evCount: 0,        // 收到的事件总数
  lastEvent: 0,      // 上一个事件的时间戳,兜底重同步靠它判断"流是不是悄悄断了"
  lastType: '',
}
const PAGE_LOADED = Date.now()

/* ---------------- markdown(小而够用,先转义再渲染) ---------------- */
const esc = (s) => s.replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

function md(src) {
  const blocks = []
  const hold = (html) => `\u0000B${blocks.push(html) - 1}\u0000`
  let s = esc(src)

  // 围栏代码块(未闭合的也算——流式输出时代码块经常还没写完)
  s = s.replace(/```(\w*)[^\n]*\n?([\s\S]*?)(```|$)/g, (_, lang, code) =>
    hold(`<pre><button class="copy" type="button">复制</button><code data-lang="${lang}">${code.replace(/\n$/, '')}</code></pre>`))
  // $$...$$ 数学块:不装作能渲染 LaTeX,原样保留但单独标出来
  s = s.replace(/\$\$([\s\S]*?)\$\$/g, (_, m) => hold(`<div class="math">${m.trim()}</div>`))
  // 行内 code
  s = s.replace(/`([^`\n]+)`/g, (_, c) => hold(`<code>${c}</code>`))

  const lines = s.split('\n')
  const out = []
  let list = null
  let para = []
  let table = null   // {head:[], rows:[][]}

  const flushPara = () => { if (para.length) { out.push(`<p>${inline(para.join(' '))}</p>`); para = [] } }
  const flushList = () => { if (list) { out.push(`</${list}>`); list = null } }
  const flushTable = () => {
    if (!table) return
    const cells = (r, tag) => r.map((c) => `<${tag}>${inline(c)}</${tag}>`).join('')
    out.push(`<div class="tbl"><table><thead><tr>${cells(table.head, 'th')}</tr></thead>` +
             `<tbody>${table.rows.map((r) => `<tr>${cells(r, 'td')}</tr>`).join('')}</tbody></table></div>`)
    table = null
  }
  const flush = () => { flushPara(); flushList(); flushTable() }
  const splitRow = (t) => t.replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim())
  const isRow = (t) => t.startsWith('|') && t.includes('|', 1)
  const isSep = (t) => /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/.test(t)

  const isItem = (t) => /^[-*+]\s+/.test(t) || /^\d+[.)]\s+/.test(t)
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim()
    if (!t) {
      // 空行不应该把列表切成好几个:模型很喜欢在条目之间空一行,
      // 切开的话每个 <ol> 都从 1 开始,看起来就是"1. 1. 1."
      let j = i + 1
      while (j < lines.length && !lines[j].trim()) j++
      if (list && j < lines.length && isItem(lines[j].trim())) { flushPara(); continue }
      flush(); continue
    }

    // 表格:表头行 + 分隔行 + 若干数据行(df.to_markdown() 就是这个格式)
    if (isRow(t) && !table && lines[i + 1] && isSep(lines[i + 1].trim())) {
      flushPara(); flushList()
      table = { head: splitRow(t), rows: [] }
      i++
      continue
    }
    if (table) {
      if (isRow(t)) { table.rows.push(splitRow(t)); continue }
      flushTable()
    }

    let m
    if ((m = t.match(/^(#{1,6})\s+(.*)$/))) {
      flush()
      const lv = Math.min(m[1].length + 2, 6)
      out.push(`<h${lv}>${inline(m[2])}</h${lv}>`)
    } else if (/^([-*_])\1{2,}$/.test(t)) {
      flush(); out.push('<hr>')
    } else if ((m = t.match(/^[-*+]\s+(.*)$/))) {
      flushPara(); flushTable()
      if (list !== 'ul') { flushList(); out.push('<ul>'); list = 'ul' }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if ((m = t.match(/^\d+[.)]\s+(.*)$/))) {
      flushPara(); flushTable()
      if (list !== 'ol') { flushList(); out.push('<ol>'); list = 'ol' }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if (t.startsWith('&gt;')) {
      flush(); out.push(`<blockquote>${inline(t.slice(4).trim())}</blockquote>`)
    } else if (/^\u0000B\d+\u0000$/.test(t)) {
      flush(); out.push(t)
    } else {
      flushList(); flushTable()
      para.push(t)
    }
  }
  flush()

  return out.join('\n').replace(/\u0000B(\d+)\u0000/g, (_, i) => blocks[+i])
}

function inline(s) {
  return s
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|\W)\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/\\\[|\\\]|\\\(|\\\)/g, '')
}

/* ---------------- 消息渲染 ---------------- */
const stream = $('stream')
const atBottom = () => stream.scrollHeight - stream.scrollTop - stream.clientHeight < 120
function scroll(force) { if (force || atBottom()) stream.scrollTop = stream.scrollHeight }

function addMessage(role, html) {
  const wrap = document.createElement('div')
  wrap.className = `msg ${role}`
  wrap.innerHTML = `<div class="who">${role === 'user' ? 'Elena' : 'Fish.AI'}</div>` +
                   `<div class="bubble"></div>`
  wrap.querySelector('.bubble').innerHTML = html
  stream.appendChild(wrap)
  placeThinking()
  scroll(true)
  return wrap.querySelector('.bubble')
}

function addUser(text) {
  const b = addMessage('user', '')
  b.textContent = text          // 用户输入原样显示,不当 markdown 解析
  return b
}

/** key 必须是 assistantMessageID + textID 的组合。
 *  textID 是【每条消息内部】的序号,实测每一轮都是 'text-0' ——
 *  只用它做 key 的话,第二轮的增量会追加进第一轮的气泡,新气泡永远不出现,
 *  表现就是"发了消息没反应"。 */
const textKey = (d) => `${d.assistantMessageID}:${d.textID}`

function ensureText(key) {
  let t = state.texts.get(key)
  if (!t) {
    t = { el: addMessage('assistant', '<span class="cursor"></span>'), raw: '', dirty: false }
    state.texts.set(key, t)
  }
  return t
}

/* 增量渲染合并到一帧:每个 token 都整段重新 md() 的话,长回答后半段会明显卡。 */
let raf = 0
function markDirty(t) {
  t.dirty = true
  if (raf) return
  raf = requestAnimationFrame(() => {
    raf = 0
    for (const t of state.texts.values()) {
      if (!t.dirty) continue
      t.dirty = false
      t.el.innerHTML = md(t.raw) + (t.done ? '' : '<span class="cursor"></span>')
    }
    for (const t of state.tools.values()) {
      if (!t.dirty) continue
      t.dirty = false
      t.el.querySelector('.in').textContent = t.argsRaw
    }
    scroll()
  })
}

/* 代码块复制按钮(事件委托,流式重渲染也不用重新绑定) */
document.addEventListener('click', async (e) => {
  const b = e.target.closest('.copy')
  if (!b) return
  const code = b.parentElement.querySelector('code')?.textContent ?? ''
  try { await navigator.clipboard.writeText(code); b.textContent = '已复制' } catch { b.textContent = '失败' }
  setTimeout(() => { b.textContent = '复制' }, 1200)
})

/* ---------------- 生成中提示 ---------------- */
const thinking = document.createElement('div')
thinking.className = 'thinking'
thinking.innerHTML = '<span class="spin"></span><span class="ttext"></span><span class="sub"></span>'
thinking.style.display = 'none'

function placeThinking() { if (state.busy) stream.appendChild(thinking) }

function renderThinking() {
  if (!state.busy || pendingPerm || pendingQ) { thinking.style.display = 'none'; return }
  thinking.style.display = ''
  const secs = Math.max(0, Math.round((Date.now() - state.turnStart) / 1000))
  const s = state.status
  let main, sub = ''
  if (state.phase === 'gen') {
    main = `生成中 <b>${secs}s</b>`
    if (s?.llama?.tps) sub = `${s.llama.tps.toFixed(1)} tok/s`
  } else if (state.phase === 'tool') {
    main = `执行工具中 <b>${secs}s</b>`
  } else {
    main = `模型正在读取提示 <b>${secs}s</b>`
    const cold = state.turnsSent <= 1 && s?.warm?.state !== 'done'
    if (cold) sub = '首次运行要把模型读进内存,可能需要 1–2 分钟,不是卡住了'
    else if (secs > 20) sub = '上下文越长这一步越久;通常几秒到几十秒'
  }
  thinking.querySelector('.ttext').innerHTML = main
  thinking.querySelector('.sub').textContent = sub
}
setInterval(renderThinking, 1000)

/* ---------------- 工具卡片 ---------------- */
// 这些是文件操作类工具,记进"计算记录"只会淹没真正的计算
const NOISE = new Set(['read', 'write', 'edit', 'glob', 'grep', 'list', 'ls',
                       'todowrite', 'todoread', 'task', 'patch', 'question'])
const TOOL_LABEL = { bash: '运行命令', read: '读取文件', write: '写入文件', edit: '修改文件',
                     glob: '查找文件', grep: '搜索内容', list: '列目录', question: '提问' }

function ensureTool(callID, name) {
  let t = state.tools.get(callID)
  if (t) return t
  const el = document.createElement('details')
  el.className = 'tool'
  el.open = true
  el.innerHTML =
    `<summary><span class="spin"></span><span class="tname"></span><span class="tsum"></span>` +
    `<span class="tstate">执行中…</span></summary>` +
    `<div class="body"><div class="lbl">输入</div><pre class="in"></pre></div>`
  el.querySelector('.tname').textContent = TOOL_LABEL[name] || name || 'tool'
  stream.appendChild(el)
  placeThinking()
  scroll()
  t = { el, name: name || 'tool', argsRaw: '', input: null, dirty: false }
  state.tools.set(callID, t)
  return t
}

function setToolInput(t, input) {
  t.input = input
  const code = pickCode(input)
  t.el.querySelector('.in').textContent = code || JSON.stringify(input, null, 2)
  const sum = t.el.querySelector('.tsum')
  sum.textContent = code ? code.split('\n')[0].slice(0, 90) : (input?.filePath || input?.path || '')
}

function toolDone(callID, ok, payload) {
  const t = state.tools.get(callID)
  if (!t) return
  t.el.querySelector('.spin')?.remove()
  const st = t.el.querySelector('.tstate')
  st.textContent = ok ? '完成' : '失败'
  st.className = `tstate ${ok ? 'ok' : 'bad'}`

  const body = t.el.querySelector('.body')
  const lbl = document.createElement('div')
  lbl.className = 'lbl'
  lbl.textContent = ok ? '输出' : '错误'
  const pre = document.createElement('pre')
  pre.textContent = payload || '(无输出)'
  body.append(lbl, pre)

  if (ok) t.el.open = false
  if (ok && !NOISE.has(t.name)) recordStat(t, payload)
  if (['bash', 'write', 'edit'].includes(t.name)) scheduleFiles()   // 它可能刚生成了文件
  scroll()
}

/** 从工具输入里挑出最值得展示的那一段(bash 的 command、SQL 的 sql,等等) */
function pickCode(input) {
  if (!input || typeof input !== 'object') return null
  for (const k of ['command', 'code', 'sql', 'query', 'script', 'statement']) {
    if (typeof input[k] === 'string' && input[k].trim()) return input[k]
  }
  return null
}

/* ---------------- 右侧:计算记录 ---------------- */
function recordStat(t, output) {
  const box = $('stats')
  if (state.statCount === 0) box.innerHTML = ''
  state.statCount++
  $('stat-count').textContent = state.statCount

  const card = document.createElement('div')
  card.className = 'stat'
  const time = new Date().toLocaleTimeString('zh-CN', { hour12: false })
  card.innerHTML = `<div class="hd"><span class="tag"></span><time></time></div>`
  card.querySelector('.tag').textContent = t.name
  card.querySelector('time').textContent = time

  const code = pickCode(t.input)
  if (code) {
    const p = document.createElement('pre')
    p.style.borderBottom = '1px solid var(--line)'
    p.style.color = 'var(--ink-dim)'
    p.textContent = code.length > 900 ? code.slice(0, 900) + '\n…' : code
    card.appendChild(p)
  }
  const out = document.createElement('pre')
  out.textContent = (output || '').length > 1600 ? output.slice(0, 1600) + '\n…' : (output || '(无输出)')
  card.appendChild(out)

  // 把输出里的数字抽出来做成小标签,方便一眼核对
  const nums = [...new Set((output || '').match(/-?\d+\.?\d*(?:[eE][-+]?\d+)?/g) || [])]
    .filter((n) => n.length > 1 || /\d/.test(n))
    .slice(0, 8)
  if (nums.length) {
    const row = document.createElement('div')
    row.className = 'nums'
    for (const n of nums) {
      const s = document.createElement('span')
      s.className = 'num'
      s.textContent = n
      row.appendChild(s)
    }
    card.appendChild(row)
  }

  box.insertBefore(card, box.firstChild)
}

/* ---------------- 右侧:文件面板 ---------------- */
const ICON = { xlsx: '📊', xls: '📊', csv: '📄', tsv: '📄', json: '🧾', txt: '📝', md: '📝',
               py: '🐍', parquet: '🗜️', sav: '📦', dta: '📦', sas7bdat: '📦', rds: '📦', png: '🖼️', svg: '🖼️' }
const fmtSize = (n) => n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`
const fmtAgo = (ms) => {
  const d = (Date.now() - ms) / 1000
  if (d < 60) return '刚刚'
  if (d < 3600) return `${Math.floor(d / 60)} 分钟前`
  if (d < 86400) return `${Math.floor(d / 3600)} 小时前`
  return new Date(ms).toLocaleDateString('zh-CN')
}

async function loadFiles() {
  try {
    state.files = await api('/fish/files')
  } catch { return }
  const box = $('files')
  box.innerHTML = ''
  $('file-count').textContent = state.files.length
  for (const f of state.files) {
    const el = document.createElement('div')
    el.className = 'file'
    el.title = '点击把文件名填进输入框'
    const ext = f.name.split('.').pop().toLowerCase()
    el.innerHTML = `<span class="ico">${f.dir ? '📁' : (ICON[ext] || '📄')}</span><span class="fn"></span><span class="fm"></span>`
    el.querySelector('.fn').textContent = f.name
    el.querySelector('.fm').textContent = f.dir ? '目录' : `${fmtSize(f.size)} · ${fmtAgo(f.mtime)}`
    el.addEventListener('click', () => insertText(f.name))
    box.appendChild(el)
  }
  renderWelcome()
}
let filesTimer = 0
function scheduleFiles() { clearTimeout(filesTimer); filesTimer = setTimeout(loadFiles, 800) }

function insertText(s) {
  const box = $('input')
  const v = box.value
  box.value = (v && !/\s$/.test(v) ? v + ' ' : v) + s + ' '
  box.focus()
  box.dispatchEvent(new Event('input'))
}

async function uploadFiles(fileList) {
  const files = [...fileList].filter((f) => f.size > 0 || f.type)
  if (!files.length) return
  const prog = $('up-prog')
  const bar = prog.querySelector('i')
  prog.classList.add('on')
  const names = []
  for (let i = 0; i < files.length; i++) {
    const f = files[i]
    try {
      const r = await new Promise((resolve, reject) => {
        const x = new XMLHttpRequest()
        x.open('POST', `/fish/upload?name=${encodeURIComponent(f.name)}`)
        x.upload.onprogress = (e) => {
          if (e.lengthComputable) bar.style.width = `${((i + e.loaded / e.total) / files.length) * 100}%`
        }
        x.onload = () => x.status === 200 ? resolve(JSON.parse(x.responseText)) : reject(new Error(x.responseText || x.status))
        x.onerror = () => reject(new Error('network error'))
        x.send(f)
      })
      names.push(r.name)
    } catch (e) {
      addMessage('assistant', `<p class="err">上传 ${esc(f.name)} 失败:${esc(e.message)}</p>`)
    }
  }
  prog.classList.remove('on')
  bar.style.width = '0'
  await loadFiles()
  if (names.length) {
    activatePane('files')
    // 上传完直接把文件名放进输入框,少一步
    if (!$('input').value.trim()) insertText(names.map((n) => `${n}`).join(' '))
  }
}

// 拖拽:整页都是投放区
let dragDepth = 0
document.addEventListener('dragenter', (e) => {
  if (![...e.dataTransfer?.types || []].includes('Files')) return
  dragDepth++
  $('drop').classList.add('on')
})
document.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('drop').classList.remove('on') } })
document.addEventListener('dragover', (e) => { if ([...e.dataTransfer?.types || []].includes('Files')) e.preventDefault() })
document.addEventListener('drop', (e) => {
  dragDepth = 0
  $('drop').classList.remove('on')
  if (!e.dataTransfer?.files?.length) return
  e.preventDefault()
  uploadFiles(e.dataTransfer.files)
})
$('dropzone').addEventListener('click', () => $('file-input').click())
$('btn-attach').addEventListener('click', () => $('file-input').click())
$('file-input').addEventListener('change', function () { uploadFiles(this.files); this.value = '' })
$('btn-refresh').addEventListener('click', loadFiles)
$('btn-folder').addEventListener('click', () => api('/fish/open-folder', {}).catch(fail))

/* 右侧标签页 */
function activatePane(name) {
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('on', t.dataset.pane === name))
  document.querySelectorAll('.pane').forEach((p) => p.classList.toggle('on', p.id === `pane-${name}`))
}
document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => activatePane(t.dataset.pane)))

/* ---------------- 欢迎卡 ---------------- */
function renderWelcome() {
  const w = $('welcome')
  if (!w) return
  const first = state.files.find((f) => !f.dir && /\.(xlsx|xls|csv|tsv|json|parquet|sav|dta|rds)$/i.test(f.name))
  const chips = first
    ? [`${first.name} 里有什么?`, `${first.name} 各列的基本统计量`, `${first.name} 有没有异常值或缺失值?`, `按某一列分组,比较各组的均值`]
    : ['把数据文件拖进来,先看看里面有什么', '两个样本的均值差异显著吗?该用什么检验?', '解释一下 p 值是什么,不是什么']
  const box = w.querySelector('.chips')
  box.innerHTML = ''
  for (const c of chips) {
    const b = document.createElement('button')
    b.className = 'chip'
    b.textContent = c
    b.addEventListener('click', () => { $('input').value = c; $('input').focus(); $('input').dispatchEvent(new Event('input')) })
    box.appendChild(b)
  }
  w.querySelector('.nofile').style.display = state.files.length ? 'none' : ''
}

function showWelcome() {
  stream.innerHTML =
    `<div class="msg"><div class="bubble welcome" id="welcome">
      <h3>🐟 Fish.AI for Elena</h3>
      <p>问它关于数据文件的问题。每个数字都来自它当场写、当场跑的 Python 代码——不是心算出来的。全程在这台机器上,数据不出门。</p>
      <p class="nofile">先把 Excel / CSV / JSON 文件<b>拖进这个窗口</b>,或点右边的"打开文件夹"放进去。</p>
      <div class="chips"></div>
    </div></div>`
  renderWelcome()
}

/* ---------------- 状态栏 + 横幅 ---------------- */
function banner(kind, text, spin, btn) {
  const b = $('banner')
  if (!kind) { b.className = ''; return }
  b.className = `on ${kind}`
  $('banner-text').textContent = text
  $('banner-spin').style.display = spin ? '' : 'none'
  const bb = $('banner-btn')
  if (btn) { bb.style.display = ''; bb.textContent = btn.label; bb.onclick = btn.onclick } else { bb.style.display = 'none' }
}

let bannerDoneAt = 0
async function refreshStatus() {
  let s
  try { s = await (await fetch('/fish/status')).json() } catch { return }
  state.status = s
  const up = s.llama.up && s.opencode.up
  if (s.llama.model) $('v-model').textContent = s.llama.model.replace(/\.gguf$/i, '').replace(/-UD-.*$/, '').replace(/-Q\d.*$/, '')
  if (s.llama.ctx) state.ctxWindow = s.llama.ctx
  if (s.workspace) $('ws-path').textContent = s.workspace
  // llama's gauge is live: non-zero only while generating. Remember the last reading
  // so the pill keeps showing it after the turn ends.
  if (s.llama.tps) { state.tpsLive = s.llama.tps; $('v-tps').textContent = s.llama.tps.toFixed(1) }

  const dot = $('d-engine'), lbl = $('v-engine')
  const showLog = (which) => ({ label: '看日志', onclick: () => showLogs(which) })
  const secs = Math.round((Date.now() - PAGE_LOADED) / 1000)

  if (!up) {
    dot.className = 'dot down'
    if (state.everUp) {
      lbl.textContent = s.llama.up ? 'agent 掉线' : '推理掉线'
      banner('bad', `${s.llama.up ? 'agent 运行时' : '推理引擎'}没有响应。在启动它的终端里看看有没有报错;通常需要重新运行 start.ps1。`, false, showLog(s.llama.up ? 'opencode' : 'llama'))
    } else {
      lbl.textContent = '启动中'
      const what = !s.llama.up ? '推理引擎正在把模型读进显存' : 'agent 运行时正在启动'
      banner(secs > 150 ? 'warn' : '', `${what}…已 ${secs}s。${secs > 150 ? '有点久了,看看启动终端有没有报错。' : '35B 模型通常需要 20–60 秒。'}`, true, secs > 60 ? showLog('llama') : null)
    }
    $('send').disabled = true
    return
  }
  state.everUp = true
  if (!state.busy) $('send').disabled = false

  const w = s.warm || {}
  if (w.state === 'running' || w.state === 'waiting' || w.state === 'pending') {
    dot.className = 'dot busy'
    lbl.textContent = '预热中'
    const ws = w.startedAt ? Math.round((Date.now() - w.startedAt) / 1000) : 0
    banner('', `正在预热模型(已 ${ws}s)——预热完首条消息就不用等两分钟。可以先把问题打好,也可以直接发,发了会打断预热。`, true)
  } else {
    dot.className = s.llama.processing ? 'dot busy' : 'dot up'
    lbl.textContent = s.llama.processing ? '计算中' : '就绪'
    if (w.state === 'done') {
      if (!bannerDoneAt) bannerDoneAt = Date.now()
      // 只在刚预热完的那几秒提示一下;刷新页面时预热早已结束,就别再报一遍了
      if (Date.now() - bannerDoneAt < 8000 && w.endedAt && Date.now() - w.endedAt < 60000) {
        const secsW = w.endedAt && w.startedAt ? Math.round((w.endedAt - w.startedAt) / 1000) : null
        banner('ok', `模型已预热${secsW ? `(用了 ${secsW}s)` : ''}${w.promptTokens ? `,${(w.promptTokens / 1000).toFixed(1)}k token 的系统提示已缓存` : ''}。现在可以问了。`, false)
      } else banner(null)
    } else if (w.state === 'failed' || w.state === 'timeout') {
      if (!bannerDoneAt) bannerDoneAt = Date.now()
      if (Date.now() - bannerDoneAt < 20000) banner('warn', `预热没有成功(${w.error || w.state}),首条消息会慢一些,之后正常。`, false)
      else banner(null)
    } else banner(null)   // skipped / cancelled:用户已经在用了,不打扰
  }
}

async function showLogs(which) {
  $('log-title').textContent = which === 'opencode' ? 'agent 运行时日志 (opencode)' : '推理引擎日志 (llama-server)'
  $('log-body').textContent = '读取中…'
  $('log-mask').classList.add('on')
  try {
    const r = await api(`/fish/logs?which=${which}`)
    $('log-body').textContent = r.text || '(日志为空——如果是用 start.ps1 启动的,日志在 logs\\ 目录下)'
  } catch (e) { $('log-body').textContent = e.message }
}
$('log-close').addEventListener('click', () => $('log-mask').classList.remove('on'))

function updateCtx(inputTokens) {
  if (!state.ctxWindow || !inputTokens) return
  const pct = Math.min(100, (inputTokens / state.ctxWindow) * 100)
  const bar = $('v-ctxbar')
  bar.style.width = pct + '%'
  bar.className = pct > 85 ? 'bad' : pct > 65 ? 'warn' : ''
  $('v-ctx').textContent = `${(inputTokens / 1000).toFixed(1)}k`
  $('hint-ctx').textContent = pct > 65
    ? `上下文已用 ${pct.toFixed(0)}% —— 接近上限时 tool calling 会静默失效,建议开新会话`
    : ''
}

/* ---------------- 权限弹窗 ---------------- */
let pendingPerm = null
function askPermission(d) {
  pendingPerm = d
  $('perm-title').textContent = `agent 请求:${TOOL_LABEL[d.action] || d.action || '执行操作'}`
  $('perm-action').textContent = (d.resources || []).length
    ? `涉及:${d.resources.join('、')}`
    : '没有声明具体资源。'
  // metadata 经常是空的。真正要给用户看的命令在对应的工具调用里,
  // 通过 source.callID 回查 —— 弹窗不显示将要执行什么就失去了意义。
  const meta = d.metadata || {}
  const tool = d.source?.callID ? state.tools.get(d.source.callID) : null
  const shown =
    pickCode(meta) ||
    (tool && (pickCode(tool.input) || tool.argsRaw)) ||
    (d.resources || []).join('\n') ||
    stringify(meta)
  $('perm-body').textContent = shown && shown !== '{}' ? shown : '(agent 没有说明细节,谨慎批准)'
  $('perm-mask').classList.add('on')
  renderThinking()
}

async function replyPermission(reply) {
  const d = pendingPerm
  $('perm-mask').classList.remove('on')
  pendingPerm = null
  if (!d) return
  state.lastEvent = Date.now()
  try {
    await api(`/api/session/${d.sessionID}/permission/${d.id}/reply`, { reply })
  } catch (e) {
    addMessage('assistant', `<p class="err">权限回复失败:${esc(e.message)}</p>`)
  }
}

document.querySelectorAll('[data-reply]').forEach((b) =>
  b.addEventListener('click', () => replyPermission(b.dataset.reply)))

/* ---------------- agent 提问(question) ----------------
 * 和 permission 是两套独立机制,别混。permission 是"我要执行这个命令,批不批";
 * question 是"我需要你做个选择才能继续"。只做 permission 不做 question 的话,
 * agent 一提问就永久卡住,而界面上什么都不显示 —— 这个坑踩过。
 * 回复格式:{ answers: [ ["选中的label", ...], ... ] },每个问题一个数组。 */
let pendingQ = null

function askQuestion(d) {
  pendingQ = d
  const qs = d.questions || []
  $('q-header').textContent = qs[0]?.header || 'agent 有问题要问你'
  const body = $('q-body')
  body.innerHTML = ''

  qs.forEach((q, qi) => {
    const block = document.createElement('div')
    block.className = 'qblock'

    const t = document.createElement('div')
    t.className = 'qtext'
    t.textContent = q.question || `问题 ${qi + 1}`
    block.appendChild(t)

    const opts = document.createElement('div')
    opts.className = 'qopts'
    ;(q.options || []).forEach((o) => {
      const lab = document.createElement('label')
      lab.className = 'qopt'
      const inp = document.createElement('input')
      inp.type = q.multiple ? 'checkbox' : 'radio'
      inp.name = `q${qi}`
      inp.value = o.label
      inp.addEventListener('change', () => {
        // 单选时把同组其他项的高亮清掉
        if (!q.multiple) opts.querySelectorAll('.qopt').forEach((e) => e.classList.remove('sel'))
        lab.classList.toggle('sel', inp.checked)
      })
      const txt = document.createElement('div')
      txt.innerHTML = `<div class="lb"></div>${o.description ? '<div class="ds"></div>' : ''}`
      txt.querySelector('.lb').textContent = o.label
      if (o.description) txt.querySelector('.ds').textContent = o.description
      lab.append(inp, txt)
      opts.appendChild(lab)
    })
    block.appendChild(opts)

    // 选项之外总留一个自由输入 —— 模型给的选项经常不全
    const free = document.createElement('div')
    free.className = 'qfree'
    free.innerHTML = '<input type="text" placeholder="或者直接写(选项不够用时)">'
    block.appendChild(free)

    const hint = document.createElement('div')
    hint.className = 'qhint'
    hint.textContent = q.multiple ? '可多选' : '单选'
    block.appendChild(hint)

    body.appendChild(block)
  })

  $('q-mask').classList.add('on')
  renderThinking()
}

async function replyQuestion(reject) {
  const d = pendingQ
  $('q-mask').classList.remove('on')
  pendingQ = null
  if (!d) return

  try {
    if (reject) {
      await api(`/api/session/${d.sessionID}/question/${d.id}/reject`, {})
      return
    }
    const answers = [...$('q-body').querySelectorAll('.qblock')].map((block) => {
      const picked = [...block.querySelectorAll('input[type=checkbox],input[type=radio]')]
        .filter((i) => i.checked).map((i) => i.value)
      const free = block.querySelector('.qfree input')?.value.trim()
      if (free) picked.push(free)
      return picked
    })
    await api(`/api/session/${d.sessionID}/question/${d.id}/reply`, { answers })
    setBusy(true)          // 回答完 agent 会接着跑
    state.lastEvent = Date.now()
  } catch (e) {
    fail(e)
  }
}

$('q-submit').addEventListener('click', () => replyQuestion(false))
$('q-reject').addEventListener('click', () => replyQuestion(true))

/* ---------------- 从服务端重建整个视图 ----------------
 * 这一个函数同时解决三个问题,它们的根子是同一个:浏览器不该是状态的唯一持有者。
 *   1. 刷新页面丢历史        —— 重新拉 /message 重建
 *   2. 挂起的权限请求变孤儿  —— 重新拉 /permission 重新弹窗
 *   3. SSE 断线期间漏事件    —— 重连后再跑一次,缺的内容补回来
 * opencode 服务端本来就存着全部状态,拉回来比在前端补事件可靠得多。 */
async function resync() {
  if (!state.sessionID) return
  let msgs, perms, questions
  try {
    msgs = await api(`/api/session/${state.sessionID}/message`)
    perms = await api(`/api/session/${state.sessionID}/permission`).catch(() => [])
    questions = await api(`/api/session/${state.sessionID}/question`).catch(() => [])
  } catch (e) { return fail(e) }

  stream.innerHTML = ''
  state.texts.clear()
  state.tools.clear()

  const list = (msgs || []).slice().sort(
    (a, b) => (a.time?.created ?? 0) - (b.time?.created ?? 0))

  state.sessionTurns = list.filter((m) => (m.role ?? m.type) === 'user').length
  if (!list.length) showWelcome()

  // 刷新后必须把"这一轮还没跑完"这件事也恢复出来。
  // 只恢复视图不恢复 busy 的话:发送按钮是可点的(可以插一条把会话搅乱),
  // 而且那个"25 秒没事件就重同步"的兜底第一行就是 if (!busy) return,永远不会触发。
  let inflight = false
  for (const m of list) {
    for (const p of (m.content ?? m.parts ?? [])) {
      if (p.type === 'tool' && ['pending', 'running'].includes(p.state?.status)) inflight = true
    }
  }
  const lastAssistant = [...list].reverse().find((m) => (m.role ?? m.type) === 'assistant')
  // finish 带 tool 说明后面还有步骤;完全没有 finish 说明这条消息还在生成中
  if (lastAssistant && (!lastAssistant.finish || /tool/i.test(String(lastAssistant.finish)))) {
    inflight = true
  }

  for (const m of list) {
    const role = m.role ?? m.type          // 运行时用 type,schema 里叫 role,两个都认
    if (role === 'user') {
      const text = m.text ?? contentText(m.content)
      if (text) addUser(text)
      continue
    }
    for (const part of (m.content ?? m.parts ?? [])) {
      if (part.type === 'text' && part.text) {
        addMessage('assistant', md(part.text))
      } else if (part.type === 'tool') {
        restoreTool(part)
      }
      // reasoning / step-start / step-finish / snapshot 等不渲染
    }
    if (m.error) {
      addMessage('assistant',
        `<p class="err">出错:${esc(m.error.message || m.error.name || '未知错误')}</p>`)
    }
  }

  // 重连/刷新后可能有还挂着的权限请求或提问 —— 不重新弹的话 agent 会永远等下去。
  //
  // !! 但绝不能重建【用户正在填】的那个弹窗。askQuestion() 会把选项重新渲染一遍,
  //    已经勾上的全没了,提交上去就是空数组,agent 收到 "Unanswered" 又问一遍。
  //    这个 bug 真实发生过:兜底定时器 25 秒触发一次 resync,把用户勾了一半的答案清空。
  const asArr = (x) => (Array.isArray(x) ? x : x ? [x] : [])
  const pendingP = asArr(perms)
  const pendingQs = asArr(questions)

  if (pendingP.length) {
    if (!pendingPerm || pendingPerm.id !== pendingP[0].id) askPermission(pendingP[0])
    inflight = true
  }
  if (pendingQs.length) {
    if (!pendingQ || pendingQ.id !== pendingQs[0].id) askQuestion(pendingQs[0])
    inflight = true
  }

  if (inflight && !state.busy) { state.turnStart = Date.now(); state.phase = 'prefill' }
  setBusy(inflight)
  if (inflight) state.lastEvent = Date.now()   // 给兜底计时器一个起点
  scroll(true)
}

/** 用历史里的 ToolPart 重建一张工具卡片(状态机见 ToolState:pending/running/completed/error) */
function restoreTool(part) {
  // 历史里的 ToolPart 和事件流里的字段名不一样:id 而不是 callID,name 而不是 tool,
  // error 是 {type,message} 对象而不是字符串。两套都认。
  const callID = part.callID ?? part.id
  const name = part.tool ?? part.name
  const t = ensureTool(callID, name)
  t.name = name || t.name
  t.el.querySelector('.tname').textContent = TOOL_LABEL[t.name] || t.name
  if (part.state?.input) setToolInput(t, part.state.input)
  else t.el.querySelector('.in').textContent = part.state?.raw || ''
  const st = part.state?.status
  const s = part.state ?? {}
  if (st === 'completed') {
    toolDone(callID, true, typeof s.output === 'string' ? s.output : (contentText(s.content) || stringify(s.structured) || stringify(s.result?.value)))
  } else if (st === 'error') {
    const e = s.error
    toolDone(callID, false, typeof e === 'string' ? e : (e?.message || e?.name || stringify(e) || stringify(s.result?.value)))
  }
}

/* ---------------- 事件流 ---------------- */
function connect() {
  const es = new EventSource('/api/event')
  state.es = es                       // 挂到 state 上,出问题时能在控制台查 readyState
  let wasOpen = false

  es.onopen = () => {
    // 首次连上不用补;是【重连】才补,因为断开期间的事件已经错过了
    if (wasOpen) resync()
    wasOpen = true
  }
  es.onmessage = (m) => {
    state.evCount++
    state.lastEvent = Date.now()
    let ev
    try { ev = JSON.parse(m.data) } catch { return }
    const d = ev.data || {}
    state.lastType = ev.type
    // 全局流会带上所有会话,只处理当前这个
    if (d.sessionID && state.sessionID && d.sessionID !== state.sessionID) return
    handle(ev.type, d)
  }
  es.onerror = () => { /* EventSource 自己会重连,重连后 onopen 里 resync */ }

  // 兜底:正在生成却超过 25 秒一个事件都没有,说明流悄悄断了(浏览器不一定报错)。
  // 直接从服务端重新拉状态,而不是干等 —— 这类"卡住"靠猜是查不出来的。
  // 例外:prefill 阶段本来就没有事件(模型在读提示,几十秒很正常),这时看 llama 是否在算。
  setInterval(() => {
    if (!state.busy) return
    // 弹窗开着的时候,卡住的是人不是流 —— 没有事件是正常的,别白跑
    if (pendingQ || pendingPerm) return
    if (Date.now() - state.lastEvent < 25000) return
    if (state.status?.llama?.processing) return
    state.lastEvent = Date.now()
    resync()
  }, 5000)

  // 切回标签页时也补一次:后台标签页的 SSE 常被浏览器节流
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) resync()
  })
}

function handle(type, d) {
  switch (type) {
    case 'session.next.step.started':
      state.stepStart = d.timestamp
      state.tpsLive = 0
      if (!state.busy) state.turnStart = Date.now()
      state.phase = 'prefill'
      setBusy(true)
      break

    case 'session.next.text.started':
      ensureText(textKey(d))
      state.phase = 'gen'
      break

    case 'session.next.text.delta': {
      const t = ensureText(textKey(d))
      t.raw += d.delta
      state.phase = 'gen'
      markDirty(t)
      break
    }

    case 'session.next.text.ended': {
      const t = ensureText(textKey(d))
      t.raw = d.text ?? t.raw
      t.done = true
      markDirty(t)
      break
    }

    case 'session.next.tool.input.started':
      ensureTool(d.callID, d.name)
      state.phase = 'gen'
      break

    case 'session.next.tool.input.delta': {
      const t = ensureTool(d.callID)
      t.argsRaw += d.delta
      t.dirty = true
      markDirty(t)
      break
    }

    case 'session.next.tool.called': {
      const t = ensureTool(d.callID, d.tool)
      t.name = d.tool || t.name
      t.el.querySelector('.tname').textContent = TOOL_LABEL[t.name] || t.name
      setToolInput(t, d.input)
      state.phase = 'tool'
      scroll()
      break
    }

    case 'session.next.tool.success':
      toolDone(d.callID, true, contentText(d.content) || stringify(d.structured))
      state.phase = 'prefill'
      break

    case 'session.next.tool.failed':
      toolDone(d.callID, false, (d.error && (d.error.message || d.error.name)) || stringify(d.error))
      state.phase = 'prefill'
      break

    case 'session.next.step.ended': {
      const out = d.tokens?.output ?? 0
      // llama 自己的 tok/s 更准(状态栏那个);这里只在这一轮没采到时兜底
      if (!state.tpsLive && state.stepStart && out > 0) {
        const secs = (d.timestamp - state.stepStart) / 1000
        if (secs > 0.4) $('v-tps').textContent = (out / secs).toFixed(1)
      }
      // 命中前缀缓存的 token 不计入 input,但它们照样占着上下文窗口
      updateCtx((d.tokens?.input ?? 0) + (d.tokens?.cache?.read ?? 0))

      // 解锁必须靠这里,不能只等 session.idle —— 实测 /api/event 上
      // 根本不发 session.idle,只发 step.ended。只监听 idle 的话按钮会
      // 永远停在"生成中",第二轮消息发不出去(表现就是"没法连续交互")。
      // finish 里带 tool 说明还要接着跑工具,那轮还没完,保持 busy。
      if (!/tool/i.test(String(d.finish ?? ''))) {
        setBusy(false)
        document.querySelectorAll('.cursor').forEach((c) => c.remove())
      }
      break
    }

    case 'session.idle':
      setBusy(false)
      document.querySelectorAll('.cursor').forEach((c) => c.remove())
      break

    case 'permission.asked':
    case 'permission.v2.asked':
      askPermission(d)
      break

    case 'permission.replied':
    case 'permission.v2.replied':
      $('perm-mask').classList.remove('on')
      pendingPerm = null
      break

    case 'question.asked':
    case 'question.v2.asked':
      askQuestion(d)
      break

    case 'question.replied':
    case 'question.v2.replied':
    case 'question.rejected':
    case 'question.v2.rejected':
      $('q-mask').classList.remove('on')
      pendingQ = null
      break

    // agent 侧出错。不显示的话界面就是一片空白,你只会看到"没反应"
    case 'session.error':
    case 'session.next.error': {
      const e = d.error ?? d
      addMessage('assistant',
        `<p class="err">agent 出错:${esc(e.message || e.name || stringify(e) || '未知错误')}</p>`)
      setBusy(false)
      break
    }
  }
}

const stringify = (o) => {
  if (o == null) return ''
  if (typeof o === 'string') return o
  try { const s = JSON.stringify(o, null, 2); return s === '{}' ? '' : s } catch { return String(o) }
}

/** tool.success 的 content 是 [{type:'text',text}|{type:'file',...}] */
function contentText(content) {
  if (!Array.isArray(content)) return ''
  return content.map((c) => (c && c.type === 'text' ? c.text : `[${c?.type || '?'}]`))
                .filter(Boolean).join('\n').trim()
}

/* ---------------- 发送 / 会话 ---------------- */
function setBusy(b) {
  state.busy = b
  $('send').disabled = b || !(state.status?.llama?.up && state.status?.opencode?.up)
  $('send').textContent = b ? '生成中' : '发送'
  $('btn-stop').style.display = b ? '' : 'none'
  if (b) placeThinking()
  renderThinking()
}

const LAST_SESSION = 'fish.lastSession'

async function newSession(silent) {
  // 旧会话还在生成的话先掐掉:换了 sessionID 之后它的事件会被过滤掉,
  // 不主动收尾的话发送按钮会永远卡在"生成中",而且它还在后台烧 token。
  if (state.sessionID && state.busy) {
    try { await api(`/api/session/${state.sessionID}/interrupt`, {}) } catch { /* 已经结束了 */ }
  }
  const s = await api('/api/session', {})
  state.sessionID = s.id
  try { localStorage.setItem(LAST_SESSION, s.id) } catch { /* 隐私模式 */ }
  state.texts.clear()
  state.tools.clear()
  state.sessionTurns = 0
  setBusy(false)
  if (!silent) {
    showWelcome()
    $('v-ctxbar').style.width = '0'
    $('v-ctx').textContent = '—'
    $('hint-ctx').textContent = ''
    $('input').focus()
  }
}

async function send() {
  const box = $('input')
  const text = box.value.trim()
  if (!text || state.busy) return
  if (!state.sessionID) { try { await newSession(true) } catch (e) { return fail(e) } }

  $('welcome')?.parentElement.remove()
  addUser(text)
  box.value = ''
  box.style.height = 'auto'
  state.turnsSent++
  // 本地小模型不会给会话起标题(opencode 默认留 "New session - 日期"),
  // 用第一条消息当标题,历史列表里才认得出来
  if (state.sessionTurns === 0) {
    api(`/fish/session/${state.sessionID}`, { title: text.replace(/\s+/g, ' ').slice(0, 60) }, 'PATCH').catch(() => {})
  }
  state.sessionTurns++
  state.turnStart = Date.now()
  state.phase = 'prefill'
  setBusy(true)
  try {
    await api(`/api/session/${state.sessionID}/prompt`, { prompt: { text } })
  } catch (e) { setBusy(false); fail(e) }
}

const fail = (e) =>
  addMessage('assistant', `<p class="err">出错:${esc(e.message)}</p>`)

$('send').addEventListener('click', send)
$('input').addEventListener('keydown', (e) => {
  if ((e.key === 'Enter' || e.keyCode === 13) && !e.shiftKey && !e.isComposing) { e.preventDefault(); send() }
})
$('input').addEventListener('input', function () {
  this.style.height = 'auto'
  this.style.height = Math.min(this.scrollHeight, 190) + 'px'
})
$('btn-new').addEventListener('click', () => newSession(false).catch(fail))
$('btn-stop').addEventListener('click', async () => {
  try { await api(`/api/session/${state.sessionID}/interrupt`, {}) } catch (e) { fail(e) }
  setBusy(false)
})

/* ---------------- 历史会话 ---------------- */
async function showHistory() {
  $('hist-mask').classList.add('on')
  const body = $('hist-body')
  body.innerHTML = '<div class="empty">加载中…</div>'
  let list
  try {
    const dir = state.status?.workspace
    const r = await api(`/api/session?limit=40${dir ? `&directory=${encodeURIComponent(dir)}` : ''}`)
    list = (Array.isArray(r) ? r : r.items || []).filter((s) => !dir || !s.location?.directory || s.location.directory === dir)
  } catch (e) { body.innerHTML = `<p class="err">${esc(e.message)}</p>`; return }
  body.innerHTML = ''
  if (!list.length) { body.innerHTML = '<div class="empty">还没有历史会话</div>'; return }
  list.sort((a, b) => (b.time?.updated ?? 0) - (a.time?.updated ?? 0))
  for (const s of list) {
    const el = document.createElement('div')
    el.className = `sess${s.id === state.sessionID ? ' cur' : ''}`
    el.innerHTML = `<span class="st"></span><span class="sm"></span><button class="del" title="删除这个会话">🗑</button>`
    el.querySelector('.st').textContent = (s.title || '').replace(/^New session - .*/, '') ||
      `会话 ${new Date(s.time?.created ?? 0).toLocaleString('zh-CN', { hour12: false })}`
    el.querySelector('.sm').textContent = fmtAgo(s.time?.updated ?? s.time?.created ?? 0)
    el.addEventListener('click', async () => {
      $('hist-mask').classList.remove('on')
      if (s.id === state.sessionID) return
      if (state.busy) { try { await api(`/api/session/${state.sessionID}/interrupt`, {}) } catch { /* ok */ } }
      state.sessionID = s.id
      try { localStorage.setItem(LAST_SESSION, s.id) } catch { /* ok */ }
      setBusy(false)
      await resync()
    })
    el.querySelector('.del').addEventListener('click', async (e) => {
      e.stopPropagation()
      if (!confirm(`删除会话"${el.querySelector('.st').textContent}"?`)) return
      try {
        await api(`/fish/session/${s.id}`, undefined, 'DELETE')
        el.remove()
        if (s.id === state.sessionID) await newSession(false)
      } catch (err) { fail(err) }
    })
    body.appendChild(el)
  }
}
$('btn-hist').addEventListener('click', () => showHistory().catch(fail))
$('hist-close').addEventListener('click', () => $('hist-mask').classList.remove('on'))
document.querySelectorAll('.mask').forEach((m) => m.addEventListener('click', (e) => {
  // 点空白处关掉信息类弹窗;权限和提问必须明确作答,不给误触的机会
  if (e.target === m && (m.id === 'hist-mask' || m.id === 'log-mask')) m.classList.remove('on')
}))

/* ---------------- 启动 ---------------- */
;(async () => {
  showWelcome()
  await refreshStatus()
  setInterval(refreshStatus, 2500)
  loadFiles()
  setInterval(loadFiles, 20000)

  // 优先接回上次的会话 —— 刷新页面不该丢掉对话,也不该把挂起的权限请求丢成孤儿。
  // 会话在 opencode 服务端是持久的,这里只是把 id 记在本地。
  let restored = false
  try {
    const last = localStorage.getItem(LAST_SESSION)
    if (last) {
      await api(`/api/session/${last}`)   // 不存在会抛,落到下面新建
      state.sessionID = last
      restored = true
    }
  } catch { /* 会话没了,新建 */ }

  if (!restored) {
    try { await newSession(true) } catch (e) { return fail(e) }
  }

  connect()
  if (restored) await resync()
})()
