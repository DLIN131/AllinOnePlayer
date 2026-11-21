package com.allinoneplayer.net

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import com.allinoneplayer.App
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

/** 被 Cloudflare 擋下，需要使用者在看得到的網頁裡手動過驗證 */
class BlockedException(val site: String) : Exception("需要通過網站驗證")

/**
 * 有 Cloudflare 的站，用隱藏的 WebView（真正的 Chromium）先打開該站過驗證，
 * 之後在它裡面用 fetch() 抓資料，透過 JS bridge 傳回來。
 * 每個站一個 WebView，停在該站的 robots.txt（同網域、沒有腳本、不耗資源）。
 * fetch 被驗證擋下時，直接在隱藏 WebView 打開那一頁，讓驗證頁自己跑完，拿畫面上的 HTML。
 */
object WebFetcher {
    private val webs = HashMap<String, WebView>()
    private val ready = ConcurrentHashMap.newKeySet<String>()
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val seq = AtomicInteger()
    private val pending = ConcurrentHashMap<Int, CompletableDeferred<Resp>>()

    private class Bridge {
        @JavascriptInterface
        fun done(id: Int, status: Int, url: String, body: String) {
            pending.remove(id)?.complete(Resp(status, url, body))
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun webView(site: String): WebView = webs[site] ?: WebView(App.instance).also { w ->
        w.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            userAgentString = Net.userAgent
            // 只拿 HTML，不需要載圖
            loadsImagesAutomatically = false
            blockNetworkImage = true
            mediaPlaybackRequiresUserGesture = true
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true)
        w.webViewClient = WebViewClient()
        w.addJavascriptInterface(Bridge(), "AppBridge")
        w.resumeTimers()
        webs[site] = w
    }

    /** 使用者過完驗證、或登入 / 登出後呼叫，下次請求重新暖機 */
    fun reset(site: String) {
        ready.remove(site)
    }

    // ---------- 背景時暫停、太久沒用就釋放（把記憶體還給播放器） ----------

    private val mainHandler = Handler(Looper.getMainLooper())
    private val releaseLater = Runnable { releaseAll() }
    private const val RELEASE_AFTER_MS = 60_000L

    fun pause() {
        if (webs.isEmpty()) return
        webs.values.forEach { it.onPause() }
        webs.values.firstOrNull()?.pauseTimers()
        mainHandler.removeCallbacks(releaseLater)
        mainHandler.postDelayed(releaseLater, RELEASE_AFTER_MS)
    }

    fun resume() {
        mainHandler.removeCallbacks(releaseLater)
        webs.values.firstOrNull()?.resumeTimers()
        webs.values.forEach { it.onResume() }
    }

    private fun releaseAll() {
        val all = webs.values.toList()
        webs.clear()
        ready.clear()
        pending.values.forEach { it.completeExceptionally(NetException("連線中斷，請重試")) }
        pending.clear()
        for (w in all) {
            w.stopLoading()
            w.removeJavascriptInterface("AppBridge")
            // pauseTimers() 是全 App 共用的，釋放前要恢復，不然下一個 WebView 的 JS 不會動
            w.resumeTimers()
            w.destroy()
        }
    }

    // ---------- 請求 ----------

    suspend fun request(
        site: String,
        url: String,
        method: String = "GET",
        body: String? = null,
        contentType: String? = null,
        headers: Map<String, String> = emptyMap(),
        json: Boolean = false,
    ): Resp {
        ensureReady(site)
        val r = jsFetch(site, url, init(method, body, contentType, headers, json))
        if (!Net.isChallenge(r.status, r.text)) return r
        if (method != "GET") {
            ready.remove(site)
            throw BlockedException(site)
        }
        return lock(site).withLock {
            ready.remove(site)
            val html = load(site, url) ?: throw BlockedException(site)
            Resp(200, html.first, html.second)
        }
    }

    private fun init(method: String, body: String?, contentType: String?, headers: Map<String, String>, json: Boolean): String {
        if (method == "GET" && body == null && headers.isEmpty() && !json) return "{credentials: 'include'}"
        val h = JSONObject()
        if (json) {
            h.put("Accept", "application/json")
            h.put("Content-Type", contentType ?: "application/json")
            h.put("X-Requested-With", "XMLHttpRequest")
        } else if (body != null) {
            h.put("Content-Type", contentType ?: "application/x-www-form-urlencoded; charset=UTF-8")
            h.put("X-Requested-With", "XMLHttpRequest")
        }
        headers.forEach { (k, v) -> h.put(k, v) }
        // 網站自己的 axios 會把 XSRF-TOKEN cookie 放進標頭，這裡照做（沒有就是空字串）
        val xsrf = if (json) "h['X-XSRF-TOKEN'] = decodeURIComponent((document.cookie.match(/(?:^|; )XSRF-TOKEN=([^;]+)/) || [])[1] || '');" else ""
        val b = if (body != null && method != "GET") JSONObject.quote(body) else "undefined"
        return "(function(){ var h = $h; $xsrf return {method: ${JSONObject.quote(method)}, credentials: 'include', headers: h, body: $b}; })()"
    }

    private fun lock(site: String) = locks.getOrPut(site) { Mutex() }

    private val CHALLENGE = Regex("Just a moment|請稍候|Attention Required|cf-chl|challenge-platform", RegexOption.IGNORE_CASE)

    /** 在隱藏 WebView 打開網頁，等驗證跑完（最多 25 秒），回傳（最後網址, HTML）；過不了回傳 null */
    private suspend fun load(site: String, url: String): Pair<String, String>? = withContext(Dispatchers.Main) {
        val w = webView(site)
        w.loadUrl(url)
        val r = withTimeoutOrNull(25_000) {
            delay(800)
            var result: Pair<String, String>? = null
            while (result == null) {
                val s = w.eval("document.readyState+'|'+document.title+'|'+document.documentElement.outerHTML.slice(0,4000)")
                if (s.startsWith("complete") && !CHALLENGE.containsMatchIn(s)) {
                    result = w.eval("location.href") to w.eval("document.documentElement.outerHTML")
                } else delay(700)
            }
            result
        }
        if (r == null) w.stopLoading() else CookieManager.getInstance().flush()
        r
    }

    /** 停在該站的 robots.txt（同網域、沒有腳本），之後的 fetch 都從這裡發 */
    private suspend fun ensureReady(site: String) {
        if (site in ready) return
        lock(site).withLock {
            if (site in ready) return
            load(site, Sites.base(site) + "/robots.txt") ?: throw BlockedException(site)
            ready.add(site)
        }
    }

    // ---------- 自動重新登入（使用者讓 App 記住密碼的站） ----------

    private val LOGIN_PAGE = Regex("/login(?:[/?#]|$)", RegexOption.IGNORE_CASE)

    /**
     * 在隱藏 WebView 打開登入頁，填好帳密、勾「記住我」、按登入；之後每 2 秒抓一次 checkUrl（要登入才看得到的頁面），
     * 沒被轉到登入頁就是成功。頁面上可能有好幾個登入表單（藏在彈窗裡），填看得到的那一個。
     */
    suspend fun autoLogin(site: String, loginUrl: String, checkUrl: String, user: String, pass: String): Boolean = lock(site).withLock {
        ready.remove(site)
        try {
            load(site, loginUrl) ?: return@withLock false
            val fill = """
                (function(){
                  var forms=[].slice.call(document.querySelectorAll('form')).filter(function(f){return f.querySelector('input[type="password"]')});
                  var f=forms.filter(function(x){return x.querySelector('input[type="password"]').offsetParent!==null})[0]||forms[0];
                  if(!f)return false;
                  var u=f.querySelector('input[name="username"],input[name="UserName"],input[name="login"],input[name="email"],input[type="email"],input[type="text"]');
                  var p=f.querySelector('input[type="password"]');
                  if(!u)return false;
                  u.value=${JSONObject.quote(user)}; p.value=${JSONObject.quote(pass)};
                  [u,p].forEach(function(el){el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}))});
                  f.querySelectorAll('input[type="checkbox"]').forEach(function(c){if(/remember|cookiedate/i.test(c.name+' '+c.id))c.checked=true});
                  var b=f.querySelector('.login_submit,button[name="submit_login"],[type="submit"]');
                  if(b)b.click();else f.submit();
                  return true;
                })()
            """.trimIndent()
            var filled = false
            for (i in 0 until 6) {
                filled = withContext(Dispatchers.Main) { webView(site).eval(fill) } == "true"
                if (filled) break
                delay(2500)
            }
            if (!filled) return@withLock false
            for (i in 0 until 10) {
                delay(2000)
                val r = runCatching { withTimeoutOrNull(8000) { jsFetch(site, checkUrl, "{credentials: 'include'}") } }.getOrNull() ?: continue
                if (r.status in 200..399 && !LOGIN_PAGE.containsMatchIn(r.url) && !Regex("<title>\\s*Login\\b", RegexOption.IGNORE_CASE).containsMatchIn(r.text)) {
                    CookieManager.getInstance().flush()
                    return@withLock true
                }
            }
            false
        } finally {
            withContext(Dispatchers.Main) { runCatching { webView(site).loadUrl("about:blank") } }
            ready.remove(site)
        }
    }

    private suspend fun jsFetch(site: String, url: String, init: String): Resp {
        val id = seq.incrementAndGet()
        val result = CompletableDeferred<Resp>()
        pending[id] = result
        val js = """
            fetch(${JSONObject.quote(url)}, $init)
              .then(function (r) { return r.text().then(function (t) { AppBridge.done($id, r.status, r.url, t); }); })
              .catch(function (e) { AppBridge.done($id, -1, '', String(e)); });
        """.trimIndent()
        withContext(Dispatchers.Main) { webView(site).evaluateJavascript(js, null) }
        return try {
            val r = withTimeout(40_000) { result.await() }
            if (r.status == -1) {
                ready.remove(site)
                throw NetException("連不上網站（網路中斷或網站被擋）")
            }
            r
        } finally {
            pending.remove(id)
        }
    }

    private suspend fun WebView.eval(js: String): String = suspendCancellableCoroutine { cont ->
        evaluateJavascript(js) { raw ->
            val s = runCatching { JSONObject("{\"v\":$raw}").optString("v") }.getOrDefault("")
            if (cont.isActive) cont.resume(s)
        }
    }
}
