// 頁面不能直接碰網路 session 和視窗，透過這裡呼叫主程序
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('updater', {
  supported: () => ipcRenderer.invoke('update:supported'),
  download: (url, onProgress) => {
    const listener = (_e, p) => onProgress(p)
    ipcRenderer.on('update:progress', listener)
    return ipcRenderer.invoke('update:download', url).finally(() => ipcRenderer.removeListener('update:progress', listener))
  },
  install: () => ipcRenderer.invoke('update:install'),
})

// 頁面載好時回報主程序（主程序在等，太久沒回報會自動重載，見 watchdog.js）；頁面錯誤也記到 startup.log
window.addEventListener('error', (e) => ipcRenderer.send('app:error', `${e.message} @ ${e.filename}:${e.lineno}`))
window.addEventListener('unhandledrejection', (e) => ipcRenderer.send('app:error', `unhandled: ${e.reason?.message || e.reason}`))

const on = (channel) => (fn) => {
  const l = (_e, v) => fn(v)
  ipcRenderer.on(channel, l)
  return () => ipcRenderer.removeListener(channel, l)
}

contextBridge.exposeInMainWorld('hub', {
  ready: () => ipcRenderer.send('app:ready'),
  repair: () => ipcRenderer.invoke('app:repair'),
  version: () => ipcRenderer.invoke('app:version'),
  // 程式資料（進度、紀錄、設定…）存在主程序的 state.json；讀取一次拿全部，之後寫入只送變動
  state: {
    all: () => ipcRenderer.sendSync('state:all'),
    set: (key, value) => ipcRenderer.send('state:set', key, value),
  },
  /** opts: { json, method, body, headers, api, form } → { ok, status, data, url, error } */
  get: (site, url, opts) => ipcRenderer.invoke('net:get', site, url, opts),
  config: () => ipcRenderer.invoke('site:config'),
  setBase: (site, base) => ipcRenderer.invoke('site:setBase', site, base),
  authStatus: (site) => ipcRenderer.invoke('auth:status', site),
  login: (site) => ipcRenderer.invoke('auth:login', site),
  logout: (site) => ipcRenderer.invoke('auth:logout', site),
  setAccountName: (site, name) => ipcRenderer.invoke('auth:setName', site, name),
  // 要不要讓程式記住密碼（過期時自動重新登入）；false 也用來忘記已記住的密碼
  rememberLogin: (site, yes) => ipcRenderer.invoke('auth:remember', site, yes),
  openSite: (site, url) => ipcRenderer.invoke('site:open', site, url),
  external: (url) => ipcRenderer.invoke('shell:external', url),
  /** 播放前登記影片 CDN 要帶的標頭 */
  media: (url, headers) => ipcRenderer.invoke('net:media', url, headers),
  fullscreen: (on) => ipcRenderer.invoke('win:fullscreen', on),
  backup: {
    export: () => ipcRenderer.invoke('backup:export'),
    import: () => ipcRenderer.invoke('backup:import'),
    addDir: () => ipcRenderer.invoke('backup:addDir'),
  },
  // 漫畫下載（CBZ）：頁面逐張送圖，主程序寫檔
  cbz: {
    dir: () => ipcRenderer.invoke('cbz:dir'),
    chooseDir: () => ipcRenderer.invoke('cbz:chooseDir'),
    openDir: () => ipcRenderer.invoke('cbz:openDir'),
    show: (file) => ipcRenderer.invoke('cbz:show', file),
    exists: (name) => ipcRenderer.invoke('cbz:exists', name),
    fetch: (site, url) => ipcRenderer.invoke('cbz:fetch', site, url),
    open: (name) => ipcRenderer.invoke('cbz:open', name),
    add: (id, name, data) => ipcRenderer.invoke('cbz:add', id, name, data),
    finish: (id) => ipcRenderer.invoke('cbz:finish', id),
    abort: (id) => ipcRenderer.invoke('cbz:abort', id),
  },
  // 影片下載：主程序整個處理（HLS → MP4、MP4 續傳）
  vdl: {
    list: () => ipcRenderer.invoke('vdl:list'),
    options: (url, conn) => ipcRenderer.invoke('vdl:options', url, conn),
    add: (v) => ipcRenderer.invoke('vdl:add', v),
    pause: (id) => ipcRenderer.invoke('vdl:pause', id),
    resume: (id) => ipcRenderer.invoke('vdl:resume', id),
    remove: (id, deleteFile) => ipcRenderer.invoke('vdl:remove', id, deleteFile),
    show: (id) => ipcRenderer.invoke('vdl:show', id),
    dir: () => ipcRenderer.invoke('vdl:dir'),
    openDir: () => ipcRenderer.invoke('vdl:openDir'),
    chooseDir: () => ipcRenderer.invoke('vdl:chooseDir'),
    onUpdate: on('vdl:update'),
    onRemoved: on('vdl:removed'),
  },
  lib: {
    list: () => ipcRenderer.invoke('lib:list'),
    open: (file) => ipcRenderer.invoke('lib:open', file),
    pick: () => ipcRenderer.invoke('lib:pick'),
    trash: (file) => ipcRenderer.invoke('lib:trash', file),
    forget: (file) => ipcRenderer.invoke('lib:forget', file),
    external: (file) => ipcRenderer.invoke('lib:external', file),
  },
})
