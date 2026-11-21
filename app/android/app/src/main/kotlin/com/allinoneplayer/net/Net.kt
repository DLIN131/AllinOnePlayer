package com.allinoneplayer.net

import android.webkit.CookieManager
import android.webkit.WebSettings
import com.allinoneplayer.App
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** 一次請求的結果；url 是轉址後的最後網址 */
class Resp(val status: Int, val url: String, val text: String)

class NetException(message: String, val status: Int = 0) : Exception(message)

/**
 * 各站的網址設定。網域只存在 Dart 端（Base64），App 啟動時傳過來；
 * 原生這邊只需要知道：網址屬於哪個站（補 Referer、選 cookie）、哪些站一律走隱藏 WebView。
 */
object Sites {
    class Def(val key: String, val base: String, val viaWeb: Boolean)

    private val defs = ConcurrentHashMap<String, Def>()

    fun configure(list: List<Def>) {
        list.forEach { defs[it.key] = it }
    }

    fun base(site: String): String = defs[site]?.base?.trimEnd('/') ?: throw NetException("未知的來源：$site")
    fun has(site: String) = defs.containsKey(site)
    fun viaWeb(site: String) = defs[site]?.viaWeb == true

    fun host(site: String) = base(site).substringAfter("://").substringBefore('/')

    /** 這個站的 cookie 可能放在哪些網址（主機本身、根網域、www；eh 的帳號在論壇子網域） */
    fun urls(site: String): List<String> {
        val root = rootDomain(host(site))
        return listOfNotNull(base(site), "https://$root", "https://www.$root", if (site == "eh") "https://forums.$root" else null).distinct()
    }

    /** 取網域最後兩段，例如 cdn.example.com → example.com */
    fun rootDomain(host: String) = host.split('.').takeLast(2).joinToString(".")

    /** 網址是哪個站的（含圖片 CDN 子網域） */
    fun siteForUrl(url: String): String? {
        val host = url.substringAfter("://", "").substringBefore('/').substringBefore(':').lowercase()
        if (host.isEmpty()) return null
        for (d in defs.values) {
            val root = rootDomain(host(d.key))
            if (host == root || host.endsWith(".$root")) return d.key
        }
        return null
    }
}

/**
 * OkHttp 跟 WebView 共用同一份 cookie（CookieManager）：
 * 在登入頁（WebView）登入後，一般請求也帶得到登入狀態；伺服器用 Set-Cookie 換的新 token 也會寫回 WebView。
 */
object WebCookieJar : CookieJar {
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val cm = CookieManager.getInstance()
        cookies.forEach { cm.setCookie(url.toString(), it.toString()) }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val raw = CookieManager.getInstance().getCookie(url.toString()) ?: return emptyList()
        return raw.split(';').mapNotNull { Cookie.parse(url, it.trim()) }
    }
}

object Net {
    /**
     * 全部用同一個「電腦版 Chrome」UA（版本跟裝置上的 WebView 一致）：
     * 網站給的頁面格式跟桌面版一樣，Cloudflare 的通行 cookie 也綁 UA，WebView 和 OkHttp 要用同一個。
     */
    val userAgent: String by lazy {
        val chrome = runCatching { WebSettings.getDefaultUserAgent(App.instance) }.getOrNull()
            ?.let { Regex("Chrome/([\\d.]+)").find(it)?.groupValues?.get(1) } ?: "130.0.0.0"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome Safari/537.36"
    }

    val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .cookieJar(WebCookieJar)
            .addInterceptor { chain ->
                val req = chain.request()
                val b = req.newBuilder()
                if (req.header("User-Agent") == null) b.header("User-Agent", userAgent)
                if (req.header("Referer") == null) {
                    Sites.siteForUrl(req.url.toString())?.let { b.header("Referer", Sites.base(it) + "/") }
                }
                chain.proceed(b.build())
            }
            .build()
    }

    /** 這次開 App 期間被 Cloudflare 擋過的站，之後直接走 WebView */
    private val viaWebNow = ConcurrentHashMap.newKeySet<String>()

    fun full(site: String, path: String) = if (path.startsWith("http")) path else Sites.base(site) + path

    fun isChallenge(status: Int, text: String) =
        (status == 403 || status == 503) &&
            Regex("challenge-platform|Just a moment|cf-chl|Attention Required|Cloudflare", RegexOption.IGNORE_CASE)
                .containsMatchIn(text.take(20000))

    class Req(
        val site: String,
        val url: String,
        val method: String = "GET",
        val body: String? = null,
        val contentType: String? = null,
        val headers: Map<String, String> = emptyMap(),
        /** true：一律在隱藏 WebView 裡送（網站自己的 API，要帶 XSRF 等） */
        val web: Boolean = false,
        /** 送網站 JSON API 時跟網站自己的 axios 一樣：Accept JSON、X-Requested-With、X-XSRF-TOKEN */
        val json: Boolean = false,
    )

    suspend fun fetch(r: Req): Resp {
        val url = full(r.site, r.url)
        val useWeb = r.web || ((r.site in viaWebNow || Sites.viaWeb(r.site)) && Sites.siteForUrl(url) == r.site)
        try {
            if (useWeb) return WebFetcher.request(r.site, url, r.method, r.body, r.contentType, r.headers, r.json)
            var token = if (r.site == "nh") nhToken() else null
            var resp = okFetch(r, url, token)
            if (r.site == "nh" && resp.status == 401 && token != null && nhRefresh()) {
                token = nhToken()
                resp = okFetch(r, url, token)
            }
            if (isChallenge(resp.status, resp.text)) {
                viaWebNow.add(r.site)
                return WebFetcher.request(r.site, url, r.method, r.body, r.contentType, r.headers, r.json)
            }
            return resp
        } catch (e: UnknownHostException) {
            throw NetException("連不上網站（網路中斷或網站被擋）")
        } catch (e: java.net.SocketTimeoutException) {
            throw NetException("連線逾時，請稍後再試")
        } catch (e: javax.net.ssl.SSLException) {
            throw NetException("連不上網站（連線被中斷，可能被擋）")
        } catch (e: java.net.ConnectException) {
            throw NetException("連不上網站（網路中斷或網站被擋）")
        }
    }

    private suspend fun okFetch(r: Req, url: String, token: String?): Resp = withContext(Dispatchers.IO) {
        val b = Request.Builder().url(url)
        if (Sites.has(r.site)) b.header("Referer", Sites.base(r.site) + "/")
        r.headers.forEach { (k, v) -> b.header(k, v) }
        if (token != null) b.header("Authorization", "User $token")
        if (r.json) {
            b.header("Accept", "application/json")
            b.header("X-Requested-With", "XMLHttpRequest")
        }
        val type = (r.contentType ?: if (r.json) "application/json" else "application/x-www-form-urlencoded; charset=UTF-8").toMediaType()
        when (r.method) {
            "GET" -> b.get()
            "DELETE" -> if (r.body != null) b.delete(r.body.toRequestBody(type)) else b.delete()
            else -> b.method(r.method, (r.body ?: "").toRequestBody(type))
        }
        http.newCall(b.build()).execute().use { resp -> Resp(resp.code, resp.request.url.toString(), resp.body?.string().orEmpty()) }
    }

    // ---------- cookie ----------

    fun cookie(url: String, name: String): String? =
        CookieManager.getInstance().getCookie(url)?.split(';')?.map { it.trim() }
            ?.firstOrNull { it.startsWith("$name=") }?.substringAfter('=')
            ?.let { runCatching { java.net.URLDecoder.decode(it, "UTF-8") }.getOrDefault(it) }
            ?.takeIf { it.isNotEmpty() }

    fun nhToken(): String? = cookie(Sites.base("nh"), "access_token")

    /** 網站本身的換票方式：refresh token 在 cookie 裡，POST /auth/refresh 會寫回新的 access_token */
    suspend fun nhRefresh(): Boolean = runCatching {
        okFetch(Req("nh", "", "POST"), Sites.base("nh") + "/auth/refresh", null).status in 200..299
    }.getOrDefault(false)

    /** 清掉某個站（含子網域）的 cookie＝登出 */
    fun clearCookies(site: String) {
        val cm = CookieManager.getInstance()
        val root = Sites.rootDomain(Sites.host(site))
        for (u in Sites.urls(site)) {
            val names = cm.getCookie(u)?.split(';')?.map { it.trim().substringBefore('=') }.orEmpty()
            for (n in names) {
                cm.setCookie(u, "$n=; Max-Age=0; Path=/")
                cm.setCookie(u, "$n=; Max-Age=0; Path=/; Domain=.$root")
            }
        }
        cm.flush()
        LoginKeeper.forget(site)
        WebFetcher.reset(site)
    }
}
