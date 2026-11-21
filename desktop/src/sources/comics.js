// 漫畫四站（nh、jm、wn、eh）：語言判斷、編號搜尋、各站轉接層。資料格式跟影片來源一樣（見 ../sources.js）。
import { abs, base, enc, form, json, label, LoginError, NetError, parse, prefix, raw, text, txt } from '../net.js'

// ============ 語言 ============

export const Lang = {
  names: { zh: '中文', en: 'English', ja: '日本語' },
  short: { zh: '中', en: 'EN', ja: '日' },
  /** 目前的語言篩選（'' = 全部）；nh、eh 可以請伺服器篩，另外兩站在畫面端篩 */
  filter: '',
  rules: [
    ['zh', /chinese|中文|漢化|汉化|中国翻訳|中國翻譯|中国翻译|中譯|中译|个人翻译|個人翻譯|翻譯|翻译/i],
    ['en', /english|英文|英訳|英語|英语/i],
    ['ja', /japanese|日文|日語|日语|日本語/i],
  ],
  detect(...hints) {
    for (const h of hints) {
      if (!h || !String(h).trim()) continue
      for (const [lang, re] of this.rules) if (re.test(h)) return lang
    }
    return ''
  },
  bracketTags: (t) => (String(t || '').match(/[[【(（][^\]】)）]{1,30}[\]】)）]/g) || []).join(' '),
}

// ============ 編號搜尋、書名整理 ============

const hostName = (k) => {
  try {
    const p = new URL(base(k)).hostname.split('.')
    return p.length >= 2 ? p[p.length - 2] : p[0]
  } catch {
    return k
  }
}
const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

export const Query = {
  /** 編號：站別代號、站名、各站前綴＋編號 → 那一站；作品網址 → 依網址；純數字 → 每個漫畫站都試 */
  parseId(q) {
    const s = q.trim()
    const t = s.replace(/\s+/g, '')
    const one = (site, id) => ({ sites: [site], id: String(Number(id)) })
    let m = s.match(/\/g\/(\d+)\/([0-9a-f]{10})/)
    if (m && s.includes(hostName('eh'))) return { sites: ['eh'], id: `${m[1]}_${m[2]}` }
    m = s.match(/\/g\/(\d+)/)
    if (m && s.includes(hostName('nh'))) return one('nh', m[1])
    m = s.match(/\/(?:album|photo)\/(\d+)/)
    if (m) return one('jm', m[1])
    m = s.match(/aid-(\d+)/)
    if (m) return one('wn', m[1])
    for (const k of ['nh', 'jm', 'wn']) {
      const lbl = label(k)
      const names = [k, prefix(k), lbl, lbl.slice(0, 2), hostName(k)].filter(Boolean).map(escRe)
      m = t.match(new RegExp(`^(?:${names.join('|')})(\\d{1,9})$`, 'i'))
      if (m) return one(k, m[1])
    }
    m = t.match(/^\d{1,8}$/)
    if (m) return { sites: ['nh', 'jm', 'wn'], id: String(Number(m[0])), plain: true }
    return null
  },
  parseAuthors(title) {
    const m = title.match(/^\s*(?:\([^)]*\)\s*)?\[([^\]]+)]/)
    if (!m) return []
    const head = m[1]
    if (/翻訳|翻譯|汉化|漢化|chinese|english|中文|DL版|digital/i.test(head)) return []
    const inner = head.match(/^(.*?)\s*\(([^)]+)\)\s*$/)
    const names = inner ? [...inner[2].split(/[,、，]/), inner[1]] : head.split(/[,、，]/)
    return [...new Set(names.map((x) => x.trim()).filter((x) => x && x.length < 40))]
  },
  cleanTitle(t) {
    const s = t
      .split(/\s[|｜]\s/)[0]
      .replace(/\[[^\]]*]|\([^)]*\)|\{[^}]*}|【[^】]*】|（[^）]*）/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
    return s.length >= 2 ? s : t.trim()
  },
}

const comicItem = (o) => ({ type: 'comic', poster: true, sub: '', lang: '', ...o })

// ============ nh（官方 v2 API） ============

const NH_LANG = { 29963: 'zh', 12227: 'en', 6346: 'ja' }
const NH_LANG_NAME = { zh: 'chinese', en: 'english', ja: 'japanese' }
const NH_TYPE = { artist: '作者', group: '社團', parody: '原作', character: '角色', tag: '標籤', language: '語言', category: '分類' }

function nhImg(pre, p) {
  if (!p) return ''
  if (/^http/.test(p)) return p
  let h = 0
  for (const c of p) h = (h * 31 + c.charCodeAt(0)) | 0
  return `https://${pre}${Math.abs(h % 4) + 1}.${new URL(base('nh')).hostname}/${p.replace(/^\/+/, '')}`
}
const nhThumb = (o, k) => (o[k] && typeof o[k] === 'object' ? o[k].path : typeof o[k] === 'string' && o[k].trim() ? o[k] : null)

function nhItem(o) {
  const t = o.title || {}
  const title = o.english_title || o.japanese_title || t.english || `#${o.id}`
  const ids = o.tag_ids || []
  const lang = ['zh', 'en', 'ja'].find((l) => ids.some((i) => NH_LANG[i] === l)) || Lang.detect(Lang.bracketTags(title))
  const pages = o.num_pages || 0
  return comicItem({ src: 'nh', id: String(o.id), title, cover: nhImg('t', nhThumb(o, 'thumbnail')), sub: `${pages || '?'} 頁`, lang })
}

const nhPage = (o, page) => ({ items: (o.result || []).map(nhItem), hasMore: page < (o.num_pages || 1) })
const nhWithLang = (q) => [q.trim(), NH_LANG_NAME[Lang.filter] ? `language:${NH_LANG_NAME[Lang.filter]}` : ''].filter(Boolean).join(' ')

function nhDetail(o) {
  const id = String(o.id)
  const order = Object.keys(NH_TYPE)
  const rawTags = [...(o.tags || [])].sort((a, b) => order.indexOf(a.type) - order.indexOf(b.type))
  const t = o.title || {}
  const title = t.english || t.pretty || `#${id}`
  const pages = o.num_pages || 0
  const cover = nhImg('t', nhThumb(o, 'cover') || nhThumb(o, 'thumbnail'))
  const lang = Lang.detect(rawTags.filter((x) => x.type === 'language' && x.name !== 'translated').map((x) => x.name).join(' '))
  const up = o.upload_date ? new Date(o.upload_date * 1000) : null
  return {
    item: comicItem({ src: 'nh', id, title, cover, sub: `${pages} 頁`, lang }),
    title,
    subtitle: t.japanese || '',
    cover,
    description: '',
    tags: rawTags.map((x) => ({ src: 'nh', title: `${NH_TYPE[x.type] || x.type}：${x.name}`, params: { q: `${x.type}:"${x.name}"` } })),
    lang,
    info: [
      { label: '編號', text: `#${id}`, links: [] },
      { label: '頁數', text: String(pages), links: [] },
      { label: '收藏數', text: o.num_favorites != null ? String(o.num_favorites) : '-', links: [] },
      { label: '上傳', text: up ? up.toISOString().slice(0, 10).replace(/-/g, '/') : '-', links: [] },
    ],
    chapters: [],
    episodes: [],
    pages: pages || null,
    related: (o.related || []).map(nhItem),
    url: `${base('nh')}/g/${id}/`,
    extra: { reader: (o.pages || []).map((p) => ({ url: nhImg('i', p.path), segs: 0, w: p.width || 0, h: p.height || 0 })) },
  }
}

const NH_SORTS = [
  ['date', '最新'],
  ['popular-today', '今日熱門'],
  ['popular-week', '本週熱門'],
  ['popular', '歷來熱門'],
]

export const nh = {
  key: 'nh',
  kind: 'comic',
  hasAccount: true,
  sections: [
    { id: 'latest', title: '最新', filters: [{ key: 'sort', label: '排序', options: NH_SORTS }] },
    { id: 'fav', title: '網站收藏' },
  ],
  searchFilters: [{ key: 'sort', label: '排序', options: NH_SORTS }],
  imageHeaders: () => ({ Referer: base('nh') + '/' }),
  idTag: (id) => `#${id}`,
  async list(p, page) {
    if (p.section === 'fav') return nh.favorites(page)
    if (p.q != null) return nh.search(p.q, page, p)
    const sort = p.sort || 'date'
    if (sort === 'date' && !Lang.filter) return nhPage(await json('nh', `/api/v2/galleries?page=${page}&per_page=25`), page)
    return nh.search('', page, { sort })
  },
  async search(q, page, p = {}) {
    const query = enc(nhWithLang(q) || 'pages:>0')
    return nhPage(await json('nh', `/api/v2/search?query=${query}&sort=${p.sort || 'date'}&page=${page}`), page)
  },
  detail: async (it) => nhDetail(await json('nh', `/api/v2/galleries/${it.id}?include=related`)),
  async read(d) {
    if (d.extra.reader?.length) return d.extra.reader
    return (await nh.detail(d.item)).extra.reader
  },
  async favorites(page) {
    const r = await raw('nh', `/api/v2/favorites?page=${page}`, { json: true })
    if (r.status === 401 || r.status === 403) throw new LoginError('nh', `還沒登入${label('nh')}`)
    if (!r.ok) throw new NetError(r.error, r.status)
    return nhPage(r.data, page)
  },
  async isFavorite(id) {
    const o = await json('nh', `/api/v2/galleries/${id}/favorite`)
    return !!(o.favorited || o.is_favorite || o.favorite)
  },
  setFavorite: (id, on) => json('nh', `/api/v2/galleries/${id}/favorite`, { method: on ? 'POST' : 'DELETE' }),
}

// ============ jm（網頁，有 Cloudflare） ============

const JM_SORTS = [
  ['mr', '最新'],
  ['mv', '最多觀看'],
  ['tf', '最多喜歡'],
  ['mp', '最多圖片'],
]
const JM_LANG_TAG = { zh: '中文', en: '英文', ja: '日文' }
const JM_TYPE = { works: '作品', actor: '角色', tags: '標籤', author: '作者' }

function jmList(s, page) {
  const doc = parse(s)
  const seen = new Set()
  const items = []
  for (const a of doc.querySelectorAll('a[href*="/album/"]')) {
    const m = (a.getAttribute('href') || '').match(/\/album\/(\d+)/)
    const img = a.querySelector('img')
    if (!m || !img) continue
    const src = [img.getAttribute('data-original'), img.getAttribute('data-src'), img.getAttribute('src')].find((x) => x && !x.includes('blank.')) || ''
    const id = m[1]
    if (!src.includes('/media/albums/') || seen.has(id)) continue
    seen.add(id)
    const box = a.closest('.list-col, .well, .p-b-15') || a.parentElement?.parentElement
    const cat = [txt(box?.querySelector('.label-category')), txt(box?.querySelector('.label-sub'))].filter(Boolean).join('・')
    const title = txt(box?.querySelector('.video-title')) || img.getAttribute('title') || img.getAttribute('alt') || `JM${id}`
    const tagText = [...(box?.querySelectorAll('a.tag') || [])].map(txt).join(' ')
    items.push(comicItem({ src: 'jm', id, title, cover: abs(src, base('jm')), sub: cat, lang: Lang.detect(tagText, cat, Lang.bracketTags(title)) }))
  }
  return { items, hasMore: !!doc.querySelector(`.pagination a[href*="page=${page + 1}"]`) }
}

async function md5hex(s) {
  // Web Crypto 沒有 md5：用簡短的實作
  return md5(s)
}

/** 每張要切幾段由編號和檔名的 md5 決定 */
async function jmSegments(scrambleId, aid, file) {
  if (aid < scrambleId) return 0
  if (aid < 268850) return 10
  const x = aid < 421926 ? 10 : 8
  const h = await md5hex(`${aid}${file}`)
  return (h.charCodeAt(h.length - 1) % x) * 2 + 2
}

export const jm = {
  key: 'jm',
  kind: 'comic',
  hasAccount: true,
  username: '',
  sections: [
    { id: 'latest', title: '最新', filters: [{ key: 'sort', label: '排序', options: JM_SORTS }] },
    { id: 'fav', title: '網站收藏' },
  ],
  searchFilters: [{ key: 'sort', label: '排序', options: JM_SORTS }],
  imageHeaders: () => ({ Referer: base('jm') + '/' }),
  idTag: (id) => `JM${id}`,
  async list(p, page) {
    if (p.section === 'fav') return jm.favorites(page)
    if (p.q != null) return jm.search(p.q, page, p)
    const sort = p.sort || 'mr'
    if (Lang.filter) return jm.search('', page, { sort })
    return jmList(await text('jm', `/albums?o=${sort}&page=${page}`), page)
  },
  async search(q, page, p = {}) {
    let query = q.trim()
    const tag = JM_LANG_TAG[Lang.filter]
    if (tag) query = !query ? tag : /[\s+-]/.test(query) ? query : `+${query} +${tag}`
    return jmList(await text('jm', `/search/photos?search_query=${enc(query)}&o=${p.sort || 'mr'}&page=${page}`), page)
  },
  async detail(it) {
    const id = it.id
    const s = await text('jm', `/album/${id}/`)
    const doc = parse(s)
    const tags = []
    for (const span of doc.querySelectorAll('span[data-type]')) {
      const type = span.getAttribute('data-type')
      for (const a of span.querySelectorAll('a[class*="web-"]')) {
        const name = txt(a)
        if (name && !tags.some((t) => t.name === name && t.type === type)) tags.push({ type, name })
      }
    }
    const order = Object.keys(JM_TYPE)
    tags.sort((a, b) => order.indexOf(a.type) - order.indexOf(b.type))
    const chapters = []
    for (const a of doc.querySelectorAll('.episode a[href*="/photo/"]')) {
      const m = (a.getAttribute('href') || '').match(/\/photo\/(\d+)/)
      if (!m || chapters.some((c) => c.id === m[1])) continue
      const t = (txt(a.querySelector('h3, li')) || txt(a)).replace(/^(第\s*\d+\s*話)\s+(.*?)\s*\1$/, '$1 $2')
      chapters.push({ id: m[1], title: t })
    }
    const pageCount = (txt(doc.querySelector('.pagecount')).match(/\d+/) || [])[0]
    const date = doc.querySelector('[itemprop=datePublished]')?.getAttribute('content') || ''
    const cover = abs(doc.querySelector(`img[src*="/media/albums/${id}"]`)?.getAttribute('src'), base('jm'))
    const title = txt(doc.querySelector('#book-name, h1')) || `JM${id}`
    const lang = Lang.detect(tags.filter((t) => t.type === 'tags').map((t) => t.name).join(' '), Lang.bracketTags(title))
    return {
      item: comicItem({ src: 'jm', id, title, cover, sub: pageCount ? `${pageCount} 頁` : '', lang }),
      title,
      subtitle: '',
      cover,
      description: '',
      tags: tags.map((t) => ({ src: 'jm', title: `${JM_TYPE[t.type] || t.type}：${t.name}`, params: { q: t.name } })),
      lang,
      info: [
        { label: '編號', text: `JM${id}`, links: [] },
        { label: '頁數', text: pageCount || '-', links: [] },
        { label: '上架', text: date || '-', links: [] },
        { label: '章節', text: chapters.length ? `${chapters.length} 話` : '單本', links: [] },
      ],
      chapters,
      episodes: [],
      pages: Number(pageCount) || null,
      related: jmList(s, 1).items.filter((x) => x.id !== id).slice(0, 18),
      url: `${base('jm')}/album/${id}/`,
      extra: {},
    }
  },
  async read(d, chapterId) {
    const id = chapterId || d.item.id
    const s = await text('jm', `/photo/${id}`)
    const aid = Number((s.match(/var aid = (\d+);/) || [])[1] || id)
    const scramble = Number((s.match(/var scramble_id = (\d+);/) || [])[1] || 220980)
    let files = []
    try {
      files = JSON.parse((s.match(/var page_arr = (\[[^\]]*\]);/) || [])[1] || '[]')
    } catch {}
    const urls = {}
    for (const m of s.matchAll(new RegExp(`data-original="([^"]*/media/photos/${aid}/([^"?/]+)[^"]*)"`, 'g'))) if (!urls[m[2]]) urls[m[2]] = m[1]
    if (!files.length) files = Object.keys(urls)
    const cdn = (Object.values(urls)[0] || '').replace(/\/media\/photos\/.*$/, '') || base('jm').replace('//', '//cdn-msp.')
    if (!files.length) throw new NetError('找不到圖片')
    return Promise.all(
      files.map(async (f) => ({ url: urls[f] || `${cdn}/media/photos/${aid}/${f}`, segs: f.endsWith('.gif') ? 0 : await jmSegments(scramble, aid, f.replace(/\.[^.]+$/, '')) })),
    )
  },
  async favorites(page) {
    if (!jm.username) throw new LoginError('jm', '已登入，但讀不到帳號名稱。請到「我的」頁的帳號設定填寫你的帳號名稱，就能讀取收藏')
    const s = await text('jm', `/user/${enc(jm.username)}/favorite/albums?page=${page}`)
    const r = jmList(s, page)
    if (page === 1 && !r.items.length) {
      if (/^login\b/i.test(parse(s).title || '')) throw new LoginError('jm', '登入已失效，請到「我的」頁重新登入')
      throw new NetError(`帳號「${jm.username}」的收藏是空的。如果網站上明明有收藏，可能是帳號名稱不對，請到「我的」頁確認或修改`)
    }
    return r
  },
  async addFavorite(id) {
    const r = await raw('jm', '/ajax/favorite_album', { method: 'POST', body: form([['album_id', id], ['fid', '0']]), form: true, headers: { 'X-Requested-With': 'XMLHttpRequest' } })
    if (!r.ok) throw new NetError(r.error, r.status)
    let o
    try {
      o = JSON.parse(r.data)
    } catch {
      throw new NetError(/login/i.test(r.data) ? `還沒登入${label('jm')}` : '網站回應看不懂')
    }
    const msg = o.msg || o.message || ''
    if ((o.status ?? 1) !== 1) throw new NetError(msg || '收藏失敗')
    return msg || '已加到網站收藏'
  },
}

// ============ wn（網頁） ============

const WN_CATE_LANG = { 1: 'zh', 9: 'zh', 10: 'zh', 20: 'zh', 12: 'ja', 13: 'ja', 14: 'ja', 16: 'en', 17: 'en', 18: 'en' }

function wnList(s, page) {
  const doc = parse(s)
  const seen = new Set()
  const items = []
  for (const a of doc.querySelectorAll('a[href*="photos-index-aid-"]')) {
    const m = (a.getAttribute('href') || '').match(/aid-(\d+)/)
    const img = a.querySelector('img')
    if (!m || !img || seen.has(m[1])) continue
    const id = m[1]
    seen.add(id)
    const box = a.closest('li') || a.parentElement?.parentElement
    const info = txt(box?.querySelector('.info_col'))
    const pages = Number((info.match(/(\d+)\s*張/) || [])[1]) || null
    const title = a.getAttribute('title') || img.getAttribute('alt') || txt(box?.querySelector('.title')) || `#${id}`
    const cate = Number(((box?.querySelector('[class*="cate-"]')?.className || '').match(/cate-(\d+)/) || [])[1])
    items.push(comicItem({ src: 'wn', id, title, cover: abs(img.getAttribute('data-original') || img.getAttribute('src'), base('wn')), sub: pages ? `${pages} 頁` : '', lang: WN_CATE_LANG[cate] || Lang.detect(Lang.bracketTags(title)) }))
  }
  const pager = doc.querySelector('.paginator, .f_left.paginator')
  const next = new RegExp(`(page-|p=)${page + 1}\\b`)
  const hasMore = !!pager && [...pager.querySelectorAll('a')].some((a) => /後頁|下一頁|>/.test(txt(a)) || next.test(a.getAttribute('href') || ''))
  return { items, hasMore }
}

export const wn = {
  key: 'wn',
  kind: 'comic',
  hasAccount: true,
  sections: [
    { id: 'latest', title: '最新' },
    { id: 'fav', title: '網站收藏' },
  ],
  searchFilters: [],
  imageHeaders: () => ({ Referer: base('wn') + '/' }),
  idTag: (id) => `${prefix('wn')}${id}`,
  async list(p, page) {
    if (p.section === 'fav') return wn.favorites(page)
    if (p.q != null) return wn.search(p.q, page, p)
    if (!Lang.filter) return wnList(await text('wn', `/albums-index-page-${page}.html`), page)
    const cates = Object.entries(WN_CATE_LANG).filter(([, l]) => l === Lang.filter).map(([c]) => c)
    const pages = await Promise.all(cates.map(async (c) => wnList(await text('wn', `/albums-index-page-${page}-cate-${c}.html`), page)))
    return { items: pages.flatMap((p) => p.items).sort((a, b) => Number(b.id) - Number(a.id)), hasMore: pages.some((p) => p.hasMore) }
  },
  search: async (q, page) => wnList(await text('wn', `/search/index.php?q=${enc(q)}&m=&syn=yes&f=_all&s=create_time_DESC&p=${page}`), page),
  async detail(it) {
    const id = it.id
    const s = await text('wn', `/photos-index-aid-${id}.html`)
    const doc = parse(s)
    const coverImg = doc.querySelector('.uwthumb img')
    if (!coverImg) throw new NetError('找不到（可能已被刪除）', 404)
    const info = [{ label: '編號', text: `${prefix('wn')}${id}`, links: [] }]
    let pages = null
    for (const l of [...doc.querySelectorAll('.uwconn label')].map(txt).filter(Boolean)) {
      const parts = l.split(/[：:]/)
      if (parts.length < 2) continue
      const k = parts[0].trim()
      const v = parts.slice(1).join(':').trim()
      if (k.includes('頁數')) pages = Number((v.match(/\d+/) || [])[0]) || null
      if (!k.includes('編號')) info.push({ label: k, text: v, links: [] })
    }
    const category = info.find((r) => r.label.includes('分類'))?.text || ''
    const title = txt(doc.querySelector('#bodywrap h2, h2')) || `#${id}`
    const lang = Lang.detect(category, Lang.bracketTags(title))
    const cover = abs(coverImg.getAttribute('src'), base('wn'))
    return {
      item: comicItem({ src: 'wn', id, title, cover, sub: pages ? `${pages} 頁` : '', lang }),
      title,
      subtitle: '',
      cover,
      description: txt(doc.querySelector('.uwconn p')).replace(/^簡介[：:]\s*/, ''),
      tags: [...doc.querySelectorAll('a.tagshow')].map((a) => ({ src: 'wn', title: `標籤：${txt(a)}`, params: { q: txt(a) } })),
      lang,
      info,
      chapters: [],
      episodes: [],
      pages,
      related: wnList(s, 1).items.filter((x) => x.id !== id).slice(0, 18),
      url: `${base('wn')}/photos-index-aid-${id}.html`,
      extra: {},
    }
  },
  async read(d) {
    const js = await text('wn', `/photos-gallery-aid-${d.item.id}.html`)
    const list = []
    for (const m of js.matchAll(/url:\s*fast_img_host\+\\?"([^"\\]+)\\?",\s*caption:\s*\\?"([^"\\]*)/g)) {
      if (/\/(themes|static)\//.test(m[1]) || m[2].includes('收藏')) continue
      list.push([abs(m[1], base('wn')), m[2]])
    }
    const num = (c) => Number((c.match(/\d+/) || [])[0])
    if (list.every(([, c]) => /\d/.test(c))) list.sort((a, b) => num(a[1]) - num(b[1]))
    if (!list.length) throw new NetError('找不到圖片')
    return list.map(([url]) => ({ url, segs: 0 }))
  },
  async favorites(page) {
    const s = await text('wn', `/users-users_fav-page-${page}.html`)
    if (/users-login|login_name/i.test(s) && !s.includes('users-logout')) throw new LoginError('wn', `還沒登入${label('wn')}`)
    return wnList(s, page)
  },
}

// ============ eh（網頁） ============

const EH_JA = /doujinshi|manga|artist cg|game cg|non-h/i
const EH_LANG = { zh: 'chinese', en: 'english' }
const EH_NS = { language: '語言', parody: '原作', character: '角色', group: '社團', artist: '作者', cosplayer: 'Coser', male: '標籤', female: '標籤', mixed: '標籤', other: '標籤', reclass: '分類' }
const ehCursors = {}
const ehNl = {}
const ehSplit = (id) => {
  const i = id.indexOf('_')
  return i < 0 ? [id, ''] : [id.slice(0, i), id.slice(i + 1)]
}
const ehWithLang = (q) => [q.trim(), EH_LANG[Lang.filter] ? `language:${EH_LANG[Lang.filter]}$` : ''].filter(Boolean).join(' ')

function ehList(s) {
  const doc = parse(s)
  const items = []
  const seen = new Set()
  for (const a of doc.querySelectorAll('a[href*="/g/"]')) {
    const m = (a.getAttribute('href') || '').match(/\/g\/(\d+)\/([0-9a-f]{10})/)
    if (!m || seen.has(m[1])) continue
    const row = a.closest('tr, .gl1t')
    if (!row) continue
    const title = txt(a.querySelector('.glink')) || txt(row.querySelector('.glink'))
    if (!title) continue
    seen.add(m[1])
    const img = row.querySelector('img[data-src]') || row.querySelector('.glthumb img') || row.querySelector('img')
    const src = [img?.getAttribute('data-src'), img?.getAttribute('src')].find((x) => x && !x.startsWith('data:')) || ''
    const cat = txt(row.querySelector('.cn') || row.querySelector('.cs'))
    const pages = Number((txt(row).match(/(\d+)\s*pages?/) || [])[1]) || null
    const langTag = [...row.querySelectorAll('.gt, .gtl')].map((e) => e.getAttribute('title') || '').find((t) => t.startsWith('language:') && !t.endsWith('translated')) || ''
    let lang = Lang.detect(langTag, Lang.bracketTags(title))
    if (!lang && EH_JA.test(cat)) lang = 'ja'
    items.push(comicItem({ src: 'eh', id: `${m[1]}_${m[2]}`, title, cover: abs(src, base('eh')), sub: [cat, pages ? `${pages} 頁` : ''].filter(Boolean).join('・'), lang }))
  }
  return items
}

async function ehListPage(first, page) {
  const url = page > 1 ? ehCursors[first]?.[page] : first
  if (!url) return { items: [], hasMore: false }
  const s = await text('eh', url)
  const next = parse(s).querySelector('a#dnext, a#unext')?.getAttribute('href') || null
  if (next) (ehCursors[first] ||= {})[page + 1] = next
  return { items: ehList(s), hasMore: !!next }
}

const pageLinks = (s) => [...parse(s).querySelectorAll('#gdt a[href*="/s/"]')].map((a) => a.getAttribute('href')).filter(Boolean)

async function ehResolve(spage, retry) {
  let url = spage
  if (retry && ehNl[spage]) url += `${url.includes('?') ? '&' : '?'}nl=${ehNl[spage]}`
  const s = await text('eh', url)
  const src = (s.match(/<img id="img" src="([^"]+)"/) || [])[1]
  const nl = (s.match(/nl\('([^']+)'\)/) || [])[1]
  if (nl) ehNl[spage] = nl
  if (!src) throw new NetError(/limit/i.test(s) ? '已達網站的圖片瀏覽上限，請稍後再試或登入' : '找不到圖片')
  return src.replace(/&amp;/g, '&')
}

export const eh = {
  key: 'eh',
  kind: 'comic',
  hasAccount: true,
  sections: [
    {
      id: 'latest',
      title: '最新',
      filters: [
        {
          key: 'sort',
          label: '排序',
          options: [
            ['latest', '最新'],
            ['popular', '熱門'],
          ],
        },
      ],
    },
    { id: 'fav', title: '網站收藏' },
  ],
  searchFilters: [],
  imageHeaders: () => ({ Referer: base('eh') + '/' }),
  idTag: (id) => `EH${ehSplit(id)[0]}`,
  split: ehSplit,
  async list(p, page) {
    if (p.section === 'fav') return eh.favorites(page)
    if (p.q != null) return eh.search(p.q, page, p)
    if (p.sort === 'popular') return page > 1 ? { items: [], hasMore: false } : { items: ehList(await text('eh', '/popular')), hasMore: false }
    const q = ehWithLang('')
    return ehListPage(q ? `/?f_search=${enc(q)}` : '/', page)
  },
  search: (q, page) => ehListPage(`/?f_search=${enc(ehWithLang(q))}`, page),
  async detail(it) {
    const [gid, token] = ehSplit(it.id)
    if (!token) throw new NetError('需要完整的作品網址（含 token）')
    const url = `/g/${gid}/${token}/`
    let s = await text('eh', url)
    if (!parse(s).querySelector('#gn') && s.includes('nw=always')) s = await text('eh', `${url}?nw=always`)
    const doc = parse(s)
    if (!doc.querySelector('#gn')) throw new NetError(txt(doc.querySelector('.d p') || doc.querySelector('p')) || '找不到（可能已被刪除）', 404)
    const tags = []
    for (const tr of doc.querySelectorAll('#taglist tr')) {
      const ns = txt(tr.querySelector('.tc')).replace(/:$/, '')
      for (const a of tr.querySelectorAll('a')) {
        const name = txt(a)
        tags.push({ label: EH_NS[ns] || ns, name: ['male', 'female', 'mixed'].includes(ns) ? `${ns[0]}:${name}` : name, q: `${ns}:"${name}$"`, ns })
      }
    }
    const order = ['作者', '社團', '原作', '角色', '語言', '標籤']
    const rank = (l) => (order.includes(l) ? order.indexOf(l) : 99)
    tags.sort((a, b) => rank(a.label) - rank(b.label))
    const info = [{ label: '編號', text: gid, links: [] }]
    const zh = { Posted: '上傳', 'File Size': '大小', Length: '頁數', Favorited: '收藏數' }
    for (const tr of doc.querySelectorAll('#gdd tr')) {
      const k = txt(tr.querySelector('.gdt1')).replace(/:$/, '')
      if (zh[k]) info.push({ label: zh[k], text: txt(tr.querySelector('.gdt2')).replace(/\s*pages?$/, '').replace(/\s*times$/, ''), links: [] })
    }
    const pages = Number((txt(doc.querySelector('#gdd')).match(/(\d+)\s*pages?/) || [])[1]) || null
    const cover = ((doc.querySelector('#gd1 div')?.getAttribute('style') || '').match(/url\(([^)]+)\)/) || [])[1] || ''
    const langNames = tags.filter((t) => t.ns === 'language' && t.name !== 'translated').map((t) => t.name).join(' ')
    const title = txt(doc.querySelector('#gn'))
    let lang = Lang.detect(langNames, Lang.bracketTags(title))
    if (!lang && !langNames) lang = 'ja'
    const fav = txt(doc.querySelector('#favoritelink'))
    return {
      item: comicItem({ src: 'eh', id: `${gid}_${token}`, title, cover, sub: pages ? `${pages} 頁` : '', lang }),
      title,
      subtitle: txt(doc.querySelector('#gj')),
      cover,
      description: '',
      tags: tags.map((t) => ({ src: 'eh', title: `${t.label}：${t.name}`, params: { q: t.q } })),
      lang,
      info,
      chapters: [],
      episodes: [],
      pages,
      related: [],
      url: `${base('eh')}/g/${gid}/${token}/`,
      extra: { firstHtml: s, siteFav: fav && !/add to favorites/i.test(fav) ? fav : null },
    }
  },
  async read(d) {
    const [gid, token] = ehSplit(d.item.id)
    const first = pageLinks(d.extra.firstHtml || (await text('eh', `/g/${gid}/${token}/`)))
    const perPage = Math.max(1, first.length)
    const total = d.pages || first.length
    const rest = []
    for (let p = 1; p * perPage < total; p++) rest.push(p)
    const more = []
    for (let i = 0; i < rest.length; i += 4) {
      const got = await Promise.all(rest.slice(i, i + 4).map(async (p) => pageLinks(await text('eh', `/g/${gid}/${token}/?p=${p}`))))
      more.push(...got.flat())
    }
    const all = [...new Set([...first, ...more])]
    if (!all.length) throw new NetError('找不到圖片')
    return all.map((sp) => ({ url: '', segs: 0, resolve: (retry) => ehResolve(sp, retry) }))
  },
  favorites: (page) => ehListPage('/favorites.php', page),
}

// ============ 加到網站收藏（eh、wn 用網站自己的表單） ============

const isLoginPage = (html) => /requires you to log on|login_form|ipb_login_form|users-check_login|name="login_name"/i.test(html)

export function parseFavForm(html, pageUrl) {
  const doc = parse(html)
  const f = doc.querySelector('form')
  if (!f) return null
  const action = f.getAttribute('action') ? new URL(f.getAttribute('action'), pageUrl).href : pageUrl
  const fields = []
  let choiceName = null
  const choices = []
  let selected = null
  const t = (s) => (s || '').replace(/\s+/g, ' ').trim()
  const groups = {}
  for (const r of f.querySelectorAll('input[type=radio][name]')) (groups[r.name] ||= []).push(r)
  const group = Object.entries(groups).find(([, v]) => v.length > 1)
  if (group) {
    choiceName = group[0]
    for (const r of group[1]) {
      let lbl = r.id ? t(f.querySelector(`label[for="${r.id}"]`)?.textContent) : ''
      for (let p = r.parentElement, i = 0; !lbl && p && i < 3; p = p.parentElement, i++) lbl = t(p.textContent)
      choices.push([r.value, lbl || r.value])
      if (r.hasAttribute('checked')) selected = r.value
    }
  } else {
    const s = f.querySelector('select[name]')
    if (s) {
      choiceName = s.name
      for (const o of s.querySelectorAll('option')) {
        const v = o.getAttribute('value') || o.textContent
        choices.push([v, t(o.textContent)])
        if (o.hasAttribute('selected')) selected = v
      }
    }
  }
  if (!selected && choices.length) selected = choices[0][0]
  let submitAdded = false
  for (const i of f.querySelectorAll('input[name]')) {
    const type = (i.getAttribute('type') || '').toLowerCase()
    if (type === 'radio') {
      if (i.name !== choiceName && i.hasAttribute('checked')) fields.push([i.name, i.value])
    } else if (type === 'checkbox') {
      if (i.hasAttribute('checked')) fields.push([i.name, i.value || 'on'])
    } else if (type === 'submit') {
      if (!submitAdded) {
        fields.push([i.name, i.getAttribute('value') || ''])
        submitAdded = true
      }
    } else if (!['button', 'image', 'reset', 'file'].includes(type)) fields.push([i.name, i.getAttribute('value') || ''])
  }
  for (const ta of f.querySelectorAll('textarea[name]')) fields.push([ta.name, ta.textContent])
  for (const s of f.querySelectorAll('select[name]')) {
    if (s.name === choiceName) continue
    const o = s.querySelector('option[selected]') || s.querySelector('option')
    fields.push([s.name, o?.getAttribute('value') || ''])
  }
  return {
    action,
    choices,
    selected,
    body: (choice) => {
      const out = fields.filter(([k]) => k !== choiceName)
      const v = choice ?? selected
      if (choiceName && v != null) out.push([choiceName, v])
      return out
    },
  }
}

export async function siteFavForm(d) {
  const site = d.item.src
  let url
  if (site === 'eh') {
    const [gid, t] = ehSplit(d.item.id)
    url = `/gallerypopups.php?gid=${gid}&t=${t}&act=addfav`
  } else url = `/users-addfav-id-${d.item.id}.html`
  const r = await raw(site, url)
  if (!r.ok) throw new NetError(r.error, r.status)
  if (isLoginPage(r.data)) throw new LoginError(site, `還沒登入${label(site)}，登入後才能加到網站收藏`)
  return parseFavForm(r.data, base(site) + url) || (() => { throw new NetError('網站的收藏表單跟預期的不一樣') })()
}

export async function siteFavSubmit(d, f, choice) {
  const site = d.item.src
  const r = await raw(site, f.action, { method: 'POST', body: form(f.body(choice)), form: true })
  if (!r.ok) throw new NetError(r.error, r.status)
  if (isLoginPage(r.data)) throw new LoginError(site, `還沒登入${label(site)}，登入後才能加到網站收藏`)
  try {
    const o = JSON.parse(r.data)
    const m = o.msg || o.message || o.html
    if (m) return parse(m).body.textContent.slice(0, 80)
  } catch {}
  const t2 = (parse(r.data).body?.textContent || '').replace(/\s+/g, ' ').trim()
  return t2 && t2.length <= 60 ? t2 : choice === 'favdel' ? '已從網站收藏移除' : '已加到網站收藏'
}

// ============ md5（jm 切條數要用；Web Crypto 沒有 md5） ============

function md5(str) {
  const bytes = new TextEncoder().encode(str)
  const k = []
  for (let i = 0; i < 64; i++) k[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0
  const r = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
  const len = bytes.length
  const n = ((len + 8) >>> 6) + 1
  const w = new Uint32Array(n * 16)
  for (let i = 0; i < len; i++) w[i >> 2] |= bytes[i] << ((i % 4) * 8)
  w[len >> 2] |= 0x80 << ((len % 4) * 8)
  w[n * 16 - 2] = (len * 8) >>> 0
  w[n * 16 - 1] = Math.floor((len * 8) / 2 ** 32)
  let [a0, b0, c0, d0] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
  for (let i = 0; i < n * 16; i += 16) {
    let [a, b, c, d] = [a0, b0, c0, d0]
    for (let j = 0; j < 64; j++) {
      let f, g
      if (j < 16) [f, g] = [(b & c) | (~b & d), j]
      else if (j < 32) [f, g] = [(d & b) | (~d & c), (5 * j + 1) % 16]
      else if (j < 48) [f, g] = [b ^ c ^ d, (3 * j + 5) % 16]
      else [f, g] = [c ^ (b | ~d), (7 * j) % 16]
      const tmp = d
      d = c
      c = b
      const x = (a + f + k[j] + w[i + g]) >>> 0
      b = (b + ((x << r[j]) | (x >>> (32 - r[j])))) >>> 0
      a = tmp
    }
    a0 = (a0 + a) >>> 0
    b0 = (b0 + b) >>> 0
    c0 = (c0 + c) >>> 0
    d0 = (d0 + d) >>> 0
  }
  return [a0, b0, c0, d0].map((v) => [0, 8, 16, 24].map((s) => ((v >>> s) & 0xff).toString(16).padStart(2, '0')).join('')).join('')
}
export const _md5 = md5
