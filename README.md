# AllinOnePlayer

把幾個影片、漫畫來源整合在一起的播放／閱讀器，三個版本共用一套介面設計：

| 版本 | 技術 | 下載 |
|---|---|---|
| 手機（Android） | Flutter + 原生 Media3 播放器 | [AllinOnePlayer.apk](../../releases/latest/download/AllinOnePlayer.apk) |
| 電視（Android TV） | Flutter（遙控器操作）+ 原生 Media3 播放器 | [AllinOnePlayerTV.apk](../../releases/latest/download/AllinOnePlayerTV.apk) |
| 電腦（Windows） | Electron | [AllinOnePlayer-Windows.zip](../../releases/latest/download/AllinOnePlayer-Windows.zip) |

## 功能

- 影片：分類、篩選、搜尋、續播、劇集連播、下載（手機、電腦）
- 漫畫：直向捲動／左右翻頁閱讀、章節、閱讀進度、編號搜尋、語言篩選、下載成 CBZ、書櫃與合集
- 各網站的帳號登入（在網站自己的登入頁登入，App 不存密碼），網站帳號的收藏、觀看紀錄
- 本機收藏、紀錄、開啟密碼（PIN）、App 內自動更新

## 結構

```
app/       Flutter（手機 + 電視，flavor：phone / tv）
  lib/core/   各來源的資料解析、本機資料、帳號、下載
  lib/ui/     介面（手機底部分頁、電視左側選單）
  android/    原生層：連線（隱藏 WebView、cookie 共用）、播放器、影片下載
desktop/   電腦版（Electron）
```

詳細的技術說明和每一版的變更在 [project.context.md](project.context.md)。

## 建置

```
cd app
flutter build apk --flavor phone --release
flutter build apk --flavor tv --release
```

推上 `main` 後 GitHub Actions 會自動建置並發布 `v1.0.<編號>`，App 會提示更新。
