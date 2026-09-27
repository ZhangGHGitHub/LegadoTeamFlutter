package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * WebView 桥接 — 反爬验证 + BackstageWebView 语义（cacheMode / java·source 注入）
 *
 * 支持方法：
 * - loadUrl / evaluateJs / close：既有验证码通道（纯字符串语义不变）
 * - backstageEval：对齐 Kotlin BackstageWebView（cacheFirst→LOAD_CACHE_ELSE_NETWORK；
 *   isRule 或 sourceKey 非空时注入 java/source/cache JavascriptInterface +
 *   getInjectionString；B1 加法式返回 cookie 回流信封，见 [buildEnvelope]；
 *   B2 webView 主路径 eval 结果空/命中挑战签名时按阶梯重试，见
 *   [RETRY_LADDER_MS] / [CHALLENGE_SIGNATURES]）
 *
 * — WebViewBridge + Bridge｜2026-08-13｜项 B/B1 cookie 回流 + sourceKey
 * ｜2026-09-26 项 B/B2 eval 重试阶梯
 */
class WebViewBridge {

    private var webView: WebView? = null
    // [销毁竞态防护 | 2026-09-26] 已销毁标志：置位后一切后续回调立即让路
    private var destroyed = false
    private val handler = Handler(Looper.getMainLooper())

    companion object {
        private const val TIMEOUT_MS = 60_000L

        /** B2 eval 重试阶梯（可配置常量）：[200,400,600,800,1000]ms 循环 */
        private val RETRY_LADDER_MS = longArrayOf(200L, 400L, 600L, 800L, 1000L)

        /** B2 最大重试次数（30 次，累计阶梯 ≤18s，总预算受 TIMEOUT_MS 约束） */
        private const val MAX_EVAL_RETRIES = 30

        /** B2 挑战签名（可配置常量）：WAF 挑战页标志，命中即按阶梯重试 */
        private val CHALLENGE_SIGNATURES = listOf("acw_sc__v2", "setCookie", "正在验证")

        /** 对齐 WebJsExtensions 随机接口名，避免与页面全局冲突 */
        private fun randomIfaceName(): String {
            val u = UUID.randomUUID().toString().replace("-", "")
            val letter = ('a' + (u[0].code % 26))
            return letter + u.substring(1, 12)
        }
    }

    /** 包装 MethodChannel.Result，防止重复回复 */
    private class SafeResult(private val result: MethodChannel.Result) {
        private val completed = AtomicBoolean(false)

        val isCompleted: Boolean get() = completed.get()

        fun success(value: Any?) {
            if (completed.compareAndSet(false, true)) {
                result.success(value)
            }
        }

        fun error(code: String, message: String?, details: Any?) {
            if (completed.compareAndSet(false, true)) {
                result.error(code, message, details)
            }
        }

        fun notImplemented() {
            if (completed.compareAndSet(false, true)) {
                result.notImplemented()
            }
        }
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val safeResult = SafeResult(result)
        when (call.method) {
            "loadUrl" -> {
                val url = call.argument<String>("url")
                    ?: return safeResult.error("ARG_ERROR", "url is required", null)
                val js = call.argument<String>("javaScript")
                loadUrlWithJs(url, js, safeResult, context)
            }
            "evaluateJs" -> {
                val js = call.argument<String>("javaScript")
                    ?: return safeResult.error("ARG_ERROR", "javaScript is required", null)
                evaluateJs(js, safeResult)
            }
            "backstageEval" -> {
                // [并发竞态修复 | 2026-09-26] 每次调用独立实例：共享实例的
                // destroyInternal 会销毁上一个（在途）调用正在使用的 WebView，
                // 被销毁 WebView 的 chromium 回调再触发即在原生层 NPE 崩溃
                // 整个应用（真机实测：916 源并发搜索）。backstageEval 的
                // WebView 生命周期由本次调用闭环（完成自毁 + 超时兜底），
                // 独立实例无共享状态损失。
                WebViewBridge().backstageEval(call, safeResult, context)
            }
            "close" -> {
                destroy()
                safeResult.success(null)
            }
            else -> safeResult.notImplemented()
        }
    }

    /**
     * 对齐 BackstageWebView.getStrResponse：
     * action=webView | webViewGetSource | webViewGetOverrideUrl
     *
     * B1 加法式返回值：有 cookie 回流时返回信封
     * `{"result": ..., "cookies": {"<url>": "k=v; ..."}}`（CookieManager
     * 按 finalUrl 读取）；无 cookie 时返回纯结果串（与旧版语义一致，
     * 旧版 Kotlin 返回的纯串 Dart 侧按「非信封」兜底解析）。
     */
    @SuppressLint("SetJavaScriptEnabled")
    private fun backstageEval(call: MethodCall, result: SafeResult, context: Context) {
        val action = call.argument<String>("action") ?: "webView"
        val url = call.argument<String>("url").orEmpty()
        val html = call.argument<String>("html").orEmpty()
        val js = call.argument<String>("javaScript").orEmpty()
        val sourceRegex = call.argument<String>("sourceRegex").orEmpty()
        val overrideUrlRegex = call.argument<String>("overrideUrlRegex").orEmpty()
        val cacheFirst = call.argument<Boolean>("cacheFirst") == true
        val isRule = call.argument<Boolean>("isRule") == true
        val resultJson = call.argument<String>("result").orEmpty()
        val delayTime = (call.argument<Number>("delayTime")?.toLong() ?: 0L).coerceAtLeast(0L)
        val sourceKey = call.argument<String>("sourceKey").orEmpty()

        // B1（设计文档 §2.2 G4）：sourceKey 非空按 isRule 同等口径生效
        // （对齐上游 tag 语义）——注入 java/source/cache 接口、
        // window.result 与 eval 前缀，页内 JS 可经 java 桥读取源 key
        val ruleLike = isRule || sourceKey.isNotEmpty()

        if (url.isEmpty() && html.isEmpty()) {
            result.success("")
            return
        }

        handler.post {
            try {
                destroyInternal()
                // B2：eval 重试阶梯的总预算锚点（与全局超时同一起算口径，
                // 保证等待 + 重试总耗时不超 TIMEOUT_MS=60s）
                val opStartMs = System.currentTimeMillis()
                val nameJava = randomIfaceName()
                val nameSource = randomIfaceName()
                val nameCache = randomIfaceName()
                val cacheIface = WebCacheJsInterface()
                val sourceIface = SourceJsInterface(sourceKey)
                val javaIface = JavaJsInterface(sourceIface, cacheIface)

                if (resultJson.isNotEmpty()) {
                    cacheIface.putMemory("webview_result", resultJson)
                }

                val capturedOverride = AtomicBoolean(false)
                var overrideHit: String? = null
                // B1：当前页 cookie 快照（onPageFinished 捕获 + 最终 eval
                // 前重读），随结果信封回传，Rust 侧按 ETLD+1 归一落库
                var capturedCookies = ""

                webView = WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.blockNetworkImage = true
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    settings.cacheMode =
                        if (cacheFirst) WebSettings.LOAD_CACHE_ELSE_NETWORK
                        else WebSettings.LOAD_DEFAULT

                    // 对齐 BackstageWebView：ruleLike（isRule 或 sourceKey 非空）
                    // + html 时注入 java/source/cache（B1 同等口径）
                    if (ruleLike && html.isNotEmpty()) {
                        addJavascriptInterface(cacheIface, nameCache)
                        addJavascriptInterface(sourceIface, nameSource)
                        addJavascriptInterface(javaIface, nameJava)
                    }

                    webViewClient = object : WebViewClient() {
                        private var pageFinished = false

                        override fun shouldOverrideUrlLoading(
                            view: WebView,
                            request: WebResourceRequest
                        ): Boolean {
                            if (action == "webViewGetOverrideUrl" &&
                                overrideUrlRegex.isNotEmpty()
                            ) {
                                val u = request.url?.toString().orEmpty()
                                if (u.isNotEmpty() &&
                                    Regex(overrideUrlRegex).containsMatchIn(u)
                                ) {
                                    if (capturedOverride.compareAndSet(false, true)) {
                                        overrideHit = u
                                        // B1：拦截命中 URL 的 cookie 随结果回传
                                        val c =
                                            CookieManager.getInstance().getCookie(u).orEmpty()
                                        result.success(buildEnvelope(u, c, u))
                                        destroyInternal()
                                    }
                                    return true
                                }
                            }
                            return false
                        }

                        override fun onPageFinished(view: WebView?, finishedUrl: String?) {
                            super.onPageFinished(view, finishedUrl)
                            if (pageFinished) return
                            pageFinished = true
                            if (result.isCompleted) return
                            if (destroyed) return

                            // B1：首次 onPageFinished 捕获当前页 cookie（WAF 挑战
                            // 页通常由验证 JS 写入 cookie，最终 eval 前再重读）
                            val fUrl = finishedUrl ?: view?.url?.toString().orEmpty()
                            if (fUrl.isNotEmpty()) {
                                capturedCookies =
                                    CookieManager.getInstance().getCookie(fUrl).orEmpty()
                            }

                            // 对齐：window.result = cache.getFromMemory('webview_result')
                            if (ruleLike && resultJson.isNotEmpty()) {
                                view?.evaluateJavascript(
                                    "window.result = $nameCache.getFromMemory('webview_result');",
                                    null
                                )
                            }

                            when (action) {
                                "webViewGetOverrideUrl" -> {
                                    // 触发型 JS 后等待跳转；超时见下方 handler
                                    if (js.isNotEmpty()) {
                                        handler.postDelayed({
                                            view?.evaluateJavascript(js, null)
                                        }, 100L + delayTime)
                                    }
                                }
                                "webViewGetSource" -> {
                                    val wait = if (delayTime > 0) delayTime else 900L
                                    if (js.isNotEmpty()) {
                                        view?.evaluateJavascript(js, null)
                                    }
                                    handler.postDelayed({
                                        if (result.isCompleted) return@postDelayed
                                        sniffSource(view, finishedUrl, sourceRegex, result)
                                    }, wait)
                                }
                                else -> {
                                    // webView：延时后执行 JS（缺省 outerHTML）
                                    val wait = if (js.isEmpty()) {
                                        if (delayTime > 0) delayTime else 900L
                                    } else {
                                        100L + delayTime
                                    }
                                    // B2 eval 重试阶梯（局部递归函数：捕获局部
                                    // capturedCookies / result / opStartMs）
                                    //
                                    // eval 结果空 / 命中挑战签名（CHALLENGE_SIGNATURES，
                                    // WAF 挑战页标志）→ 按 [200,400,600,800,1000]ms
                                    // 阶梯重试至多 MAX_EVAL_RETRIES 次；总预算受
                                    // TIMEOUT_MS 约束（自 opStartMs 起算，剩余不足
                                    // 直接采纳最后结果——全局超时兜底会先触发）。
                                    // cookie 快照在最终采纳时重读（重试窗口内验证
                                    // 流程可能新写 cookie，以最新快照为准，B1 口径）
                                    fun evalWithRetry(wv: WebView, script: String, attempt: Int) {
                                        wv.evaluateJavascript(script) { value ->
                                            if (result.isCompleted) return@evaluateJavascript
                                            val text = unescapeJsResult(value)
                                            val remaining =
                                                TIMEOUT_MS - (System.currentTimeMillis() - opStartMs)
                                            if (attempt < MAX_EVAL_RETRIES &&
                                                needsRetryResult(text) &&
                                                remaining > 0
                                            ) {
                                                val delay = RETRY_LADDER_MS[
                                                    attempt % RETRY_LADDER_MS.size
                                                ].coerceAtMost(remaining)
                                                handler.postDelayed({
                                                    if (!result.isCompleted) {
                                                        evalWithRetry(wv, script, attempt + 1)
                                                    }
                                                }, delay)
                                                return@evaluateJavascript
                                            }
                                            val cUrl = wv.url?.toString().orEmpty()
                                            capturedCookies =
                                                CookieManager.getInstance()
                                                    .getCookie(cUrl).orEmpty()
                                            result.success(
                                                buildEnvelope(text, capturedCookies, cUrl)
                                            )
                                            destroyInternal()
                                        }
                                    }
                                    handler.postDelayed({
                                        // [崩溃防护 | 2026-09-26] 簇B 修复使
                                        // java.webView(null,…) 真正可达，桥内
                                        // 并发竞态的 NPE（WebViewBridge.kt:217
                                        // 真机实测）会杀死整个应用——降级为日志，
                                        // 该源按超时/空结果失败
                                        try {
                                            if (!result.isCompleted) {
                                                val userJs =
                                                    if (js.isNotEmpty()) js
                                                    else "document.documentElement.outerHTML"
                                                val injection =
                                                    if (ruleLike && html.isNotEmpty()) {
                                                        "try{var cache=$nameCache,source=$nameSource,java=$nameJava;}catch(e){}\n"
                                                    } else ""
                                                view?.let { wv ->
                                                    evalWithRetry(wv, injection + userJs, 0)
                                                }
                                            }
                                        } catch (t: Throwable) {
                                            android.util.Log.e("WebViewBridge", "webViewEval", t)
                                            destroyInternal()
                                        }
                                    }, wait)
                                }
                            }
                        }

                        override fun onReceivedError(
                            view: WebView?,
                            request: WebResourceRequest?,
                            error: WebResourceError?
                        ) {
                            super.onReceivedError(view, request, error)
                            if (request?.isForMainFrame == true && !result.isCompleted) {
                                // 对齐 Flutter 路径：资源错误按终态放行，仍尝试取结果
                                onPageFinished(view, view?.url)
                            }
                        }
                    }
                }

                handler.postDelayed({
                    if (!result.isCompleted) {
                        if (action == "webViewGetOverrideUrl") {
                            result.success(
                                if (overrideHit != null) {
                                    buildEnvelope(
                                        overrideHit,
                                        capturedCookies,
                                        overrideHit,
                                    )
                                } else "[ERROR] webViewGetOverrideUrl 等待跳转超时"
                            )
                        } else {
                            result.error(
                                "TIMEOUT",
                                "WebView backstage timed out after ${TIMEOUT_MS}ms",
                                null
                            )
                        }
                        destroyInternal()
                    }
                }, TIMEOUT_MS)

                val wv = webView!!
                if (html.isNotEmpty()) {
                    val base = if (url.isNotEmpty()) url else null
                    wv.loadDataWithBaseURL(base, html, "text/html", "utf-8", base)
                } else {
                    // URL 入口：初始 URL 命中 override 则直接返回
                    if (action == "webViewGetOverrideUrl" &&
                        overrideUrlRegex.isNotEmpty() &&
                        Regex(overrideUrlRegex).containsMatchIn(url)
                    ) {
                        result.success(url)
                        destroyInternal()
                        return@post
                    }
                    wv.loadUrl(url)
                }
            } catch (e: Exception) {
                result.error("WEBVIEW_ERROR", e.message, e.stackTraceToString())
            }
        }
    }

    private fun sniffSource(
        view: WebView?,
        finishedUrl: String?,
        sourceRegex: String,
        result: SafeResult
    ) {
        if (sourceRegex.isEmpty()) {
            result.success("")
            destroyInternal()
            return
        }
        val regex = Regex(sourceRegex)
        if (!finishedUrl.isNullOrEmpty() && regex.containsMatchIn(finishedUrl)) {
            // B1：命中页 URL 的 cookie 随结果回传
            result.success(
                buildEnvelope(
                    finishedUrl,
                    CookieManager.getInstance().getCookie(finishedUrl).orEmpty(),
                    finishedUrl,
                )
            )
            destroyInternal()
            return
        }
        val collectJs = """
            (function(){
              var urls = [];
              try {
                performance.getEntriesByType('resource').forEach(function(r){ urls.push(r.name); });
              } catch (e) {}
              try {
                document.querySelectorAll('a[href],link[href],img[src],script[src],source[src],iframe[src],video[src],audio[src],embed[src],object[data]')
                  .forEach(function(el){
                    var u = el.src || el.href || el.data;
                    if (u) urls.push(u);
                  });
              } catch (e) {}
              return JSON.stringify(urls);
            })()
        """.trimIndent()
        view?.evaluateJavascript(collectJs) { value ->
            if (result.isCompleted) return@evaluateJavascript
            val listJson = unescapeJsResult(value)
            try {
                val arr = JSONArray(listJson)
                for (i in 0 until arr.length()) {
                    val candidate = arr.optString(i)
                    if (candidate.isNotEmpty() && regex.containsMatchIn(candidate)) {
                        // B1：命中资源 URL 的 cookie 随结果回传
                        result.success(
                            buildEnvelope(
                                candidate,
                                CookieManager.getInstance().getCookie(candidate).orEmpty(),
                                candidate,
                            )
                        )
                        destroyInternal()
                        return@evaluateJavascript
                    }
                }
            } catch (_: Exception) {
            }
            result.success("")
            destroyInternal()
        } ?: run {
            result.success("")
            destroyInternal()
        }
    }

    /** B2 重试判定：结果空（页面未就绪/外框空）或命中挑战签名（WAF 挑战页标志） */
    private fun needsRetryResult(text: String): Boolean {
        if (text.isEmpty()) return true
        return CHALLENGE_SIGNATURES.any { sig -> text.contains(sig) }
    }

    /**
     * B1 cookie 回流信封（加法式）：无 cookie 时返回纯结果串（与旧版
     * 语义逐字节一致，旧版 Kotlin 兼容）；有 cookie 时返回
     * `{"result": ..., "cookies": {"<cookieUrl>": "k=v; ..."}}`。
     * Dart 侧 [PlatformBridgeService] 解析信封，非信封值按纯结果兜底。
     */
    private fun buildEnvelope(
        resultText: String,
        cookies: String,
        cookieUrl: String,
    ): String {
        if (cookies.isEmpty() || cookieUrl.isEmpty()) return resultText
        return JSONObject().apply {
            put("result", resultText)
            put("cookies", JSONObject().apply { put(cookieUrl, cookies) })
        }.toString()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun loadUrlWithJs(
        url: String,
        js: String?,
        result: SafeResult,
        context: Context
    ) {
        handler.post {
            try {
                destroyInternal()

                webView = WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.userAgentString = settings.userAgentString
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW

                    webViewClient = object : WebViewClient() {
                        private var pageFinished = false

                        override fun onPageFinished(view: WebView?, finishedUrl: String?) {
                            super.onPageFinished(view, finishedUrl)
                            if (pageFinished) return
                            pageFinished = true

                            if (js != null) {
                                handler.postDelayed({
                                    evaluateJsInternal(js, result)
                                }, 500)
                            } else {
                                result.success(finishedUrl)
                            }
                        }

                        override fun onReceivedError(
                            view: WebView?,
                            request: WebResourceRequest?,
                            error: WebResourceError?
                        ) {
                            super.onReceivedError(view, request, error)
                            if (request?.isForMainFrame == true) {
                                result.error(
                                    "LOAD_ERROR",
                                    "Failed to load: ${error?.description}",
                                    null
                                )
                            }
                        }
                    }
                }

                handler.postDelayed({
                    if (!result.isCompleted) {
                        result.error("TIMEOUT", "WebView load timed out after ${TIMEOUT_MS}ms", null)
                        destroyInternal()
                    }
                }, TIMEOUT_MS)

                webView?.loadUrl(url)
            } catch (e: Exception) {
                result.error("WEBVIEW_ERROR", e.message, e.stackTraceToString())
            }
        }
    }

    private fun evaluateJs(js: String, result: SafeResult) {
        handler.post {
            if (webView == null) {
                result.error("NO_WEBVIEW", "WebView not initialized. Call loadUrl first.", null)
                return@post
            }
            evaluateJsInternal(js, result)
        }
    }

    @Suppress("DEPRECATION")
    private fun evaluateJsInternal(js: String, result: SafeResult) {
        webView?.evaluateJavascript(js) { value ->
            if (!result.isCompleted) {
                result.success(value)
            }
        }
    }

    fun destroy() {
        handler.post { destroyInternal() }
    }

    private fun destroyInternal() {
        if (destroyed) return
        destroyed = true
        val wv = webView
        webView = null
        wv?.let {
            // 真销毁延迟 2s：让在途 chromium 回调（onPageFinished 等）先
            // 落地——同步 destroy() 会把在途内部 Handler 置空，回调里的
            // evaluateJavascript 再触发即 NPE（真机崩溃根因）
            handler.postDelayed({
                try {
                    it.stopLoading()
                    it.loadUrl("about:blank")
                    it.clearHistory()
                    it.removeJavascriptInterface("java")
                    it.destroy()
                } catch (_: Exception) {
                }
            }, 2000L)
        }
    }

    /** evaluateJavascript 回调值为 JSON 编码字符串 */
    private fun unescapeJsResult(raw: String?): String {
        if (raw.isNullOrEmpty() || raw == "null") return ""
        return try {
            org.json.JSONTokener(raw).nextValue()?.let {
                when (it) {
                    is String -> it
                    else -> it.toString()
                }
            } ?: raw
        } catch (_: Exception) {
            var s = raw
            if (s.length >= 2 && s.startsWith("\"") && s.endsWith("\"")) {
                s = s.substring(1, s.length - 1)
                    .replace("\\\"", "\"")
                    .replace("\\n", "\n")
                    .replace("\\\\", "\\")
            }
            s
        }
    }

    // ─── JavascriptInterface：对齐 WebCacheManager / BaseSource / 精简 java ───

    class WebCacheJsInterface {
        private val memory = ConcurrentHashMap<String, String>()

        @JavascriptInterface
        fun put(key: String, value: String) {
            memory[key] = value
        }

        @JavascriptInterface
        fun putMemory(key: String, value: String) {
            memory[key] = value
        }

        @JavascriptInterface
        fun getFromMemory(key: String): String? = memory[key]

        @JavascriptInterface
        fun deleteMemory(key: String) {
            memory.remove(key)
        }

        @JavascriptInterface
        fun get(key: String): String? = memory[key]

        @JavascriptInterface
        fun delete(key: String) {
            memory.remove(key)
        }
    }

    class SourceJsInterface(private val sourceKey: String) {
        private val vars = ConcurrentHashMap<String, String>()
        private var variable: String = ""
        private var loginHeader: String = ""
        private var loginInfo: String = ""

        @JavascriptInterface
        fun getKey(): String = sourceKey

        @JavascriptInterface
        fun get(key: String): String = vars[key] ?: ""

        @JavascriptInterface
        fun put(key: String, value: String): String {
            vars[key] = value
            return value
        }

        @JavascriptInterface
        fun getVariable(): String = variable

        @JavascriptInterface
        fun putVariable(value: String?) {
            variable = value ?: ""
        }

        @JavascriptInterface
        fun getLoginHeader(): String? = loginHeader.ifEmpty { null }

        @JavascriptInterface
        fun getLoginInfo(): String? = loginInfo.ifEmpty { null }

        @JavascriptInterface
        fun putLoginInfo(info: String): Boolean {
            loginInfo = info
            return true
        }

        @JavascriptInterface
        fun removeLoginInfo() {
            loginInfo = ""
        }

        @JavascriptInterface
        fun login() {
            // 页内登录钩子：完整登录链在无头 QuickJS；此处为可调用空实现
        }
    }

    /**
     * 精简 `java` 桥：页内常用同步 API + 变量读写。
     * 网络类 API（ajax 等）返回空串，复杂逻辑仍走无头宿主。
     */
    class JavaJsInterface(
        private val source: SourceJsInterface,
        private val cache: WebCacheJsInterface
    ) {
        @JavascriptInterface
        fun get(key: String): String = source.get(key)

        @JavascriptInterface
        fun put(key: String, value: String): String = source.put(key, value)

        @JavascriptInterface
        fun getString(rule: String?): String = ""

        @JavascriptInterface
        fun ajax(url: String?): String = ""

        @JavascriptInterface
        fun getSource(): SourceJsInterface = source

        @JavascriptInterface
        fun toast(msg: String?) {
            // no-op：后台 WebView 无 UI
        }

        @JavascriptInterface
        fun log(msg: String?) {
            android.util.Log.d("LegadoWebJs", msg ?: "")
        }

        @JavascriptInterface
        fun getWebView(): String = ""

        /** 对齐 WebJsExtensions.request：异步结果写入 cache，由页内 Promise 轮询 */
        @JavascriptInterface
        fun request(funName: String, jsParam: Array<String?>, id: String) {
            cache.putMemory(id, "")
            android.util.Log.d(
                "LegadoWebJs",
                "java.request($funName) 页内异步未全量实现，返回空（id=$id）"
            )
        }
    }
}
