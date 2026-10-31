package io.legado.flutter

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Web 服务前台服务桥（批9b-6c）
 *
 * Flutter → Android 通道 `legado/web_service_foreground`，与
 * [WebServerForegroundService] 配对；只负责启停与状态查询，不承载 Rust server
 * 生命周期（server 仍由 Dart 经 FFI 启停在 Flutter 进程内）。
 *
 * 方法：
 * - `start`：`ContextCompat.startForegroundService`；成功 true，失败
 *   `result.error("web_foreground_start_failed", ...)`（Dart 侧静默记日志）；
 * - `stop`：`stopService`（幂等）；成功 true，异常回 error；
 * - `isRunning`：返回 [WebServerForegroundService.isRunning]（供 Dart 新引擎
 *   初始化对账，避免重复拉起）。
 *
 * 失败不抛异常到 Flutter：Android 12+ 后台启动限制
 * （`ForegroundServiceStartNotAllowedException`）在 UI 前台交互路径不应出现，
 * 真出现时由 Dart 降级为「仅前台可用」，不阻断 Web 服务开关。
 *
 * — 全栈工程师 ｜ 2026-11-01
 */
object WebServiceForegroundBridge {

    /** 与 Dart `WebServiceForegroundService.channel` 同名 */
    const val CHANNEL = "legado/web_service_foreground"

    private const val TAG = "WebServerFgsBridge"

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "start" -> {
                try {
                    WebServerForegroundService.start(context.applicationContext)
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "启动 Web 服务前台服务失败：${e.message}", e)
                    result.error(
                        "web_foreground_start_failed",
                        e.message ?: e.javaClass.simpleName,
                        null,
                    )
                }
            }

            "stop" -> {
                try {
                    WebServerForegroundService.stop(context.applicationContext)
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "停止 Web 服务前台服务失败：${e.message}", e)
                    result.error(
                        "web_foreground_stop_failed",
                        e.message ?: e.javaClass.simpleName,
                        null,
                    )
                }
            }

            "isRunning" -> result.success(WebServerForegroundService.isRunning)

            else -> result.notImplemented()
        }
    }
}
