package io.legado.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.view.KeyEvent

/**
 * 阅读器按键桥接 — [M5] 音量键翻页
 *
 * 原版语义（`app/src/main/java/io/legado/app/ui/book/manga/
 * ReadMangaActivity.kt` L894-902）：阅读器 `onKeyDown` 拦截
 * `KEYCODE_VOLUME_UP` → 上一页、`KEYCODE_VOLUME_DOWN` → 下一页，
 * 并 `return true` 消费（不调系统音量）。Flutter 层无按键拦截
 * 通道，本桥接承载：
 *
 * - Dart 经 `setVolumeKeyCapture(enabled)` 开关捕获——仅漫画阅读器
 *   活跃且设置开启时启用，退出阅读器立即关闭，防拦截范围外泄到
 *   其它页面（回归系统音量键默认行为）；
 * - `MainActivity.onKeyDown` 在捕获开启且为音量键时经本通道通知
 *   Dart 翻页并消费按键；方向反转（reverseVolumeKeyPage）在 Dart
 *   侧处理。
 *
 * 事件形状（批1b-2a）：
 * - 旧：`invokeMethod("volumeKey", "up"/"down")`；
 * - 新：`invokeMethod("volumeKey", {"direction": "up"/"down",
 *   "longPress": Boolean})`。
 * `longPress` 取 `KeyEvent.repeatCount > 0`（对齐原版
 * ReadBookActivity.onKeyDown 的 `val longPress = event.repeatCount > 0`），
 * 供 Dart 侧按 `keyPageOnLongPress` 语义消费。注意当前通道路径的消费方
 * 是漫画阅读器（原版 ReadMangaActivity 不区分长按，仍每个 keydown
 * 翻页）；文本阅读器主路径经 Flutter KeyRepeatEvent 取得同一 repeat
 * 信息。Dart 解析侧同时兼容旧 String 形态（向后兼容）。
 *
 * 全部异常捕获后经 `result.error` / 不消费降级返回，绝不向 Flutter
 * 引擎抛未捕获异常（对照 D2 教训：插件原生层异常会 FATAL 强杀）。
 *
 * 支持方法：
 * - `setVolumeKeyCapture`: 参数 Boolean；成功返回 true。
 * 信道事件（原生 → Dart）：
 * - `volumeKey`: `{direction: "up"/"down", longPress: Boolean}`（旧版 String）。
 */
class ReaderKeysBridge {

    companion object {
        const val CHANNEL = "legado/reader_keys"

        /** 音量键 keyCode → 方向；非音量键返回 null（纯函数，Kotlin 单测覆盖） */
        internal fun volumeDirection(keyCode: Int): String? = when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "up"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "down"
            else -> null
        }

        /** 长按 repeat 判定：`repeatCount > 0`（对齐原版 onKeyDown） */
        internal fun longPressFromRepeatCount(repeatCount: Int): Boolean =
            repeatCount > 0

        /** Dart 侧事件负载（批1b-2a 新协议；旧 String 形态由 Dart 兼容） */
        internal fun volumeKeyPayload(
            direction: String,
            longPress: Boolean,
        ): Map<String, Any> = mapOf(
            "direction" to direction,
            "longPress" to longPress,
        )
    }

    private var channel: MethodChannel? = null

    /** 捕获开关（仅 UI 线程读写的简单标记，@Volatile 保可见性） */
    @Volatile
    private var captureEnabled = false

    fun setMethodChannel(channel: MethodChannel) {
        this.channel = channel
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setVolumeKeyCapture" -> {
                    captureEnabled = call.arguments as? Boolean ?: false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // 绝不外抛（D2 教训：未捕获异常主线程 FATAL）
            result.error("READER_KEYS_ERROR", e.message, null)
        }
    }

    /**
     * `MainActivity.onKeyDown` 调用：捕获开启且为音量键时通知 Dart
     * 翻页并消费按键。
     *
     * @param keyCode `KeyEvent.keyCode`
     * @param event 原始按键事件（取 `repeatCount` 判定长按 repeat；
     *              允许 null 兼容旧调用方，此时按非长按处理）
     * @return true = 已消费（不调系统音量）；false = 交还系统处理
     *         （捕获未开 / 非音量键 / channel 未注册 / 通知失败的安全降级）
     */
    fun handleKeyDown(keyCode: Int, event: KeyEvent? = null): Boolean {
        if (!captureEnabled) return false
        val direction = volumeDirection(keyCode) ?: return false
        // [审查回修 P3-3] channel 未注册时 fail-open：不得消费按键
        //（修前 `channel?.invokeMethod` 空安全调用后仍 return true，
        // 会把音量键吞掉且无任何翻页效果）
        val activeChannel = channel ?: return false
        // repeatCount > 0 即系统长按自动重复（原版 onKeyDown 同一判定）
        val longPress = longPressFromRepeatCount(event?.repeatCount ?: 0)
        return try {
            activeChannel.invokeMethod(
                "volumeKey",
                volumeKeyPayload(direction, longPress)
            )
            true
        } catch (e: Exception) {
            // 通知失败则不消费（安全降级，让系统处理音量）
            false
        }
    }
}
