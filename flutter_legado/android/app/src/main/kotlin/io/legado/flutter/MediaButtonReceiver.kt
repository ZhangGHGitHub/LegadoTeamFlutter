package io.legado.flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.KeyEvent

/**
 * 静态耳机媒体键接收器（批9b-5）
 *
 * 对齐原版 `legado-master/.../receiver/MediaButtonReceiver.kt:27-71` 的静态
 * 注册形态（manifest `:497-503`，`exported=true`、无 priority）：
 * 收到 `ACTION_MEDIA_BUTTON` 后把 `KEYCODE_MEDIA_*` 交给 Dart
 * [HeadsetMediaButtonBridge]；进程/引擎不存活时安全消费并日志。
 *
 * ## 路由优先级（与 MediaSession 去重）
 * - `BaseReadAloudService`/`AudioPlayService` 运行时，原版经 MediaSession
 *   直接处理后仍会自广播媒体键；我方 TTS/音频书运行时
 *   [MediaSessionBridge] 会话活跃，系统优先把按键投给会话回调。为避免同一
 *   按键被「会话 + 静态接收器」双处理，本接收器检测到
 *   [MediaSessionBridge.hasActiveSession] 时**不转发**（仅日志），由会话
 *   Callback 处理暂停/恢复（[MediaSessionBridge] `onPlay`/`onPause`）。
 * - 会话不活跃（退出听书页后会话被释放、或从未启动过播放）时，静态接收器
 *   把按键交给 Dart `HeadsetMediaButtonService` 按偏好决策。
 *
 * ## 已知限制
 * 进程被系统杀死后广播可能无法拉起 Flutter 引擎（未做 headless
 * FlutterEngine），此时仅日志忽略；与原版常驻后台服务的差异登记在
 * Active Plan 9b-5。
 *
 * — 全栈工程师 ｜ 2026-11-04
 */
class MediaButtonReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (handleIntent(context, intent) && isOrderedBroadcast) {
            // 对齐原版：消费后中止有序广播，避免系统/其他应用重复处理
            abortBroadcast()
        }
    }

    companion object {

        private const val TAG = "MediaButtonReceiver"

        /** 媒体键只转发按下事件（对齐原版 `action == ACTION_DOWN`） */
        internal fun shouldForward(action: Int, repeatCount: Int): Boolean =
            action == 0 && repeatCount <= 0

        /**
         * 处理媒体键 Intent。
         *
         * @return true=已识别并消费（调用方据此 abortBroadcast）
         */
        @JvmStatic
        @Suppress("DEPRECATION")
        fun handleIntent(context: Context, intent: Intent): Boolean {
            if (intent.action != Intent.ACTION_MEDIA_BUTTON) return false
            val keyEvent = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                ?: return false
            val keyCode = keyEvent.keyCode
            val action = keyEvent.action
            val repeatCount = keyEvent.repeatCount
            if (!shouldForward(action, repeatCount)) {
                // ACTION_UP / 长按重复：消费但不重复触发，避免长按连续切换
                return true
            }
            if (MediaSessionBridge.hasActiveSession()) {
                Log.d(TAG, "媒体会话活跃，交会话处理（keyCode=$keyCode）")
                return true
            }
            Log.d(TAG, "转发耳机键到 Flutter（keyCode=$keyCode）")
            HeadsetMediaButtonBridge.deliver(keyCode, action, repeatCount)
            return true
        }
    }
}
