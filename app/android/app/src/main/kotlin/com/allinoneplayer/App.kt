package com.allinoneplayer

import android.app.Application
import com.google.android.gms.net.CronetProviderInstaller

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
        // 影片 CDN 優先用 Play 服務的 Cronet（Chrome 同一套網路層）；背景安裝，沒有 Play 服務就算了
        runCatching { CronetProviderInstaller.installProvider(this) }
    }

    companion object {
        lateinit var instance: App
            private set

        val isTv: Boolean get() = BuildConfig.IS_TV
    }
}
