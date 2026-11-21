package com.allinoneplayer

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import com.allinoneplayer.download.VideoDownloads
import com.allinoneplayer.net.BlockedException
import com.allinoneplayer.net.Creds
import com.allinoneplayer.net.LoginKeeper
import com.allinoneplayer.net.Net
import com.allinoneplayer.net.NetException
import com.allinoneplayer.net.Sites
import com.allinoneplayer.net.WebFetcher
import com.allinoneplayer.player.Conn
import com.allinoneplayer.player.PlayerActivity
import com.allinoneplayer.web.WebActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * Dart ↔ 原生的橋：
 *   MethodChannel aio/native：網路請求、cookie、開網頁（登入／驗證）、播放器、影片下載、安裝更新。
 *   EventChannel aio/events：網頁載入完成、下載狀態變動。
 * 解析網頁都在 Dart；這裡只負責「能連上網站」的部分（Cloudflare、cookie 共用、CDN 標頭）。
 */
object Bridge {
    private const val REQ_PLAYER = 7101
    private const val REQ_WEB = 7102

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var pendingPlayer: MethodChannel.Result? = null
    private var pendingWeb: MethodChannel.Result? = null

    fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    fun attach(engine: FlutterEngine, act: Activity) {
        activity = act
        EventChannel(engine.dartExecutor.binaryMessenger, "aio/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        MethodChannel(engine.dartExecutor.binaryMessenger, "aio/native").setMethodCallHandler { call, result -> handle(call, result) }
    }

    fun detach(act: Activity) {
        if (activity === act) activity = null
    }

    @Suppress("UNCHECKED_CAST")
    private fun args(call: MethodCall): Map<String, Any?> = (call.arguments as? Map<String, Any?>).orEmpty()

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val a = args(call)
        when (call.method) {
            "info" -> result.success(
                mapOf(
                    "isTv" to App.isTv,
                    "version" to BuildConfig.VERSION_NAME,
                    "versionCode" to BuildConfig.VERSION_CODE,
                    "apkName" to BuildConfig.APK_NAME,
                    "userAgent" to Net.userAgent,
                    "filesDir" to App.instance.filesDir.absolutePath,
                    "externalDir" to (App.instance.getExternalFilesDir(null)?.absolutePath ?: App.instance.filesDir.absolutePath),
                    "cacheDir" to App.instance.cacheDir.absolutePath,
                )
            )
            "configure" -> {
                val list = (a["sites"] as? List<Map<String, Any?>>).orEmpty().map {
                    Sites.Def(it["key"] as String, it["base"] as String, it["viaWeb"] == true)
                }
                Sites.configure(list)
                // 上次關 App 時被丟掉的登入 cookie 補回來（要在任何請求之前）
                runCatching { LoginKeeper.restore() }
                result.success(null)
            }
            "fetch" -> scope.launch {
                try {
                    val r = Net.fetch(
                        Net.Req(
                            site = a["site"] as String,
                            url = a["url"] as String,
                            method = a["method"] as? String ?: "GET",
                            body = a["body"] as? String,
                            contentType = a["contentType"] as? String,
                            headers = (a["headers"] as? Map<String, String>).orEmpty(),
                            web = a["web"] == true,
                            json = a["json"] == true,
                        )
                    )
                    result.success(mapOf("status" to r.status, "url" to r.url, "text" to r.text))
                } catch (e: BlockedException) {
                    result.error("blocked", e.message, e.site)
                } catch (e: NetException) {
                    result.error("net", e.message, e.status)
                } catch (e: Exception) {
                    result.error("net", e.message ?: e.toString(), 0)
                }
            }
            "cookie" -> result.success(Net.cookie(a["url"] as String, a["name"] as String))
            "clearCookies" -> {
                runCatching { Net.clearCookies(a["site"] as String) }
                result.success(null)
            }
            "loginKeep" -> {
                runCatching { LoginKeeper.save(a["site"] as String) }
                result.success(null)
            }
            "loginForget" -> {
                LoginKeeper.forget(a["site"] as String)
                result.success(null)
            }
            "credOffer" -> result.success(Creds.offer(a["site"] as String))
            "credRemember" -> result.success(Creds.remember(a["site"] as String, a["yes"] == true))
            "credHas" -> result.success(Creds.has(a["site"] as String))
            "credForget" -> {
                Creds.forget(a["site"] as String)
                result.success(null)
            }
            "autoLogin" -> scope.launch {
                val site = a["site"] as String
                val c = Creds.read(site)
                if (c == null) {
                    result.success(false)
                    return@launch
                }
                val ok = runCatching { WebFetcher.autoLogin(site, a["url"] as String, a["check"] as String, c.first, c.second) }.getOrDefault(false)
                if (ok) runCatching { LoginKeeper.save(site) }
                result.success(ok)
            }
            "resetWeb" -> {
                WebFetcher.reset(a["site"] as String)
                result.success(null)
            }
            "openWeb" -> {
                val act = activity ?: return result.error("noActivity", "畫面還沒準備好", null)
                pendingWeb?.success(mapOf("typed" to ""))
                pendingWeb = result
                act.startActivityForResult(WebActivity.intent(act, a), REQ_WEB)
            }
            "closeWeb" -> {
                WebActivity.current?.close()
                result.success(null)
            }
            "play" -> {
                val act = activity ?: return result.error("noActivity", "畫面還沒準備好", null)
                pendingPlayer?.success(null)
                pendingPlayer = result
                act.startActivityForResult(PlayerActivity.intent(act, a), REQ_PLAYER)
            }
            "dl.list" -> result.success(VideoDownloads.list())
            "dl.variants" -> scope.launch {
                try {
                    val v = VideoDownloads.variants(a["url"] as String, Conn.from((a["conn"] as? Map<String, Any?>).orEmpty()))
                    result.success(v.map { mapOf("height" to it.height, "bandwidth" to it.bandwidth, "url" to it.url) })
                } catch (e: Exception) {
                    result.error("net", e.message ?: e.toString(), null)
                }
            }
            "dl.start" -> {
                VideoDownloads.start(a)
                result.success(null)
            }
            "dl.pause" -> { VideoDownloads.pause(a["key"] as String); result.success(null) }
            "dl.resume" -> { VideoDownloads.resume(a["key"] as String); result.success(null) }
            "dl.delete" -> { VideoDownloads.delete(a["key"] as String); result.success(null) }
            "freeSpace" -> result.success(VideoDownloads.freeSpace())
            "installApk" -> {
                val act = activity ?: return result.error("noActivity", "畫面還沒準備好", null)
                val f = File(a["path"] as String)
                val uri = FileProvider.getUriForFile(act, act.packageName + ".files", f)
                act.startActivity(
                    Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(null)
            }
            "shareFile" -> {
                val act = activity ?: return result.error("noActivity", "畫面還沒準備好", null)
                val f = File(a["path"] as String)
                val uri = FileProvider.getUriForFile(act, act.packageName + ".files", f)
                act.startActivity(
                    Intent.createChooser(
                        Intent(Intent.ACTION_SEND).setType(a["mime"] as? String ?: "*/*").putExtra(Intent.EXTRA_STREAM, uri)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), "分享"
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 播放器、網頁關閉後的結果 */
    fun onActivityResult(requestCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            REQ_PLAYER -> {
                pendingPlayer?.success(
                    mapOf(
                        "position" to (data?.getLongExtra(PlayerActivity.RESULT_POSITION, 0L) ?: 0L),
                        "duration" to (data?.getLongExtra(PlayerActivity.RESULT_DURATION, 0L) ?: 0L),
                        "next" to (data?.getBooleanExtra(PlayerActivity.RESULT_NEXT, false) ?: false),
                    )
                )
                pendingPlayer = null
                return true
            }
            REQ_WEB -> {
                pendingWeb?.success(mapOf("typed" to (data?.getStringExtra(WebActivity.RESULT_TYPED) ?: "")))
                pendingWeb = null
                return true
            }
        }
        return false
    }
}
