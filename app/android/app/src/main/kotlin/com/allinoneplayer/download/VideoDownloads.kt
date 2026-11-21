package com.allinoneplayer.download

import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import com.allinoneplayer.App
import com.allinoneplayer.Bridge
import com.allinoneplayer.player.Conn
import com.allinoneplayer.player.Media
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile

/**
 * 影片下載（手機版）。
 * HLS：各分段依序接成一個 <key>.ts；MP4：整個檔案續傳到 <key>.mp4。App 內離線播放。
 * 存在 App 專屬資料夾（不會出現在相簿，移除 App 時一起刪掉），另有 <key>.json（進度與影片資料）、<key>.jpg（封面）。
 * 一次下載一部，HLS 每部同時抓 4 個分段；狀態都在主執行緒更新，變動時用 Bridge 事件通知 Dart。
 */
object VideoDownloads {
    enum class Status { queued, running, paused, failed, done }

    class Item(
        /** 來源代號_編號 */
        val key: String,
        /** Dart 存的影片資料（標題、封面、來源…），原樣存回去 */
        val meta: JSONObject,
        val kind: String,
        val url: String,
        val conn: JSONObject,
        val quality: String,
        var status: Status,
        var total: Int,
        var done: Int,
        var bytes: Long,
        var size: Long,
        val addedAt: Long,
    ) {
        var error: String? = null
        val ext get() = if (kind == "mp4") "mp4" else "ts"
        val file get() = File(root, "${safe(key)}.$ext")
        val progress: Float
            get() = when {
                status == Status.done -> 1f
                kind == "mp4" -> if (size > 0) bytes.toFloat() / size else 0f
                else -> if (total > 0) done.toFloat() / total else 0f
            }

        fun toJson(): JSONObject = JSONObject()
            .put("key", key).put("meta", meta).put("kind", kind).put("url", url).put("conn", conn)
            .put("quality", quality).put("status", status.name).put("total", total).put("done", done)
            .put("bytes", bytes).put("size", size).put("addedAt", addedAt).put("error", error)
            .put("progress", progress.toDouble()).put("file", file.absolutePath)
            .put("cover", File(root, "${safe(key)}.jpg").takeIf { it.exists() }?.absolutePath ?: "")
    }

    private const val PARALLEL = 4
    private const val RETRIES = 3

    /** 新加入的在前面 */
    val items = ArrayList<Item>()

    private val root: File by lazy {
        (App.instance.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: File(App.instance.filesDir, "downloads")).apply {
            mkdirs()
            File(this, ".nomedia").takeIf { !it.exists() }?.createNewFile()
        }
    }

    fun safe(key: String) = key.replace(Regex("[^A-Za-z0-9_.-]"), "_")

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    @OptIn(ExperimentalCoroutinesApi::class)
    private val saveDispatcher = Dispatchers.IO.limitedParallelism(1)
    private var runner: Job? = null
    private var current: Pair<String, Job>? = null
    private var loaded = false
    private val main = Handler(Looper.getMainLooper())
    private var notifyPending = false

    fun load() {
        if (loaded) return
        loaded = true
        root.listFiles { f -> f.name.endsWith(".json") }.orEmpty()
            .mapNotNull { runCatching { fromJson(JSONObject(it.readText())) }.getOrNull() }
            .sortedByDescending { it.addedAt }
            .forEach { items.add(it) }
    }

    fun find(key: String): Item? = items.firstOrNull { it.key == key }

    fun list(): String {
        load()
        return JSONArray(items.map { it.toJson() }).toString()
    }

    fun freeSpace(): Long = runCatching { StatFs(root.path).availableBytes }.getOrDefault(Long.MAX_VALUE)

    /** 下載前讓使用者選畫質：讀主清單（不是主清單就回傳空的，表示只有一種畫質） */
    suspend fun variants(url: String, conn: Conn): List<Hls.Variant> {
        val text = String(Media.bytes(url, conn), Charsets.UTF_8)
        return if (Hls.isMaster(text)) Hls.variants(text, url) else emptyList()
    }

    fun start(args: Map<String, Any?>) {
        load()
        val key = args["key"] as String
        find(key)?.let { delete(it.key) }
        @Suppress("UNCHECKED_CAST")
        val item = Item(
            key = key,
            meta = JSONObject((args["meta"] as? Map<String, Any?>).orEmpty()),
            kind = args["kind"] as? String ?: "hls",
            url = args["url"] as String,
            conn = JSONObject((args["conn"] as? Map<String, Any?>).orEmpty()),
            quality = args["quality"] as? String ?: "",
            status = Status.queued, total = 0, done = 0, bytes = 0, size = 0,
            addedAt = System.currentTimeMillis(),
        )
        items.add(0, item)
        save(item)
        changed()
        kick()
    }

    fun pause(key: String) {
        val item = find(key) ?: return
        if (current?.first == key) current?.second?.cancel()
        if (item.status == Status.running || item.status == Status.queued) item.status = Status.paused
        save(item)
        changed()
    }

    fun resume(key: String) {
        val item = find(key) ?: return
        if (item.status == Status.done) return
        item.error = null
        item.status = Status.queued
        save(item)
        changed()
        kick()
    }

    fun delete(key: String) {
        val item = find(key) ?: return
        if (current?.first == key) current?.second?.cancel()
        items.remove(item)
        changed()
        scope.launch(Dispatchers.IO) {
            delay(300)
            listOf("ts", "mp4", "json", "jpg").forEach { File(root, "${safe(key)}.$it").delete() }
        }
    }

    private fun kick() {
        DownloadService.start()
        if (runner?.isActive == true) return
        runner = scope.launch {
            while (true) {
                val next = items.lastOrNull { it.status == Status.queued } ?: break
                val job = launch { run(next) }
                current = next.key to job
                job.join()
                current = null
            }
        }
    }

    private fun connOf(item: Item): Conn = Conn(
        headers = item.conn.optJSONObject("headers")?.let { h -> h.keys().asSequence().associateWith { h.optString(it) } }.orEmpty(),
        cronet = item.conn.optBoolean("cronet"),
        unwrap = item.conn.optBoolean("unwrap"),
    )

    private suspend fun run(item: Item) {
        item.status = Status.running
        item.error = null
        changed()
        DownloadService.update(item)
        val conn = connOf(item)
        try {
            saveCover(item)
            if (item.kind == "mp4") {
                withContext(Dispatchers.IO) { if (item.file.exists() && item.file.length() > item.bytes) RandomAccessFile(item.file, "rw").use { it.setLength(item.bytes) } }
                Media.download(item.url, conn, item.file) { b, total ->
                    main.post {
                        item.bytes = b
                        if (total > 0) item.size = total
                        save(item)
                        changed()
                        DownloadService.update(item)
                    }
                }
            } else {
                val text = String(Media.bytes(item.url, conn), Charsets.UTF_8)
                // 主清單：挑最高畫質（正常情況 Dart 已經挑好，這裡是保險）
                val mediaUrl = if (Hls.isMaster(text)) Hls.variants(text, item.url).firstOrNull()?.url ?: throw Exception("找不到影片畫質") else item.url
                val mediaText = if (mediaUrl == item.url) text else String(Media.bytes(mediaUrl, conn), Charsets.UTF_8)
                val segments = Hls.segments(mediaText, mediaUrl)
                if (segments.isEmpty()) throw Exception("找不到影片分段")
                item.total = segments.size
                withContext(Dispatchers.IO) {
                    // 上次中斷時寫到一半的分段丟掉，從記錄的位置接著寫
                    RandomAccessFile(item.file, "rw").use { it.setLength(item.bytes) }
                }
                FileOutputStream(item.file, true).use { out ->
                    while (item.done < segments.size) {
                        val from = item.done
                        val to = minOf(from + PARALLEL, segments.size)
                        val chunks = coroutineScope {
                            (from until to).map { i -> async { fetch(segments[i].url, conn) } }.map { it.await() }
                        }
                        withContext(Dispatchers.IO) { chunks.forEach(out::write) }
                        item.done = to
                        item.bytes += chunks.sumOf { it.size.toLong() }
                        save(item)
                        changed()
                        DownloadService.update(item)
                    }
                }
            }
            item.status = Status.done
        } catch (e: CancellationException) {
            if (item.status == Status.running) item.status = Status.paused
            throw e
        } catch (e: Exception) {
            item.status = Status.failed
            item.error = e.message ?: e.toString()
        } finally {
            if (items.contains(item)) save(item)
            changed()
        }
    }

    private suspend fun fetch(url: String, conn: Conn): ByteArray {
        var last: Exception? = null
        repeat(RETRIES) { attempt ->
            try {
                return Media.bytes(url, conn)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                last = e
                delay(1000L * (attempt + 1))
            }
        }
        throw Exception("網路錯誤：${last?.message}")
    }

    private suspend fun saveCover(item: Item) {
        val f = File(root, "${safe(item.key)}.jpg")
        val cover = item.meta.optString("cover")
        if (f.exists() || cover.isEmpty()) return
        runCatching {
            val h = item.meta.optJSONObject("coverHeaders")
            val data = Media.bytes(cover, Conn(h?.let { o -> o.keys().asSequence().associateWith { o.optString(it) } }.orEmpty()))
            withContext(Dispatchers.IO) { f.writeBytes(data) }
        }
    }

    private fun save(item: Item) {
        val json = item.toJson().put("status", if (item.status == Status.done) "done" else "paused").toString()
        scope.launch(saveDispatcher) { runCatching { File(root, "${safe(item.key)}.json").writeText(json) } }
    }

    private fun fromJson(o: JSONObject): Item = Item(
        key = o.getString("key"),
        meta = o.optJSONObject("meta") ?: JSONObject(),
        kind = o.optString("kind", "hls"),
        url = o.getString("url"),
        conn = o.optJSONObject("conn") ?: JSONObject(),
        quality = o.optString("quality"),
        // App 被關掉時還沒下載完的，先當作暫停
        status = if (o.optString("status") == "done") Status.done else Status.paused,
        total = o.optInt("total"),
        done = o.optInt("done"),
        bytes = o.optLong("bytes"),
        size = o.optLong("size"),
        addedAt = o.optLong("addedAt"),
    )

    /** 狀態有變：合併成最多每 300 毫秒通知 Dart 一次 */
    private fun changed() {
        if (notifyPending) return
        notifyPending = true
        main.postDelayed({
            notifyPending = false
            Bridge.emit(mapOf("type" to "downloads", "items" to list()))
        }, 300)
    }
}

fun fmtSize(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.2f GB".format(bytes / (1L shl 30).toDouble())
    else -> "%.0f MB".format(bytes / (1L shl 20).toDouble())
}
