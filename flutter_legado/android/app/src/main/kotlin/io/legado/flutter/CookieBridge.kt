package io.legado.flutter

import android.app.Activity
import android.webkit.CookieManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Cookie 桥 — WebView 登录页读取系统 CookieManager
 *
 * 对齐原版 WebViewLoginFragment 链路：CookieManager.getCookie(url) →
 * CookieStore.setCookie(sourceKey, cookie)（Dart 侧落库为 loginHeader，
 * 请求路径由 Rust 侧自动合并）。Flutter 侧 webview_flutter 未暴露
 * getCookies，经此通道读取 Android 系统 CookieManager。
 *
 * 支持方法：
 * - getCookie(url)：返回该 url 的 Cookie 串（无则空串）
 *
 * — Qoder UI ｜ 2026-08-28（登录域原版对齐重构）
 */
class CookieBridge {

    companion object {
        const val CHANNEL = "legado/cookie"
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "getCookie" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("args", "url required", null)
                    return
                }
                activity.runOnUiThread {
                    try {
                        val cookie = CookieManager.getInstance().getCookie(url)
                        result.success(cookie ?: "")
                    } catch (e: Exception) {
                        result.error("cookie", e.message, null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }
}
