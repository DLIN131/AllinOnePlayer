// 本機資料：收藏、紀錄、續播位置、搜尋字、設定（存在主程序的 state.json，見 store.js）
import { store } from './store.js'

const listeners = new Set()
export const onData = (fn) => (listeners.add(fn), () => listeners.delete(fn))
const changed = () => listeners.forEach((fn) => fn())

const key = (it) => `${it.src}_${it.id}`
const slim = (it) => ({ src: it.src, id: it.id, title: it.title, cover: it.cover, sub: it.sub || '', type: it.type || 'video', poster: !!it.poster, lang: it.lang || '' })

// ---------- 收藏 ----------

export const favorites = () => store.get('favorites', []).map((e) => e.item)
export const isFavorite = (k) => store.get('favorites', []).some((e) => key(e.item) === k)
export function setFavorite(it, on) {
  const list = store.get('favorites', []).filter((e) => key(e.item) !== key(it))
  if (on) list.unshift({ item: slim(it), t: Date.now() })
  store.set('favorites', list)
  changed()
}

// ---------- 紀錄 ----------

/** { item, t, pos, dur（秒）, ch, cht, page, total, ep } */
export const history = () => store.get('history', [])
export const historyOf = (k) => history().find((h) => key(h.item) === k) || null
export function addHistory(entry) {
  const list = history().filter((h) => key(h.item) !== key(entry.item))
  list.unshift({ ...entry, item: slim(entry.item), ep: entry.ep ? slim(entry.ep) : undefined, t: Date.now() })
  store.set('history', list.slice(0, 500))
  changed()
}
export function removeHistory(k) {
  store.set('history', history().filter((h) => key(h.item) !== k))
  changed()
}
export function clearHistory(comics) {
  store.set('history', comics == null ? [] : history().filter((h) => (h.item.type === 'comic') !== comics))
  changed()
}
export const progressOf = (h) => (!h ? 0 : h.item.type === 'comic' ? (h.total ? (h.page + 1) / h.total : 0) : h.dur ? h.pos / h.dur : 0)

// ---------- 續播位置（秒；劇集的每一集各自記） ----------

export const position = (k) => store.get('positions', {})[k] || 0
export function setPosition(k, sec) {
  const m = { ...store.get('positions', {}) }
  if (sec > 0) m[k] = sec
  else delete m[k]
  const keys = Object.keys(m)
  if (keys.length > 800) delete m[keys[0]]
  store.set('positions', m)
}

// ---------- 搜尋字、設定 ----------

export const searches = () => store.get('searches', [])
export function addSearch(q) {
  q = q.trim()
  if (!q) return
  store.set('searches', [q, ...searches().filter((x) => x !== q)].slice(0, 20))
}
export const clearSearches = () => store.set('searches', [])

export const setting = (k, d) => store.get('settings', {})[k] ?? d
export function setSetting(k, v) {
  const s = { ...store.get('settings', {}) }
  if (v == null) delete s[k]
  else s[k] = v
  store.set('settings', s)
  changed()
}
