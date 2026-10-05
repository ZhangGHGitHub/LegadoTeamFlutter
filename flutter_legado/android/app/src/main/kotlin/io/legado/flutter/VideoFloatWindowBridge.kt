package io.legado.flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
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
     * @return false = 无悬浮窗权限（Dart 侧应调用 requestOverlayPermission 引导）
     */
    private fun show(rawArgs: Any?): Boolean {
        val ctx = activity ?: return false
        if (!canDrawOverlays()) return false
        val map = rawArgs as? Map<*, *> ?: return false
        val state = VideoFloatState.fromMap(map) ?: return false
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
            emit("onError", mapOf("message" to (e.message ?: "start_service_failed")))
            false
        }
    }
}
