package io.legado.flutter

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Web 服务前台服务桥（批9b-6c）
 *
 * Flutter → Android 通道 `legado/web_service_foreground`，与
 * [WebServerForegroundService] 配对；只负责启停、状态查询与 Android 13+
 * 通知权限请求，不承载 Rust server 生命周期（server 仍由 Dart 经 FFI
 * 启停在 Flutter 进程内）。
 *
 * 方法：
 * - `start`：`ContextCompat.startForegroundService`；成功 true，失败
 *   `result.error("web_foreground_start_failed", ...)`；
 * - `stop`：`stopService`（幂等）；成功 true，异常回 error；
 * - `isRunning`：返回 [WebServerForegroundService.isRunning]；
 * - `hasNotificationPermission`：Android 13+ 查询 `POST_NOTIFICATIONS`
 *   （低版本恒 true，不触系统）；
 * - `requestNotificationPermission`：Android 13+ 在用户开启 Web 服务时
 *   调起系统权限对话框；结果经 [onRequestPermissionsResult]（MainActivity
 *   转发）回传布尔值。拒绝不阻断 FGS（仅通知不可见），由 Dart 侧提示。
 *
 * 失败不抛异常到 Flutter：Android 12+ 后台启动限制
 * （`ForegroundServiceStartNotAllowedException`）在 UI 前台交互路径不应出现，
 * 真出现时由 Dart 降级为「仅前台可用」，不阻断 Web 服务开关。
 *
 * 权限请求的挂起 `Result` 由本对象持有：Activity 销毁/请求被替换时以 false
 * 完成，避免 Dart Future 永久挂起（审查回修 P3 边界）。
 *
 * — 全栈工程师 ｜ 2026-11-01
 */
object WebServiceForegroundBridge {

    /** 与 Dart `WebServiceForegroundService.channel` 同名 */
    const val CHANNEL = "legado/web_service_foreground"

    // 方法名集中登记：与 Dart `WebServiceForegroundService` 的 invokeMethod
    // 字面量一一对应，跨层断言见 WebServerForegroundServiceTest。
    const val METHOD_START = "start"
    const val METHOD_STOP = "stop"
    const val METHOD_IS_RUNNING = "isRunning"
    const val METHOD_HAS_NOTIFICATION_PERMISSION = "hasNotificationPermission"
    const val METHOD_REQUEST_NOTIFICATION_PERMISSION = "requestNotificationPermission"

    /** 通知权限请求码（MainActivity.onRequestPermissionsResult 据此转发） */
    const val REQUEST_CODE_NOTIFICATION_PERMISSION = 0x1E63

    private const val TAG = "WebServerFgsBridge"

    /** 挂起中的权限请求（单值：UI 侧 `_webServiceBusy` 已串行化开关操作） */
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            METHOD_START -> {
                try {
                    WebServerForegroundService.start(activity.applicationContext)
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

            METHOD_STOP -> {
                try {
                    WebServerForegroundService.stop(activity.applicationContext)
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

            METHOD_IS_RUNNING -> result.success(WebServerForegroundService.isRunning)

            METHOD_HAS_NOTIFICATION_PERMISSION ->
                result.success(hasNotificationPermission(activity))

            METHOD_REQUEST_NOTIFICATION_PERMISSION ->
                requestNotificationPermission(activity, result)

            else -> result.notImplemented()
        }
    }

    /** 当前是否已授予通知权限（Android 13 以下无该运行时权限，恒 true） */
    private fun hasNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * 请求通知权限：已授予/低版本立即回 true；否则挂起 Result，等待
     * [onRequestPermissionsResult]。
     *
     * Activity 正在结束（isFinishing / isDestroyed）时不弹框，按当前状态
     * 回 false，避免系统静默丢弃请求导致 Dart 永久等待。
     */
    private fun requestNotificationPermission(
        activity: Activity,
        result: MethodChannel.Result,
    ) {
        if (hasNotificationPermission(activity)) {
            result.success(true)
            return
        }
        if (activity.isFinishing || activity.isDestroyed) {
            Log.w(TAG, "Activity 已结束，跳过通知权限请求（按未授予处理）")
            result.success(false)
            return
        }
        // 极端并发：先以 false 完成旧请求，保证没有永不返回的 Future
        runCatching { pendingPermissionResult?.success(false) }
        pendingPermissionResult = result
        try {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_CODE_NOTIFICATION_PERMISSION,
            )
        } catch (e: Exception) {
            Log.w(TAG, "请求通知权限失败：${e.message}", e)
            pendingPermissionResult = null
            result.success(false)
        }
    }

    /**
     * MainActivity.onRequestPermissionsResult 转发；返回 true 表示本桥消费。
     *
     * 用户拒绝/取消（grantResults 为空）按未授予回 false——FGS 继续运行，
     * 仅通知不可见（Dart 侧 UI 提示）。
     */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE_NOTIFICATION_PERMISSION) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        runCatching { pendingPermissionResult?.success(granted) }
        pendingPermissionResult = null
        return true
    }

    /** Activity 销毁兜底：挂起请求以 false 完成，避免 Dart Future 泄漏 */
    fun onActivityDestroyed() {
        runCatching { pendingPermissionResult?.success(false) }
        pendingPermissionResult = null
    }
}
