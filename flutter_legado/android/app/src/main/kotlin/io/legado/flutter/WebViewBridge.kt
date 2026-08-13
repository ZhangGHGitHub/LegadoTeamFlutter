package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * WebView 桥接 — 反爬验证 + BackstageWebView 语义（cacheMode / java·source 注入）
 *
 * 支持方法：
 * - loadUrl / evaluateJs / close：既有验证码通道
 * - backstageEval：对齐 Kotlin BackstageWebView（cacheFirst→LOAD_CACHE_ELSE_NETWORK；
 *   isRule 时注入 java/source/cache JavascriptInterface + getInjectionString）
 *
 * — WebViewBridge + Bridge｜2026-08-13
 */
class WebViewBridge {

    private var webView: WebView? = null
    private val handler = Handler(Looper.getMainLooper())

    companion object {
        private const val TIMEOUT_MS = 60_000L

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
                backstageEval(call, safeResult, context)
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

        if (url.isEmpty() && html.isEmpty()) {
            result.success("")
            return
        }

        handler.post {
            try {
                destroyInternal()
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

                webView = WebView(context).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.blockNetworkImage = true
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                    settings.cacheMode =
                        if (cacheFirst) WebSettings.LOAD_CACHE_ELSE_NETWORK
                        else WebSettings.LOAD_DEFAULT

                    // 对齐 BackstageWebView：isRule + html 时注入 java/source/cache
                    if (isRule && html.isNotEmpty()) {
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
                                        result.success(u)
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

                            // 对齐：window.result = cache.getFromMemory('webview_result')
                            if (isRule && resultJson.isNotEmpty()) {
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
                                    handler.postDelayed({
                                        if (result.isCompleted) return@postDelayed
                                        val userJs =
                                            if (js.isNotEmpty()) js
                                            else "document.documentElement.outerHTML"
                                        val injection =
                                            if (isRule && html.isNotEmpty()) {
                                                "try{var cache=$nameCache,source=$nameSource,java=$nameJava;}catch(e){}\n"
                                            } else ""
                                        view?.evaluateJavascript(injection + userJs) { value ->
                                            if (!result.isCompleted) {
                                                result.success(unescapeJsResult(value))
                                                destroyInternal()
                                            }
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
                                if (overrideHit != null) overrideHit
                                else "[ERROR] webViewGetOverrideUrl 等待跳转超时"
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
            result.success(finishedUrl)
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
                        result.success(candidate)
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
        webView?.let { wv ->
            try {
                wv.stopLoading()
                wv.loadUrl("about:blank")
                wv.clearHistory()
                wv.removeJavascriptInterface("java")
                wv.destroy()
            } catch (_: Exception) {
            }
        }
        webView = null
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
