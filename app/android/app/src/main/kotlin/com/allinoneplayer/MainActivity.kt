package com.allinoneplayer

import android.content.Intent
import com.allinoneplayer.download.VideoDownloads
import com.allinoneplayer.net.WebFetcher
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Bridge.attach(flutterEngine, this)
        VideoDownloads.load()
    }

    @Deprecated("startActivityForResult 是播放器、網頁回傳結果最簡單的方式")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!Bridge.onActivityResult(requestCode, data)) super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onStart() {
        super.onStart()
        WebFetcher.resume()
        com.allinoneplayer.player.PreviewPlayer.resume()
    }

    override fun onStop() {
        super.onStop()
        com.allinoneplayer.player.PreviewPlayer.pause()
        // 退到背景就可能被系統關掉：登入 cookie 先寫到硬碟、更新備份
        runCatching { com.allinoneplayer.net.LoginKeeper.saveKnown() }
        // 退到背景或進入播放器：暫停隱藏 WebView，太久沒回來就釋放。
        // 開著登入／驗證網頁時不行：pauseTimers() 是整個 App 共用的，會連那個網頁的 JS 一起停掉
        if (com.allinoneplayer.web.WebActivity.current == null) WebFetcher.pause()
    }

    override fun onDestroy() {
        Bridge.detach(this)
        super.onDestroy()
    }
}
