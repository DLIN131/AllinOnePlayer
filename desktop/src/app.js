// 電腦版主畫面：左側選單（首頁／來源／搜尋／收藏／我的），右邊是頁面堆疊（點進去的頁面可以返回）
import * as cdl from './comic-downloader.js'
import * as data from './data.js'
import { base, fmtSize, fmtTime, label, loadConfig, LoginError, NetError } from './net.js'
import { COLORS, COMIC_KEYS, MAIN_KEYS, src, VIDEO_KEYS } from './sources.js'
import { Lang, Query, siteFavForm, siteFavSubmit } from './sources/comics.js'
import { actressLink, CASTS, lookupActresses } from './sources/va.js'
import { store } from './store.js'
import { badge, btn, card, confirmDialog, dialog, emptyView, errorView, filterBar, h, icon, iconBtn, loading, pagedGrid, pick, promptDialog, shelf, toast } from './ui/dom.js'
import { openPlayer } from './ui/player.js'
import { openReader } from './ui/reader.js'

const REPO = 'DLIN131/AllinOnePlayer'
const ZIP_NAME = 'AllinOnePlayer-Windows.zip'
const view = document.getElementById('view')

// ============ 導覽：每個分頁一個堆疊 ============

const TABS = [
  ['home', '首頁', 'house'],
  ['sources', '來源', 'compass'],
  ['search', '搜尋', 'search'],
  ['library', '收藏', 'library'],
  ['me', '我的', 'user'],
]
let tab = 'home'
const stacks = {}

function renderNav() {
  const nav = document.getElementById('nav')
  nav.replaceChildren(
    ...TABS.map(([id, text, ic]) =>
      h(`button.nav-item${id === tab ? '.on' : ''}`, { type: 'button', on: { click: () => goTab(id, id === tab) } }, icon(ic), h('span', text), id === 'library' ? h('span#dlBadge.dl-badge.hidden') : null),
    ),
  )
  updateDlBadge()
}

function goTab(id, reset = false) {
  tab = id
  if (reset || !stacks[id]) stacks[id] = []
  renderNav()
  if (!stacks[id].length) push(rootPage(id), true)
  else show()
}

function rootPage(id) {
  return { home: homePage, sources: sourcesPage, search: () => searchPage(), library: libraryPage, me: mePage }[id]()
}

/** 打開一頁（page = { title, el, onShow? }） */
function push(page, root = false) {
  const s = (stacks[tab] ||= [])
  page.root = root
  s.push(page)
  show()
}

function back() {
  const s = stacks[tab]
  if (s.length > 1) {
    s.pop().onLeave?.()
    show()
  }
}

function show() {
  const s = stacks[tab]
  const page = s[s.length - 1]
  const head = h('header.page-head', s.length > 1 ? iconBtn('back', '返回（Alt+←）', back) : null, h('h1', page.title), page.actions || null)
  view.replaceChildren(head, page.el)
  view.scrollTop = page.scroll || 0
  page.onShow?.()
}

view.addEventListener('scroll', () => {
  const s = stacks[tab]
  if (s?.length) s[s.length - 1].scroll = view.scrollTop
})
document.addEventListener('keydown', (e) => {
  if (document.querySelector('#player:not(.hidden), #reader:not(.hidden), .modal-layer')) return
  if ((e.altKey && e.key === 'ArrowLeft') || (e.key === 'Backspace' && !/INPUT|TEXTAREA/.test(document.activeElement?.tagName))) {
    e.preventDefault()
    back()
  }
})
window.addEventListener('mouseup', (e) => {
  if (e.button === 3) back()
})

// ============ 開項目、開連結 ============

function openItem(it) {
  if (it.type === 'actress') return push(listPage(actressLink(it.title, it.id)))
  if (it.src === 'local') return openBook(it.id)
  push(detailPage(it))
}

function openLink(l) {
  if (l.params.section === 'openSeries') return push(detailPage({ src: l.src, id: l.params.id, title: l.title, cover: '', type: 'series', poster: true }))
  push(listPage(l))
}

async function loginSite(site) {
  if (site === 'va') return vaLoginDialog()
  const s = await window.hub.login(site)
  toast(s.loggedIn ? `${label(site)} 已登入${s.name ? '：' + s.name : ''}` : `${label(site)} 尚未登入`)
  if (site === 'jm' && s.name) src('jm').username = s.name
}

// ============ 首頁 ============

function homePage() {
  const el = h('div.page')
  const render = () => {
    const hidden = data.setting('homeHidden', [])
    const cont = data.history().filter((x) => x.item.src !== 'local' && ((data.progressOf(x) > 0.01 && data.progressOf(x) < 0.97) || x.ep)).slice(0, 20)
    el.replaceChildren(
      cont.length ? shelf('繼續觀看／閱讀', cont.map((x) => x.item), openItem, { showSource: true, progressOf: (it) => data.progressOf(cont.find((x) => x.item.id === it.id && x.item.src === it.src)) }) : null,
      ...MAIN_KEYS.filter((k) => !hidden.includes(k)).map(homeShelf),
    )
  }
  render()
  return { title: '首頁', el, actions: iconBtn('refresh', '重新整理', render) }
}

function homeShelf(k) {
  const s = src(k)
  const holder = h('section.shelf', h('div.shelf-head', h('h2', label(k))), loading())
  const grid = s.sections.find((x) => !x.shelves && x.id !== 'fav' && x.id !== 'actresses') || s.sections[0]
  const load = grid.shelves ? s.shelves(grid.id).then((sh) => sh[0]?.items || []) : s.list({ section: grid.id }, 1).then((r) => r.items.slice(0, 24))
  load
    .then((items) => {
      if (!items.length) return holder.remove()
      holder.replaceWith(shelf(label(k), items, openItem, { onMore: () => push(sourcePage(k)) }))
    })
    .catch((e) => {
      holder.replaceChildren(h('div.shelf-head', h('h2', label(k)), h('button.more', { type: 'button', on: { click: () => push(sourcePage(k)) } }, '更多', icon('right'))), errorView(e, () => holder.replaceWith(homeShelf(k)), { compact: true, onLogin: loginSite }))
    })
  return holder
}

// ============ 來源 ============

function sourcesPage() {
  const tile = (k) => {
    const s = src(k)
    return h(
      'button.source-tile',
      { type: 'button', style: { '--c': COLORS[k] }, on: { click: () => push(sourcePage(k)) } },
      icon(s.kind === 'comic' ? 'book' : 'film', 'big'),
      h('div', h('b', label(k)), h('span.muted', s.sections.map((x) => x.title).join('・'))),
    )
  }
  return { title: '來源', el: h('div.page', h('h2.group', '影片'), h('div.tiles', VIDEO_KEYS.map(tile)), h('h2.group', '漫畫'), h('div.tiles', COMIC_KEYS.map(tile))) }
}

function langButton(onChange) {
  return btn(Lang.filter ? Lang.short[Lang.filter] : '語言', async () => {
    const v = await pick('只看這個語言', [['', '全部'], ...Object.entries(Lang.names)], Lang.filter)
    if (v == null) return
    Lang.filter = v
    data.setSetting('lang', v)
    onChange()
  }, { icon: 'lang' })
}

function sourcePage(k) {
  const s = src(k)
  const tabs = h('div.tabs')
  const body = h('div')
  let active = s.sections[0].id
  const cache = {}
  const render = () => {
    tabs.replaceChildren(...s.sections.map((x) => h(`button.tab${x.id === active ? '.on' : ''}`, { type: 'button', on: { click: () => ((active = x.id), render()) } }, x.title)))
    const x = s.sections.find((y) => y.id === active)
    body.replaceChildren((cache[active + Lang.filter] ||= x.shelves ? shelvesView(s, x.id) : sectionGrid(s, x)))
  }
  render()
  return { title: label(k), el: h('div.page', tabs, body), actions: s.kind === 'comic' ? langButton(() => render()) : null }
}

function sectionGrid(s, x) {
  const values = {}
  const lang = Lang.filter
  const filter = s.kind === 'comic' && lang && (s.key === 'jm' || s.key === 'wn') ? (it) => it.lang === lang : null
  let grid
  const bar = () => filterBar(x.filters, values, (k, v) => {
    values[k] = v
    barEl.replaceWith((barEl = bar() || h('div')))
    grid.reload()
  }) || h('div')
  let barEl = bar()
  grid = pagedGrid((p) => s.list({ section: x.id, ...values }, p), openItem, { filter, emptyText: x.id === 'fav' ? '網站帳號的收藏是空的' : '沒有內容', onLogin: loginSite })
  return h('div', barEl, grid.el)
}

function shelvesView(s, section) {
  const el = h('div', loading())
  s.shelves(section)
    .then((list) =>
      el.replaceChildren(
        ...list.map((sh) =>
          sh.items.length
            ? shelf(sh.title, sh.items, openItem, { onMore: sh.more ? () => openLink(sh.more) : null })
            : h('section.shelf', h('div.shelf-head', h('h2', sh.title)), h('div.chips', sh.chips.map((l) => h('button.chip', { type: 'button', on: { click: () => openLink(l) } }, l.title)))),
        ),
        list.length ? null : emptyView('沒有內容'),
      ),
    )
    .catch((e) => el.replaceChildren(errorView(e, () => el.replaceWith(shelvesView(s, section)))))
  return el
}

/** 某個來源的一個列表（分類、標籤、女優、站內搜尋…） */
function listPage(link) {
  const s = src(link.src)
  const p = link.params
  let filters
  if (p.q != null) filters = s.searchFilters
  else {
    const sec = s.sections.find((x) => x.id === (p.section || s.sections[0].id))
    filters = (sec?.filters || []).filter((f) => !(f.key in p) && !(p.url && (f.key === 'cat' || f.key === 'genre')))
    if (s.key === 'va' && p.actress === '1') filters = [{ key: 'filters', label: '演出', options: CASTS }, ...filters]
  }
  const values = {}
  const load = (pg) => {
    const all = { ...p, ...values }
    return all.q != null ? s.search(all.q, pg, all) : s.list(all, pg)
  }
  const grid = pagedGrid(load, openItem, { onLogin: loginSite })
  let barEl
  const bar = () =>
    filterBar(filters, values, (k, v) => {
      values[k] = v
      const nb = bar()
      barEl.replaceWith(nb)
      barEl = nb
      grid.reload()
    }) || h('div')
  barEl = bar()
  return { title: link.title, el: h('div.page', barEl, grid.el) }
}

// ============ 搜尋 ============

function searchPage(initial = '', comicsOnly = false) {
  const keys = comicsOnly ? COMIC_KEYS : MAIN_KEYS
  let picked = new Set(comicsOnly ? COMIC_KEYS : data.setting('searchSites', MAIN_KEYS))
  const input = h('input.field.search-input', { type: 'search', placeholder: comicsOnly ? '書名、作者、編號（JM123、#123）或作品網址' : '片名、番號、書名、作者…', value: initial })
  const chips = h('div.chips')
  const results = h('div')
  const renderChips = () =>
    chips.replaceChildren(
      ...keys.map((k) =>
        h(
          `button.chip.site${picked.has(k) ? '.on' : ''}`,
          {
            type: 'button',
            style: { '--c': COLORS[k] },
            on: {
              click: () => {
                picked.has(k) ? picked.delete(k) : picked.add(k)
                if (!comicsOnly) data.setSetting('searchSites', [...picked])
                renderChips()
                if (input.value.trim()) run()
              },
            },
          },
          label(k),
        ),
      ),
    )
  function historyView() {
    const words = data.searches()
    results.replaceChildren(
      words.length
        ? h('div', h('div.shelf-head', h('h2', '最近搜尋'), h('button.more', { type: 'button', on: { click: () => (data.clearSearches(), historyView()) } }, '清除')), h('div.chips', words.map((w) => h('button.chip', { type: 'button', on: { click: () => ((input.value = w), run()) } }, w))))
        : emptyView('輸入關鍵字開始搜尋', 'search'),
    )
  }
  function run() {
    const q = input.value.trim()
    if (!q) return historyView()
    data.addSearch(q)
    const id = Query.parseId(q)
    if (id && !id.plain && picked.has(id.sites[0])) return openItem({ src: id.sites[0], id: id.id, title: q, cover: '', type: 'comic', poster: true })
    const rows = []
    if (id?.plain) {
      const ks = id.sites.filter((k) => picked.has(k))
      if (ks.length) rows.push(h('section.shelf', h('div.shelf-head', h('h2', `用編號 ${id.id} 開啟`)), h('div.chips', ks.map((k) => btn(`${label(k)} ${src(k).idTag(id.id)}`, () => openItem({ src: k, id: id.id, title: src(k).idTag(id.id), cover: '', type: 'comic', poster: true }))))))
    }
    for (const k of keys.filter((x) => picked.has(x))) {
      const holder = h('section.shelf', h('div.shelf-head', h('h2', label(k))), loading())
      src(k)
        .search(q, 1, {})
        .then((r) => {
          if (!r.items.length) return holder.replaceChildren(h('div.shelf-head', h('h2', label(k))), h('p.muted.pad', '找不到'))
          holder.replaceWith(shelf(`${label(k)}（${r.total || r.items.length + (r.hasMore ? '+' : '')}）`, r.items, openItem, { onMore: () => push(listPage({ src: k, title: `${label(k)}：${q}`, params: { q } })) }))
        })
        .catch((e) => holder.replaceChildren(h('div.shelf-head', h('h2', label(k))), errorView(e, run, { compact: true, onLogin: loginSite })))
      rows.push(holder)
    }
    results.replaceChildren(...rows)
  }
  input.addEventListener('keydown', (e) => e.key === 'Enter' && run())
  renderChips()
  if (initial) setTimeout(run)
  else historyView()
  return { title: comicsOnly ? '各站搜尋' : '搜尋', el: h('div.page', h('div.search-row', input, btn('搜尋', run, { primary: true, icon: 'search' })), chips, results), onShow: () => setTimeout(() => input.focus(), 30) }
}

// ============ 作品頁 ============

function detailPage(item) {
  const s = src(item.src)
  const el = h('div.page', loading())
  const page = { title: item.title || '作品', el }
  let d = null
  let siteSaved = null
  const load = async () => {
    el.replaceChildren(loading())
    try {
      d = await s.detail(item)
      page.title = d.title
      render()
      if (s.key === 'va') {
        const id = d.extra.itemId
        if (id) s.itemView(id).then((v) => ((siteSaved = v), render())).catch(() => {})
      }
    } catch (e) {
      el.replaceChildren(errorView(e, load, { onLogin: loginSite }))
    }
  }
  const render = () => {
    const fav = data.isFavorite(`${d.item.src}_${d.item.id}`)
    const poster = s.kind === 'comic' || d.item.poster
    const actions = h('div.actions')
    if (s.kind === 'comic') {
      const hh = data.historyOf(`${d.item.src}_${d.item.id}`)
      const resume = hh && (hh.page > 0 || hh.ch)
      actions.append(btn(resume ? `繼續閱讀（${hh.cht ? hh.cht + ' ' : ''}第 ${hh.page + 1}${hh.total ? ' / ' + hh.total : ''} 頁）` : '開始閱讀', () => read(d, resume ? hh.ch : null, resume ? hh.page : 0), { primary: true, icon: 'book' }))
      if (resume) actions.append(btn('從頭開始', () => read(d, d.chapters[0]?.id || null, 0)))
    } else {
      const hh = data.historyOf(`${d.item.src}_${d.item.id}`)
      const ep = d.item.type === 'series' ? hh?.ep : null
      const pos = data.position(`${(ep || d.item).src}_${(ep || d.item).id}`)
      const text = d.item.type === 'series' ? (ep ? `繼續播放：${ep.title}` : '播放第一集') : pos > 5 ? `繼續播放（${fmtTime(pos)}）` : '播放'
      actions.append(btn(text, () => play(d, ep), { primary: true, icon: 'play' }))
    }
    actions.append(btn(fav ? '已收藏' : '收藏', () => (data.setFavorite(d.item, !fav), render()), { icon: 'heart', cls: fav ? 'faved' : '' }))
    if (s.hasAccount && (s.kind === 'comic' || siteSaved != null)) actions.append(btn(s.key === 'va' && siteSaved ? '已在網站收藏' : '網站收藏', () => siteFav(d), { icon: 'bookmark' }))
    actions.append(btn('下載', () => download(d), { icon: 'download' }))
    if (s.kind === 'comic') {
      actions.append(btn('各站搜同一本', () => push(searchPage(Query.cleanTitle(d.title), true)), { icon: 'search' }))
      for (const a of Query.parseAuthors(d.title).slice(0, 2)) actions.append(btn(a, () => push(searchPage(a, true)), { icon: 'person' }))
    }
    actions.append(btn('網頁', () => window.hub.openSite(s.key, d.url), { icon: 'globe' }))

    const info = h(
      'div.info',
      d.info.map((r) => h('div.info-row', h('span.k', r.label), r.links.length ? h('span.v.chips', r.links.map((l) => h('button.chip', { type: 'button', on: { click: () => openLink(l) } }, l.title))) : h('span.v', r.text))),
    )
    if (s.key === 'va') {
      const v = h('span.v', h('span.muted', '查詢中…'))
      info.append(h('div.info-row', h('span.k', '女優（番號查詢）'), v))
      lookupActresses(d.item.id)
        .then((names) => v.replaceChildren(...(names.length ? [h('span.chips', names.map((n) => h('button.chip', { type: 'button', on: { click: () => push(listPage({ src: 'va', title: n, params: { q: n } })) } }, n)))] : [h('span.muted', '查不到')])))
        .catch(() => v.replaceChildren(h('span.muted', '查不到')))
    }
    const hh = data.historyOf(`${d.item.src}_${d.item.id}`)
    el.replaceChildren(
      h(
        `div.detail-head${poster ? '.poster' : ''}`,
        h('div.cover', h('img', { src: d.cover || d.item.cover, alt: '' })),
        h('div.meta', h('div.badges', badge(s.key), d.lang ? h('span.muted', Lang.names[d.lang]) : null, d.subtitle && s.kind !== 'comic' ? h('span.muted', d.subtitle) : null), h('h2.title', d.title), d.subtitle && s.kind === 'comic' ? h('p.muted', d.subtitle) : null, actions),
      ),
      info,
      d.description ? h('p.desc', d.description) : null,
      d.tags.length ? h('section', h('h3.sec', '標籤'), h('div.chips', d.tags.map((t) => h('button.chip', { type: 'button', on: { click: () => (t.params.q != null ? push(listPage({ src: t.src, title: t.title, params: { q: t.params.q } })) : openLink(t)) } }, t.title)))) : null,
      d.chapters.length
        ? h(
            'section',
            h('h3.sec', `章節（${d.chapters.length}）`),
            h(
              'div.chapters',
              d.chapters.map((c) =>
                h(`button.chapter${hh?.ch === c.id ? '.on' : ''}`, { type: 'button', title: '右鍵：只下載這一話', on: { click: () => read(d, c.id, hh?.ch === c.id ? hh.page : 0), contextmenu: (e) => (e.preventDefault(), cdl.enqueue(d, c) && toast(`已加入下載：${c.title}`)) } }, c.title),
              ),
            ),
          )
        : null,
      d.episodes.length ? shelf(`${d.episodesTitle || '選集'}（${d.episodes.length}）`, d.episodes, (e) => (s.key === 'vc' ? play(d, e) : openItem(e)), { progressOf: (e) => epProgress(e) }) : null,
      d.related.length ? shelf(s.kind === 'comic' ? '相關作品' : '相關影片', d.related, openItem) : null,
    )
  }
  const epProgress = (e) => {
    const hh = data.historyOf(`${e.src}_${e.id}`)
    const pos = data.position(`${e.src}_${e.id}`)
    return hh?.dur ? (pos || hh.pos) / hh.dur : 0
  }
  page.onShow = () => d && render()
  load()
  return page

  // ---------- 動作 ----------

  async function play(dd, ep) {
    try {
      if (!ep && dd.item.type === 'series' && dd.episodes.length) ep = dd.episodes[0]
      for (;;) {
        const st = await s.stream(dd, ep)
        const it = ep || dd.item
        const k = `${it.src}_${it.id}`
        const list = dd.episodes
        const idx = list.findIndex((x) => x.id === it.id)
        const next = idx >= 0 && idx + 1 < list.length ? list[idx + 1] : null
        const r = await openPlayer({ title: ep && ep.id !== dd.item.id ? `${dd.title}　${ep.title}` : dd.title, stream: st, startSec: data.position(k), hasNext: !!next })
        const done = r.duration > 0 && r.duration - r.position < 30
        if (r.position > 0) data.setPosition(k, done ? 0 : r.position)
        data.addHistory({ item: dd.item, pos: done ? 0 : r.position, dur: r.duration, ep })
        if (r.next && next) {
          ep = next
          continue
        }
        break
      }
      render()
    } catch (e) {
      toast(e.message || String(e))
    }
  }

  async function read(dd, chapterId, startPage) {
    if (dd.chapters.length && !chapterId) chapterId = dd.chapters[0].id
    try {
      toast('載入中…')
      const pages = await s.read(dd, chapterId)
      openReader({
        title: dd.title,
        pages,
        startPage,
        chapters: dd.chapters,
        chapterId,
        loadChapter: (id) => s.read(dd, id),
        onProgress: (pg, total, ch) => data.addHistory({ item: dd.item, ch: ch || '', cht: dd.chapters.find((c) => c.id === ch)?.title || '', page: pg, total }),
        onClose: () => render(),
      })
    } catch (e) {
      toast(e.message || String(e))
    }
  }

  async function siteFav(dd) {
    try {
      if (s.key === 'va') {
        const id = dd.extra.itemId
        const on = siteSaved !== true
        await s.setSaved(id, on)
        siteSaved = on
        toast(on ? '已加到網站收藏' : '已從網站收藏移除')
        render()
      } else if (s.key === 'nh') {
        const on = !(await s.isFavorite(dd.item.id))
        await s.setFavorite(dd.item.id, on)
        toast(on ? '已加到網站收藏' : '已從網站收藏移除')
      } else if (s.key === 'jm') toast(await s.addFavorite(dd.item.id))
      else {
        const f = await siteFavForm(dd)
        let choice = null
        if (f.choices.length > 1) {
          choice = await pick('加到哪個收藏夾', f.choices, f.selected)
          if (choice == null) return
        }
        toast(await siteFavSubmit(dd, f, choice))
      }
    } catch (e) {
      if (e instanceof LoginError && (await confirmDialog('需要登入', e.message, '登入'))) loginSite(e.site)
      else toast(e.message || String(e))
    }
  }

  async function download(dd) {
    if (s.kind === 'comic') {
      if (dd.chapters.length > 1) {
        const p = await pick('下載哪一話', [['all', `全部 ${dd.chapters.length} 話（各存一個檔）`], ...dd.chapters.map((c) => [c.id, c.title])], null)
        if (p == null) return
        for (const c of dd.chapters) if (p === 'all' || p === c.id) cdl.enqueue(dd, c)
      } else cdl.enqueue(dd, null)
      return toast('已加入下載（到「收藏 › 下載」看進度）')
    }
    try {
      let ep = null
      if (dd.item.type === 'series') {
        const p = await pick('下載哪一集', dd.episodes.map((e) => [e.id, e.title]), null)
        if (p == null) return
        ep = dd.episodes.find((e) => e.id === p)
      }
      const st = await s.stream(dd, ep)
      const conn = { headers: st.headers || {}, unwrap: !!st.unwrap }
      let url = st.downloadUrl || st.url
      let quality = ''
      if (st.kind === 'mp4') {
        if (st.qualities?.length > 1) {
          url = await pick('選擇畫質', st.qualities.map(([l, u]) => [u, l]), st.qualities[0][1])
          if (!url) return
        }
        quality = (st.qualities?.find((q) => q[1] === url) || [''])[0]
      } else {
        const vs = await window.hub.vdl.options(url, conn)
        if (vs.length > 1) {
          const u = await pick('選擇畫質', vs.map((v) => [v.url, `${v.height}p${v.bandwidth ? `（約 ${fmtSize((v.bandwidth / 8) * 3600)}／小時）` : ''}`]), vs[0].url)
          if (!u) return
          url = u
          quality = `${vs.find((v) => v.url === u).height}p`
        } else if (vs.length) {
          url = vs[0].url
          quality = `${vs[0].height}p`
        }
      }
      const it = ep || dd.item
      await window.hub.vdl.add({ key: `${it.src}_${it.id}`, src: it.src, title: ep ? `${dd.title} ${ep.title}` : dd.title, cover: it.cover || dd.cover, kind: st.kind, mediaUrl: url, conn, quality })
      toast('已加入下載（到「收藏 › 下載」看進度）')
    } catch (e) {
      toast(`無法下載：${e.message || e}`)
    }
  }
}

// ============ 收藏（本機收藏、紀錄、網站收藏、下載、書櫃） ============

function libraryPage() {
  const TABS2 = [
    ['fav', '收藏'],
    ['history', '紀錄'],
    ['site', '網站收藏'],
    ['downloads', '下載'],
    ['shelf', '書櫃'],
  ]
  let active = 'fav'
  let kind = ''
  const tabs = h('div.tabs')
  const body = h('div')
  const kindSwitch = (onChange) =>
    h(
      'div.seg',
      [
        ['', '全部'],
        ['video', '影片'],
        ['comic', '漫畫'],
      ].map(([v, l]) => h(`button${kind === v ? '.on' : ''}`, { type: 'button', on: { click: () => ((kind = v), onChange()) } }, l)),
    )
  const kindOk = (it) => !kind || (kind === 'comic') === (it.type === 'comic')
  const grids = (items, opts) => {
    const vids = items.filter((x) => !x.poster)
    const posters = items.filter((x) => x.poster)
    const g = (list) => h(`div.grid${list[0]?.poster ? '.posters' : ''}`, list.map((it) => card(it, openItem, opts)))
    return h('div', vids.length && posters.length ? h('h3.sec', `影片（${vids.length}）`) : null, vids.length ? g(vids) : null, vids.length && posters.length ? h('h3.sec', `漫畫・劇集（${posters.length}）`) : null, posters.length ? g(posters) : null)
  }
  const render = () => {
    tabs.replaceChildren(...TABS2.map(([id, t]) => h(`button.tab${id === active ? '.on' : ''}`, { type: 'button', on: { click: () => ((active = id), render()) } }, t)))
    if (active === 'fav') {
      const items = data.favorites().filter(kindOk)
      body.replaceChildren(
        kindSwitch(render),
        items.length
          ? grids(items, { showSource: true, onMenu: async (it) => (await confirmDialog('移除收藏', it.title, '移除')) && (data.setFavorite(it, false), render()) })
          : emptyView('還沒有收藏。在作品頁按「收藏」就會出現在這裡（右鍵可以移除）', 'heart'),
      )
    } else if (active === 'history') {
      const list = data.history().filter((x) => kindOk(x.item))
      body.replaceChildren(
        h('div.row-actions', kindSwitch(render), btn('清除紀錄', async () => (await confirmDialog('清除紀錄', '清除這些觀看／閱讀紀錄？', '清除', true)) && (data.clearHistory(kind ? kind === 'comic' : null), render()), { icon: 'trash' })),
        list.length
          ? grids(list.map((x) => x.item), { showSource: true, progressOf: undefined, onMenu: async (it) => (await confirmDialog('刪除這筆紀錄', it.title, '刪除')) && (data.removeHistory(`${it.src}_${it.id}`), render()) })
          : emptyView('還沒有紀錄', 'history'),
      )
    } else if (active === 'site') body.replaceChildren(siteFavorites())
    else if (active === 'downloads') body.replaceChildren(downloadsView())
    else body.replaceChildren(shelfView())
  }
  render()
  return { title: '收藏', el: h('div.page', tabs, body), onShow: render }
}

function siteFavorites() {
  const el = h('div', loading())
  const sites = ['va', 'nh', 'jm', 'wn', 'eh']
  Promise.all(sites.map((k) => window.hub.authStatus(k).then((s) => [k, s]).catch(() => [k, { loggedIn: false }]))).then((all) => {
    const logged = all.filter(([, s]) => s.loggedIn || s.expired)
    if (!logged.length) return el.replaceChildren(emptyView('還沒有登入任何網站。到「我的」登入後，網站帳號的收藏會出現在這裡', 'bookmark'))
    el.replaceChildren()
    for (const [k, st] of logged) {
      if (k === 'jm' && st.name) src('jm').username = st.name
      const rows = k === 'va' ? [['/saved', '收藏'], ['/history', '觀看紀錄']] : [[null, '收藏']]
      for (const [path, t] of rows) {
        const title = `${label(k)} ${t}`
        const holder = h('section.shelf', h('div.shelf-head', h('h2', title)), loading())
        el.append(holder)
        const link = path ? { src: k, title, params: { section: 'account', path } } : { src: k, title, params: { section: 'fav' } }
        ;(path ? src('va').accountList(path, 1) : src(k).favorites(1))
          .then((r) => (r.items.length ? holder.replaceWith(shelf(title, r.items, openItem, { onMore: () => push(listPage(link)) })) : holder.replaceChildren(h('div.shelf-head', h('h2', title)), h('p.muted.pad', '是空的'))))
          .catch((e) => holder.replaceChildren(h('div.shelf-head', h('h2', title)), errorView(e, () => {}, { compact: true, onLogin: loginSite })))
      }
    }
  })
  return el
}

// ---------- 下載 ----------

let videoJobs = []
const statusText = (s, err, prog) =>
  ({ running: `下載中 ${Math.round(prog * 100)}%`, merging: '轉檔中…', queued: '排隊中', paused: `已暫停 ${Math.round(prog * 100)}%`, error: `失敗：${err}`, canceled: '已取消', done: '已完成' })[s] || s

function updateDlBadge() {
  const n = videoJobs.filter((j) => ['running', 'queued', 'merging'].includes(j.status)).length + cdl.activeCount()
  const b = document.getElementById('dlBadge')
  if (!b) return
  b.textContent = n
  b.classList.toggle('hidden', !n)
}

function downloadsView() {
  const el = h('div')
  const render = () => {
    const vids = videoJobs
    const comics = cdl.allJobs()
    if (!vids.length && !comics.length) return el.replaceChildren(h('div.row-actions', folderButtons()), emptyView('還沒有下載。在作品頁按「下載」', 'download'))
    el.replaceChildren(
      h('div.row-actions', folderButtons()),
      vids.length ? h('h3.sec', `影片（${vids.length}）`) : null,
      ...vids.map((j) => {
        const prog = j.kind === 'mp4' ? (j.size ? j.bytes / j.size : 0) : j.total ? j.done / j.total : 0
        return h(
          'div.dl-row',
          h('img.dl-cover', { src: j.cover, alt: '' }),
          h('div.dl-main', h('div.dl-title', j.title), h(`div.dl-sub${j.status === 'error' ? '.err' : ''}`, `${statusText(j.status, j.error, prog)}  ·  ${fmtSize(j.bytes || 0)}${j.quality ? '  ·  ' + j.quality : ''}${j.speed ? `  ·  ${fmtSize(j.speed)}/s` : ''}${j.missing ? '  ·  檔案已被刪除' : ''}`), j.status !== 'done' ? h('div.bar', h('div', { style: { width: `${prog * 100}%` } })) : null),
          j.status === 'done' && !j.missing ? iconBtn('play', '播放', () => openPlayer({ title: j.title, stream: { kind: 'mp4', url: j.fileUrl }, startSec: data.position(j.id) }).then((r) => r.position > 0 && data.setPosition(j.id, r.position))) : null,
          ['running', 'queued'].includes(j.status) ? iconBtn('pause', '暫停', () => window.hub.vdl.pause(j.id)) : null,
          ['paused', 'error'].includes(j.status) ? iconBtn('play', '繼續', () => window.hub.vdl.resume(j.id)) : null,
          iconBtn('folder', '在資料夾中顯示', () => window.hub.vdl.show(j.id)),
          iconBtn('trash', '刪除', async () => {
            if (await confirmDialog('刪除下載', `刪除「${j.title}」？`, '連檔案一起刪', true)) window.hub.vdl.remove(j.id, true)
          }),
        )
      }),
      comics.length ? h('div.row-actions', h('h3.sec', `漫畫（${comics.length}）`), btn('清除已完成', () => cdl.clearFinished())) : null,
      ...comics.map((j) =>
        h(
          'div.dl-row',
          h('img.dl-cover.poster', { src: j.cover, alt: '' }),
          h('div.dl-main', h('div.dl-title', j.title + (j.chapterTitle ? '　' + j.chapterTitle : '')), h(`div.dl-sub${j.status === 'error' ? '.err' : ''}`, `${statusText(j.status, j.error, j.total ? j.done / j.total : 0)}${j.total ? `  ·  ${j.done} / ${j.total} 頁` : ''}`), ['running', 'queued'].includes(j.status) ? h('div.bar', h('div', { style: { width: `${j.total ? (j.done / j.total) * 100 : 0}%` } })) : null),
          j.status === 'done' && j.file ? iconBtn('book', '閱讀', () => openBookFile(j.file)) : null,
          j.status === 'done' && j.file ? iconBtn('folder', '在資料夾中顯示', () => window.hub.cbz.show(j.file)) : null,
          ['running', 'queued'].includes(j.status) ? iconBtn('x', '取消', () => cdl.cancel(j.key)) : null,
          ['error', 'canceled'].includes(j.status) && j.d ? iconBtn('refresh', '重試', () => cdl.retry(j.key)) : null,
        ),
      ),
    )
  }
  render()
  const off = cdl.onChange(() => (el.isConnected ? render() : off()))
  const timer = setInterval(() => (el.isConnected ? render() : clearInterval(timer)), 1000)
  return el
}

function folderButtons() {
  return h('div.chips', btn('影片資料夾', () => window.hub.vdl.openDir(), { icon: 'folder' }), btn('漫畫資料夾', () => window.hub.cbz.openDir(), { icon: 'folder' }))
}

// ---------- 書櫃 ----------

let books = []

function shelfView() {
  const el = h('div', loading())
  let q = ''
  const render = () => {
    const cols = store.get('collections', [])
    const inCol = new Set(cols.flatMap((c) => c.files))
    const list = books.filter((b) => !inCol.has(b.name) && (!q || b.name.toLowerCase().includes(q.toLowerCase())))
    const input = h('input.field', { placeholder: '找書名', value: q, on: { input: (e) => ((q = e.target.value), render(), el.querySelector('input').focus()) } })
    el.replaceChildren(
      h('div.row-actions', input, btn('開啟漫畫檔', async () => (await window.hub.lib.pick(), reload()), { icon: 'plus' }), btn('重新整理', reload, { icon: 'refresh' })),
      cols.length ? h('h3.sec', `合集（${cols.length}）`) : null,
      cols.length ? h('div.grid.posters', cols.map((c) => card({ src: 'local', id: `col_${c.id}`, title: c.name, cover: coverOfCol(c), sub: `${c.files.length} 本`, type: 'comic', poster: true }, () => openCollection(c), { onMenu: () => collectionMenu(c, render) }))) : null,
      h('h3.sec', `漫畫檔（${list.length}）`),
      list.length ? h('div.grid.posters', list.map((b) => card(bookItem(b), () => openBookFile(b.file), { progress: data.progressOf(data.historyOf(`local_${b.name}`)), onMenu: () => bookMenu(b, render) }))) : emptyView('書櫃是空的。下載的漫畫會放在這裡', 'library'),
    )
  }
  const reload = async () => {
    el.replaceChildren(loading())
    books = (await window.hub.lib.list()).filter((b) => !b.error)
    render()
  }
  reload()
  return el
}

const bookItem = (b) => ({ src: 'local', id: b.name, title: b.title || b.name, cover: b.pages?.length ? `cbz://book/${b.id}/0` : '', sub: `${b.pageCount} 頁`, type: 'comic', poster: true })

function coverOfCol(c) {
  const b = books.find((x) => x.name === (c.cover || c.files[0]))
  return b?.pages?.length ? `cbz://book/${b.id}/0` : ''
}

async function openBookFile(file) {
  const r = await window.hub.lib.open(file)
  if (!r?.ok) return toast(r?.error || '打不開這個檔案')
  const b = r.book
  const it = bookItem(b)
  const hh = data.historyOf(`local_${b.name}`)
  openReader({
    title: it.title,
    pages: b.pages.map((_, i) => ({ url: `cbz://book/${b.id}/${i}`, segs: 0 })),
    startPage: hh && hh.total === b.pageCount ? hh.page : 0,
    onProgress: (pg, total) => data.addHistory({ item: it, page: pg, total }),
  })
}

function openBook(name) {
  const b = books.find((x) => x.name === name)
  if (b) openBookFile(b.file)
  else toast('找不到這本（可能已被刪除）')
}

async function openCollection(c) {
  const list = c.files.map((f) => books.find((b) => b.name === f)).filter(Boolean)
  const pages = []
  const toc = []
  for (const x of list) {
    const r = await window.hub.lib.open(x.file)
    if (!r?.ok) continue
    const b = r.book
    toc.push({ title: b.title || b.name, start: pages.length, count: b.pageCount })
    b.pages.forEach((_, i) => pages.push({ url: `cbz://book/${b.id}/${i}`, segs: 0 }))
  }
  if (!pages.length) return toast('合集是空的')
  const it = { src: 'local', id: `col_${c.id}`, title: c.name, cover: coverOfCol(c), type: 'comic', poster: true }
  const hh = data.historyOf(`local_col_${c.id}`)
  openReader({ title: c.name, pages, toc, startPage: hh && hh.total === pages.length ? hh.page : 0, onProgress: (pg, total) => data.addHistory({ item: it, page: pg, total }) })
}

async function bookMenu(b, rerender) {
  const cols = store.get('collections', [])
  const p = await pick(b.title || b.name, [['read', '閱讀'], ['col', '加入合集'], ['show', '在資料夾中顯示'], ['trash', '刪除檔案（移到資源回收筒）']], null)
  if (p === 'read') openBookFile(b.file)
  else if (p === 'show') window.hub.cbz.show(b.file)
  else if (p === 'trash') {
    if (await confirmDialog('刪除漫畫檔', `把「${b.title || b.name}」移到資源回收筒？`, '刪除', true)) {
      await window.hub.lib.trash(b.file)
      books = books.filter((x) => x.file !== b.file)
      rerender()
    }
  } else if (p === 'col') {
    const t = await pick('加入哪個合集', [['new', '＋ 新的合集'], ...cols.map((c) => [c.id, c.name])], null)
    if (!t) return
    const next = cols.map((c) => ({ ...c, files: c.files.filter((f) => f !== b.name) }))
    if (t === 'new') {
      const name = await promptDialog('合集名稱', b.title || b.name)
      if (!name?.trim()) return
      next.push({ id: String(Date.now()), name: name.trim(), files: [b.name], cover: '' })
    } else next.find((c) => c.id === t).files.push(b.name)
    store.set('collections', next)
    rerender()
  }
}

async function collectionMenu(c, rerender) {
  const p = await pick(c.name, [['read', '閱讀'], ['rename', '改名'], ...c.files.map((f, i) => [`out_${i}`, `移出：${books.find((b) => b.name === f)?.title || f}`]), ['dissolve', '解散合集（檔案不會刪）']], null)
  const cols = store.get('collections', [])
  const me = cols.find((x) => x.id === c.id)
  if (!p || !me) return
  if (p === 'read') return openCollection(c)
  if (p === 'rename') {
    const name = await promptDialog('合集名稱', c.name)
    if (name?.trim()) me.name = name.trim()
  } else if (p === 'dissolve') cols.splice(cols.indexOf(me), 1)
  else me.files.splice(Number(p.slice(4)), 1)
  store.set('collections', cols)
  rerender()
}

// ============ 我的 ============

function mePage() {
  const el = h('div.page')
  const accounts = h('div.accounts')
  const sites = ['va', 'nh', 'jm', 'wn', 'eh']
  const renderAccounts = () => {
    accounts.replaceChildren(...sites.map(accountCard))
  }
  function accountCard(k) {
    const card2 = h('div.account', h('div.acc-head', icon('user'), h('div', h('b', label(k)), h('span.muted', '檢查中…'))))
    window.hub.authStatus(k).then((s) => {
      if (k === 'jm' && s.name) src('jm').username = s.name
      const sub = s.loggedIn ? (s.name ? `已登入：${s.name}` : '已登入') : s.expired ? (k === 'jm' ? `${label(k)} 的登入已失效（同一個帳號只能在一個地方保持登入），請重新登入` : '登入已過期，請重新登入') : s.error ? `無法確認：${s.error}` : '未登入'
      card2.className = `account${s.loggedIn ? ' on' : ''}${s.expired ? ' expired' : ''}`
      card2.replaceChildren(
        h('div.acc-head', icon('user'), h('div', h('b', label(k)), h('span.muted', sub))),
        h(
          'div.chips',
          !s.loggedIn ? btn('登入', async () => (await loginSite(k), renderAccounts()), { primary: true, icon: 'login' }) : btn('登出', async () => (await confirmDialog(`登出 ${label(k)}`, '登出後網站帳號的收藏就不會顯示（本機收藏不受影響）', '登出')) && (await window.hub.logout(k), renderAccounts()), { icon: 'logout' }),
          k === 'jm' && s.loggedIn ? btn('帳號名稱', async () => {
            const v = await promptDialog('帳號名稱（讀取收藏用）', s.name || '')
            if (v == null) return
            await window.hub.setAccountName('jm', v)
            src('jm').username = v.trim()
            renderAccounts()
          }) : null,
          k === 'jm' && s.loggedIn && s.remembered ? btn('忘記記住的密碼', async () => (await window.hub.rememberLogin('jm', false), toast('已忘記'), renderAccounts())) : null,
          k === 'va' && s.loggedIn ? btn('清除網站觀看紀錄', async () => {
            if (!(await confirmDialog('清除網站觀看紀錄', '清除網站帳號上的所有觀看紀錄？', '清除', true))) return
            try {
              await src('va').clearHistory()
              toast('已清除')
            } catch (e) {
              toast(e.message)
            }
          }) : null,
          btn('開啟網站', () => window.hub.openSite(k, base(k) + '/'), { icon: 'globe' }),
        ),
      )
    })
    return card2
  }
  const settingRow = (ic, title, sub, onClick) => h('button.setting', { type: 'button', on: { click: onClick } }, icon(ic), h('div', h('b', title), sub ? h('span.muted', sub) : null), icon('right'))
  const render = () => {
    const hidden = data.setting('homeHidden', [])
    el.replaceChildren(
      h('h2.group', '網站帳號'),
      h('p.muted', '登入都是在網站自己的登入頁（或網站的登入表單）完成，程式只記帳號名稱。'),
      accounts,
      h('h2.group', '設定'),
      settingRow('house', '首頁顯示的來源', MAIN_KEYS.filter((k) => !hidden.includes(k)).map(label).join('、') || '全部隱藏', async () => {
        const k = await pick('切換首頁顯示（點一下切換）', MAIN_KEYS.map((x) => [x, `${hidden.includes(x) ? '□' : '■'} ${label(x)}`]), null)
        if (!k) return
        data.setSetting('homeHidden', hidden.includes(k) ? hidden.filter((x) => x !== k) : [...hidden, k])
        render()
      }),
      settingRow('lang', '漫畫語言', Lang.filter ? Lang.names[Lang.filter] : '全部', async () => {
        const v = await pick('只看這個語言', [['', '全部'], ...Object.entries(Lang.names)], Lang.filter)
        if (v == null) return
        Lang.filter = v
        data.setSetting('lang', v)
        render()
      }),
      settingRow('globe', '網站網址', '網站換網域時可以在這裡改', async () => {
        const k = await pick('要改哪個網站的網址', MAIN_KEYS.map((x) => [x, `${label(x)}：${base(x)}`]), null)
        if (!k) return
        const v = await promptDialog(`${label(k)} 的網址（留空 = 預設）`, base(k))
        if (v == null) return
        const r = await window.hub.setBase(k, v)
        if (!r.ok) return toast(r.error)
        await loadConfig()
        toast(`已更新 ${label(k)} 的網址`)
        render()
      }),
      settingRow('folder', '影片下載資料夾', '', async () => toast(`影片會存到：${await window.hub.vdl.chooseDir()}`)),
      settingRow('folder', '漫畫下載資料夾', '', async () => toast(`漫畫會存到：${await window.hub.cbz.chooseDir()}`)),
      settingRow('history', '匯出紀錄備份', '收藏、紀錄、閱讀進度、書櫃合集', async () => {
        const r = await window.hub.backup.export()
        if (r?.ok) toast('已匯出')
      }),
      settingRow('refresh', '匯入紀錄備份', '', async () => {
        const r = await window.hub.backup.import()
        if (r?.ok) {
          toast('已匯入，重新載入中…')
          setTimeout(() => location.reload(), 800)
        } else if (r?.error) toast(r.error)
      }),
      settingRow('shield', '修復程式', '開不起來或畫面怪怪的時候用（紀錄和登入會保留）', async () => (await confirmDialog('修復程式', '程式會重新開啟，清掉瀏覽器的暫存資料（紀錄和登入會保留）', '修復')) && window.hub.repair()),
      h('h2.group', '關於'),
      settingRow('refresh', '檢查更新', `目前版本 ${versionLabel()}`, () => checkUpdate(true)),
      settingRow('history', '更新紀錄', '', showChangelog),
    )
  }
  renderAccounts()
  render()
  return { title: '我的', el }
}

function vaLoginDialog() {
  return new Promise((resolve) => {
    const email = h('input.field', { type: 'email', placeholder: '電郵', autocomplete: 'username', autofocus: true })
    const pass = h('input.field', { type: 'password', placeholder: '密碼', autocomplete: 'current-password' })
    const err = h('p.err')
    const submit = async () => {
      if (!email.value.trim() || !pass.value) return (err.textContent = '請輸入電郵和密碼')
      err.textContent = '登入中…'
      const e = await src('va').login(email.value, pass.value)
      if (e) return (err.textContent = e)
      d.close()
      toast(`已登入 ${label('va')}`)
      resolve(true)
    }
    pass.addEventListener('keydown', (e) => e.key === 'Enter' && submit())
    const d = dialog(`登入 ${label('va')}`, [email, pass, err, h('p.muted', '密碼只會送到網站，程式不會儲存。')], [btn('取消', () => (d.close(), resolve(false))), btn('登入', submit, { primary: true })])
  })
}

// ============ 更新 ============

const versionLabel = () => (window.APP_VERSION ? `v1.0.${window.APP_VERSION}` : '開發版')

async function fetchReleases() {
  const r = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=30`, { headers: { Accept: 'application/vnd.github+json' } })
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return (await r.json())
    .filter((x) => !x.draft)
    .map((x) => {
      const lines = String(x.body || '').split('\n---')[0].split('\n').map((l) => l.trim()).filter((l) => l && !/^Co-Authored-By/i.test(l))
      return { build: Number(String(x.tag_name).split('.').pop()) || 0, tag: x.tag_name, title: (lines[0] || x.tag_name).replace(/^[-*]\s*/, ''), notes: lines.slice(1).map((l) => l.replace(/^[-*]\s*/, '')), date: String(x.published_at || '').slice(0, 10), zip: (x.assets || []).find((a) => a.name === ZIP_NAME)?.browser_download_url }
    })
}

async function checkUpdate(manual = false) {
  if (!window.APP_VERSION) return manual && toast('開發版不會自動更新')
  try {
    const list = await fetchReleases()
    const r = list.find((x) => x.zip)
    if (!r || r.build <= window.APP_VERSION) return manual && toast('已經是最新版')
    if (!manual && store.get('skippedVersion', 0) === r.build) return
    const progress = h('div.bar', h('div'))
    const status = h('p.muted')
    const d = dialog(`有新版本 ${r.tag}`, [h('b', r.title), h('ul', r.notes.map((n) => h('li', n))), status, progress], [
      btn('略過這個版本', () => (store.set('skippedVersion', r.build), d.close())),
      btn('稍後', () => d.close()),
      btn('更新', async () => {
        if (!(await window.updater.supported())) return toast('開發模式不能更新')
        try {
          status.textContent = '下載中…'
          await window.updater.download(r.zip, (p) => (progress.firstChild.style.width = `${Math.round(p * 100)}%`))
          status.textContent = '下載完成，重新啟動中…'
          await window.updater.install()
        } catch (e) {
          status.textContent = `更新失敗：${e.message || e}`
        }
      }, { primary: true }),
    ])
  } catch (e) {
    if (manual) toast(`檢查失敗：${e.message || e}`)
  }
}

async function showChangelog() {
  const body = h('div', loading())
  dialog('更新紀錄', body, [], { wide: true })
  try {
    const list = await fetchReleases()
    body.replaceChildren(...list.map((r) => h('div.release', h('div', h('b', r.tag), h('span.muted', `  ${r.date}`)), h('p', r.title), r.notes.length ? h('ul', r.notes.map((n) => h('li', n))) : null)))
  } catch (e) {
    body.replaceChildren(h('p.err', `讀不到更新紀錄：${e.message || e}`))
  }
}

// ============ 開始 ============

async function start() {
  await loadConfig()
  Lang.filter = data.setting('lang', '')
  window.hub.vdl.onUpdate((j) => {
    const i = videoJobs.findIndex((x) => x.id === j.id)
    if (i >= 0) videoJobs[i] = j
    else videoJobs.unshift(j)
    updateDlBadge()
  })
  window.hub.vdl.onRemoved((id) => {
    videoJobs = videoJobs.filter((x) => x.id !== id)
    updateDlBadge()
  })
  videoJobs = await window.hub.vdl.list()
  cdl.onChange(updateDlBadge)
  document.getElementById('version').textContent = versionLabel()
  document.getElementById('version').addEventListener('click', showChangelog)
  window.hub.lib.list().then((b) => (books = b.filter((x) => !x.error))).catch(() => {})
  goTab('home')
  setTimeout(() => checkUpdate(false), 4000)
}

start()
  .catch((e) => {
    console.error(e)
    view.replaceChildren(errorView(e, () => location.reload()))
  })
  .finally(() => window.hub.ready())

window.__app = { push, goTab, openItem, detailPage, listPage, sourcePage, searchPage, NetError }
