package io.legado.flutter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Parcelable
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
 *   [MediaSessionBridge.hasControllableSession] 时**不转发**（仅日志），
 *   由会话 Callback 处理暂停/恢复（[MediaSessionBridge] `onPlay`/`onPause`）。
 * - **会话活跃但已 stopped**（`AudioNotifier.stop()` 只发 STOPPED 状态、
 *   不释放会话）时系统可能已不再把按键路由给会话（`Media button session`
 *   为 null），若仍按「活跃」抑制转发，按键会两头丢失（批9b-5 P2-2）。
 *   故门控用「活跃且播放状态可控」：STOPPED/NONE/ERROR → 交静态接收器
 *   转发，由 Dart `HeadsetMediaButtonService` 按偏好重新决策（含再次
 *   启动朗读）；PAUSED 仍交会话，保留「暂停中按播放键恢复」语义。
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
        // [批9b-5 回修] 仅当确实转发给 Dart 时才中止有序广播：
        // - 会话活跃/无引擎/ACTION_UP/长按重复均不 abort，交系统或其它
        //   接收器处理，避免误吞媒体键（原版无条件 abort 的差异已登记）；
        // - 伪造的 am broadcast 仍会进入本接收器（exported=true），伪造
        //   事件在无引擎时仅日志、不会启动朗读。
        if (handleIntent(context, intent) && isOrderedBroadcast) {
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
         * [批9b-5 P2-2] 会话门控从 [MediaSessionBridge.hasActiveSession] 改为
         * [MediaSessionBridge.hasControllableSession]：会话活跃但 playbackState
         * 为 STOPPED/NONE/ERROR 时不再抑制转发，避免陈旧会话吞键（无音频时
         * 系统不会把按键路由到该会话）。
         *
         * @return true=已转发给 Flutter（调用方据此 abort）；false=未消费
         *         （非 MEDIA_BUTTON / 无有效 KeyEvent / UP / 长按 / 可控
         *         会话存在 / 引擎未就绪）
         */
        @JvmStatic
        @Suppress("DEPRECATION")
        fun handleIntent(context: Context, intent: Intent): Boolean {
            if (intent.action != Intent.ACTION_MEDIA_BUTTON) return false
            // 安全转换：EXTRA_KEY_EVENT 可能被伪造为其它 Parcelable，
            // 旧泛型 getParcelableExtra<KeyEvent> 会 ClassCastException。
            val raw: Parcelable? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
            val keyEvent = raw as? KeyEvent ?: return false
            val keyCode = keyEvent.keyCode
            val action = keyEvent.action
            val repeatCount = keyEvent.repeatCount
            if (!shouldForward(action, repeatCount)) {
                // ACTION_UP / 长按重复：不重复触发也不 abort
                return false
            }
            if (MediaSessionBridge.hasControllableSession()) {
                Log.d(TAG, "媒体会话可控（播放/暂停/缓冲中），交会话处理（keyCode=$keyCode）")
                return false
            }
            Log.d(TAG, "转发耳机键到 Flutter（keyCode=$keyCode）")
            return HeadsetMediaButtonBridge.deliver(keyCode, action, repeatCount)
        }
    }
}
