package io.legado.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.view.KeyEvent

/**
 * 阅读器按键桥接 — 音量键 + 自定义/硬编码翻页键（批4b）
 *
 * 协议兼容：
 * - 旧：Dart `setVolumeKeyCapture(enabled)`，原生 `volumeKey` 事件。
 *   未调用 `setPageKeyConfig` 时保持该协议（漫画阅读器继续可用）。
 * - 新：Dart `setPageKeyConfig{prevKeys,nextKeys,volumeEnabled,
 *   hardcodedEnabled}` + `setKeyRecording(bool)`；捕获开启后按
 *   custom > volume > hardcoded 优先级发送 `pageKey{direction,
 *   longPress,source}`；录制态发送 `recordKey{keyCode}`。
 *
 * 参考 `ReadBookController.kt:2698-2762`（自定义键优先于音量、
 * PAGE_UP/PAGE_DOWN/SPACE/DPAD 硬编码）与 `PageKeySheet.kt`
 * （BACK/DEL 不录制）。
 *
 * 异常全部 fail-open：channel 未注册/通知异常一律 return false，不吞键。
 */
class ReaderKeysBridge {

    /** 原生按键状态快照（复位纯函数/JVM 断言用） */
    internal data class KeyRoutingState(
        val prevKeys: Set<Int> = emptySet(),
        val nextKeys: Set<Int> = emptySet(),
        val volumeEnabled: Boolean = true,
        val hardcodedEnabled: Boolean = false,
        val pageKeyConfigActive: Boolean = false,
        val recordingEnabled: Boolean = false,
    )

    companion object {
        const val CHANNEL = "legado/reader_keys"

        private const val KEYCODE_BACK = 4
        private const val KEYCODE_DEL = 67
        private const val KEYCODE_SPACE = 62
        private const val KEYCODE_PAGE_UP = 92
        private const val KEYCODE_PAGE_DOWN = 93
        private const val KEYCODE_DPAD_UP = 19
        private const val KEYCODE_DPAD_DOWN = 20
        private const val KEYCODE_DPAD_LEFT = 21
        private const val KEYCODE_DPAD_RIGHT = 22
        private const val KEYCODE_VOLUME_UP = 24
        private const val KEYCODE_VOLUME_DOWN = 25

        /** 音量键 keyCode → 方向；非音量键返回 null（旧协议单测沿用） */
        internal fun volumeDirection(keyCode: Int): String? = when (keyCode) {
            KEYCODE_VOLUME_UP -> "up"
            KEYCODE_VOLUME_DOWN -> "down"
            else -> null
        }

        /** 长按 repeat 判定：`repeatCount > 0`（对齐原版 onKeyDown） */
        internal fun longPressFromRepeatCount(repeatCount: Int): Boolean =
            repeatCount > 0

        /** 旧音量事件负载（Dart 兼容 String 形态） */
        internal fun volumeKeyPayload(
            direction: String,
            longPress: Boolean,
        ): Map<String, Any> = mapOf(
            "direction" to direction,
            "longPress" to longPress,
        )

        /** 新翻页事件负载 */
        internal fun pageKeyPayload(
            direction: String,
            longPress: Boolean,
            source: String,
        ): Map<String, Any> = mapOf(
            "direction" to direction,
            "longPress" to longPress,
            "source" to source,
        )

        /** 录制事件负载 */
        internal fun recordKeyPayload(keyCode: Int): Map<String, Any> =
            mapOf("keyCode" to keyCode)

        /** 解析逗号/空白分隔 keyCode；非法/BACK/DEL 忽略（fail-safe 空集） */
        internal fun parseKeyCodes(raw: String?): Set<Int> {
            if (raw.isNullOrBlank()) return emptySet()
            return try {
                raw.split(Regex("[,\\s]+"))
                    .mapNotNull { it.toIntOrNull() }
                    .filter { it > 0 && it != KEYCODE_BACK && it != KEYCODE_DEL }
                    .toSet()
            } catch (_: Exception) {
                emptySet()
            }
        }

        /**
         * keyCode 解析（纯函数，JVM 单测覆盖）：
         * custom prev/next 优先；其次 volumeEnabled 音量键；
         * 最后 hardcodedEnabled 的 PAGE_UP/DPAD_UP/LEFT、
         * PAGE_DOWN/SPACE/DPAD_DOWN/RIGHT。
         *
         * @return (direction "up"/"down", source "custom"/"volume"/"hardcoded")
         */
        internal fun directionForKey(
            keyCode: Int,
            prevKeys: Set<Int>,
            nextKeys: Set<Int>,
            volumeEnabled: Boolean,
            hardcodedEnabled: Boolean,
        ): Pair<String, String>? {
            if (keyCode <= 0) return null
            if (prevKeys.contains(keyCode)) return "up" to "custom"
            if (nextKeys.contains(keyCode)) return "down" to "custom"
            if (volumeEnabled) {
                when (keyCode) {
                    KEYCODE_VOLUME_UP -> return "up" to "volume"
                    KEYCODE_VOLUME_DOWN -> return "down" to "volume"
                }
            }
            if (hardcodedEnabled) {
                when (keyCode) {
                    KEYCODE_PAGE_UP,
                    KEYCODE_DPAD_UP,
                    KEYCODE_DPAD_LEFT -> return "up" to "hardcoded"
                    KEYCODE_PAGE_DOWN,
                    KEYCODE_SPACE,
                    KEYCODE_DPAD_DOWN,
                    KEYCODE_DPAD_RIGHT -> return "down" to "hardcoded"
                }
            }
            return null
        }

        /** 录制可接受的 keyCode（BACK/DEL 交还系统） */
        internal fun isRecordableKey(keyCode: Int): Boolean =
            keyCode > 0 && keyCode != KEYCODE_BACK && keyCode != KEYCODE_DEL

        /** 未配置 page 协议时，音量键继续走旧 volumeKey 通道（漫画兼容） */
        internal fun useLegacyVolumeChannel(
            pageKeyConfigActive: Boolean,
            source: String,
        ): Boolean = !pageKeyConfigActive && source == "volume"

        /** setVolumeKeyCapture(false) 的 legacy 默认态（漫画音量键） */
        internal fun resetLegacyState(): KeyRoutingState = KeyRoutingState()

        /** 录制只处理首次 keydown，长按 repeat 消费但不重复追加 */
        internal fun shouldSendRecordKey(repeatCount: Int): Boolean =
            repeatCount == 0
    }

    private var channel: MethodChannel? = null

    @Volatile
    private var captureEnabled = false

    @Volatile
    private var keyState = KeyRoutingState()

    fun setMethodChannel(channel: MethodChannel) {
        this.channel = channel
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setVolumeKeyCapture" -> {
                    captureEnabled = call.arguments as? Boolean ?: false
                    if (!captureEnabled) {
                        // P1-2 捕获关闭：完整复位 legacy 默认态，避免文本
                        // 阅读器的 volumeEnabled=false/自定义键残留污染漫画。
                        keyState = resetLegacyState()
                    }
                    result.success(true)
                }
                "setPageKeyConfig" -> {
                    val args = call.arguments as? Map<*, *>
                    keyState = keyState.copy(
                        prevKeys = parseKeyCodes(
                            args?.get("prevKeys") as? String,
                        ),
                        nextKeys = parseKeyCodes(
                            args?.get("nextKeys") as? String,
                        ),
                        volumeEnabled =
                            args?.get("volumeEnabled") as? Boolean ?: true,
                        hardcodedEnabled =
                            args?.get("hardcodedEnabled") as? Boolean ?: false,
                        pageKeyConfigActive = true,
                    )
                    result.success(true)
                }
                "setKeyRecording" -> {
                    keyState = keyState.copy(
                        recordingEnabled = call.arguments as? Boolean ?: false,
                    )
                    result.success(true)
                }
                "resetPageKeyConfig" -> {
                    // page 租约清空但音量租约仍在（漫画压栈）时复位
                    // custom/volumeEnabled 残留，保持 capture 不变。
                    keyState = resetLegacyState()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("READER_KEYS_ERROR", e.message, null)
        }
    }

    /**
     * `MainActivity.onKeyDown` 调用。
     *
     * @return true = 已消费；false = 交还系统
     */
    fun handleKeyDown(keyCode: Int, event: KeyEvent? = null): Boolean {
        if (!captureEnabled) return false
        val activeChannel = channel ?: return false
        val repeatCount = event?.repeatCount ?: 0
        val longPress = longPressFromRepeatCount(repeatCount)
        val state = keyState
        return try {
            if (state.recordingEnabled) {
                if (!isRecordableKey(keyCode)) return false
                if (!shouldSendRecordKey(repeatCount)) return true
                activeChannel.invokeMethod("recordKey", recordKeyPayload(keyCode))
                return true
            }
            val resolved = directionForKey(
                keyCode = keyCode,
                prevKeys = state.prevKeys,
                nextKeys = state.nextKeys,
                volumeEnabled = state.volumeEnabled,
                hardcodedEnabled = state.hardcodedEnabled,
            ) ?: return false
            val direction = resolved.first
            val source = resolved.second
            if (state.pageKeyConfigActive) {
                activeChannel.invokeMethod(
                    "pageKey",
                    pageKeyPayload(direction, longPress, source),
                )
            } else if (
                useLegacyVolumeChannel(state.pageKeyConfigActive, source)
            ) {
                activeChannel.invokeMethod(
                    "volumeKey",
                    volumeKeyPayload(direction, longPress),
                )
            } else {
                return false
            }
            true
        } catch (e: Exception) {
            false
        }
    }
}
