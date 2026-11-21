// 介面小工具：建元素、圖示（Lucide 字型，跟手機版同一套）、提示、選單、共用元件
import { label, LoginError, NetError } from '../net.js'
import { COLORS } from '../sources.js'

// replaceChildren / append 遇到 null、false 會變成文字「null」：統一過濾掉（畫面上很多「有才放」的元素）
for (const name of ['replaceChildren', 'append']) {
  const orig = Element.prototype[name]
  Element.prototype[name] = function (...kids) {
    return orig.apply(this, kids.flat(Infinity).filter((x) => x != null && x !== false))
  }
}

const ICONS = {
  house: 57589, compass: 57499, search: 57681, library: 57600, user: 58465, play: 57660, heart: 57586, bookmark: 57440, download: 57522,
  globe: 57576, book: 57439, right: 57455, left: 57454, down: 57453, x: 57778, refresh: 57669, trash: 57742, pause: 57646, login: 57613,
  logout: 57614, list: 57809, lang: 57598, back: 57416, max: 57618, min: 57626, settings: 57684, folder: 57927, person: 57759,
  shield: 57855, alert: 57463, image: 57590, film: 57552, inbox: 57591, history: 57845, lock: 57611, check: 57452,
  vertical: 58578, horizontal: 58575, swap: 58391, plus: 57661, external: 57529, next: 57696, volume: 57771, mute: 57772,
}

/** h('div.class#id', { attrs, on: {click} }, ...children) */
export function h(tag, props, ...children) {
  if (props == null || typeof props !== 'object' || props instanceof Node || Array.isArray(props)) {
    if (props != null) children.unshift(props)
    props = {}
  }
  const [, name = 'div', rest = ''] = tag.match(/^([a-z0-9]*)(.*)$/i)
  const el = document.createElement(name || 'div')
  for (const m of rest.matchAll(/([.#])([\w-]+)/g)) {
    if (m[1] === '.') el.classList.add(m[2])
    else el.id = m[2]
  }
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue
    if (k === 'on') for (const [e, fn] of Object.entries(v)) el.addEventListener(e, fn)
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v)
    else if (k === 'class') el.className += ' ' + v
    else if (k in el && k !== 'list' && typeof v !== 'string') el[k] = v
    else el.setAttribute(k, v === true ? '' : v)
  }
  for (const c of children.flat(Infinity)) if (c != null && c !== false) el.append(c instanceof Node ? c : document.createTextNode(String(c)))
  return el
}

export const icon = (name, cls = '') => h(`i.ic${cls ? '.' + cls : ''}`, { 'aria-hidden': 'true' }, String.fromCharCode(ICONS[name] || 63))

export function btn(text, onClick, { icon: ic, primary = false, cls = '', title } = {}) {
  return h(`button.btn${primary ? '.primary' : ''}${cls ? '.' + cls : ''}`, { type: 'button', title, on: { click: onClick } }, ic ? icon(ic) : null, text ? h('span', text) : null)
}

export const iconBtn = (name, title, onClick) => h('button.icon-btn', { type: 'button', title, 'aria-label': title, on: { click: onClick } }, icon(name))

let toastTimer
export function toast(msg) {
  const t = document.getElementById('toast')
  t.textContent = msg
  t.classList.remove('hidden')
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => t.classList.add('hidden'), 3200)
}

/** 對話框；回傳 { el, close }。content 可以是元素陣列 */
export function dialog(title, content, actions = [], { wide = false, onClose } = {}) {
  const layer = h('div.modal-layer')
  const close = () => {
    layer.remove()
    document.removeEventListener('keydown', esc)
    onClose?.()
  }
  const esc = (e) => {
    if (e.key === 'Escape') close()
  }
  document.addEventListener('keydown', esc)
  const box = h(`div.modal${wide ? '.wide' : ''}`, { role: 'dialog', 'aria-label': title }, h('div.modal-head', h('h3', title), iconBtn('x', '關閉', close)), h('div.modal-body', content), actions.length ? h('div.modal-actions', actions) : null)
  layer.append(box)
  layer.addEventListener('mousedown', (e) => {
    if (e.target === layer) close()
  })
  document.body.append(layer)
  setTimeout(() => (box.querySelector('[autofocus]') || box.querySelector('input, button.primary, .opt'))?.focus(), 30)
  return { el: box, close }
}

/** 選一個選項 */
export function pick(title, options, current) {
  return new Promise((resolve) => {
    let done = false
    const d = dialog(
      title,
      h(
        'div.opts',
        options.map(([v, l]) =>
          h(
            `button.opt${v === current ? '.on' : ''}`,
            {
              type: 'button',
              on: {
                click: () => {
                  done = true
                  d.close()
                  resolve(v)
                },
              },
            },
            h('span', l),
            v === current ? icon('check') : null,
          ),
        ),
      ),
      [],
      { onClose: () => !done && resolve(null) },
    )
  })
}

export function confirmDialog(title, body, okText = '確定', danger = false) {
  return new Promise((resolve) => {
    let done = false
    const finish = (v) => {
      done = true
      d.close()
      resolve(v)
    }
    const d = dialog(title, h('p.muted', body), [btn('取消', () => finish(false)), btn(okText, () => finish(true), { primary: true, cls: danger ? 'danger' : '' })], { onClose: () => !done && resolve(false) })
  })
}

export function promptDialog(title, initial = '', placeholder = '') {
  return new Promise((resolve) => {
    let done = false
    const input = h('input.field', { value: initial, placeholder, autofocus: true })
    const finish = (v) => {
      done = true
      d.close()
      resolve(v)
    }
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') finish(input.value)
    })
    const d = dialog(title, input, [btn('取消', () => finish(null)), btn('確定', () => finish(input.value), { primary: true })], { onClose: () => !done && resolve(null) })
  })
}

// ---------- 卡片、列表 ----------

export const badge = (site) => h('span.badge', { style: { borderColor: COLORS[site] || '#94A3B8' } }, label(site))

const LANG_SHORT = { zh: '中', en: 'EN', ja: '日' }

/** 長按封面的預覽（app.js 設定）：{ can(it), open(it, onOpen, action) } */
export const hooks = { preview: null }
const LONG_PRESS_MS = 450

export function card(it, onOpen, { showSource = false, progress = 0, onMenu, menuLabel } = {}) {
  const img = h('img', { loading: 'lazy', alt: '', src: it.cover || '', draggable: false, on: { error: (e) => e.target.classList.add('broken') } })
  // 影片：按住滑鼠 0.45 秒＝預覽（放開後不算點擊）
  const pv = hooks.preview?.can(it) ? hooks.preview : null
  let pressTimer = null
  let longFired = false
  const cancelPress = () => {
    clearTimeout(pressTimer)
    pressTimer = null
  }
  const el = h(
    `button.card${it.poster ? '.poster' : ''}`,
    {
      type: 'button',
      title: pv ? `${it.title}\n（按住封面可以預覽）` : it.title,
      on: {
        click: (e) => {
          if (longFired) {
            longFired = false
            e.preventDefault()
            return
          }
          onOpen(it)
        },
        contextmenu: (e) => onMenu && (e.preventDefault(), onMenu(it)),
        mousedown: (e) => {
          if (!pv || e.button !== 0) return
          longFired = false
          cancelPress()
          pressTimer = setTimeout(() => {
            pressTimer = null
            longFired = true
            pv.open(it, () => onOpen(it), onMenu ? [menuLabel || '更多', () => onMenu(it)] : null)
          }, LONG_PRESS_MS)
        },
        mouseup: cancelPress,
        mouseleave: cancelPress,
        dragstart: (e) => e.preventDefault(),
      },
    },
    h(
      'div.thumb',
      img,
      showSource ? h('div.tl', badge(it.src)) : null,
      it.lang ? h('div.tr.chip-sm', LANG_SHORT[it.lang] || '') : null,
      it.sub && !it.poster ? h('div.br.chip-sm', it.sub) : null,
      progress > 0 ? h('div.progress', h('div', { style: { width: `${Math.min(100, progress * 100)}%` } })) : null,
    ),
    h('div.title', it.title),
    it.sub && it.poster ? h('div.sub', it.sub) : null,
  )
  return el
}

export function shelf(title, items, onOpen, { onMore, showSource, progressOf, onMenu } = {}) {
  const row = h('div.row')
  for (const it of items) row.append(card(it, onOpen, { showSource, progress: progressOf?.(it) || 0, onMenu }))
  return h('section.shelf', h('div.shelf-head', h('h2', title), onMore ? h('button.more', { type: 'button', on: { click: onMore } }, '更多', icon('right')) : null), row)
}

export const loading = () => h('div.loading', h('div.spinner'))

export function emptyView(text, ic = 'inbox') {
  return h('div.empty', icon(ic, 'big'), h('p', text))
}

/** 錯誤：登入過期時可以去登入；被網站驗證擋時主程序會自己開驗證視窗，這裡只要重試 */
export function errorView(err, onRetry, { compact = false, onLogin } = {}) {
  const msg = err instanceof NetError || err instanceof LoginError ? err.message : `載入失敗：${err?.message || err}`
  return h(
    `div.error${compact ? '.compact' : ''}`,
    compact ? null : icon('alert', 'big'),
    h('p', msg),
    h('div.actions', err instanceof LoginError && onLogin ? btn(`登入 ${label(err.site)}`, () => onLogin(err.site), { icon: 'login', primary: true }) : null, btn('重試', onRetry, { icon: 'refresh' })),
  )
}

/** 篩選列：顯示目前的值，點了跳出選項 */
export function filterBar(filters, values, onChange) {
  if (!filters?.length) return null
  return h(
    'div.filters',
    filters.map((f) => {
      const v = values[f.key] ?? f.options[0][0]
      const lbl = (f.options.find((o) => o[0] === v) || f.options[0])[1]
      return h(
        `button.filter${v !== f.options[0][0] ? '.on' : ''}`,
        {
          type: 'button',
          on: {
            click: async () => {
              const p = await pick(f.label, f.options, v)
              if (p != null && p !== v) onChange(f.key, p)
            },
          },
        },
        h('span.muted', `${f.label}：`),
        h('b', lbl),
        icon('down'),
      )
    }),
  )
}

/** 分頁載入的格狀列表（捲到底自動載下一頁）。回傳 { el, reload } */
export function pagedGrid(load, onOpen, { showSource = false, emptyText = '沒有內容', filter, header, onMenu, onLogin } = {}) {
  const grid = h('div.grid')
  const foot = h('div.foot')
  const el = h('div.paged', header || null, grid, foot)
  const keys = new Set()
  let page = 0
  let more = true
  let busy = false
  let gen = 0
  let count = 0
  // 出錯後停下來等使用者按「重試」（不然捲到底的偵測、補滿畫面會一直自動重試，錯誤畫面一直被轉圈蓋掉）
  let failed = false
  const io = new IntersectionObserver((es) => es.some((e) => e.isIntersecting) && next())
  io.observe(foot)
  async function next(retry = false) {
    if (busy || !more || (failed && !retry)) return
    failed = false
    busy = true
    const my = gen
    foot.replaceChildren(loading())
    try {
      for (let tries = 0; tries < 5; tries++) {
        const r = await load(page + 1)
        if (my !== gen) return
        page++
        const got = r.items.filter((it) => !keys.has(`${it.src}_${it.id}`) && (keys.add(`${it.src}_${it.id}`), !filter || filter(it)))
        for (const it of got) grid.append(card(it, onOpen, { showSource, onMenu }))
        count += got.length
        more = r.hasMore && r.items.length > 0
        if (got.length || !more) break
      }
      foot.replaceChildren()
      if (!count && !more) foot.replaceChildren(emptyView(emptyText))
      if (grid.children.length && grid.querySelectorAll('.card.poster').length > grid.children.length / 2) grid.classList.add('posters')
    } catch (e) {
      if (my !== gen) return
      failed = true
      foot.replaceChildren(errorView(e, () => next(true), { compact: count > 0, onLogin: onLogin ? async (site) => (await onLogin(site), next(true)) : null }))
    } finally {
      if (my === gen) busy = false
    }
    // 第一頁太少填不滿畫面時繼續載
    if (!failed && more && foot.getBoundingClientRect().top < window.innerHeight + 400) setTimeout(next, 50)
  }
  const reload = () => {
    gen++
    failed = false
    busy = false
    page = 0
    more = true
    count = 0
    keys.clear()
    grid.replaceChildren()
    grid.classList.remove('posters')
    next()
  }
  next()
  return { el, reload }
}
