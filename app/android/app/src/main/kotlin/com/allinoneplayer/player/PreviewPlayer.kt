package com.allinoneplayer.player

import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.allinoneplayer.App
import com.allinoneplayer.Bridge
import io.flutter.view.TextureRegistry

/**
 * 長按封面的預覽：小播放器畫在 Flutter 的 Texture 上（Dart 端顯示在預覽框裡），一律靜音。
 * 跟正式播放器用同一套連線（Media.source：Referer、Cronet、PNG 拆包），所以三個影片站都能播。
 * montage：沒有預覽短片的站直接播正片，在 10%～85% 幾個時間點之間每 5 秒跳一次。
 * 狀態用事件 {type: preview, id, state: ready|error, w, h, message} 送回 Dart。
 */
@OptIn(UnstableApi::class)
object PreviewPlayer {
    private var registry: TextureRegistry? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var player: ExoPlayer? = null
    private val main = Handler(Looper.getMainLooper())
    private val POINTS = doubleArrayOf(0.1, 0.25, 0.4, 0.55, 0.7, 0.85)
    private const val STEP_MS = 5000L
    private var step = 0
    private var jump: Runnable? = null

    fun attach(r: TextureRegistry) {
        registry = r
    }

    fun start(kind: String, url: String, conn: Conn, montage: Boolean): Long {
        stop()
        val reg = registry ?: throw IllegalStateException("畫面還沒準備好")
        val p = reg.createSurfaceProducer()
        val id = p.id()
        val ex = ExoPlayer.Builder(App.instance).build()
        ex.volume = 0f
        ex.repeatMode = if (montage) Player.REPEAT_MODE_OFF else Player.REPEAT_MODE_ONE
        p.setSize(1280, 720)
        p.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceAvailable() {
                if (player === ex) ex.setVideoSurface(p.surface)
            }

            override fun onSurfaceCleanup() {
                if (player === ex) ex.setVideoSurface(null)
            }
        })
        ex.setVideoSurface(p.surface)
        var shown = false
        var jumping = false
        ex.addListener(object : Player.Listener {
            override fun onVideoSizeChanged(v: VideoSize) {
                if (v.width > 0 && v.height > 0) p.setSize(v.width, v.height)
            }

            override fun onRenderedFirstFrame() {
                if (shown || player !== ex) return
                shown = true
                val v = ex.videoSize
                Bridge.emit(mapOf("type" to "preview", "id" to id, "state" to "ready", "w" to v.width, "h" to v.height))
            }

            override fun onPlaybackStateChanged(state: Int) {
                if (!montage || jumping || state != Player.STATE_READY || player !== ex) return
                val dur = ex.duration
                if (dur == C.TIME_UNSET || dur <= 0) return
                jumping = true
                step = 0
                ex.seekTo((dur * POINTS[0]).toLong())
                val r = object : Runnable {
                    override fun run() {
                        if (player !== ex) return
                        step = (step + 1) % POINTS.size
                        ex.seekTo((dur * POINTS[step]).toLong())
                        main.postDelayed(this, STEP_MS)
                    }
                }
                jump = r
                main.postDelayed(r, STEP_MS)
            }

            override fun onPlayerError(error: PlaybackException) {
                if (player !== ex) return
                val code = Media.httpCode(error)?.let { "HTTP $it" } ?: error.errorCodeName
                Bridge.emit(mapOf("type" to "preview", "id" to id, "state" to "error", "message" to code))
            }
        })
        producer = p
        player = ex
        ex.setMediaSource(Media.source(kind, url, conn))
        ex.prepare()
        ex.playWhenReady = true
        return id
    }

    fun stop() {
        jump?.let { main.removeCallbacks(it) }
        jump = null
        player?.release()
        player = null
        producer?.release()
        producer = null
    }

    /** App 退到背景：先停下來，回來再繼續 */
    fun pause() {
        player?.playWhenReady = false
    }

    fun resume() {
        player?.playWhenReady = true
    }
}
