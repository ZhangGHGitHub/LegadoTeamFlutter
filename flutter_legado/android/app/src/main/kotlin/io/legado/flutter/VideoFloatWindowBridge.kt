package io.legado.flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * [V-B3] 视频悬浮窗 Flutter 桥（通道 `legado/video_float`）
 *
 * 对齐原版三处入口的语义：
 * ① `VideoPlayerActivity.startFloatingWindow`（VideoPlayerActivity.kt:729-738）：
 *    Dart 播放页点「悬浮窗」→ [show]（服务已运行则 ACTION_REPLACE 换内容）；
 * ② `defaultFloatWindow` 设置开启时新开播放页直接转悬浮窗（:177-193）：
 *    Dart 侧解析出播放目标后同样走 [show]；
 * ③ `SourceHelp.openVideoPlayer(isFloat=true)`（SourceHelp.kt:188-206）：
 *    书源 JS 入口直开悬浮窗，Dart 解析后走 [show]。
 *
 * 回向事件（原生 → Dart，方法名与 Dart 侧 handler 对应）：
 * - onClosed / onCompleted / onSkipNext / onSkipPrevious / onError
 * - onReturnToFullscreen 不在此通道发：经 MainActivity Intent 单路径回传
 *   （避免「通道事件 + Intent」双导航；[setPendingReturn]/[deliverReturn]）
 *
 * 权限：`SYSTEM_ALERT_WINDOW` 为特殊权限，无运行时弹窗，只能经
 * [requestOverlayPermission] 打开系统设置页引导（对齐原版
 * BaseService.checkFloatPermission → PermissionsCompat 跳设置）。
 */
class VideoFloatWindowBridge {

    companion object {
        const val CHANNEL = "legado/video_float"

        private const val TAG = "VideoFloatWindowBridge"

        /** show 失败错误码（与 Dart `VideoFloatWindowBridge.lastShowError` 对齐） */
        const val ERR_NO_PERMISSION = "no_overlay_permission"
        const val ERR_BACKGROUND_START_REJECTED = "background_start_rejected"
        const val ERR_START_FAILED = "start_service_failed"
        const val ERR_CHANNEL_UNAVAILABLE = "channel_unavailable"

        @Volatile
        private var instance: VideoFloatWindowBridge? = null

        /** 原生 → Dart 事件（服务侧调用；未注册/引擎销毁时静默丢弃） */
        fun emit(method: String, arguments: Any?) {
            val channel = instance?.channel ?: return
            Handler(Looper.getMainLooper()).post {
                try {
                    channel.invokeMethod(method, arguments)
                } catch (_: Exception) {
                }
            }
        }
    }

    private var channel: MethodChannel? = null
    private var activity: Activity? = null

    /** 冷启动回全屏：Intent 状态暂存，等 Dart 调 getInitialFloatReturn 取走 */
    private var pendingReturn: Map<String, Any?>? = null

    fun register(engine: FlutterEngine, activity: Activity) {
        instance = this
        this.activity = activity
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler(::handleMethodCall)
        channel = ch
    }

    fun dispose() {
        if (instance === this) instance = null
        channel?.setMethodCallHandler(null)
        channel = null
        activity = null
    }

    /** MainActivity.onCreate：记录冷启动携带的回全屏状态
     *
     * 注意：configureFlutterEngine 早于 Dart 入口执行，但 Dart 侧 handler
     * 尚未注册，此处**不能**直接 invoke（会丢事件）；统一暂存，由 Dart
     * attach 后调 getInitialFloatReturn 取走。
     */
    fun setPendingReturn(intent: Intent?) {
        val state = extractReturnState(intent) ?: return
        pendingReturn = state
    }

    /** MainActivity.onNewIntent：悬浮窗「全屏」/通知点击经 Intent 回到应用 */
    fun deliverReturn(intent: Intent?) {
        val state = extractReturnState(intent) ?: return
        val ch = channel
        if (ch != null) {
            ch.invokeMethod("onReturnToFullscreen", state)
        } else {
            pendingReturn = state
        }
    }

    private fun extractReturnState(intent: Intent?): Map<String, Any?>? {
        val bundle = intent?.getBundleExtra(VideoPlayService.EXTRA_RETURN) ?: return null
        if (bundle.isEmpty) return null
        return bundle.keySet().associateWith { bundle.get(it) }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canDrawOverlays" -> result.success(canDrawOverlays())
            "requestOverlayPermission" -> {
                requestOverlayPermission()
                result.success(null)
            }
            "show" -> result.success(show(call.arguments))
            "isActive" -> result.success(VideoPlayService.active != null)
            "getState" -> result.success(VideoPlayService.active?.currentStateMap())
            "takeOver" -> {
                val state = VideoPlayService.active?.stateMapAndStop()
                result.success(state)
            }
            "dismiss" -> {
                VideoPlayService.active?.dismiss()
                result.success(null)
            }
            "getInitialFloatReturn" -> {
                val state = pendingReturn
                pendingReturn = null
                result.success(state)
            }
            else -> result.notImplemented()
        }
    }

    private fun canDrawOverlays(): Boolean {
        val ctx = activity ?: return false
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(ctx)
    }

    private fun requestOverlayPermission() {
        val ctx = activity ?: return
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:${ctx.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(intent)
        } catch (_: Exception) {
            try {
                ctx.startActivity(
                    Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 启动/替换悬浮窗内容。
     *
     * @return `true` = 已提交启动；`String` = 失败错误码（Dart 侧按类型分流
     * 提示）：[ERR_NO_PERMISSION] / [ERR_BACKGROUND_START_REJECTED] /
     * [ERR_START_FAILED] / [ERR_CHANNEL_UNAVAILABLE]。
     */
    private fun show(rawArgs: Any?): Any {
        val ctx = activity ?: return ERR_CHANNEL_UNAVAILABLE
        if (!canDrawOverlays()) return ERR_NO_PERMISSION
        val map = rawArgs as? Map<*, *> ?: return ERR_START_FAILED
        val state = VideoFloatState.fromMap(map) ?: return ERR_START_FAILED
        val action = if (VideoPlayService.active != null) {
            VideoPlayService.ACTION_REPLACE
        } else {
            VideoPlayService.ACTION_START
        }
        val intent = Intent(ctx, VideoPlayService::class.java).apply {
            this.action = action
            putExtra(VideoPlayService.EXTRA_STATE, bundleFromMap(state.toMap()))
        }
        return try {
            ContextCompat.startForegroundService(ctx, intent)
            true
        } catch (e: Exception) {
            // [W4] 后台启动 FGS 被系统限制（Android 12+）与权限缺失分流：
            // 前者异常类型为 ForegroundServiceStartNotAllowedException
            // （IllegalStateException 子类，低版本无该类，按类名链判定，
            // 对齐原版 ContextExtensions.isForegroundServiceStartDenied）
            if (e.isForegroundServiceStartDenied()) {
                Log.w(TAG, "startForegroundService rejected in background", e)
                ERR_BACKGROUND_START_REJECTED
            } else {
                Log.e(TAG, "startForegroundService failed", e)
                ERR_START_FAILED
            }
        }
    }
}

/**
 * [W4] 判定异常链中是否含 Android 12+ 的 FGS 后台启动限制异常。
 * 按类名判定避免低版本加载不存在的类（对齐原版 ContextExtensions.kt:163-175）。
 */
private fun Throwable.isForegroundServiceStartDenied(): Boolean {
    var current: Throwable? = this
    while (current != null) {
        val name = current.javaClass.name
        if (name == "android.app.ForegroundServiceStartNotAllowedException" ||
            current.javaClass.simpleName == "ForegroundServiceStartNotAllowedException"
        ) {
            return true
        }
        val cause = current.cause
        current = cause?.takeUnless { it === current }
    }
    return false
}
