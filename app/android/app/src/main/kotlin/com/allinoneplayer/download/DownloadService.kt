package com.allinoneplayer.download

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.allinoneplayer.App

/**
 * 前景服務：有東西在下載時讓 App 切到背景也不會被系統殺掉，通知列顯示目前進度。
 * 實際下載邏輯在 [VideoDownloads]。
 */
class DownloadService : Service() {
    companion object {
        private const val CHANNEL = "downloads"
        private const val NOTIFY_ID = 1001
        private var lastPercent = -1

        fun start() {
            val ctx = App.instance
            runCatching { ContextCompat.startForegroundService(ctx, Intent(ctx, DownloadService::class.java)) }
        }

        fun update(item: VideoDownloads.Item) {
            val percent = (item.progress * 100).toInt()
            if (percent == lastPercent) return
            lastPercent = percent
            val ctx = App.instance
            val nm = ctx.getSystemService(NotificationManager::class.java)
            runCatching { nm.notify(NOTIFY_ID, build(ctx, item)) }
        }

        private fun build(ctx: Context, item: VideoDownloads.Item?): Notification {
            ensureChannel(ctx)
            val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val open = PendingIntent.getActivity(ctx, 0, launch ?: Intent(), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val queued = VideoDownloads.items.count { it.status == VideoDownloads.Status.queued }
            val percent = ((item?.progress ?: 0f) * 100).toInt()
            val title = item?.meta?.optString("title").orEmpty()
            return NotificationCompat.Builder(ctx, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(if (item != null) "下載中 $percent%" else "準備下載…")
                .setContentText(
                    title.take(40) + (item?.let { "  ·  ${fmtSize(it.bytes)}" } ?: "") + if (queued > 0) "（還有 $queued 部排隊中）" else ""
                )
                .setProgress(100, percent, item == null || item.progress == 0f)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setContentIntent(open)
                .build()
        }

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(NotificationChannel(CHANNEL, "下載", NotificationManager.IMPORTANCE_LOW))
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val watcher = object : Runnable {
        override fun run() {
            val busy = VideoDownloads.items.any { it.status == VideoDownloads.Status.queued || it.status == VideoDownloads.Status.running }
            if (!busy) {
                lastPercent = -1
                ServiceCompat.stopForeground(this@DownloadService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            } else handler.postDelayed(this, 1_000)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val running = VideoDownloads.items.firstOrNull { it.status == VideoDownloads.Status.running }
        ServiceCompat.startForeground(
            this, NOTIFY_ID, build(this, running),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        // 佇列清空就自己結束（不由外面 stopService，避免還沒 startForeground 就被停掉而閃退）
        handler.removeCallbacks(watcher)
        handler.postDelayed(watcher, 1_000)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(watcher)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
