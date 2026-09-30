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
 * - `MainActivity.onKeyDown` 在捕获开启且为音量键时经本通道
 *   `invokeMethod("volumeKey", "up"/"down")` 通知 Dart 翻页并消费
 *   按键；方向反转（reverseVolumeKeyPage）在 Dart 侧处理。
 *
 * 全部异常捕获后经 `result.error` / 不消费降级返回，绝不向 Flutter
 * 引擎抛未捕获异常（对照 D2 教训：插件原生层异常会 FATAL 强杀）。
 *
 * 支持方法：
 * - `setVolumeKeyCapture`: 参数 Boolean；成功返回 true。
 * 信道事件（原生 → Dart）：
 * - `volumeKey`: 参数 "up" / "down"。
 */
class ReaderKeysBridge {

    companion object {
        const val CHANNEL = "legado/reader_keys"
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
     * @return true = 已消费（不调系统音量）；false = 交还系统处理
     *         （捕获未开 / 非音量键 / 通知失败的安全降级）
     */
    fun handleKeyDown(keyCode: Int): Boolean {
        if (!captureEnabled) return false
        val direction = when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "up"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "down"
            else -> return false
        }
        return try {
            channel?.invokeMethod("volumeKey", direction)
            true
        } catch (e: Exception) {
            // 通知失败则不消费（安全降级，让系统处理音量）
            false
        }
    }
}
