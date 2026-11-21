// 登入視窗用：在 Google 的登入頁把 Chromium 才有的 navigator.userAgentData 藏起來（UA 已經改報 Firefox，兩個要一致，不然會被判定是內嵌瀏覽器）
const { webFrame } = require('electron')

const h = location.hostname
if (h.startsWith('accounts.google.') || h === 'accounts.youtube.com') {
  webFrame.executeJavaScript("Object.defineProperty(Navigator.prototype, 'userAgentData', { get: () => undefined, configurable: true })").catch(() => {})
}
