// vb：網站沒有 API，全部從 HTML 解析（有 Cloudflare）。影片是直連 MP4（多畫質），要帶 Referer。
import { abs, base, enc, NetError, parse, text, txt } from '../net.js'

const b64 = (s) => new TextDecoder().decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)))
// 類型名稱要跟網站的查詢參數完全一致（Base64 存放）
const GENRES = b64('6KOP55WqLOazoem6teeVqixNb3Rpb24gQW5pbWUsM0RDRywyLjVELDJE5YuV55WrLEFJ55Sf5oiQLE1NRCxDb3NwbGF5').split(',')
const SORTS = ['最新上市', '最新上傳', '本日排行', '本週排行', '本月排行', '觀看次數', '讚好比例']
const K = 'vb'

function searchUrl({ query = '', genre = '', sort = '' } = {}) {
  const p = []
  if (query.trim()) p.push(`query=${enc(query.trim())}`)
  if (genre) p.push(`genre=${enc(genre)}`)
  if (sort) p.push(`sort=${enc(sort)}`)
  return `${base(K)}/search${p.length ? '?' + p.join('&') : ''}`
}

const ownText = (el) => [...(el?.childNodes || [])].filter((n) => n.nodeType === 3).map((n) => n.textContent).join('').trim()

/** 一堆指向 watch?v= 的連結 → 影片卡片（同一部的縮圖連結和標題連結會合併） */
function cards(links) {
  const out = new Map()
  for (const a of links) {
    const href = a.getAttribute('href') || ''
    const id = ((href.split('watch?v=')[1] || '').match(/^[A-Za-z0-9]+/) || [])[0]
    if (!id) continue
    const prev = out.get(id)
    let card = a
    let p = a.parentElement
    for (let n = 0; n < 4 && p; n++, p = p.parentElement) {
      if (p.classList.contains('video-item-container') || p.querySelector('.video-title, .title, .home-rows-videos-title')) {
        card = p
        break
      }
    }
    const img = a.querySelector('img') || card.querySelector('img')
    const cover = abs(img?.getAttribute('src'), base(K))
    const title = txt(a.querySelector('.title, .home-rows-videos-title')) || txt(card.querySelector('.video-title, .title, .home-rows-videos-title')) || (card.getAttribute('title') || a.getAttribute('title') || '').trim()
    const duration = txt(a.querySelector('.duration') || card.querySelector('.duration'))
    out.set(id, {
      src: K,
      id,
      title: title || prev?.title || '',
      cover: cover || prev?.cover || '',
      sub: duration || prev?.sub || '',
      type: 'video',
      poster: cover.includes('/cover/') || !!prev?.poster,
    })
  }
  return [...out.values()].filter((v) => v.cover || v.title)
}

async function listUrl(url, page) {
  const d = parse(await text(K, `${url}${url.includes('?') ? '&' : '?'}page=${page}`))
  const items = cards(d.querySelectorAll('a[href*="watch?v="]'))
  return { items, hasMore: items.length > 0 && !!d.querySelector(`a[href*="page=${page + 1}"]`) }
}

export const vb = {
  key: K,
  kind: 'video',
  hasAccount: false,
  sections: [
    { id: 'home', title: '首頁', shelves: true },
    {
      id: 'browse',
      title: '分類',
      filters: [
        { key: 'genre', label: '類型', options: [['', '全部'], ...GENRES.map((g) => [g, g])] },
        { key: 'sort', label: '排序', options: SORTS.map((s) => [s, s]) },
      ],
    },
  ],
  searchFilters: [
    { key: 'genre', label: '類型', options: [['', '全部'], ...GENRES.map((g) => [g, g])] },
    { key: 'sort', label: '排序', options: [['', '預設'], ...SORTS.map((s) => [s, s])] },
  ],
  imageHeaders: () => ({ Referer: base(K) + '/' }),
  idTag: (id) => id,

  async shelves() {
    const d = parse(await text(K, '/'))
    const out = []
    for (const header of d.querySelectorAll('a.horizontal-row-title')) {
      const title = ownText(header.querySelector('h3'))
      const links = []
      let n = header.nextElementSibling
      while (n && !(n.tagName === 'A' && n.classList.contains('horizontal-row-title'))) {
        links.push(...n.querySelectorAll('a[href*="watch?v="]'))
        n = n.nextElementSibling
      }
      const items = cards(links)
      if (title && items.length) out.push({ title, items, more: { src: K, title, params: { section: 'browse', url: abs(header.getAttribute('href'), base(K)) } } })
    }
    return out
  },

  list: (p, page) => listUrl(p.url || searchUrl({ genre: p.genre || '', sort: p.sort || SORTS[0] }), page),
  search: (q, page, p = {}) => listUrl(searchUrl({ query: q, genre: p.genre || '', sort: p.sort || '' }), page),

  async detail(item) {
    const d = parse(await text(K, `/watch?v=${item.id}`))
    const sources = new Map()
    for (const s of d.querySelectorAll('video source[src]')) {
      const src = abs(s.getAttribute('src'), base(K))
      const q = Number(s.getAttribute('size')) || Number((src.match(/(\d+)p/) || [])[1])
      if (q && !sources.has(q)) sources.set(q, src)
    }
    const qualities = [...sources.keys()].sort((a, b) => b - a)
    const tags = []
    for (const a of d.querySelectorAll('.single-video-tag a[href]')) {
      const name = ownText(a).replace(/ /g, ' ').trim().replace(/^#/, '').trim()
      if (!name || name === 'add' || name === 'remove') continue
      tags.push({ src: K, title: name, params: { section: 'browse', url: abs(a.getAttribute('href'), base(K)) } })
    }
    const info = [...d.querySelectorAll('.video-description-panel .hidden-xs')].map((e) => e.textContent.trim()).find((t) => t.includes('觀看次數')) || ''
    const artist = txt(d.querySelector('#video-artist-name'))
    const title = txt(d.querySelector('#shareBtn-title')) || (d.title || '').split(' - ')[0].trim() || item.title
    return {
      item,
      title,
      subtitle: '',
      cover: abs(d.querySelector('video[poster]')?.getAttribute('poster'), base(K)) || item.cover,
      description: (d.querySelector('.video-caption-text')?.textContent || '').trim(),
      info: [
        ...(artist ? [{ label: '作者', text: artist, links: [{ src: K, title: artist, params: { section: 'browse', url: searchUrl({ query: artist }) } }] }] : []),
        ...(info ? [{ label: '資訊', text: info, links: [] }] : []),
        ...(qualities.length ? [{ label: '畫質', text: qualities.map((q) => `${q}p`).join(' / '), links: [] }] : []),
      ],
      tags,
      episodes: cards(d.querySelectorAll('#playlist-scroll a[href*="watch?v="]')),
      episodesTitle: '播放清單',
      related: cards(d.querySelectorAll('#related-tabcontent a[href*="watch?v="]')),
      chapters: [],
      url: `${base(K)}/watch?v=${item.id}`,
      extra: { sources: qualities.map((q) => [`${q}p`, sources.get(q)]) },
    }
  },

  async stream(d, ep) {
    const det = ep ? await vb.detail(ep) : d
    const q = det.extra.sources || []
    if (!q.length) throw new NetError('找不到播放網址（網站可能改版）')
    return { kind: 'mp4', url: q[0][1], qualities: q, headers: { Referer: base(K) + '/' } }
  },
}
