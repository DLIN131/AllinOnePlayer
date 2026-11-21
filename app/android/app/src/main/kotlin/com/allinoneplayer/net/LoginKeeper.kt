package com.allinoneplayer.net

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.webkit.CookieManager
import com.allinoneplayer.App
import org.json.JSONObject
import java.security.KeyStore
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 讓登入撐過「重開 App」：
 * 有的站登入用的是工作階段 cookie（沒有到期日），WebView 在 App 被關掉時就丟掉，結果每次重開都被登出。
 * 登入確認成功後把該站的 cookie 備份一份；下次開 App 時，備份裡有、現在卻不見的 cookie 補回去（改成 30 天後到期）。
 * 登出、或補回去之後網站還是說沒登入（網站那邊真的過期了）就刪掉備份。
 */
object LoginKeeper {
    private val prefs by lazy { App.instance.getSharedPreferences("login_keep", Context.MODE_PRIVATE) }

    /** Cloudflare 通行證、統計用的 cookie 不用補（補了舊的反而可能被當成可疑） */
    private val SKIP = Regex("^(cf_clearance|__cf_bm|_cfuvid|cf_chl.*|__cflb|_ga.*|_gid|_gat.*|__gads|__gpi|__eoi|FCNIL|FCCDCF|FCOEC)$")
    private const val KEEP_SECONDS = 30 * 24 * 3600

    @Volatile
    private var restored = false

    private fun parse(raw: String?): LinkedHashMap<String, String> {
        val out = LinkedHashMap<String, String>()
        raw?.split(';')?.forEach {
            val p = it.trim()
            val i = p.indexOf('=')
            if (i > 0) out[p.substring(0, i)] = p.substring(i + 1)
        }
        return out
    }

    /** 登入確認成功時呼叫：備份這個站目前的 cookie */
    fun save(site: String) {
        if (!Sites.has(site)) return
        val cm = CookieManager.getInstance()
        val o = JSONObject()
        for (u in Sites.urls(site)) {
            val kept = parse(cm.getCookie(u)).filterKeys { !SKIP.matches(it) }
            if (kept.isNotEmpty()) o.put(u, kept.entries.joinToString("; ") { "${it.key}=${it.value}" })
        }
        if (o.length() > 0) prefs.edit().putString(site, o.toString()).apply()
        cm.flush()
    }

    /** App 退到背景時：已經在備份的站更新一次（網站可能換過 token） */
    fun saveKnown() {
        prefs.all.keys.forEach { runCatching { save(it) } }
        CookieManager.getInstance().flush()
    }

    fun forget(site: String) {
        prefs.edit().remove(site).apply()
    }

    /** 開 App 時呼叫一次（在任何請求之前） */
    fun restore() {
        if (restored) return
        restored = true
        val cm = CookieManager.getInstance()
        var n = 0
        for ((_, v) in prefs.all) {
            val o = runCatching { JSONObject(v as String) }.getOrNull() ?: continue
            for (u in o.keys()) {
                val now = parse(cm.getCookie(u))
                for ((k, value) in parse(o.optString(u))) {
                    if (k in now) continue
                    cm.setCookie(u, "$k=$value; Path=/; Max-Age=$KEEP_SECONDS" + if (u.startsWith("https")) "; Secure" else "")
                    n++
                }
            }
        }
        if (n > 0) cm.flush()
    }
}

/**
 * 記住密碼（使用者同意才存）：網站那邊的登入過期（jm 一陣子沒動就會被登出）時，用隱藏 WebView 自動重新登入。
 * 用 Android Keystore 的金鑰加密，金鑰拿不出這台裝置；登出或按「忘記密碼」就刪掉。
 */
object Creds {
    private const val ALIAS = "aio_login"
    private val prefs by lazy { App.instance.getSharedPreferences("login_cred", Context.MODE_PRIVATE) }

    /** 登入頁剛拿到、還沒決定要不要記住的帳密（只在記憶體） */
    private val stash = ConcurrentHashMap<String, Pair<String, String>>()

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val g = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        g.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return g.generateKey()
    }

    fun has(site: String) = prefs.contains(site)

    private fun save(site: String, user: String, pass: String) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val enc = c.doFinal(JSONObject().put("u", user).put("p", pass).toString().toByteArray())
        prefs.edit().putString(site, Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(enc, Base64.NO_WRAP)).apply()
    }

    fun read(site: String): Pair<String, String>? = runCatching {
        val (iv, enc) = prefs.getString(site, null)!!.split(':').map { Base64.decode(it, Base64.NO_WRAP) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        val j = JSONObject(String(c.doFinal(enc)))
        j.getString("u") to j.getString("p")
    }.getOrNull()

    fun stash(site: String, user: String, pass: String) {
        if (user.isNotBlank() && pass.isNotEmpty()) stash[site] = user.trim() to pass
    }

    /** 登入成功後呼叫：已經記住過的直接更新（可能換了密碼）並回傳 false；不然回傳 true 讓畫面問使用者 */
    fun offer(site: String): Boolean {
        val c = stash[site] ?: return false
        if (has(site)) {
            runCatching { save(site, c.first, c.second) }
            stash.remove(site)
            return false
        }
        return true
    }

    /** 使用者回答要不要記住；yes=false 也用來「忘記密碼」 */
    fun remember(site: String, yes: Boolean): Boolean {
        val c = stash.remove(site)
        if (yes && c != null) runCatching { save(site, c.first, c.second) }
        if (!yes) prefs.edit().remove(site).apply()
        return has(site)
    }

    fun forget(site: String) {
        stash.remove(site)
        prefs.edit().remove(site).apply()
    }
}
