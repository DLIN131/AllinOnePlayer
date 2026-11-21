// vc：頁面資料內嵌在 HTML 裡（見 tsr.js），一般 HTTP 就抓得到。
// 影片是 HLS，但清單和片段都包在 PNG 裡，播放時走主程序的 vh:// 協定拆開。分類名稱一律從網站資料來，不寫死。
import { base, enc, fmtCount, fmtTime, NetError, text } from '../net.js'
import { pageData } from './tsr.js'

const K = 'vc'
const ORDERS = [
  ['createdAt', '最新發布'],
  ['viewCount', '最多觀看'],
  ['likeCount', '最多喜歡'],
]
const SERIES_FILTERS = [
  ['all', '全部'],
  ['ongoing', '連載中'],
  ['completed', '已完結'],
  ['fresh', '本週更新'],
]
const SERIES_SORTS = [
  ['updated', '最新更新'],
  ['hot', '最多觀看'],
  ['likes', '最多喜歡'],
  ['most', '集數最多'],
]
const SEARCH_SORTS = [
  ['', '相關度'],
  ['createdAt:desc', '最新發布'],
  ['viewCount:desc', '最多播放'],
  ['likeCount:desc', '最多喜歡'],
]

async function page(path) {
  const data = pageData(await text(K, path))
  if (!data) throw new NetError('讀不到頁面內容（網站可能改版或換網址）')
  delete data.ads
  return data
}

const s = (m, k) => (typeof m?.[k] === 'string' ? m[k] : '')
const n = (m, k) => (typeof m?.[k] === 'number' ? m[k] : 0)
const maps = (m, k) => (Array.isArray(m?.[k]) ? m[k].filter((x) => x && typeof x === 'object') : [])
const strs = (m, k) => (Array.isArray(m?.[k]) ? m[k].filter((x) => typeof x === 'string') : [])

function video(m) {
  const ep = m.episode
  const dur = n(m, 'duration')
  return { src: K, id: s(m, 'id'), title: s(m, 'name'), cover: s(m, 'coverImageUrl'), sub: [typeof ep === 'number' ? `第 ${ep} 集` : '', dur > 0 ? fmtTime(dur) : ''].filter(Boolean).join(' · '), type: 'video' }
}

function series(m) {
  const count = n(m, 'episodeCount')
  const status = { COMPLETED: '已完結', ONGOING: '連載中' }[s(m, 'status')] || ''
  const ep = s(m, 'epLabel') || (count > 0 ? `${count} 集` : '')
  return { src: K, id: s(m, 'id'), title: s(m, 'name'), cover: s(m, 'coverImageUrl'), sub: [ep, status].filter(Boolean).join(' · '), type: 'series', poster: m.isPoster === true }
}

function paged(d, items) {
  const cur = Math.max(1, n(d, 'pageNum'))
  const total = Math.max(1, n(d, 'totalPage'))
  return { items, hasMore: cur < total, total: d.totalVideoNum || d.total || 0 }
}

/** 網址參數；空字串、第 1 頁都省略（跟網站自己的連結一樣） */
function qs(p) {
  const q = Object.entries(p)
    .filter(([, v]) => v != null && v !== '' && v !== 1)
    .map(([k, v]) => `${k}=${enc(String(v))}`)
    .join('&')
  return q ? '?' + q : ''
}

export const tagLink = (tag, order = 'createdAt') => ({ src: K, title: tag, params: { section: 'tag', tag, order } })

let taxonomy = null

export const vc = {
  key: K,
  kind: 'video',
  hasAccount: false,
  sections: [
    { id: 'home', title: '首頁', shelves: true },
    { id: 'videos', title: '影片', filters: [{ key: 'order', label: '排序', options: ORDERS }] },
    {
      id: 'series',
      title: '劇集',
      filters: [
        { key: 'f', label: '狀態', options: SERIES_FILTERS },
        { key: 'sort', label: '排序', options: SERIES_SORTS },
      ],
    },
    { id: 'cats', title: '分類', shelves: true },
  ],
  searchFilters: [
    {
      key: 'tab',
      label: '類型',
      options: [
        ['video', '影片'],
        ['series', '劇集'],
      ],
    },
    { key: 'sort', label: '排序', options: SEARCH_SORTS },
  ],
  imageHeaders: () => ({}),
  idTag: (id) => id,

  async shelves(section) {
    if (section === 'cats') {
      if (!taxonomy) taxonomy = (await page('/cat')).taxonomy || {}
      const t = taxonomy
      const byParent = t.byParent || {}
      const out = maps(t, 'cats').map((c) => {
        const id = s(c, 'id')
        const kids = (byParent[id] || []).map((k) => s(k, 'id'))
        return { title: `${id}（${n(c, 'count')}）`, items: [], more: tagLink(id), chips: [tagLink(id), ...kids.map((k) => tagLink(k))] }
      })
      const genres = maps(t, 'genre').map((g) => tagLink(s(g, 'id')))
      if (genres.length) out.push({ title: '類型', items: [], chips: genres })
      return out
    }
    const d = await page('/home')
    const out = new Map()
    let latest = null
    for (const [key, value] of Object.entries(d)) {
      if (key.startsWith('hero')) continue
      const list = Array.isArray(value) ? value.filter((x) => x && typeof x === 'object') : []
      if (!list.length) continue
      let shelf
      if ('episodeCount' in list[0]) {
        shelf = key.startsWith('fresh')
          ? { title: '本週更新劇集', items: list.map(series), more: { src: K, title: '本週更新劇集', params: { section: 'series', f: 'fresh' } } }
          : { title: '熱門劇集', items: list.map(series), more: { src: K, title: '熱門劇集', params: { section: 'series', sort: 'hot' } } }
      } else if ('duration' in list[0]) {
        const videos = list.map(video)
        if (key.startsWith('latest')) shelf = latest = { title: '最新影片', items: videos, more: { src: K, title: '最新影片', params: { section: 'videos' } } }
        else {
          // 分類是這一區影片最常見的第一個標籤
          const count = {}
          for (const m of list) {
            const t = strs(m, 'tags')[0]
            if (t) count[t] = (count[t] || 0) + 1
          }
          const tag = Object.entries(count).sort((a, b) => b[1] - a[1])[0]?.[0]
          if (!tag) continue
          const hot = key.startsWith('hot')
          shelf = { title: hot ? `最受歡迎・${tag}` : `今日熱門・${tag}`, items: videos, more: tagLink(tag, hot ? 'likeCount' : 'createdAt') }
        }
      } else continue
      if (!out.has(shelf.title)) out.set(shelf.title, shelf)
    }
    const list = [...out.values()]
    if (latest) {
      list.splice(list.indexOf(latest), 1)
      list.unshift(latest)
    }
    return list
  },

  async list(p, pg) {
    if (p.section === 'tag') {
      const order = p.order || 'createdAt'
      const d = await page(`/t/${enc(p.tag || '')}${qs({ order: order === 'createdAt' ? null : order, page: pg })}`)
      return paged(d, maps(d, 'videos').map(video))
    }
    if (p.section === 'series') {
      const f = p.f || 'all'
      const sort = p.sort || 'updated'
      const d = await page(`/series${qs({ f: f === 'all' ? null : f, sort: sort === 'updated' ? null : sort, tag: p.tag, page: pg })}`)
      return paged(d, maps(d, 'list').map(series))
    }
    const order = p.order || 'createdAt'
    const d = await page(`/v${qs({ order: order === 'createdAt' ? null : order, page: pg })}`)
    return paged(d, maps(d, 'videos').map(video))
  },

  async search(q, pg, p = {}) {
    const tab = p.tab || 'video'
    const d = await page(`/search${qs({ q, t: p.cat, tab: tab === 'video' ? null : tab, sort: p.sort, page: pg })}`)
    return tab === 'series' ? paged(d, maps(d, 'seriesList').map(series)) : paged(d, maps(d, 'videos').map(video))
  },

  async detail(item) {
    if (item.type === 'series') {
      const d = await page(`/s/${item.id}`)
      if (!d.series) throw new NetError('找不到這部劇集（可能已被刪除）', 404)
      const it = series(d.series)
      return {
        item: it,
        title: it.title,
        subtitle: '',
        cover: it.cover,
        description: s(d.series, 'description'),
        info: [...(it.sub ? [{ label: '集數', text: it.sub, links: [] }] : []), ...(n(d.series, 'viewCount') ? [{ label: '觀看', text: fmtCount(n(d.series, 'viewCount')), links: [] }] : [])],
        tags: strs(d.series, 'tags').map((t) => tagLink(t)),
        episodes: maps(d, 'episodes').map(video),
        episodesTitle: '選集',
        related: maps(d, 'more').map(series),
        chapters: [],
        url: `${base(K)}/s/${item.id}`,
        extra: {},
      }
    }
    const d = await page(`/v/${item.id}`)
    const v = d.video
    if (!v) throw new NetError('找不到這部影片（可能已被刪除）', 404)
    const it = video(v)
    const ser = d.series ? series(d.series) : null
    const res = Math.max(0, ...maps(v, 'sources').map((x) => n(x, 'resolution')))
    return {
      item: it,
      title: it.title,
      subtitle: s(v, 'vid'),
      cover: it.cover,
      description: '',
      info: [
        ...(n(v, 'duration') ? [{ label: '時長', text: fmtTime(n(v, 'duration')), links: [] }] : []),
        ...(n(v, 'viewCount') ? [{ label: '觀看', text: fmtCount(n(v, 'viewCount')), links: [] }] : []),
        ...(s(v, 'createdAt') ? [{ label: '發布', text: s(v, 'createdAt').slice(0, 10), links: [] }] : []),
        ...(res ? [{ label: '畫質', text: `${res}p`, links: [] }] : []),
        ...(ser ? [{ label: '劇集', text: ser.title, links: [{ src: K, title: ser.title, params: { section: 'openSeries', id: ser.id } }] }] : []),
      ],
      tags: strs(v, 'tags').map((t) => tagLink(t)),
      episodes: maps(d, 'episodes').map(video),
      episodesTitle: '選集',
      related: [...maps(d, 'relatedVideos').map(video), ...maps(d, 'moreSeries').map(series)],
      chapters: [],
      url: `${base(K)}/v/${item.id}`,
      extra: {},
    }
  },

  // 清單和片段走主程序的 vh:// 協定（拆 PNG 包裝），播放器直接吃
  stream: async (d, ep) => ({ kind: 'hls', url: `vh://hls/${(ep || d.item).id}`, headers: {}, unwrap: true, downloadUrl: `${base(K)}/api/hls/${(ep || d.item).id}` }),
}
