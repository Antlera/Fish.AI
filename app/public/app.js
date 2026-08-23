/* Fish.AI for Elena —— 前端逻辑
 *
 * 和 opencode 的对接要点(踩过的坑,别改回去):
 *   1. token 级增量只在【全局】事件流 /api/event 上,session 级的
 *      /api/session/{id}/event 只给 text.started / text.ended。
 *      所以这里订阅全局流,再按 sessionID 过滤。
 *   2. POST /prompt 是异步的,立刻返回 message id,输出全靠 SSE。
 *   3. 所有 REST 响应都包在 {"data": ...} 里。
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
  ctxWindow: null,
  texts: new Map(),   // textID -> {el, raw}
  tools: new Map(),   // callID -> {el, name, argsRaw, input, bodyEl}
  stepStart: null,
  statCount: 0,
  es: null,          // EventSource,诊断用
  evCount: 0,        // 收到的事件总数
  lastEvent: 0,      // 上一个事件的时间戳,兜底重同步靠它判断"流是不是悄悄断了"
  lastType: '',
}

/* ---------------- markdown(小而够用,先转义再渲染) ---------------- */
const esc = (s) => s.replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

function md(src) {
  const blocks = []
  let s = esc(src)

  // 围栏代码块
  s = s.replace(/```(\w*)\n?([\s\S]*?)```/g, (_, lang, code) =>
    `\u0000B${blocks.push(`<pre><code data-lang="${lang}">${code.replace(/\n$/, '')}</code></pre>`) - 1}\u0000`)
  // $$...$$ 数学块:不装作能渲染 LaTeX,原样保留但单独标出来
  s = s.replace(/\$\$([\s\S]*?)\$\$/g, (_, m) =>
    `\u0000B${blocks.push(`<div class="math">${m.trim()}</div>`) - 1}\u0000`)
  // 行内 code
  s = s.replace(/`([^`\n]+)`/g, (_, c) => `\u0000B${blocks.push(`<code>${c}</code>`) - 1}\u0000`)

  const lines = s.split('\n')
  const out = []
  let list = null

  const flush = () => { if (list) { out.push(`</${list}>`); list = null } }

  for (const line of lines) {
    const t = line.trim()
    if (!t) { flush(); continue }

    let m
    if ((m = t.match(/^(#{1,6})\s+(.*)$/))) {
      flush()
      const lv = Math.min(m[1].length + 2, 6)
      out.push(`<h${lv}>${inline(m[2])}</h${lv}>`)
    } else if (/^([-*_])\1{2,}$/.test(t)) {
      flush(); out.push('<hr>')
    } else if ((m = t.match(/^[-*+]\s+(.*)$/))) {
      if (list !== 'ul') { flush(); out.push('<ul>'); list = 'ul' }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if ((m = t.match(/^\d+[.)]\s+(.*)$/))) {
      if (list !== 'ol') { flush(); out.push('<ol>'); list = 'ol' }
      out.push(`<li>${inline(m[1])}</li>`)
    } else if (t.startsWith('&gt;')) {
      flush(); out.push(`<p style="border-left:3px solid var(--line);padding-left:10px;color:var(--ink-dim)">${inline(t.slice(4).trim())}</p>`)
    } else if (/^\u0000B\d+\u0000$/.test(t)) {
      flush(); out.push(t)
    } else {
      flush(); out.push(`<p>${inline(t)}</p>`)
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
  scroll(true)
  return wrap.querySelector('.bubble')
}

/** key 必须是 assistantMessageID + textID 的组合。
 *  textID 是【每条消息内部】的序号,实测每一轮都是 'text-0' ——
 *  只用它做 key 的话,第二轮的增量会追加进第一轮的气泡,新气泡永远不出现,
 *  表现就是"发了消息没反应"。 */
const textKey = (d) => `${d.assistantMessageID}:${d.textID}`

function ensureText(key) {
  let t = state.texts.get(key)
  if (!t) {
    t = { el: addMessage('assistant', '<span class="cursor"></span>'), raw: '' }
    state.texts.set(key, t)
  }
  return t
}

/* ---------------- 工具卡片 ---------------- */
// 这些是文件操作类工具,记进"计算记录"只会淹没真正的计算
const NOISE = new Set(['read', 'write', 'edit', 'glob', 'grep', 'list', 'ls',
                       'todowrite', 'todoread', 'task', 'patch'])

function ensureTool(callID, name) {
  let t = state.tools.get(callID)
  if (t) return t
  const el = document.createElement('details')
  el.className = 'tool'
  el.open = true
  el.innerHTML =
    `<summary><span class="spin"></span><span class="tname"></span>` +
    `<span class="tstate">执行中…</span></summary>` +
    `<div class="body"><div class="lbl">输入</div><pre class="in"></pre></div>`
  el.querySelector('.tname').textContent = name || 'tool'
  stream.appendChild(el)
  scroll()
  t = { el, name: name || 'tool', argsRaw: '', input: null }
  state.tools.set(callID, t)
  return t
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

/* ---------------- 右侧统计面板 ---------------- */
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

/* ---------------- 状态栏 ---------------- */
async function refreshStatus() {
  try {
    const s = await (await fetch('/fish/status')).json()
    $('d-llama').className = `dot ${s.llama.up ? 'up' : 'down'}`
    $('d-oc').className = `dot ${s.opencode.up ? 'up' : 'down'}`
    if (s.llama.model) {
      $('v-model').textContent = s.llama.model.replace(/\.gguf$/i, '').replace(/-UD-.*$/, '')
    }
    if (s.llama.ctx) state.ctxWindow = s.llama.ctx
  } catch { /* 状态栏坏了不影响对话 */ }
}

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
  $('perm-title').textContent = `agent 请求:${d.action || '执行操作'}`
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
}

async function replyPermission(reply) {
  const d = pendingPerm
  $('perm-mask').classList.remove('on')
  pendingPerm = null
  if (!d) return
  try {
    await api(`/api/session/${d.sessionID}/permission/${d.id}/reply`, { reply })
  } catch (e) {
    addMessage('assistant', `<p style="color:var(--bad)">权限回复失败:${esc(e.message)}</p>`)
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
    ;(q.options || []).forEach((o, oi) => {
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
      void oi
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
      if (text) addMessage('user', md(text))
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
        `<p style="color:var(--bad);margin:0">出错:${esc(m.error.message || m.error.name || '未知错误')}</p>`)
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

  setBusy(inflight)
  if (inflight) state.lastEvent = Date.now()   // 给兜底计时器一个起点
  scroll(true)
}

/** 用历史里的 ToolPart 重建一张工具卡片(状态机见 ToolState:pending/running/completed/error) */
function restoreTool(part) {
  const t = ensureTool(part.callID, part.tool)
  t.input = part.state?.input ?? null
  t.el.querySelector('.in').textContent =
    pickCode(t.input) || stringify(t.input) || part.state?.raw || ''
  const st = part.state?.status
  if (st === 'completed')  toolDone(part.callID, true, part.state.output)
  else if (st === 'error') toolDone(part.callID, false, part.state.error)
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
  setInterval(() => {
    if (!state.busy) return
    // 弹窗开着的时候,卡住的是人不是流 —— 没有事件是正常的,别白跑
    if (pendingQ || pendingPerm) return
    if (Date.now() - state.lastEvent < 25000) return
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
      setBusy(true)
      break

    case 'session.next.text.started':
      ensureText(textKey(d))
      break

    case 'session.next.text.delta': {
      const t = ensureText(textKey(d))
      t.raw += d.delta
      t.el.innerHTML = md(t.raw) + '<span class="cursor"></span>'
      scroll()
      break
    }

    case 'session.next.text.ended': {
      const t = ensureText(textKey(d))
      t.raw = d.text ?? t.raw
      t.el.innerHTML = md(t.raw)
      scroll()
      break
    }

    case 'session.next.tool.input.started':
      ensureTool(d.callID, d.name)
      break

    case 'session.next.tool.input.delta': {
      const t = ensureTool(d.callID)
      t.argsRaw += d.delta
      t.el.querySelector('.in').textContent = t.argsRaw
      scroll()
      break
    }

    case 'session.next.tool.called': {
      const t = ensureTool(d.callID, d.tool)
      t.name = d.tool || t.name
      t.input = d.input
      t.el.querySelector('.tname').textContent = t.name
      t.el.querySelector('.in').textContent = pickCode(d.input) || JSON.stringify(d.input, null, 2)
      scroll()
      break
    }

    case 'session.next.tool.success':
      toolDone(d.callID, true, contentText(d.content) || stringify(d.structured))
      break

    case 'session.next.tool.failed':
      toolDone(d.callID, false, (d.error && (d.error.message || d.error.name)) || stringify(d.error))
      break

    case 'session.next.step.ended': {
      const out = d.tokens?.output ?? 0
      if (state.stepStart && out > 0) {
        const secs = (d.timestamp - state.stepStart) / 1000
        if (secs > 0.4) $('v-tps').textContent = (out / secs).toFixed(1)
      }
      updateCtx(d.tokens?.input)

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
        `<p style="color:var(--bad);margin:0">agent 出错:${esc(e.message || e.name || stringify(e) || '未知错误')}</p>`)
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
  $('send').disabled = b
  $('send').textContent = b ? '生成中' : '发送'
  $('btn-stop').style.display = b ? '' : 'none'
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
  setBusy(false)
  if (!silent) {
    stream.innerHTML = ''
    addMessage('assistant', '<p style="color:var(--ink-dim);margin:0">新会话已开始。上一轮的上下文不再影响这一轮。</p>')
  }
}

async function send() {
  const box = $('input')
  const text = box.value.trim()
  if (!text || state.busy) return
  if (!state.sessionID) { try { await newSession(true) } catch (e) { return fail(e) } }

  addMessage('user', md(text))
  box.value = ''
  box.style.height = 'auto'
  setBusy(true)
  try {
    await api(`/api/session/${state.sessionID}/prompt`, { prompt: { text } })
  } catch (e) { setBusy(false); fail(e) }
}

const fail = (e) =>
  addMessage('assistant', `<p style="color:var(--bad);margin:0">出错:${esc(e.message)}</p>`)

$('send').addEventListener('click', send)
$('input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); send() }
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

/* ---------------- 启动 ---------------- */
;(async () => {
  await refreshStatus()
  setInterval(refreshStatus, 5000)

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
