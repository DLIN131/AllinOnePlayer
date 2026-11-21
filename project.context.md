# AllinOnePlayer — 專案脈絡

改任何東西前先讀這份；每次改動都在最後的「版本紀錄」加一筆。

## 規則

- **不寫出任何網站名稱或網域。** 程式、註解、文件、commit 一律只用來源代號；網域、站名、分類名稱清單只以 Base64 存放（`app/lib/core/sites.dart`、各來源檔）。
  本機 `.git/hooks/pre-commit` 會在 commit 前掃描禁用字（清單只在本機，不進 repo）。
- commit 訊息＝發布說明（App 內「更新紀錄」直接顯示）：繁體中文、寫給使用者看，第一行是標題、其餘用「- 」條列。
- 測試用的網頁存檔放 `fixtures/`（已 gitignore），不能進 repo。
- 開發機：Flutter `D:\FlutterSDK\flutter`、JDK `D:\FlutterSDK\jdk-21`、Android SDK / Node / Python 在 `D:\DevTools`（先 `. D:\DevTools\env.ps1`）。不開模擬器，用截圖測試看畫面。

## 來源代號

| 代號 | 類型 | 取資料 | 播放／閱讀 | 帳號 |
|---|---|---|---|---|
| va | 影片 | HTML，有 Cloudflare → 隱藏 WebView | HLS；網址藏在 p,a,c,k,e,d 打包的 JS；CDN 要 Referer+Origin，Cronet 優先，403 重試，BucketPunish = 網站端壞掉 | 網站 JSON API：`POST /api/login`、`/saved` `/history`、`/api/items/<id>/save|view`、`DELETE /api/history`（WebView 內送，帶 XSRF） |
| vx | （va 附屬） | 番號查女優的另一個站，一般 HTTP | — | — |
| vb | 影片 | HTML，有 Cloudflare | 直連 MP4 多畫質，要 Referer；壞了自動降畫質 | 無 |
| vc | 影片／劇集 | 頁面內嵌 SSR 資料（`Tsr` 解析，不執行 JS），一般 HTTP | HLS，清單與片段包在 PNG 裡（自訂區塊 0x726f5564，旗標 bit0 = zlib）→ 原生 `UnwrapDataSource` | 無 |
| nh | 漫畫 | 官方 v2 API | 圖片直連 | `access_token` cookie → `Authorization: User`；401 時 `POST /auth/refresh` |
| jm | 漫畫 | HTML，有 Cloudflare | 圖片切條倒置：段數 = md5(aid+檔名) 規則（`JmSource.segments`），閱讀時畫布還原、下載時 isolate 還原存 JPEG | 網站登入頁；收藏網址要帳號名稱（登入頁讀「看得到的」帳號欄）；同帳號只能一處登入 |
| wn | 漫畫 | HTML | 閱讀清單在 photos-gallery 頁的 JS | 網站登入頁 |
| eh | 漫畫 | HTML；列表用 next= 游標翻頁 | 每頁要再開 /s/ 頁拿圖，失敗用 nl= 換伺服器 | 論壇子網域登入（`ipb_member_id`） |

## 架構

### 手機／電視（`app/`，Flutter，flavor phone / tv）

- **網路全走原生**（`android/.../net`）：Dart 只解析。`Net.kt` = OkHttp + 跟 WebView 共用 cookie（`WebCookieJar`）+ 每站 Referer + nh token；
  `WebFetcher.kt` = 每站一個隱藏 WebView，停在 robots.txt，用 JS `fetch()` 抓；被驗證擋就直接開那頁等驗證跑完。背景暫停、60 秒後釋放。
  UA 一律「電腦版 Chrome」（版本同裝置 WebView），因為 Cloudflare 的通行 cookie 綁 UA。
- `web/WebActivity.kt`：看得到的網頁（登入／驗證／瀏覽），每次載完頁面送事件給 Dart，Dart 確認登入成功後關掉。
  注意 `pauseTimers()` 是全 App 共用：開著這頁時 MainActivity 不能暫停 WebFetcher。
- `player/PlayerActivity.kt`：Media3，手機用內建控制列＋手勢（雙擊快轉、長按 2 倍速），電視自己處理遙控器（左右快轉、長按 OK 2 倍速、上鍵選項）。結束回傳位置／是否要下一集。
- `download/`：影片下載（HLS 片段接成 .ts、MP4 續傳），前景服務，狀態用事件送 Dart。
- Dart：`core/sources/*.dart` 各來源；`core/model.dart` 統一資料型別（Item / Detail / Section / FilterSpec / Link…）；
  `core/store.dart` 本機資料（state.json 原子寫入 + .bak）；`core/auth.dart` 各站登入狀態；`core/comic/` CBZ 讀寫、切條還原、漫畫下載、書櫃；
  `core/playback.dart` 播放流程；`core/updater.dart` App 內更新（依檔名挑 AllinOnePlayer.apk / AllinOnePlayerTV.apk）；`core/pin_lock.dart` 開啟密碼（PBKDF2）。
- 介面（`ui/`）：設計系統 = ui-ux-pro-max 的 Video Streaming/OTT → Dark Mode (OLED)，只做深色（設計系統標明不建議淺色）。
  token 在 `ui/theme.dart`（bg #000、card #0C0C0D、muted #181818、fg #F8FAFC、muted-fg #94A3B8、accent #E11D48、焦點外框白色）；圖示 Lucide。
  手機底部 5 分頁（首頁／來源／搜尋／收藏／我的），電視左側選單（移到就切換），電視尺寸以 960×540dp 設計。
  `Tap` 元件 = 可點也可遙控器選（選到時白框＋放大，不改排版）。

### 電腦版（`desktop/`，Electron）

（建置中）

## 測試

- `flutter test test/core_test.dart`：解析器、切條、CBZ、更新說明。
- `LIVE=1 flutter test test/live_test.dart`：連真的網站測 vc / nh / wn / eh（有 Cloudflare 的站一般 HTTP 連不上，不在這裡測）。
- `SHOTS=1 FONT=<中文字型> OUT=<資料夾> flutter test test/shots_test.dart`：用真資料把主要畫面畫成 PNG（手機 411×891、電視 960×540）。
- Android：`flutter build apk --flavor phone|tv --release`。

## 版本紀錄

- v1.0.1（2026-11-21）：第一版。手機／電視 Flutter 介面、七個來源、各站登入、原生播放器、影片與漫畫下載、書櫃合集、開啟密碼、App 內更新。
