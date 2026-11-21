package com.allinoneplayer.web

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import com.allinoneplayer.Bridge
import com.allinoneplayer.net.Net
import com.allinoneplayer.net.Sites
import com.allinoneplayer.net.WebFetcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * 看得到的網頁：登入（各站自己的登入頁）、過 Cloudflare 驗證、開網站瀏覽。
 * 跟背景抓資料共用同一個 UA 和 cookie，所以在這裡登入後 App 其他地方都是登入狀態。
 * 每次頁面載完會通知 Dart（Bridge 事件 web），Dart 確認登入成功後呼叫 close() 自動關掉。
 */
class WebActivity : ComponentActivity() {

    companion object {
        const val EXTRA_SITE = "site"
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_MODE = "mode" // login | verify | browse
        const val EXTRA_PREFILL = "prefill"
        const val RESULT_TYPED = "typed"

        /** JM 登入頁一開就有整頁廣告蓋住表單，直接藏起來 */
        private const val JM_CSS =
            "#outsidenoticeModal,#shunt-modal,#billboard-modal,#bouns-popup,#guide-modal,#headelikes_modal,.modal-backdrop{display:none!important}" +
                "body.modal-open{overflow:auto!important;padding-right:0!important}"

        /** 勾選「記住我／保持登入」：看名稱、id 或旁邊的字（論壇的叫 CookieDate）；用 click() 讓網站自己的程式也知道 */
        private const val REMEMBER_JS =
            "(function(){[].slice.call(document.querySelectorAll('input[type=checkbox]')).forEach(function(c){" +
                "var lb=(c.labels&&c.labels[0]&&c.labels[0].textContent)||'';var near=((c.parentElement&&c.parentElement.textContent)||'').slice(0,40);" +
                "if(!c.checked&&/remember|cookiedate|keep|stay|persist|記住|保持登入|自動登入|下次/i.test(c.name+' '+c.id+' '+lb+' '+near))c.click()})})();0"

        /**
         * vb 的登入表單沒有「記住我」，網站給的登入只有 2 小時（一陣子沒用就要重登）。
         * 網站的登入程式通常還是看 remember 這個欄位，補一個隱藏欄位；網站不理會也沒影響。
         */
        const val VB_REMEMBER_JS =
            "(function(){[].slice.call(document.querySelectorAll('form')).forEach(function(f){" +
                "if(f.querySelector('input[type=password]')&&!f.querySelector('[name=remember]')){var i=document.createElement('input');i.type='hidden';i.name='remember';i.value='on';f.appendChild(i)}})})();0"

        /** 這些站網站那邊的登入一陣子沒動就失效，登入時問使用者要不要讓 App 記住密碼、過期時自動重新登入 */
        val CRED_SITES = setOf("jm")

        @Volatile
        var current: WebActivity? = null
            private set

        fun intent(ctx: Context, args: Map<String, Any?>): Intent = Intent(ctx, WebActivity::class.java).apply {
            putExtra(EXTRA_SITE, args["site"] as? String)
            putExtra(EXTRA_URL, args["url"] as? String)
            putExtra(EXTRA_TITLE, args["title"] as? String)
            putExtra(EXTRA_MODE, args["mode"] as? String ?: "browse")
            putExtra(EXTRA_PREFILL, args["prefill"] as? String)
        }
    }

    private lateinit var web: WebView
    private lateinit var titleView: TextView
    private lateinit var loading: ProgressBar
    private var site = ""
    private var mode = "browse"
    private var typed = ""
    private var typedPass = ""

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        site = intent.getStringExtra(EXTRA_SITE).orEmpty()
        mode = intent.getStringExtra(EXTRA_MODE) ?: "browse"
        val url = intent.getStringExtra(EXTRA_URL).orEmpty()
        val prefill = intent.getStringExtra(EXTRA_PREFILL).orEmpty()

        web = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = Net.userAgent
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            settings.builtInZoomControls = true
            settings.displayZoomControls = false
            settings.setSupportMultipleWindows(false)
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            webViewClient = object : WebViewClient() {
                // 廣告會把頁面導到別的網站，只允許留在同一個站
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val u = request.url.toString()
                    if (!u.startsWith("http")) return true
                    val owner = Sites.siteForUrl(u)
                    return owner != null && owner != site
                }

                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    loading.visibility = View.VISIBLE
                    if (site == "jm") view.evaluateJavascript(injectCss(JM_CSS), null)
                }

                override fun onPageFinished(view: WebView, url: String) {
                    loading.visibility = View.GONE
                    if (site == "jm") view.evaluateJavascript(injectCss(JM_CSS), null)
                    CookieManager.getInstance().flush()
                    if (mode != "login") view.title?.takeIf { it.isNotBlank() }?.let { titleView.text = it }
                    if (mode == "login") {
                        // 每個站的登入頁都預設勾「記住我／保持登入」：沒勾的話網站給的是關掉就失效的登入，重開 App 就要重登
                        view.evaluateJavascript(REMEMBER_JS, null)
                        if (site == "vb") view.evaluateJavascript(VB_REMEMBER_JS, null)
                    }
                    if (site == "jm" && mode == "login" && url.contains("login", true)) {
                        // 重新登入時先填好上次的帳號
                        view.evaluateJavascript(
                            "document.querySelectorAll('input[name=\"id_remember\"],input[name=\"login_remember\"]').forEach(function(c){c.checked=true});" +
                                "document.querySelectorAll('input[name=\"username\"]').forEach(function(u){if(!u.value)u.value=${JSONObject.quote(prefill)}});0",
                            null,
                        )
                    }
                    Bridge.emit(mapOf("type" to "web", "site" to site, "mode" to mode, "url" to url))
                }
            }
        }

        titleView = TextView(this).apply {
            text = intent.getStringExtra(EXTRA_TITLE) ?: ""
            setTextColor(Color.WHITE)
            textSize = 17f
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        loading = ProgressBar(this, null, android.R.attr.progressBarStyleSmall)
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0xFF0C0C0D.toInt())
            setPadding(dp(8), 0, dp(8), 0)
            addView(button("返回") { onBack() }, LinearLayout.LayoutParams(-2, dp(48)))
            addView(titleView, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = dp(8) })
            addView(loading, LinearLayout.LayoutParams(dp(24), dp(24)).apply { rightMargin = dp(8) })
            if (mode != "browse") addView(button(if (mode == "login") "完成" else "驗證完成") { close() }, LinearLayout.LayoutParams(-2, dp(48)))
            addView(button("重新整理") { web.reload() }, LinearLayout.LayoutParams(-2, dp(48)))
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            addView(bar, LinearLayout.LayoutParams(-1, dp(56)))
            addView(FrameLayout(this@WebActivity).apply {
                setBackgroundColor(Color.WHITE)
                addView(web, FrameLayout.LayoutParams(-1, -1))
            }, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { v, insets ->
            val i = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            v.setPadding(i.left, i.top, i.right, i.bottom)
            WindowInsetsCompat.CONSUMED
        }
        setContentView(root)
        onBackPressedDispatcher.addCallback(this) { onBack() }

        if (site in CRED_SITES && mode == "login") watchUsername()
        web.loadUrl(url)
        web.requestFocus()
    }

    private fun button(label: String, onClick: () -> Unit): TextView = TextView(this).apply {
        text = label
        setTextColor(Color.WHITE)
        textSize = 15f
        gravity = Gravity.CENTER
        setPadding(dp(14), 0, dp(14), 0)
        isFocusable = true
        isClickable = true
        // 電視遙控器移到按鈕上要看得出來
        background = GradientDrawable().apply { cornerRadius = dp(8).toFloat(); setColor(Color.TRANSPARENT) }
        setOnFocusChangeListener { v, f ->
            (v.background as GradientDrawable).apply {
                setColor(if (f) 0x33FFFFFF else Color.TRANSPARENT)
                setStroke(if (f) dp(2) else 0, Color.WHITE)
            }
        }
        setOnClickListener { onClick() }
    }

    /**
     * JM：記下使用者在「看得到的」帳號欄打的字（頁面上還有兩個藏在彈窗裡），收藏網址要用。
     * 密碼也先放在記憶體：登入成功後 App 會問要不要記住（加密存在這台裝置），不同意就丟掉。
     */
    private fun watchUsername() {
        lifecycleScope.launch {
            while (isActive) {
                delay(1000)
                web.evaluateJavascript(
                    "(function(){var all=[].slice.call(document.querySelectorAll('input[name=\"username\"]'));" +
                        "var seen=all.filter(function(u){return u.offsetParent!==null&&u.value.trim()});" +
                        "var u=seen[0]||all.filter(function(u){return u.value.trim()})[0];var p=u&&u.form&&u.form.querySelector('input[type=\"password\"]');" +
                        "return JSON.stringify({u:(u||{}).value||'',p:(p||{}).value||''})})()",
                ) { raw ->
                    val v = runCatching { JSONObject(JSONObject("{\"v\":$raw}").optString("v")) }.getOrNull() ?: return@evaluateJavascript
                    v.optString("u").takeIf { it.isNotBlank() }?.let { typed = it.trim() }
                    v.optString("p").takeIf { it.isNotEmpty() }?.let { typedPass = it }
                }
            }
        }
    }

    private fun injectCss(css: String) =
        "(function(){if(document.getElementById('__aio_css'))return;var s=document.createElement('style');s.id='__aio_css';s.textContent=${JSONObject.quote(css)};(document.head||document.documentElement).appendChild(s);})()"

    private fun onBack() {
        if (mode == "browse" && web.canGoBack()) web.goBack()
        else if (mode == "login" && web.canGoBack() && !web.url.orEmpty().contains("login", true)) web.goBack()
        else close()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // 遙控器的選單鍵 = 完成
        if (event.keyCode == KeyEvent.KEYCODE_MENU && event.action == KeyEvent.ACTION_UP) {
            close()
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    /** 關閉並把結果交回 Dart */
    fun close() {
        if (isFinishing) return
        CookieManager.getInstance().flush()
        if (site.isNotEmpty()) WebFetcher.reset(site)
        if (mode == "login" && site in CRED_SITES) com.allinoneplayer.net.Creds.stash(site, typed, typedPass)
        setResult(Activity.RESULT_OK, Intent().putExtra(RESULT_TYPED, typed))
        finish()
    }

    override fun onResume() {
        super.onResume()
        // 計時器是全 App 共用的，背景暫停過的話要恢復，不然網頁的 JS 不會動
        web.resumeTimers()
    }

    override fun onDestroy() {
        if (current === this) current = null
        (web.parent as? ViewGroup)?.removeView(web)
        web.destroy()
        super.onDestroy()
    }
}
