package com.allinoneplayer.player

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cronet.CronetDataSource
import androidx.media3.datasource.cronet.CronetUtil
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import com.allinoneplayer.App
import com.allinoneplayer.net.Net
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import org.chromium.net.CronetEngine
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.Inflater

/**
 * 一次播放 / 下載要怎麼連線（Dart 端依來源決定後傳過來）：
 * headers：CDN 要的 Referer / Origin；cronet：優先用 Play 服務的 Cronet（CDN 會看連線指紋）；
 * unwrap：播放清單和片段包在 PNG 裡，要先拆出來（見 [Png]）。
 */
class Conn(
    val headers: Map<String, String> = emptyMap(),
    val cronet: Boolean = false,
    val unwrap: Boolean = false,
) {
    companion object {
        @Suppress("UNCHECKED_CAST")
        fun from(m: Map<String, Any?>) = Conn(
            headers = (m["headers"] as? Map<String, String>).orEmpty(),
            cronet = m["cronet"] == true,
            unwrap = m["unwrap"] == true,
        )
    }
}

@OptIn(UnstableApi::class)
object Media {
    private val http by lazy {
        OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS).build()
    }

    /** Play 服務的 Cronet；還沒裝好或沒有 Play 服務就是 null（每次重新試，晚一點裝好下一部就會用上） */
    private var cronet: CronetEngine? = null
    private val cronetExecutor by lazy { Executors.newFixedThreadPool(4) }

    private fun cronetEngine(): CronetEngine? {
        cronet?.let { return it }
        // 只用 Play 服務版，不用 Cronet 內建的 Java 備援實作（那個指紋跟 OkHttp 差不多）
        return runCatching { CronetUtil.buildCronetEngine(App.instance, Net.userAgent, true) }.getOrNull()?.also { cronet = it }
    }

    private fun http(c: Conn): DataSource.Factory {
        if (c.cronet) cronetEngine()?.let { engine ->
            return CronetDataSource.Factory(engine, cronetExecutor)
                .setUserAgent(Net.userAgent)
                .setDefaultRequestProperties(c.headers)
                .setConnectionTimeoutMs(15_000)
                .setReadTimeoutMs(30_000)
        }
        return OkHttpDataSource.Factory(http).setUserAgent(Net.userAgent).setDefaultRequestProperties(c.headers)
    }

    fun factory(c: Conn): DataSource.Factory {
        val up = http(c)
        return if (c.unwrap) DataSource.Factory { UnwrapDataSource(up.createDataSource()) } else up
    }

    /**
     * 被 CDN 擋（403）、限流（429）或伺服器出錯（5xx）時：等一下再重試同一個檔案，最多 6 次。
     * 預設做法是把這個畫質整個排除，但畫質是固定的，排除後就沒得播。
     */
    private class RetryPolicy : DefaultLoadErrorHandlingPolicy(6) {
        override fun getFallbackSelectionFor(
            fallbackOptions: LoadErrorHandlingPolicy.FallbackOptions,
            loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo,
        ): LoadErrorHandlingPolicy.FallbackSelection? =
            if (isTransient(loadErrorInfo.exception)) null else super.getFallbackSelectionFor(fallbackOptions, loadErrorInfo)

        override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long = when {
            isStorageBlocked(loadErrorInfo.exception) -> C.TIME_UNSET
            isTransient(loadErrorInfo.exception) -> (loadErrorInfo.errorCount * 1_000L).coerceAtMost(5_000L)
            else -> super.getRetryDelayMsFor(loadErrorInfo)
        }
    }

    private fun isTransient(e: Throwable): Boolean {
        val code = (e as? HttpDataSource.InvalidResponseCodeException)?.responseCode ?: return false
        if (isStorageBlocked(e)) return false
        return code == 403 || code == 429 || code >= 500
    }

    /** 影片檔所在的雲端儲存空間被停用（403 + BucketPunish）：網站那邊的問題，重試也沒用 */
    private fun isStorageBlocked(e: Throwable): Boolean {
        val ex = e as? HttpDataSource.InvalidResponseCodeException ?: return false
        return ex.responseCode == 403 && String(ex.responseBody, Charsets.UTF_8).contains("BucketPunish")
    }

    const val STORAGE_BLOCKED_MESSAGE =
        "這部影片在網站的伺服器上目前無法播放（網站本身也播不了，常見於最近上傳的影片），請改看其他影片或過幾天再試"

    fun isStorageBlockedError(error: PlaybackException): Boolean =
        generateSequence<Throwable>(error) { it.cause }.any { isStorageBlocked(it) }

    fun isTransientError(error: PlaybackException): Boolean =
        generateSequence<Throwable>(error) { it.cause }.any { isTransient(it) } ||
            error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED ||
            error.errorCode == PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT

    fun httpCode(error: PlaybackException): Int? =
        generateSequence<Throwable>(error) { it.cause }.firstNotNullOfOrNull { (it as? HttpDataSource.InvalidResponseCodeException)?.responseCode }

    /** kind：hls / mp4 / local（已下載的檔案） */
    fun source(kind: String, url: String, c: Conn): MediaSource = when {
        kind == "local" || url.startsWith("/") ->
            ProgressiveMediaSource.Factory(DefaultDataSource.Factory(App.instance)).createMediaSource(MediaItem.fromUri(Uri.fromFile(File(url))))
        kind == "hls" ->
            HlsMediaSource.Factory(factory(c))
                .setAllowChunklessPreparation(true)
                .setLoadErrorHandlingPolicy(RetryPolicy())
                .createMediaSource(MediaItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build())
        else ->
            ProgressiveMediaSource.Factory(factory(c))
                .setLoadErrorHandlingPolicy(RetryPolicy())
                .createMediaSource(MediaItem.fromUri(url))
    }

    /** 電視盒子記憶體小：預設緩衝會吃到上百 MB，壓到 30 秒／32 MB 就夠順了 */
    fun loadControl(): LoadControl = if (App.isTv) DefaultLoadControl.Builder()
        .setBufferDurationsMs(10_000, 30_000, 1_500, 3_000)
        .setTargetBufferBytes(32 * 1024 * 1024)
        .setPrioritizeTimeOverSizeThresholds(false)
        .build()
    else DefaultLoadControl.Builder()
        .setBufferDurationsMs(15_000, 50_000, 1_500, 3_000)
        .build()

    /** 下載用：跟播放器同一套連線抓整個檔案（片段、清單），被擋也會重試 */
    suspend fun bytes(url: String, c: Conn): ByteArray = withContext(Dispatchers.IO) {
        var attempt = 0
        while (true) {
            val ds = factory(c).createDataSource()
            try {
                ds.open(DataSpec(Uri.parse(url)))
                return@withContext DataSourceUtil.readToEnd(ds)
            } catch (e: HttpDataSource.InvalidResponseCodeException) {
                if (isStorageBlocked(e)) throw IOException(STORAGE_BLOCKED_MESSAGE)
                if (!isTransient(e) || ++attempt >= 5) throw IOException("HTTP ${e.responseCode}")
                delay(attempt * 1_000L)
            } finally {
                runCatching { ds.close() }
            }
        }
        @Suppress("UNREACHABLE_CODE")
        ByteArray(0)
    }

    /** 下載單一大檔（MP4）：串流寫入，支援從 offset 續傳；onBytes 回報累計大小 */
    suspend fun download(url: String, c: Conn, file: File, onBytes: (Long, Long) -> Unit) = withContext(Dispatchers.IO) {
        val have = if (file.exists()) file.length() else 0L
        val ds = factory(c).createDataSource()
        try {
            val len = ds.open(DataSpec.Builder().setUri(Uri.parse(url)).setPosition(have).build())
            val total = if (len == C.LENGTH_UNSET.toLong()) -1L else have + len
            java.io.FileOutputStream(file, true).use { out ->
                val buf = ByteArray(256 * 1024)
                var done = have
                var lastReport = 0L
                while (true) {
                    val n = ds.read(buf, 0, buf.size)
                    if (n == C.RESULT_END_OF_INPUT) break
                    out.write(buf, 0, n)
                    done += n
                    if (done - lastReport > 512 * 1024) {
                        lastReport = done
                        onBytes(done, total)
                    }
                    kotlinx.coroutines.yield()
                }
                onBytes(done, total)
            }
        } finally {
            runCatching { ds.close() }
        }
    }
}

/**
 * 有一個來源的播放清單和每個片段都包在 PNG 圖檔裡：
 * 真正的內容放在一個自訂類型的區塊（類型碼 0x726f5564），第一個位元組是旗標（bit0 = 有 zlib 壓縮）。
 */
object Png {
    private val SIG = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
    private const val PAYLOAD = 0x726f5564

    fun unwrap(buf: ByteArray): ByteArray {
        if (buf.size < 8 || !SIG.indices.all { buf[it] == SIG[it] }) return buf
        var i = 8
        while (i + 8 <= buf.size) {
            val len = int32(buf, i)
            val type = int32(buf, i + 4)
            val d = i + 8
            if (len < 0 || d + len > buf.size) break
            if (type == PAYLOAD) {
                val body = buf.copyOfRange(d + 1, d + len)
                return if (buf[d].toInt() and 1 != 0) inflate(body) else body
            }
            i = d + len + 4
        }
        throw IOException("影片資料格式不認得")
    }

    private fun int32(b: ByteArray, i: Int) =
        (b[i].toInt() and 0xff shl 24) or (b[i + 1].toInt() and 0xff shl 16) or (b[i + 2].toInt() and 0xff shl 8) or (b[i + 3].toInt() and 0xff)

    private fun inflate(data: ByteArray): ByteArray {
        val inf = Inflater()
        inf.setInput(data)
        val out = ByteArrayOutputStream(data.size * 2)
        val buf = ByteArray(64 * 1024)
        try {
            while (!inf.finished()) {
                val n = inf.inflate(buf)
                if (n == 0 && (inf.needsInput() || inf.needsDictionary())) break
                out.write(buf, 0, n)
            }
        } finally {
            inf.end()
        }
        return out.toByteArray()
    }
}

/** 整個檔案讀進來、拆掉 PNG 包裝，再依 DataSpec 要的範圍吐出去 */
@OptIn(UnstableApi::class)
private class UnwrapDataSource(private val upstream: DataSource) : DataSource {
    private var data: ByteArray? = null
    private var pos = 0
    private var end = 0
    private var uri: Uri? = null
    private var headers: Map<String, List<String>> = emptyMap()

    override fun addTransferListener(transferListener: TransferListener) = upstream.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long {
        // 包裝過的內容沒辦法只抓一段，一律抓整個檔
        val full = dataSpec.buildUpon().setPosition(0).setLength(C.LENGTH_UNSET.toLong()).build()
        val raw = try {
            upstream.open(full)
            uri = upstream.uri
            headers = upstream.responseHeaders
            DataSourceUtil.readToEnd(upstream)
        } finally {
            upstream.close()
        }
        val body = Png.unwrap(raw)
        val isPlaylist = body.size >= 7 && String(body, 0, 7, Charsets.US_ASCII) == "#EXTM3U"
        // 片段原本標成 image/png，改成 TS，ExoPlayer 才不會拿去猜別的格式
        headers = headers.filterKeys { !it.equals("Content-Type", true) } +
            ("Content-Type" to listOf(if (isPlaylist) MimeTypes.APPLICATION_M3U8 else MimeTypes.VIDEO_MP2T))
        data = body
        pos = dataSpec.position.toInt().coerceIn(0, body.size)
        end = if (dataSpec.length == C.LENGTH_UNSET.toLong()) body.size else (pos + dataSpec.length).toInt().coerceAtMost(body.size)
        return (end - pos).toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val d = data ?: return C.RESULT_END_OF_INPUT
        if (length == 0) return 0
        if (pos >= end) return C.RESULT_END_OF_INPUT
        val n = minOf(length, end - pos)
        System.arraycopy(d, pos, buffer, offset, n)
        pos += n
        return n
    }

    override fun getUri(): Uri? = uri

    override fun getResponseHeaders(): Map<String, List<String>> = headers

    override fun close() {
        data = null
    }
}
