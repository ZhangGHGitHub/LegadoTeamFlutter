package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.*
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * WebView 桥接 — 用于执行需要 WebView 的 JS（如反爬虫验证页面）
 *
 * 支持方法：
 * - loadUrl: 加载 URL 并可选执行 JS，返回结果
 * - evaluateJs: 在当前 WebView 上执行 JS
 * - close: 销毁 WebView
 */
class WebViewBridge {

    private var webView: WebView? = null
    private val handler = Handler(Looper.getMainLooper())

    companion object {
        private const val TIMEOUT_MS = 30_000L
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
            "close" -> {
                destroy()
                safeResult.success(null)
            }
            else -> safeResult.notImplemented()
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
                // 先销毁旧的 WebView
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
                                // 延迟执行 JS，确保 DOM 加载完成
                                handler.postDelayed({
                                    evaluateJsInternal(js, result)
                                }, 500)
                            } else {
                                // 无 JS 需要执行，直接返回页面 HTML
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

                // 设置超时
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
            wv.stopLoading()
            wv.loadUrl("about:blank")
            wv.clearHistory()
            wv.destroy()
        }
        webView = null
    }
}
