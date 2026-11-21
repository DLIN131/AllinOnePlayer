// va：網站沒有 API，全部從 HTML 解析（有 Cloudflare，主程序會開驗證視窗）。播放是 HLS，CDN 要帶網站的 Referer / Origin。
import { abs, base, enc, LoginError, NetError, parse, raw, text, txt } from '../net.js'

const b64 = (s) => new TextDecoder().decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)))
const CATS = JSON.parse(
  b64(
    'W1si5pyA6L+R5pu05pawIiwiL2RtNTM5L25ldyJdLFsi5paw5L2c5LiK5biCIiwiL2RtNjM1L3JlbGVhc2UiXSxbIuS4reaWh+Wtl+W5lSIsIi9kbTI3OC9jaGluZXNlLXN1YnRpdGxlIl0sWyLku4rml6XnhrHploAiLCIvZG0zMDEvdG9kYXktaG90Il0sWyLmnKzpgLHnhrHploAiLCIvZG0xNzAvd2Vla2x5LWhvdCJdLFsi5pys5pyI54ax6ZaAIiwiL2RtMjczL21vbnRobHktaG90Il0sWyLnhKHnorzmtYHlh7oiLCIvZG04MTcvdW5jZW5zb3JlZC1sZWFrIl0sWyJWUiIsIi9nZW5yZXMvVlIiXSxbIlNJUk8iLCIvZG0zNi9zaXJvIl0sWyJMVVhVIiwiL2RtMzQvbHV4dSJdLFsiR0FOQSIsIi9kbTM0L2dhbmEiXSxbIlBSRVNUSUdFIiwiL2RtMTAwNC9tYWFuIl0sWyJGQzIiLCIvZG01OTcvZmMyIl0sWyJIRVlaTyIsIi9kbTIyMDg2NDIvaGV5em8iXSxbIuadseS6rOeGsSIsIi9kbTQyL3Rva3lvaG90Il0sWyLkuIDmnKzpgZMiLCIvZG00NTUxMTc0LzFwb25kbyJdLFsiQ2FyaWJiZWFuY29tIiwiL2RtNjg0MDUyMS9jYXJpYmJlYW5jb20iXSxbIjEwbXVzdW1lIiwiL2RtNjIzODY4Mi8xMG11c3VtZSJdLFsi6bq76LGGIiwiL2RtNjMvbWFkb3UiXV0=',
  ),
)

const SORTS = [
  ['', '預設'],
  ['released_at', '發行日期'],
  ['published_at', '最近更新'],
  ['saved', '收藏數'],
  ['today_views', '今日瀏覽'],
  ['weekly_views', '本週瀏覽'],
  ['monthly_views', '本月瀏覽'],
  ['views', '總瀏覽數'],
]
export const CASTS = [
  ['', '全部'],
  ['individual', '單人作品'],
  ['multiple', '多人作品'],
]
const CENSORS = [
  ['', '全部'],
  ['c', '有碼'],
  ['u', '無碼'],
]

const K = 'va'

function withParams(url, page, sort, filters = '') {
  const p = []
  if (filters) p.push(`filters=${filters}`)
  if (sort) p.push(`sort=${sort}`)
  if (page > 1) p.push(`page=${page}`)
  return p.length ? url + (url.includes('?') ? '&' : '?') + p.join('&') : url
}

const hasNext = (d, page) => !!d.querySelector(`a[href*="page=${page + 1}"]`)

function cards(d) {
  const out = new Map()
  for (const card of d.querySelectorAll('div.thumbnail')) {
    const a = card.querySelector('a[href]')
    if (!a) continue
    const code = abs(a.getAttribute('href'), base(K)).split('/').pop().split('?')[0].split('#')[0]
    if (!code || out.has(code)) continue
    const img = card.querySelector('img')
    const cover = abs(img?.getAttribute('data-src') || img?.getAttribute('src'), base(K))
    const title = txt(card.querySelector('div.my-2 a')) || (img?.getAttribute('alt') || '').trim()
    out.set(code, { src: K, id: code, title, cover, sub: txt(card.querySelector('span.absolute')), type: 'video' })
  }
  return [...out.values()]
}

const censor = (items, c) => (c === 'c' ? items.filter((v) => !v.id.includes('uncensored')) : c === 'u' ? items.filter((v) => v.id.includes('uncensored')) : items)

/** 播放網址藏在 p,a,c,k,e,d 打包過的 JS 裡，先解開再找 m3u8 */
export function findPlaylist(html) {
  const m3u8 = /https?:\/\/[^'"\s]+?\.m3u8/g
  const packed = /eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)/gs
  for (const m of html.matchAll(packed)) {
    const words = m[4].split('|')
    const radix = Math.min(36, Math.max(2, Number(m[2])))
    const code = m[1].replace(/\\'/g, "'").replace(/\b\w+\b/g, (w) => {
      const i = parseInt(w, radix)
      return /^[0-9a-z]+$/i.test(w) && !Number.isNaN(i) && i.toString(radix) === w.toLowerCase() && i < words.length && words[i] ? words[i] : w
    })
    const all = [...code.matchAll(m3u8)].map((x) => x[0])
    if (all.length) return all.find((u) => u.endsWith('playlist.m3u8')) || all[0]
  }
  return (html.match(m3u8) || [])[0] || null
}

export function vaEmail(html) {
  if (!html.includes("showDropdown = 'user'")) return null
  const m = html.match(/登入為\s*<\/p>\s*<p[^>]*>\s*([^<]+?)\s*<\/p>/)
  return m ? m[1].trim() : '已登入'
}

async function accountList(path, page) {
  const html = await text(K, withParams(path, page, ''))
  if (!vaEmail(html)) throw new LoginError(K)
  const d = parse(html)
  const items = cards(d)
  return { items, hasMore: items.length > 0 && hasNext(d, page) }
}

export const actressLink = (name, url) => ({ src: K, title: name, params: { section: 'videos', url, actress: '1' } })

export const va = {
  key: K,
  kind: 'video',
  hasAccount: true,
  sections: [
    {
      id: 'videos',
      title: '影片',
      filters: [
        { key: 'cat', label: '分類', options: CATS.map(([n, p]) => [p, n]) },
        { key: 'sort', label: '排序', options: SORTS },
        { key: 'censor', label: '有碼/無碼', options: CENSORS },
      ],
    },
    { id: 'actresses', title: '女優' },
  ],
  searchFilters: [
    { key: 'sort', label: '排序', options: SORTS },
    { key: 'censor', label: '有碼/無碼', options: CENSORS },
  ],
  imageHeaders: () => ({ Referer: base(K) + '/' }),
  idTag: (id) => id,

  async list(p, page) {
    if (p.section === 'actresses') {
      const d = parse(await text(K, withParams('/actresses', page, '')))
      const items = []
      for (const li of d.querySelectorAll('li')) {
        const name = txt(li.querySelector('h4'))
        const a = li.querySelector('a[href]')
        if (!name || !a) continue
        items.push({
          src: K,
          id: abs(a.getAttribute('href'), base(K)),
          title: name,
          cover: abs(li.querySelector('img')?.getAttribute('src'), base(K)),
          sub: [...li.querySelectorAll('p')].map(txt).join(' · '),
          type: 'actress',
          poster: true,
        })
      }
      return { items, hasMore: items.length > 0 && hasNext(d, page) }
    }
    if (p.section === 'account') return accountList(p.path || '/saved', page)
    const url = p.url || p.cat || CATS[0][1]
    const d = parse(await text(K, withParams(url, page, p.sort || '', p.filters || '')))
    const all = cards(d)
    return { items: censor(all, p.censor || ''), hasMore: all.length > 0 && hasNext(d, page) }
  },

  async search(q, page, p = {}) {
    const d = parse(await text(K, withParams(`/search/${enc(q.trim())}`, page, p.sort || '')))
    const all = cards(d)
    return { items: censor(all, p.censor || ''), hasMore: all.length > 0 && hasNext(d, page) }
  },

  favorites: (page) => accountList('/saved', page),
  accountList,

  async detail(item) {
    const html = await text(K, `/${item.id}`)
    const d = parse(html)
    const rows = []
    const seen = new Set()
    for (const div of d.querySelectorAll('div.space-y-2 > div')) {
      const t = div.textContent.trim()
      const i = t.indexOf(':')
      if (i <= 0) continue
      const lbl = t.slice(0, i).trim()
      if (!lbl || lbl.length > 8 || seen.has(lbl)) continue
      seen.add(lbl)
      const links = [...div.querySelectorAll('a[href]')]
        .map((a) => {
          const url = abs(a.getAttribute('href'), base(K))
          return { src: K, title: a.textContent.trim(), params: { section: 'videos', url, ...(url.includes('/actresses/') ? { actress: '1' } : {}) } }
        })
        .filter((l) => l.title)
      rows.push({ label: lbl, text: t.slice(i + 1).trim(), links })
    }
    const cover = d.querySelector('meta[property="og:image"]')?.getAttribute('content') || item.cover
    const title = txt(d.querySelector('h1')) || item.title
    return {
      item: { src: K, id: item.id, title, cover: cover.replace('cover-n.jpg', 'cover-t.jpg'), sub: item.sub, type: 'video' },
      title,
      subtitle: item.id.toUpperCase(),
      cover,
      description: '',
      info: rows,
      tags: [],
      related: [],
      episodes: [],
      chapters: [],
      url: `${base(K)}/${item.id}`,
      extra: { playlist: findPlaylist(html), itemId: (html.match(/\/api\/items\/([A-Za-z0-9]+)\/(?:save|view)/) || [])[1] || null },
    }
  },

  async stream(d) {
    const url = d.extra.playlist
    if (!url) throw new NetError('找不到播放網址（網站可能改版）')
    return { kind: 'hls', url, headers: { Referer: base(K) + '/', Origin: base(K) } }
  },

  // ---------- 帳號 ----------
  async itemView(itemId) {
    const r = await raw(K, `/api/items/${itemId}/view`, { api: true })
    if (!r.ok) return null
    try {
      const o = JSON.parse(r.data)
      return o.user == null ? null : !!o.saved
    } catch {
      return null
    }
  },
  async setSaved(itemId, on) {
    const r = await raw(K, `/api/items/${itemId}/save`, { api: true, method: on ? 'POST' : 'DELETE', body: '{}' })
    if (r.status === 401) throw new LoginError(K)
    if (!r.ok) throw new NetError(`網站回應 HTTP ${r.status}`)
  },
  async clearHistory() {
    const r = await raw(K, '/api/history', { api: true, method: 'DELETE', body: '{}' })
    if (r.status === 401) throw new LoginError(K)
    if (!r.ok) throw new NetError(`網站回應 HTTP ${r.status}`)
  },
  /** 登入；成功回傳 null，失敗回傳原因 */
  async login(email, password) {
    const r = await raw(K, '/api/login', { api: true, method: 'POST', body: JSON.stringify({ email: email.trim(), password, remember: true }) })
    if (r.ok) {
      try {
        const who = vaEmail(await text(K, '/saved'))
        return who ? null : '登入沒有成功，請再試一次'
      } catch {
        return null
      }
    }
    if (r.status === 422) {
      try {
        const o = JSON.parse(r.data)
        const first = o.errors && Object.values(o.errors)[0]
        return (Array.isArray(first) && first[0]) || o.message || '電郵或密碼不正確'
      } catch {
        return '電郵或密碼不正確'
      }
    }
    if (r.status === 429) return '嘗試太多次了，請稍後再試'
    return r.error || `登入失敗（HTTP ${r.status}）`
  },
}

/** 用番號查女優（另一個站，沒有 Cloudflare）：搜尋是模糊比對，只留番號真的對得上的 */
const lookupCache = new Map()
export const normalizeCode = (code) =>
  code
    .trim()
    .toLowerCase()
    .replace(/-(uncensored-leak|chinese-subtitle|english-subtitle|uncensored|leak)$/, '')
    .toUpperCase()

export async function lookupActresses(code) {
  const q = normalizeCode(code)
  if (lookupCache.has(q)) return lookupCache.get(q)
  const d = parse(await text('vx', `${base('vx')}/?s=${enc(q)}`))
  const esc = q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const ok = (t) => t === q || new RegExp(`^\\d+${esc}$`).test(t)
  const out = new Map()
  for (const art of d.querySelectorAll('article.archive-list')) {
    const texts = [...art.querySelectorAll('ul.post-meta li')].map((li) => li.textContent.trim().toUpperCase())
    if (!texts.some(ok)) continue
    for (const a of art.querySelectorAll('li.actress-name a')) {
      const name = a.textContent.trim()
      if (name && !out.has(name)) out.set(name, name)
    }
  }
  const list = [...out.values()]
  lookupCache.set(q, list)
  return list
}
