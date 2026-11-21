// 漫畫閱讀（覆蓋整個視窗）：直向捲動或左右翻頁。jm 的切條圖在畫布上還原。
// 鍵盤：↑↓ 捲動（平滑）、←→ 翻頁、PageUp/PageDown、Home/End、M 切換模式、Esc 離開。
import { store } from '../store.js'
import { h, icon, iconBtn, pick, toast } from './dom.js'

let current = null

/**
 * opts: {
 *   title, pages: [{ url, segs, resolve }], startPage,
 *   chapters?: [{ id, title }], chapterId?, loadChapter?(id) → pages,
 *   toc?: [{ title, start, count }],
 *   onProgress(page, total, chapterId)
 * }
 */
export function openReader(opts) {
  if (current) current.close()
  const root = document.getElementById('reader')
  let pages = opts.pages
  let chapterId = opts.chapterId || null
  let mode = store.get('readerMode', 'vertical')
  let rtl = store.get('readerRtl', false)
  let cur = Math.max(0, Math.min(opts.startPage || 0, pages.length - 1))
  let saveTimer = null
  const scroller = h('div.reader-scroll')
  const counter = h('div.reader-count')
  const titleEl = h('div.player-title', opts.title)

  const report = () => {
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => opts.onProgress?.(cur, pages.length, chapterId), 400)
  }

  function setCur(i) {
    if (i === cur) return
    cur = i
    let label = `${cur + 1} / ${pages.length}`
    if (opts.toc?.length) {
      const t = [...opts.toc].reverse().find((x) => x.start <= cur) || opts.toc[0]
      label = `第 ${opts.toc.indexOf(t) + 1} 本 ${cur - t.start + 1} / ${t.count}（總 ${label}）`
    }
    counter.textContent = label
    report()
  }

  // ---------- 圖片 ----------

  async function imageFor(p, el, retry = false) {
    try {
      let url = p.url
      if (p.resolve && (!url || retry)) url = p.url = await p.resolve(retry)
      if (!p.segs) {
        const img = h('img', { src: url, alt: '', decoding: 'async' })
        img.addEventListener('error', () => {
          if (p.resolve && !retry) imageFor(p, el, true)
          else el.replaceChildren(failed(p, el))
        })
        el.replaceChildren(img)
        return
      }
      // 切條打亂的圖：載入後畫到畫布上拼回來
      const src = new Image()
      src.decoding = 'async'
      src.src = url
      await src.decode()
      const w = src.naturalWidth
      const hgt = src.naturalHeight
      const c = h('canvas', { width: w, height: hgt })
      const ctx = c.getContext('2d')
      const over = hgt % p.segs
      const base = Math.floor(hgt / p.segs)
      for (let i = 0; i < p.segs; i++) {
        let move = base
        const ySrc = hgt - base * (i + 1) - over
        let yDst = base * i
        if (i === 0) move += over
        else yDst += over
        ctx.drawImage(src, 0, ySrc, w, move, 0, yDst, w, move)
      }
      el.replaceChildren(c)
    } catch {
      if (p.resolve && !retry) return imageFor(p, el, true)
      el.replaceChildren(failed(p, el))
    }
  }

  const failed = (p, el) =>
    h('div.page-failed', h('span', '這頁載入失敗'), h('button.btn', { type: 'button', on: { click: () => imageFor(p, el, true) } }, '重試'))

  // ---------- 直向 ----------

  let io = null
  function renderVertical(start) {
    io?.disconnect()
    scroller.className = 'reader-scroll vertical'
    const els = pages.map((p, i) => h('div.page', { 'data-i': i }, h('div.page-ph', String(i + 1))))
    const loaded = new Set()
    io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          const i = Number(e.target.dataset.i)
          if (e.isIntersecting && !loaded.has(i)) {
            loaded.add(i)
            imageFor(pages[i], e.target)
          }
        }
        // 目前頁 = 畫面上方 1/3 處的那頁
        const mid = window.innerHeight / 3
        for (const el of els) {
          const r = el.getBoundingClientRect()
          if (r.top <= mid && r.bottom > mid) {
            setCur(Number(el.dataset.i))
            break
          }
        }
      },
      { root: scroller, rootMargin: '1500px 0px', threshold: [0, 0.5, 1] },
    )
    scroller.replaceChildren(...els, endBlock())
    els.forEach((el) => io.observe(el))
    scroller.onscroll = () => {
      const mid = window.innerHeight / 3
      for (const el of els) {
        const r = el.getBoundingClientRect()
        if (r.top <= mid && r.bottom > mid) {
          setCur(Number(el.dataset.i))
          break
        }
      }
    }
    // 跳到起始頁：圖片載入時高度會變，前幾秒內一直對齊那一頁（使用者自己捲了就停）
    const target = els[start]
    let pinned = true
    const stop = () => (pinned = false)
    scroller.addEventListener('wheel', stop, { once: true })
    scroller.addEventListener('mousedown', stop, { once: true })
    const pin = () => {
      if (!pinned || !target) return
      target.scrollIntoView({ block: 'start' })
    }
    pin()
    const t0 = Date.now()
    const tick = () => {
      if (Date.now() - t0 < 4000 && pinned) {
        pin()
        setTimeout(tick, 250)
      }
    }
    if (start > 0) tick()
    cur = start
    setCur(start)
  }

  // ---------- 左右翻頁 ----------

  function renderPaged() {
    io?.disconnect()
    scroller.onscroll = null
    scroller.className = 'reader-scroll paged'
    const el = h('div.page.single')
    scroller.replaceChildren(el, h('div.tap.left', { on: { click: () => (rtl ? next() : prev()) } }), h('div.tap.right', { on: { click: () => (rtl ? prev() : next()) } }))
    const show = () => {
      el.replaceChildren(h('div.page-ph', String(cur + 1)))
      imageFor(pages[cur], el)
      // 先載下一張
      const n = pages[cur + 1]
      if (n && n.url && !n.segs) new Image().src = n.url
    }
    paged.show = show
    show()
  }
  const paged = { show: () => {} }

  function next() {
    if (cur < pages.length - 1) {
      setCur(cur + 1)
      paged.show()
    } else nextChapter()
  }
  function prev() {
    if (cur > 0) {
      setCur(cur - 1)
      paged.show()
    }
  }

  const chapterIndex = () => (opts.chapters || []).findIndex((c) => c.id === chapterId)

  async function openChapter(i) {
    const ch = opts.chapters[i]
    if (!ch) return
    counter.textContent = '載入中…'
    try {
      pages = await opts.loadChapter(ch.id)
      chapterId = ch.id
      titleEl.textContent = `${opts.title}　${ch.title}`
      cur = 0
      render(0)
      report()
    } catch (e) {
      toast(e.message || String(e))
    }
  }

  function nextChapter() {
    const i = chapterIndex()
    if (i >= 0 && i < opts.chapters.length - 1) openChapter(i + 1)
    else toast('已經是最後一頁')
  }

  function endBlock() {
    const i = chapterIndex()
    const hasNext = i >= 0 && i < opts.chapters.length - 1
    return h(
      'div.reader-end',
      h('p', '已經是最後一頁'),
      hasNext ? h('button.btn.primary', { type: 'button', on: { click: () => openChapter(i + 1) } }, `下一話：${opts.chapters[i + 1].title}`) : h('button.btn', { type: 'button', on: { click: close } }, '返回'),
    )
  }

  const render = (start) => (mode === 'paged' ? renderPaged() : renderVertical(start))

  // ---------- 鍵盤 ----------

  let target = null
  let anim = null
  /** ↑↓ 平滑捲動：連按會累加目標位置 */
  function smooth(dy) {
    target = (target ?? scroller.scrollTop) + dy
    target = Math.max(0, Math.min(target, scroller.scrollHeight - scroller.clientHeight))
    if (anim) return
    const step = () => {
      const d = target - scroller.scrollTop
      if (Math.abs(d) < 1) {
        anim = null
        target = null
        return
      }
      scroller.scrollTop += d * 0.25
      anim = requestAnimationFrame(step)
    }
    anim = requestAnimationFrame(step)
  }

  function onKey(e) {
    if (document.querySelector('.modal-layer')) return
    const k = e.key
    const fwd = rtl ? 'ArrowLeft' : 'ArrowRight'
    const back = rtl ? 'ArrowRight' : 'ArrowLeft'
    if (k === 'Escape') close()
    else if (k === 'm' || k === 'M') toggleMode()
    else if (mode === 'paged') {
      if (k === fwd || k === 'PageDown' || k === ' ' || k === 'ArrowDown') next()
      else if (k === back || k === 'PageUp' || k === 'ArrowUp') prev()
      else if (k === 'Home') (setCur(0), paged.show())
      else if (k === 'End') (setCur(pages.length - 1), paged.show())
      else return
    } else {
      if (k === 'ArrowDown') smooth(120)
      else if (k === 'ArrowUp') smooth(-120)
      else if (k === 'PageDown' || k === ' ' || k === fwd) smooth(scroller.clientHeight * 0.9)
      else if (k === 'PageUp' || k === back) smooth(-scroller.clientHeight * 0.9)
      else if (k === 'Home') scroller.scrollTop = 0
      else if (k === 'End') scroller.scrollTop = scroller.scrollHeight
      else return
    }
    e.preventDefault()
  }

  function toggleMode() {
    mode = mode === 'paged' ? 'vertical' : 'paged'
    store.set('readerMode', mode)
    modeBtn.replaceChildren(icon(mode === 'paged' ? 'vertical' : 'horizontal'))
    render(cur)
  }

  function close() {
    clearTimeout(saveTimer)
    opts.onProgress?.(cur, pages.length, chapterId)
    io?.disconnect()
    root.replaceChildren()
    root.classList.add('hidden')
    document.removeEventListener('keydown', onKey, true)
    current = null
    opts.onClose?.()
  }

  const modeBtn = iconBtn(mode === 'paged' ? 'vertical' : 'horizontal', '切換直向／翻頁（M）', toggleMode)
  const bar = h(
    'div.reader-bar',
    iconBtn('back', '返回（Esc）', close),
    titleEl,
    opts.chapters?.length
      ? iconBtn('list', '章節', async () => {
          const p = await pick('章節', opts.chapters.map((c) => [c.id, c.title]), chapterId)
          if (p && p !== chapterId) openChapter(opts.chapters.findIndex((c) => c.id === p))
        })
      : null,
    opts.toc?.length
      ? iconBtn('list', '目錄', async () => {
          const p = await pick('目錄', opts.toc.map((t) => [String(t.start), t.title]), null)
          if (p != null) {
            setCur(Number(p))
            render(Number(p))
          }
        })
      : null,
    modeBtn,
    iconBtn('swap', '翻頁方向（日漫從右往左）', () => {
      rtl = !rtl
      store.set('readerRtl', rtl)
      toast(rtl ? '從右往左翻' : '從左往右翻')
    }),
  )
  root.replaceChildren(bar, scroller, counter)
  root.classList.remove('hidden')
  document.addEventListener('keydown', onKey, true)
  current = { close }
  if (chapterId && opts.chapters) {
    const ch = opts.chapters.find((c) => c.id === chapterId)
    if (ch) titleEl.textContent = `${opts.title}　${ch.title}`
  }
  counter.textContent = `${cur + 1} / ${pages.length}`
  render(cur)
  scroller.focus()
  return current
}
