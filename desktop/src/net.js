// 頁面這邊的網路：全部透過主程序（各站自己的 partition、Cloudflare 驗證視窗），這裡只包成好用的樣子
export class NetError extends Error {
  constructor(message, status = 0) {
    super(message)
    this.status = status
  }
}

/** 需要登入（或登入過期） */
export class LoginError extends NetError {
  constructor(site, message) {
    super(message || '登入已過期，請重新登入')
    this.site = site
  }
}

let config = { sites: {} }

export async function loadConfig() {
  config = await window.hub.config()
  return config
}

export const siteConfig = (k) => config.sites[k] || { label: k, base: '' }
export const label = (k) => (k === 'local' ? '本機' : siteConfig(k).label)
export const base = (k) => siteConfig(k).base
export const prefix = (k) => siteConfig(k).prefix || ''

export const full = (site, path) => (/^https?:/.test(path) ? path : base(site) + path)

/** 抓文字；不是 2xx 就丟出看得懂的錯誤 */
export async function text(site, path, opts = {}) {
  const r = await window.hub.get(site, full(site, path), opts)
  if (!r.ok) throw new NetError(r.error || `載入失敗（HTTP ${r.status}）`, r.status)
  return r.data
}

export async function json(site, path, opts = {}) {
  const r = await window.hub.get(site, full(site, path), { ...opts, json: true })
  if (!r.ok) throw new NetError(r.error || `載入失敗（HTTP ${r.status}）`, r.status)
  return r.data
}

/** 原始回應：{ ok, status, data, url, error } */
export const raw = (site, path, opts = {}) => window.hub.get(site, full(site, path), opts)

export const form = (fields) => fields.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&')

export const parse = (html) => new DOMParser().parseFromString(html, 'text/html')

/** 相對網址 → 絕對網址 */
export function abs(u, b) {
  if (!u || !String(u).trim()) return ''
  u = String(u).trim()
  if (u.startsWith('//')) return 'https:' + u
  if (/^https?:/.test(u)) return u
  try {
    return new URL(u, b + '/').href
  } catch {
    return u
  }
}

/** 元素文字（空白收成一個） */
export const txt = (el) => (el?.textContent || '').replace(/\s+/g, ' ').trim()

export const enc = encodeURIComponent

export function fmtTime(sec) {
  const s = Math.max(0, Math.floor(sec || 0))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const ss = String(s % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`
}

export function fmtCount(n) {
  if (n >= 100000) return `${Math.floor(n / 10000)} 萬`
  if (n >= 10000) return `${(n / 10000).toFixed(1)} 萬`
  return String(Math.floor(n))
}

export function fmtSize(b) {
  if (b >= 1 << 30) return `${(b / (1 << 30)).toFixed(2)} GB`
  if (b >= 1 << 20) return `${Math.round(b / (1 << 20))} MB`
  return `${Math.round(b / 1024)} KB`
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
