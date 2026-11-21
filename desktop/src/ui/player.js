// 播放器（覆蓋整個視窗）：HLS 用 hls.js，MP4 直接用 <video>。
// 鍵盤：空白鍵 暫停／播放、←→ 倒退／快轉 10 秒、↑↓ 音量、F 全螢幕、N 下一集、Esc 離開。
import { fmtTime } from '../net.js'
import { btn, h, icon, iconBtn, toast } from './dom.js'

let current = null

/**
 * req: { title, stream: { kind: hls|mp4|local, url, qualities: [[label, url]], headers }, startSec, hasNext }
 * 關閉時 resolve({ position, duration, next })（秒）
 */
export function openPlayer(req) {
  if (current) current.close()
  return new Promise((resolve) => {
    const root = document.getElementById('player')
    const video = h('video', { autoplay: true, controls: true, playsInline: true })
    const status = h('div.player-hint.hidden')
    let hls = null
    let wantNext = false
    let closed = false
    let netRetry = 0
    let mediaRetry = 0
    const st = req.stream
    const q = st.qualities?.length ? st.qualities : null
    let qi = q ? Math.max(0, q.findIndex((x) => x[1] === st.url)) : 0

    const hint = (t, ms = 2000) => {
      status.textContent = t
      status.classList.remove('hidden')
      clearTimeout(hint.timer)
      hint.timer = setTimeout(() => status.classList.add('hidden'), ms)
    }

    const qualitySel = h('select.sel', { title: '畫質', on: { change: () => setQuality(Number(qualitySel.value)) } })
    const speedSel = h(
      'select.sel',
      { title: '播放速度', on: { change: () => (video.playbackRate = Number(speedSel.value)) } },
      [0.75, 1, 1.25, 1.5, 2].map((s) => h('option', { value: s, selected: s === 1 }, `${s}x`)),
    )

    function setQuality(i) {
      if (hls) {
        hls.currentLevel = i
        hint(i < 0 ? '畫質：自動' : `已切換到 ${hls.levels[i]?.height || ''}p`)
      } else if (q) {
        const t = video.currentTime
        qi = i
        video.src = q[i][1]
        video.currentTime = t
        video.play().catch(() => {})
        hint(`已切換到 ${q[i][0]}`)
      }
    }

    async function load() {
      await window.hub.media(st.url, st.headers || {})
      const url = q ? q[qi][1] : st.url
      if (st.kind === 'hls' && window.Hls?.isSupported()) {
        hls = new window.Hls({ maxBufferLength: 60, startPosition: req.startSec > 5 ? req.startSec : -1 })
        hls.on(window.Hls.Events.MANIFEST_PARSED, (_e, data) => {
          const levels = data.levels.map((l, i) => ({ i, h: l.height })).filter((l) => l.h).sort((a, b) => b.h - a.h)
          qualitySel.replaceChildren(h('option', { value: -1 }, '自動'), ...levels.map((l) => h('option', { value: l.i }, `${l.h}p`)))
          // 預設最高畫質
          if (levels.length) {
            hls.currentLevel = levels[0].i
            qualitySel.value = levels[0].i
          }
          qualitySel.classList.toggle('hidden', levels.length < 2)
        })
        hls.on(window.Hls.Events.ERROR, (_e, data) => {
          if (!data.fatal) return
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR && netRetry++ < 3) {
            hint('連線被中斷，重新連線中…')
            setTimeout(() => hls?.startLoad(), 1500)
          } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR && mediaRetry++ < 3) hls.recoverMediaError()
          else {
            const code = data.response?.code
            hint(code === 403 ? '影片伺服器拒絕連線（403）。最近上傳的影片有時網站本身也播不了，請改看其他影片或稍後再試' : `播放失敗（${data.details}）`, 8000)
          }
        })
        hls.loadSource(url)
        hls.attachMedia(video)
      } else {
        video.src = url
        if (q) {
          qualitySel.replaceChildren(...q.map((x, i) => h('option', { value: i, selected: i === qi }, x[0])))
        } else qualitySel.classList.add('hidden')
        video.addEventListener(
          'loadedmetadata',
          () => {
            if (req.startSec > 5) video.currentTime = req.startSec
          },
          { once: true },
        )
        // 多畫質 MP4：這個畫質壞了就自動降一級
        video.addEventListener('error', () => {
          if (q && qi < q.length - 1) {
            const t = video.currentTime
            qi++
            hint(`改用 ${q[qi][0]}`)
            video.src = q[qi][1]
            video.currentTime = t
          } else hint('播放失敗，影片可能已失效', 6000)
        })
      }
      if (req.startSec > 5) hint(`從 ${fmtTime(req.startSec)} 繼續播放`)
      video.play().catch(() => {})
    }

    function close() {
      if (closed) return
      closed = true
      const position = video.currentTime || 0
      const duration = Number.isFinite(video.duration) ? video.duration : 0
      try {
        hls?.destroy()
      } catch {}
      video.removeAttribute('src')
      video.load()
      root.replaceChildren()
      root.classList.add('hidden')
      document.removeEventListener('keydown', onKey, true)
      window.hub.media(null)
      window.hub.fullscreen(false)
      current = null
      resolve({ position, duration: duration || 0, next: wantNext })
    }

    const playNext = () => {
      wantNext = true
      close()
    }

    function onKey(e) {
      if (e.target.tagName === 'SELECT') return
      const k = e.key
      if (k === 'Escape') close()
      else if (k === ' ' || k === 'k') video.paused ? video.play() : video.pause()
      else if (k === 'ArrowLeft') video.currentTime = Math.max(0, video.currentTime - 10)
      else if (k === 'ArrowRight') video.currentTime = video.currentTime + 10
      else if (k === 'ArrowUp') video.volume = Math.min(1, video.volume + 0.1)
      else if (k === 'ArrowDown') video.volume = Math.max(0, video.volume - 0.1)
      else if (k === 'f' || k === 'F') window.hub.fullscreen()
      else if ((k === 'n' || k === 'N') && req.hasNext) playNext()
      else return
      e.preventDefault()
      e.stopPropagation()
    }

    video.addEventListener('ended', () => {
      if (req.hasNext) {
        hint('即將播放下一集…')
        setTimeout(() => !closed && video.ended && playNext(), 1500)
      }
    })
    video.addEventListener('dblclick', () => window.hub.fullscreen())

    const bar = h(
      'div.player-bar',
      iconBtn('back', '返回（Esc）', close),
      h('div.player-title', req.title),
      req.hasNext ? btn('下一集', playNext, { icon: 'next', title: 'N' }) : null,
      qualitySel,
      speedSel,
      iconBtn('max', '全螢幕（F）', () => window.hub.fullscreen()),
    )
    root.replaceChildren(video, bar, status, h('div.player-keys', '空白鍵 暫停　←→ 快退／快轉　↑↓ 音量　F 全螢幕', req.hasNext ? '　N 下一集' : ''))
    root.classList.remove('hidden')
    document.addEventListener('keydown', onKey, true)
    current = { close }
    load().catch((e) => {
      toast(`無法播放：${e.message || e}`)
      close()
    })
  })
}

export const playerOpen = () => !!current
export { icon }
