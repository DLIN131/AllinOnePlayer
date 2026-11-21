// 影片下載佇列（主程序）：可暫停 / 續傳，關掉程式再開會從上次的位置繼續。
// HLS：選定畫質的分段依序接進 .ts 暫存檔，全部下載完再用 ffmpeg 轉成 .mp4（不重新編碼，很快）。
// MP4：直接續傳整個檔案。連線方式（CDN 要的標頭、PNG 包裝要拆）依來源決定，見 fetcher.mediaFetch。
const { app, ipcMain, dialog, shell, BrowserWindow } = require('electron')
const fs = require('original-fs')
const path = require('path')
const { spawn } = require('child_process')
const { pathToFileURL } = require('url')
const fetcher = require('./fetcher')
const paths = require('./paths')

const MAX_RUNNING = 2
/** 每部影片同時抓幾個分段 */
const PARALLEL = 6
const RETRIES = 4
const jobsFile = () => path.join(app.getPath('userData'), 'video-downloads.json')
let jobs = []
let dir = ''
const running = new Map() // job.id → AbortController
let saveTimer = null
const sendTimers = new Map()
/** 程式正在關閉：被中斷的下載記成排隊中，下次開啟自動接著下 */
let quitting = false

// ---------- HLS 播放清單 ----------

const resolveUrl = (base, u) => new URL(u, base).href

/** 主清單 → 各畫質（高到低） */
function parseVariants(text, base) {
  const lines = text.split(/\r?\n/).map((l) => l.trim())
  const out = []
  lines.forEach((line, i) => {
    if (!line.startsWith('#EXT-X-STREAM-INF:')) return
    const uri = lines.slice(i + 1).find((l) => l && !l.startsWith('#'))
    if (!uri) return
    const height = Number((line.match(/RESOLUTION=\d+x(\d+)/) || [])[1]) || 0
    // 平均位元率比較接近實際檔案大小，沒有才用峰值
    const bandwidth = Number((line.match(/AVERAGE-BANDWIDTH=(\d+)/) || [])[1]) || Number((line.match(/(?:^|[:,])BANDWIDTH=(\d+)/) || [])[1]) || 0
    if (!out.some((v) => v.height === height)) out.push({ height, bandwidth, url: resolveUrl(base, uri) })
  })
  return out.sort((a, b) => b.height - a.height)
}

/** 單一畫質的清單 → 分段 */
function parseSegments(text, base) {
  const lines = text.split(/\r?\n/).map((l) => l.trim())
  const key = lines.find((l) => l.startsWith('#EXT-X-KEY:'))
  if (key && !/METHOD=NONE/.test(key)) throw new Error('這部影片有加密，無法下載')
  const out = []
  let dur = 0
  for (const l of lines) {
    if (l.startsWith('#EXTINF:')) dur = parseFloat(l.slice(8)) || 0
    else if (l && !l.startsWith('#')) {
      out.push({ url: resolveUrl(base, l), duration: dur })
      dur = 0
    }
  }
  return out
}

async function getBytes(url, conn, signal) {
  const res = await fetcher.mediaFetch(url, conn, signal)
  const buf = Buffer.from(await res.arrayBuffer())
  return conn?.unwrap ? fetcher.unwrap(buf) : buf
}

async function getText(url, conn, signal) {
  return (await getBytes(url, conn, signal)).toString('utf8')
}

/** 下載前讓使用者選畫質 */
async function options(masterUrl, conn) {
  const text = await getText(masterUrl, conn)
  return /#EXT-X-STREAM-INF/.test(text) ? parseVariants(text, masterUrl) : []
}

// ---------- 工作清單 ----------

function load() {
  try {
    const d = JSON.parse(fs.readFileSync(jobsFile(), 'utf8'))
    jobs = Array.isArray(d.jobs) ? d.jobs : []
    dir = d.dir || ''
  } catch {}
  if (!dir) dir = paths.defaultVideoDir()
  for (const j of jobs) {
    // 上次關程式時還在下載 / 轉檔的，這次接著做
    if (j.status === 'running' || j.status === 'merging') j.status = 'queued'
    j.speed = 0
  }
}

function save() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(flush, 500)
}

function flush() {
  clearTimeout(saveTimer)
  try {
    const f = jobsFile()
    fs.writeFileSync(f + '.tmp', JSON.stringify({ dir, jobs }))
    fs.renameSync(f + '.tmp', f)
  } catch {}
}

function publicJob(j) {
  return { ...j, fileUrl: j.status === 'done' && j.file ? pathToFileURL(j.file).href : '' }
}

/** 通知頁面；下載中每 300ms 最多送一次 */
function emit(j, now = false) {
  const send = () => {
    sendTimers.delete(j.id)
    for (const w of BrowserWindow.getAllWindows()) if (!w.isDestroyed()) w.webContents.send('vdl:update', publicJob(j))
  }
  if (now) {
    clearTimeout(sendTimers.get(j.id))
    send()
  } else if (!sendTimers.has(j.id)) sendTimers.set(j.id, setTimeout(send, 300))
}

const clean = (s) =>
  String(s || '')
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/, '')
    .slice(0, 100) || 'video'

const partDir = () => path.join(dir, '.parts')
const partOf = (j) => path.join(partDir(), `${clean(j.id)}.${j.kind === 'mp4' ? 'mp4' : 'ts'}`)

/** 檔名：番號 標題.mp4；同名檔案已存在就加 (2)、(3)… */
function pickFile(j, ext) {
  fs.mkdirSync(dir, { recursive: true })
  const name = clean(`${j.title}${j.quality ? ` [${j.quality}]` : ''}`)
  for (let i = 1; ; i++) {
    const f = path.join(dir, `${name}${i > 1 ? ` (${i})` : ''}${ext}`)
    if (!fs.existsSync(f)) return f
  }
}

// ---------- 下載 ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** 有些網站把 TS 分段偽裝成圖片（前面塞一段圖片標頭）：從連續三個 0x47 封包開頭的位置開始 */
function alignTs(buf) {
  if (buf.length < 188 * 3 || (buf[0] === 0x47 && buf[188] === 0x47)) return buf
  const limit = Math.min(buf.length - 188 * 2, 1024 * 1024)
  for (let i = 1; i < limit; i++) {
    if (buf[i] === 0x47 && buf[i + 188] === 0x47 && buf[i + 376] === 0x47) return buf.subarray(i)
  }
  return buf
}

async function fetchSegment(url, conn, signal) {
  let last = null
  for (let attempt = 0; attempt < RETRIES; attempt++) {
    if (signal.aborted) throw new Error('aborted')
    try {
      return alignTs(await getBytes(url, conn, signal))
    } catch (e) {
      if (signal.aborted) throw e
      last = e
      await sleep(1000 * (attempt + 1))
    }
  }
  throw new Error(`網路錯誤：${last?.message || last}`)
}

const writeAsync = (out, buf) => new Promise((resolve, reject) => out.write(buf, (err) => (err ? reject(err) : resolve())))

/** MP4：整個檔案續傳到暫存檔 */
async function downloadFile(j, signal) {
  fs.mkdirSync(partDir(), { recursive: true })
  const part = partOf(j)
  const have = fs.existsSync(part) ? fs.statSync(part).size : 0
  const res = await fetcher.mediaFetch(j.mediaUrl, { ...j.conn, headers: { ...(j.conn?.headers || {}), ...(have ? { Range: `bytes=${have}-` } : {}) } }, signal)
  const partial = res.status === 206
  if (!partial && have) fs.truncateSync(part, 0)
  j.bytes = partial ? have : 0
  const len = Number(res.headers.get('content-length')) || 0
  j.size = len ? j.bytes + len : 0
  const out = fs.createWriteStream(part, { flags: partial ? 'a' : 'w' })
  let windowStart = Date.now()
  let windowBytes = 0
  try {
    const reader = res.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      await writeAsync(out, Buffer.from(value))
      j.bytes += value.length
      windowBytes += value.length
      const dt = Date.now() - windowStart
      if (dt > 2000) {
        j.speed = Math.round((windowBytes * 1000) / dt)
        windowStart = Date.now()
        windowBytes = 0
      }
      j.total = j.size || 0
      j.done = j.bytes
      save()
      emit(j)
    }
  } finally {
    await new Promise((r) => out.end(r))
  }
  return part
}

async function download(j, signal) {
  if (j.kind === 'mp4') return downloadFile(j, signal)
  const segs = parseSegments(await getText(j.mediaUrl, j.conn, signal), j.mediaUrl)
  if (!segs.length) throw new Error('找不到影片分段')
  j.total = segs.length
  fs.mkdirSync(partDir(), { recursive: true })
  const part = partOf(j)
  // 上次中斷時寫到一半的分段丟掉，從記錄的位置接著寫
  if (fs.existsSync(part)) fs.truncateSync(part, Math.min(j.bytes || 0, fs.statSync(part).size))
  else j.done = j.bytes = 0
  if (fs.existsSync(part) && fs.statSync(part).size !== j.bytes) j.done = j.bytes = 0
  const out = fs.createWriteStream(part, { flags: j.bytes ? 'a' : 'w' })
  // 同時抓好幾個分段，但依序寫入
  const pending = new Map()
  let next = j.done
  const fill = () => {
    while (pending.size < PARALLEL && next < segs.length) {
      const i = next++
      const p = fetchSegment(segs[i].url, j.conn, signal)
      p.catch(() => {})
      pending.set(i, p)
    }
  }
  let windowStart = Date.now()
  let windowBytes = 0
  try {
    fill()
    while (j.done < segs.length) {
      const buf = await pending.get(j.done)
      pending.delete(j.done)
      await writeAsync(out, buf)
      j.done++
      j.bytes += buf.length
      windowBytes += buf.length
      const dt = Date.now() - windowStart
      if (dt > 2000) {
        j.speed = Math.round((windowBytes * 1000) / dt)
        windowStart = Date.now()
        windowBytes = 0
      }
      save()
      emit(j)
      fill()
    }
  } finally {
    await new Promise((r) => out.end(r))
  }
  return part
}

function ffmpegPath() {
  try {
    // 打包後 ffmpeg.exe 在 app.asar.unpacked 裡
    const p = require('ffmpeg-static').replace('app.asar' + path.sep, 'app.asar.unpacked' + path.sep)
    return fs.existsSync(p) ? p : ''
  } catch {
    return ''
  }
}

/** TS → MP4（只換容器，不重新編碼） */
function remux(input, outFile, signal) {
  const ffmpeg = ffmpegPath()
  if (!ffmpeg) return Promise.reject(new Error('找不到 ffmpeg'))
  // 只取影像和聲音，TS 裡的其他資料軌放進 MP4 會出錯
  const args = ['-hide_banner', '-loglevel', 'error', '-y', '-i', input, '-map', '0:v?', '-map', '0:a?', '-c', 'copy', '-movflags', '+faststart', outFile]
  return new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, args, { windowsHide: true })
    let err = ''
    p.stderr.on('data', (d) => (err = (err + d).slice(-2000)))
    const onAbort = () => p.kill()
    signal.addEventListener('abort', onAbort, { once: true })
    p.on('error', reject)
    p.on('close', (code) => {
      signal.removeEventListener('abort', onAbort)
      if (code === 0 && fs.existsSync(outFile) && fs.statSync(outFile).size > 0) resolve()
      else {
        try {
          fs.rmSync(outFile, { force: true })
        } catch {}
        reject(new Error(err.trim() || 'ffmpeg 結束代碼 ' + code))
      }
    })
  })
}

async function runJob(j) {
  const ctl = new AbortController()
  running.set(j.id, ctl)
  j.status = 'running'
  j.error = ''
  j.speed = 0
  emit(j, true)
  try {
    const part = await download(j, ctl.signal)
    j.status = 'merging'
    j.speed = 0
    emit(j, true)
    const mp4 = pickFile(j, '.mp4')
    if (j.kind === 'mp4') {
      fs.renameSync(part, mp4)
      j.file = mp4
    } else try {
      await remux(part, mp4, ctl.signal)
      fs.rmSync(part, { force: true })
      j.file = mp4
    } catch (e) {
      if (ctl.signal.aborted) throw e
      // 轉檔失敗就保留 .ts（大部分播放器也能播）
      const ts = pickFile(j, '.ts')
      fs.renameSync(part, ts)
      j.file = ts
      j.note = `轉成 MP4 失敗，保留 TS 檔：${e.message}`
    }
    try {
      j.size = fs.statSync(j.file).size
    } catch {}
    j.status = 'done'
    j.doneAt = Date.now()
  } catch (e) {
    if (ctl.signal.aborted) {
      if (j.status !== 'removed') j.status = quitting ? 'queued' : 'paused'
    } else {
      j.status = 'error'
      j.error = e.message || String(e)
    }
  } finally {
    running.delete(j.id)
    j.speed = 0
    if (j.status !== 'removed') {
      flush()
      emit(j, true)
    }
    pump()
  }
}

/** 有空位就開始下一個排隊中的 */
function pump() {
  if (quitting) return
  for (const j of jobs) {
    if (running.size >= MAX_RUNNING) break
    if (j.status === 'queued' && !running.has(j.id)) runJob(j)
  }
}

function add(v) {
  const id = String(v.key || '')
  if (!id || !v.mediaUrl) throw new Error('缺少影片資料')
  const old = jobs.find((j) => j.id === id)
  if (old && old.status === 'done' && old.file && fs.existsSync(old.file)) return publicJob(old)
  if (old) {
    // 同一部影片換畫質重新下載：舊的暫存檔不能接著用
    if (old.mediaUrl !== v.mediaUrl) remove(id, true)
    else {
      if (old.status !== 'running') old.status = 'queued'
      flush()
      pump()
      return publicJob(old)
    }
  }
  const j = {
    id,
    src: v.src || '',
    title: v.title || '',
    cover: v.cover || '',
    kind: v.kind === 'mp4' ? 'mp4' : 'hls',
    conn: v.conn || {},
    quality: v.quality || '',
    mediaUrl: v.mediaUrl,
    status: 'queued',
    total: 0,
    done: 0,
    bytes: 0,
    speed: 0,
    error: '',
    addedAt: Date.now(),
  }
  jobs.unshift(j)
  flush()
  emit(j, true)
  pump()
  return publicJob(j)
}

function remove(id, deleteFile) {
  const j = jobs.find((x) => x.id === id)
  if (!j) return
  const ctl = running.get(id)
  j.status = 'removed'
  ctl?.abort()
  jobs = jobs.filter((x) => x !== j)
  flush()
  // 等正在寫的分段停下來再刪
  setTimeout(() => {
    try {
      fs.rmSync(partOf(j), { force: true })
    } catch {}
    if (deleteFile && j.file) {
      try {
        fs.rmSync(j.file, { force: true })
      } catch {}
    }
  }, 500)
  for (const w of BrowserWindow.getAllWindows()) if (!w.isDestroyed()) w.webContents.send('vdl:removed', id)
}

function setup() {
  load()
  ipcMain.handle('vdl:list', () =>
    jobs.map((j) => {
      // 已下載的檔案被使用者刪掉了
      if (j.status === 'done' && j.file && !fs.existsSync(j.file)) j.missing = true
      return publicJob(j)
    }),
  )
  ipcMain.handle('vdl:options', (_e, masterUrl, conn) => options(masterUrl, conn))
  ipcMain.handle('vdl:add', (_e, v) => add(v))
  ipcMain.handle('vdl:pause', (_e, id) => {
    const j = jobs.find((x) => x.id === id)
    if (!j) return
    if (running.has(id)) running.get(id).abort()
    else if (j.status === 'queued') {
      j.status = 'paused'
      flush()
      emit(j, true)
    }
  })
  ipcMain.handle('vdl:resume', (_e, id) => {
    const j = jobs.find((x) => x.id === id)
    if (!j || running.has(id) || j.status === 'done') return
    j.status = 'queued'
    j.error = ''
    flush()
    emit(j, true)
    pump()
  })
  ipcMain.handle('vdl:remove', (_e, id, deleteFile) => remove(id, deleteFile))
  ipcMain.handle('vdl:show', (_e, id) => {
    const j = jobs.find((x) => x.id === id)
    if (j?.file && fs.existsSync(j.file)) shell.showItemInFolder(j.file)
    else shell.openPath(dir)
  })
  ipcMain.handle('vdl:dir', () => dir)
  ipcMain.handle('vdl:openDir', () => {
    fs.mkdirSync(dir, { recursive: true })
    return shell.openPath(dir)
  })
  ipcMain.handle('vdl:chooseDir', async (e) => {
    const r = await dialog.showOpenDialog(BrowserWindow.fromWebContents(e.sender), { defaultPath: dir, properties: ['openDirectory', 'createDirectory'] })
    if (r.canceled || !r.filePaths[0]) return dir
    // 還在下載的暫存檔留在舊位置會接不上，先暫停全部
    for (const [, ctl] of running) ctl.abort()
    dir = r.filePaths[0]
    flush()
    return dir
  })
  app.on('before-quit', () => {
    quitting = true
    for (const [, ctl] of running) ctl.abort()
    // 程式關掉時還在下載的，下次開啟接著下
    for (const j of jobs) if (j.status === 'running' || j.status === 'merging') j.status = 'queued'
    flush()
  })
  // 程式開啟時自動接著下載上次沒下完的
  setTimeout(pump, 1500)
}

module.exports = { setup, parseVariants, parseSegments, options, add }
