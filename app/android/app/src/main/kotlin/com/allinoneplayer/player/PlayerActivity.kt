package com.allinoneplayer.player

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.SystemClock
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.annotation.OptIn
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.allinoneplayer.App
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * 全螢幕播放器（手機、電視共用）。用一般 View，不用 Flutter，盒子上比較省資源。
 *
 * 電視：不用 PlayerView 的控制列（它會搶方向鍵），按鍵自己處理，只畫一條進度列：
 *   左右 = 倒退／快轉 10 秒（長按加速），OK = 暫停／播放，長按 OK = 按住期間 2 倍速，
 *   上鍵或選單鍵 = 選項（畫質、速度、下一集），下鍵 = 顯示進度列，返回 = 離開。
 * 手機：PlayerView 內建控制列＋上方標題列；雙擊左右半邊 = 倒退／快轉 10 秒，長按 = 2 倍速。
 *
 * 結束時把播放位置交回 Dart（記錄續播位置）；選「下一集」時 next = true，由 Dart 解析下一集網址再開一次。
 */
@OptIn(UnstableApi::class)
class PlayerActivity : ComponentActivity() {

    companion object {
        const val EXTRA_REQ = "req"
        const val RESULT_POSITION = "position"
        const val RESULT_DURATION = "duration"
        const val RESULT_NEXT = "next"
        private const val SEEK_STEP_MS = 10_000L
        private const val BOOST_SPEED = 2f
        /** 兩次 OK 間隔比這短就視為長按的自動重複（人手連按不會這麼快） */
        private const val AUTO_REPEAT_GAP_MS = 200L
        private const val OVERLAY_TIMEOUT_MS = 3_500L

        fun intent(ctx: Context, req: Map<String, Any?>): Intent =
            Intent(ctx, PlayerActivity::class.java).putExtra(EXTRA_REQ, JSONObject(req).toString())
    }

    private class Quality(val label: String, val url: String)

    private lateinit var player: ExoPlayer
    private lateinit var playerView: PlayerView
    private lateinit var hint: TextView
    private lateinit var tvOverlay: View
    private lateinit var phoneBar: View
    private lateinit var status: TextView
    private lateinit var timeText: TextView
    private lateinit var progress: ProgressBar
    private var hintJob: Job? = null
    private var overlayJob: Job? = null

    private val tv = App.isTv
    private var title = ""
    private var kind = "hls"
    private var conn = Conn()
    private var qualities: List<Quality> = emptyList()
    private var qualityIndex = 0
    private var hasNext = false
    private var wantNext = false
    private var ended = false
    private var autoRetries = 0
    /** HLS 畫面高度清單（高到低）；-1 = 還沒決定，0 = 自動 */
    private var heights: List<Int> = emptyList()
    private var hlsQuality = -1
    private var speed = 1f

    private var seekTarget: Long? = null
    private var okDown = false
    private var boosting = false
    private var lastOkUp = 0L
    private var boostRelease: Job? = null

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (tv) {
                if (!isPlaying) showOverlay() else updateOverlay()
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_READY) autoRetries = 0
            if (state == Player.STATE_ENDED) {
                ended = true
                if (hasNext) {
                    showHint("即將播放下一集…")
                    lifecycleScope.launch {
                        delay(1_500)
                        if (ended) playNext()
                    }
                } else if (tv) showOverlay()
            }
            updateOverlay()
        }

        override fun onPlayerError(error: PlaybackException) {
            if (Media.isStorageBlockedError(error)) {
                showHint(Media.STORAGE_BLOCKED_MESSAGE, long = true)
                if (tv) showOverlay()
                return
            }
            // 被 CDN 擋或斷線：自動從目前位置重新連線，連續失敗 3 次才要使用者處理
            if (Media.isTransientError(error) && autoRetries < 3) {
                autoRetries++
                showHint("連線被中斷，重新連線中…")
                lifecycleScope.launch {
                    delay(autoRetries * 1_500L)
                    player.prepare()
                    player.play()
                }
                return
            }
            // 多畫質 MP4：這個畫質壞了就自動降一級
            if (kind == "mp4" && qualityIndex < qualities.lastIndex) {
                val pos = player.currentPosition
                qualityIndex++
                showHint("${qualities[qualityIndex - 1].label} 無法播放，改用 ${qualities[qualityIndex].label}")
                loadCurrent(pos)
                return
            }
            val code = Media.httpCode(error)?.let { "HTTP $it" } ?: error.errorCodeName
            showHint("播放失敗（$code），${if (tv) "按 OK" else "點播放鍵"}重試", long = true)
            if (tv) showOverlay()
        }

        override fun onTracksChanged(tracks: Tracks) {
            if (kind != "hls") return
            heights = tracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO }
                .flatMap { g -> (0 until g.length).map { g.getTrackFormat(it).height } }
                .filter { it > 0 }.distinct().sortedDescending()
            // 預設直接用最高畫質
            if (hlsQuality == -1 && heights.isNotEmpty()) applyHlsQuality(heights.first())
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        hideSystemBars()

        val req = runCatching { JSONObject(intent.getStringExtra(EXTRA_REQ).orEmpty()) }.getOrNull()
        val url = req?.optString("url").orEmpty()
        if (req == null || url.isEmpty()) {
            finish()
            return
        }
        title = req.optString("title")
        kind = req.optString("kind", "hls")
        hasNext = req.optBoolean("hasNext")
        conn = Conn(
            headers = req.optJSONObject("headers")?.let { h -> h.keys().asSequence().associateWith { h.optString(it) } }.orEmpty(),
            cronet = req.optBoolean("cronet"),
            unwrap = req.optBoolean("unwrap"),
        )
        qualities = req.optJSONArray("qualities")?.let { a ->
            (0 until a.length()).mapNotNull { a.optJSONObject(it) }.map { Quality(it.optString("label"), it.optString("url")) }
        }.orEmpty().ifEmpty { listOf(Quality("", url)) }
        qualityIndex = qualities.indexOfFirst { it.url == url }.coerceAtLeast(0)

        // 控制列的倒退／快轉鍵預設是 5 秒／15 秒，統一成 10 秒（跟雙擊一樣）
        player = ExoPlayer.Builder(this)
            .setLoadControl(Media.loadControl())
            .setSeekBackIncrementMs(SEEK_STEP_MS)
            .setSeekForwardIncrementMs(SEEK_STEP_MS)
            .build().also { it.addListener(listener) }

        playerView = PlayerView(this).apply {
            player = this@PlayerActivity.player
            useController = !tv
            isFocusable = false
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
            setBackgroundColor(Color.BLACK)
            keepScreenOn = true
            if (!tv) {
                controllerShowTimeoutMs = 3_500
                setShowNextButton(false)
                setShowPreviousButton(false)
                setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { v ->
                    phoneBar.visibility = v
                    if (v == View.VISIBLE) showSystemBarsBriefly() else hideSystemBars()
                })
            }
        }
        hint = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = if (tv) 18f else 15f
            background = GradientDrawable().apply { cornerRadius = dp(10).toFloat(); setColor(0xCC000000.toInt()) }
            setPadding(dp(14), dp(8), dp(14), dp(8))
            visibility = View.GONE
        }
        tvOverlay = buildTvOverlay()
        phoneBar = buildPhoneBar()

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(playerView)
            // 手勢層放在 PlayerView 的 overlay（影片之上、控制列之下）：控制列出現時進度條、按鈕照常可以拖、可以按
            if (!tv) playerView.overlayFrameLayout?.addView(gestureLayer(), FrameLayout.LayoutParams(-1, -1))
            addView(tvOverlay, FrameLayout.LayoutParams(-1, -1))
            addView(phoneBar, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
            addView(hint, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(72) })
        }
        setContentView(root)

        // targetSdk 36 預設啟用預測返回，返回鍵不會經過 dispatchKeyEvent
        onBackPressedDispatcher.addCallback(this) { finishWithResult() }

        val startMs = req.optLong("startMs")
        loadCurrent(if (startMs > 5_000) startMs else 0)
        if (startMs > 5_000) showHint("從 ${fmt(startMs)} 繼續播放")
        player.playWhenReady = true
        if (tv) showOverlay()
        startTicker()
    }

    private fun loadCurrent(positionMs: Long) {
        val q = qualities[qualityIndex]
        player.setMediaSource(Media.source(kind, q.url, conn))
        if (positionMs > 0) player.seekTo(positionMs)
        player.prepare()
        player.play()
    }

    // ---------- 手機 ----------

    private fun buildPhoneBar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(8), dp(8), dp(8))
            background = android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(0xCC000000.toInt(), 0x00000000),
            )
            visibility = View.GONE
        }
        bar.addView(textButton("‹ 返回") { finishWithResult() })
        bar.addView(TextView(this).apply {
            text = title
            setTextColor(Color.WHITE)
            textSize = 15f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = dp(4); rightMargin = dp(4) })
        bar.addView(textButton("選項") { showOptions() })
        bar.addView(textButton("旋轉") { rotate() })
        if (tv) bar.visibility = View.GONE
        return bar
    }

    private fun textButton(label: String, onClick: () -> Unit) = TextView(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 14f
        gravity = Gravity.CENTER
        minHeight = dp(48)
        minWidth = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
    }

    private fun rotate() {
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        requestedOrientation = if (landscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
    }

    /**
     * 左右半邊連點：點兩下 = 倒退／快轉 10 秒，點三下 = 1 分鐘（再多點一下多 10 秒）；
     * 長按 = 2 倍速（放開恢復）；單擊 = 顯示／隱藏控制列。
     */
    @SuppressLint("ClickableViewAccessibility")
    private fun gestureLayer(): View {
        val layer = View(this)
        val main = android.os.Handler(mainLooper)
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop
        val tapGap = 300L
        var taps = 0
        var lastUp = 0L
        var lastForward = true
        var downX = 0f
        var downY = 0f
        var moved = false
        val singleTap = Runnable {
            if (playerView.isControllerFullyVisible) playerView.hideController() else playerView.showController()
        }
        val longPress = Runnable { startBoost() }

        fun seek(ms: Long, text: String) {
            val dur = player.duration.takeIf { it != C.TIME_UNSET } ?: Long.MAX_VALUE
            player.seekTo((player.currentPosition + ms).coerceIn(0, dur))
            showHint(text)
        }

        layer.setOnTouchListener { _, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.x
                    downY = ev.y
                    moved = false
                    main.postDelayed(longPress, android.view.ViewConfiguration.getLongPressTimeout().toLong())
                }
                MotionEvent.ACTION_MOVE -> if (!moved && (Math.abs(ev.x - downX) > slop || Math.abs(ev.y - downY) > slop)) {
                    moved = true
                    main.removeCallbacks(longPress)
                }
                MotionEvent.ACTION_UP -> {
                    main.removeCallbacks(longPress)
                    when {
                        boosting -> stopBoost()
                        moved -> {}
                        else -> {
                            val now = SystemClock.uptimeMillis()
                            val forward = ev.x > layer.width / 2f
                            taps = if (now - lastUp < tapGap && forward == lastForward) taps + 1 else 1
                            lastUp = now
                            lastForward = forward
                            val sign = if (forward) 1 else -1
                            val word = if (forward) "快轉" else "倒退"
                            main.removeCallbacks(singleTap)
                            when (taps) {
                                1 -> main.postDelayed(singleTap, tapGap)
                                2 -> seek(sign * SEEK_STEP_MS, "$word 10 秒")
                                // 第三下：再補 50 秒，合計 1 分鐘
                                3 -> seek(sign * 50_000L, "$word 1 分鐘")
                                else -> seek(sign * SEEK_STEP_MS, "再$word 10 秒")
                            }
                        }
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    main.removeCallbacks(longPress)
                    if (boosting) stopBoost()
                }
            }
            true
        }
        return layer
    }

    private fun hideSystemBars() {
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun showSystemBarsBriefly() {
        // 控制列出現時不顯示系統列（避免畫面跳動），保持沉浸
        hideSystemBars()
    }

    // ---------- 電視 ----------

    private fun buildTvOverlay(): View {
        val titleView = TextView(this).apply {
            text = title
            setTextColor(Color.WHITE)
            textSize = 18f
            maxLines = 2
            setShadowLayer(6f, 0f, 0f, Color.BLACK)
            setPadding(dp(32), dp(24), dp(32), 0)
        }
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 16f
            setPadding(0, 0, dp(16), 0)
        }
        timeText = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            setPadding(dp(16), 0, 0, 0)
        }
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            progressTintList = ColorStateList.valueOf(0xFFE11D48.toInt())
            secondaryProgressTintList = ColorStateList.valueOf(0x66FFFFFF)
            progressBackgroundTintList = ColorStateList.valueOf(0x33FFFFFF)
        }
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(32), dp(18), dp(32), dp(24))
            setBackgroundColor(0x99000000.toInt())
            addView(status)
            addView(progress, LinearLayout.LayoutParams(0, -2, 1f))
            addView(timeText)
        }
        val help = TextView(this).apply {
            text = "OK 暫停　←→ 快退／快轉　長按 OK 2 倍速　↑ 選項"
            setTextColor(0xFF94A3B8.toInt())
            textSize = 13f
            setPadding(dp(32), 0, dp(32), dp(4))
        }
        return FrameLayout(this).apply {
            addView(titleView, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
            addView(LinearLayout(this@PlayerActivity).apply {
                orientation = LinearLayout.VERTICAL
                addView(help)
                addView(bar)
            }, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))
            visibility = View.GONE
        }
    }

    private fun showOverlay() {
        if (!tv) return
        tvOverlay.visibility = View.VISIBLE
        updateOverlay()
        overlayJob?.cancel()
        overlayJob = lifecycleScope.launch {
            delay(OVERLAY_TIMEOUT_MS)
            while (isActive && (!player.isPlaying || seekTarget != null || boosting)) delay(500)
            tvOverlay.visibility = View.GONE
        }
    }

    private fun updateOverlay() {
        if (!tv || tvOverlay.visibility != View.VISIBLE) return
        val dur = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: 0L
        val pos = seekTarget ?: player.currentPosition
        status.text = when {
            boosting -> "▶▶ 2x"
            seekTarget != null -> if (seekTarget!! >= player.currentPosition) "▶▶" else "◀◀"
            ended -> "■"
            player.playWhenReady -> "▶"
            else -> "❚❚"
        }
        val q = currentQualityLabel()?.let { "  ·  $it" }.orEmpty()
        val sp = if (speed != 1f && !boosting) "  ·  ${speed}x" else ""
        timeText.text = "${fmt(pos)} / ${if (dur > 0) fmt(dur) else "--:--"}$q$sp"
        if (dur > 0) {
            progress.progress = (pos * 1000 / dur).toInt()
            progress.secondaryProgress = (player.bufferedPosition * 1000 / dur).toInt()
        }
    }

    private fun startTicker() {
        lifecycleScope.launch {
            while (isActive) {
                if (tv && tvOverlay.visibility == View.VISIBLE) updateOverlay()
                delay(500)
            }
        }
    }

    private fun seekBy(forward: Boolean, repeat: Int) {
        val dur = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: return
        val base = seekTarget ?: player.currentPosition
        // 第一下 10 秒；長按時依影片長度加速，大約 7 秒可以從頭掃到尾
        val step = if (repeat == 0) SEEK_STEP_MS else (dur / 150).coerceIn(5_000L, 60_000L)
        seekTarget = (base + if (forward) step else -step).coerceIn(0L, dur)
        showOverlay()
    }

    private fun commitSeek() {
        val target = seekTarget ?: return
        seekTarget = null
        player.seekTo(target)
        if (ended) {
            ended = false
            player.play()
        }
        showOverlay()
    }

    private fun startBoost() {
        boosting = true
        seekTarget = null
        if (!player.isPlaying) player.play()
        player.setPlaybackSpeed(BOOST_SPEED)
        if (!tv) showHint("2 倍速播放中")
        showOverlay()
    }

    private fun stopBoost() {
        boosting = false
        player.setPlaybackSpeed(speed)
        if (!tv) hint.visibility = View.GONE
        showOverlay()
    }

    private fun togglePlay() {
        when {
            player.playerError != null -> {
                player.prepare()
                player.play()
            }
            ended -> {
                ended = false
                player.seekTo(0)
                player.play()
            }
            else -> player.playWhenReady = !player.playWhenReady
        }
        showOverlay()
    }

    // ---------- 選項：畫質、速度、下一集 ----------

    private fun currentQualityLabel(): String? = when {
        kind == "hls" && hlsQuality > 0 -> "${hlsQuality}p"
        kind == "hls" && hlsQuality == 0 -> "自動"
        kind == "mp4" && qualities.size > 1 -> qualities[qualityIndex].label
        else -> null
    }

    private fun applyHlsQuality(h: Int) {
        hlsQuality = h
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon().apply {
            clearOverridesOfType(C.TRACK_TYPE_VIDEO)
            if (h != 0) {
                player.currentTracks.groups.firstOrNull { it.type == C.TRACK_TYPE_VIDEO }?.let { g ->
                    val idx = (0 until g.length).firstOrNull { g.getTrackFormat(it).height == h }
                    if (idx != null) setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, idx))
                }
            }
        }.build()
    }

    private fun showOptions() {
        val items = mutableListOf<Pair<String, () -> Unit>>()
        if (hasNext) items += "下一集" to { playNext() }
        if (kind == "hls" && heights.isNotEmpty()) items += "畫質（${currentQualityLabel() ?: "自動"}）" to { chooseHlsQuality() }
        if (kind == "mp4" && qualities.size > 1) items += "畫質（${qualities[qualityIndex].label}）" to { chooseMp4Quality() }
        items += "播放速度（${speed}x）" to { chooseSpeed() }
        dialog("選項", items.map { it.first }) { items[it].second() }
    }

    private fun chooseHlsQuality() {
        val options = listOf(0) + heights
        dialog("選擇畫質", options.map { h -> (if (h == 0) "自動" else "${h}p") + if (h == hlsQuality) "（目前）" else "" }) { i ->
            val h = options[i]
            if (h != hlsQuality) {
                applyHlsQuality(h)
                showHint(if (h == 0) "畫質：自動" else "已切換到 ${h}p")
            }
        }
    }

    private fun chooseMp4Quality() {
        dialog("選擇畫質", qualities.mapIndexed { i, q -> q.label + if (i == qualityIndex) "（目前）" else "" }) { i ->
            if (i != qualityIndex) {
                val pos = player.currentPosition
                qualityIndex = i
                loadCurrent(pos)
                showHint("已切換到 ${qualities[i].label}")
            }
        }
    }

    private fun chooseSpeed() {
        val speeds = listOf(0.75f, 1f, 1.25f, 1.5f, 2f)
        dialog("播放速度", speeds.map { "${it}x" + if (it == speed) "（目前）" else "" }) { i ->
            speed = speeds[i]
            player.setPlaybackSpeed(speed)
            showOverlay()
        }
    }

    private fun dialog(title: String, labels: List<String>, onPick: (Int) -> Unit) {
        AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
            .setTitle(title)
            .setItems(labels.toTypedArray()) { _, i -> onPick(i) }
            .show()
    }

    private fun playNext() {
        wantNext = true
        finishWithResult()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val down = event.action == KeyEvent.ACTION_DOWN
        val first = down && event.repeatCount == 0
        when (event.keyCode) {
            KeyEvent.KEYCODE_MEDIA_NEXT, KeyEvent.KEYCODE_CHANNEL_UP -> {
                if (first && hasNext) playNext()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                if (first) togglePlay()
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PLAY -> {
                if (first) { player.play(); showOverlay() }
                return true
            }
            KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                if (first) { player.pause(); showOverlay() }
                return true
            }
        }
        if (!tv) return super.dispatchKeyEvent(event)

        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> {
                if (down) seekBy(false, event.repeatCount) else commitSeek()
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                if (down) seekBy(true, event.repeatCount) else commitSeek()
                return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER, KeyEvent.KEYCODE_SPACE -> {
                // 短按：暫停／播放（放開時才判斷）；長按：放開前以 2 倍速播放。
                // 一般遙控器長按送 repeatCount > 0 的 DOWN；部分紅外線遙控器連續送很密的「按下＋放開」。
                val now = SystemClock.uptimeMillis()
                if (down) {
                    if (event.repeatCount == 0) {
                        okDown = true
                        if (now - lastOkUp < AUTO_REPEAT_GAP_MS) {
                            boostRelease?.cancel()
                            if (!boosting) startBoost()
                        }
                    } else if (okDown && !boosting) {
                        startBoost()
                    }
                } else {
                    lastOkUp = now
                    if (boosting) {
                        boostRelease?.cancel()
                        boostRelease = lifecycleScope.launch {
                            delay(AUTO_REPEAT_GAP_MS)
                            stopBoost()
                        }
                    } else if (okDown) {
                        togglePlay()
                    }
                    okDown = false
                }
                return true
            }
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_SETTINGS -> {
                if (first) showOptions()
                return true
            }
            KeyEvent.KEYCODE_DPAD_DOWN -> {
                if (first) {
                    if (tvOverlay.visibility == View.VISIBLE && player.isPlaying) tvOverlay.visibility = View.GONE
                    else showOverlay()
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun showHint(text: String, long: Boolean = false) {
        hint.text = text
        hint.visibility = View.VISIBLE
        hintJob?.cancel()
        hintJob = lifecycleScope.launch {
            delay(if (long) 6_000 else 1_800)
            hint.visibility = View.GONE
        }
    }

    private fun finishWithResult() {
        if (isFinishing) return
        val pos = if (::player.isInitialized) player.currentPosition else 0L
        val dur = if (::player.isInitialized) player.duration.takeIf { it != C.TIME_UNSET } ?: 0L else 0L
        setResult(
            Activity.RESULT_OK,
            Intent().putExtra(RESULT_POSITION, if (ended) dur else pos).putExtra(RESULT_DURATION, dur).putExtra(RESULT_NEXT, wantNext),
        )
        finish()
    }

    override fun onPause() {
        super.onPause()
        if (!::player.isInitialized) return
        boostRelease?.cancel()
        if (boosting) stopBoost()
        okDown = false
        player.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::player.isInitialized) player.release()
    }

    private fun fmt(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        val h = s / 3600
        val m = s % 3600 / 60
        val ss = s % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, ss) else "%d:%02d".format(m, ss)
    }
}
