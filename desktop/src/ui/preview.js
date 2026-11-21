// 長按（按住滑鼠）影片封面：跳出預覽框，靜音播放。
// va 有幾秒的預覽短片（跟封面同一個資料夾）；其他站直接播正片（最低畫質），在 10%～85% 幾個時間點之間每 5 秒跳一次。
import { base, NetError } from '../net.js'
import { src, VIDEO_KEYS } from '../sources.js'
import { badge, btn, dialog, h, icon } from './dom.js'
import { playerOpen } from './player.js'

const POINTS = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85]
const STEP_MS = 5000

export const canPreview = (it) => VIDEO_KEYS.includes(it.src)

async function fullPreview(it) {
  const s = src(it.src)
  const d = await s.detail(it)
  // 劇集播第一集
  const st = await s.stream(d, it.src === 'vc' && d.episodes?.length ? d.episodes[0] : undefined)
  const url = st.qualities?.length ? st.qualities[st.qualities.length - 1][1] : st.url
  return { ...st, url, montage: true }
}

function previewOf(it) {
  const i = (it.cover || '').lastIndexOf('/')
  if (it.src === 'va' && i > 0) return { kind: 'mp4', url: it.cover.slice(0, i) + '/preview.mp4', headers: { Referer: base('va') + '/' }, fallback: () => fullPreview(it) }
  return fullPreview(it)
}

/** onOpen：開作品；action：[按鈕文字, 動作]（呼叫端原本的右鍵 / 長按功能） */
export function openPreview(it, onOpen, action) {
  const video = h('video.preview-video', { autoplay: true, playsInline: true })
  video.muted = true
  video.volume = 0
  const cover = h('img.preview-cover', { src: it.cover || '', alt: '' })
  const status = h('div.preview-status', h('div.spinner'))
  const box = h('div.preview-box', cover, video, status, h('div.preview-tags', badge(it.src), h('span.chip-sm', icon('mute'), ' 預覽')))
  let hls = null
  let timer = null
  let closed = false
  let current = null

  const fail = (msg) => {
    status.replaceChildren(h('span.preview-msg', msg))
    status.classList.remove('hidden')
  }

  function stop() {
    clearInterval(timer)
    timer = null
    try {
      hls?.destroy()
    } catch {}
    hls = null
    video.removeAttribute('src')
    video.load()
  }

  async function onError(detail) {
    const fb = current?.fallback
    if (fb && !closed) {
      current = null
      try {
        return attach(await fb())
      } catch {}
    }
    fail(`這部沒有預覽${detail ? `（${detail}）` : ''}`)
  }

  async function attach(p) {
    if (closed) return
    stop()
    current = p
    await window.hub.media(p.url, p.headers || {})
    if (closed) return
    video.loop = !p.montage
    if (p.kind === 'hls' && window.Hls?.isSupported()) {
      hls = new window.Hls({ maxBufferLength: 12, startLevel: 0, capLevelToPlayerSize: true })
      hls.on(window.Hls.Events.MANIFEST_PARSED, (_e, data) => {
        // 預覽用最低畫質
        const low = data.levels.map((l, i) => ({ i, h: l.height || 0 })).sort((a, b) => a.h - b.h)[0]
        if (low) hls.currentLevel = low.i
      })
      hls.on(window.Hls.Events.ERROR, (_e, data) => data.fatal && onError(data.response?.code ? `HTTP ${data.response.code}` : data.details))
      hls.loadSource(p.url)
      hls.attachMedia(video)
    } else {
      video.src = p.url
      video.addEventListener('error', () => onError(), { once: true })
    }
    video.addEventListener(
      'loadedmetadata',
      () => {
        if (!p.montage || !Number.isFinite(video.duration)) return
        let step = 0
        video.currentTime = video.duration * POINTS[0]
        timer = setInterval(() => {
          step = (step + 1) % POINTS.length
          video.currentTime = video.duration * POINTS[step]
        }, STEP_MS)
      },
      { once: true },
    )
    video.play().catch(() => {})
  }

  video.addEventListener('playing', () => {
    status.classList.add('hidden')
    cover.classList.add('hidden')
  })

  const finish = (fn) => {
    d.close()
    fn?.()
  }
  const d = dialog(
    it.title,
    box,
    [action ? btn(action[0], () => finish(action[1])) : null, btn('關閉', () => finish()), btn('開啟', () => finish(onOpen), { icon: 'play', primary: true })].filter(Boolean),
    {
      wide: true,
      onClose: () => {
        closed = true
        stop()
        // 預覽完直接開了播放器的話，標頭已經換成正片的，不要清掉
        if (!playerOpen()) window.hub.media(null)
      },
    },
  )
  d.el.classList.add('preview-modal')

  Promise.resolve()
    .then(() => previewOf(it))
    .then(attach)
    .catch((e) => fail(e instanceof NetError ? e.message : '這部沒有預覽'))
}
