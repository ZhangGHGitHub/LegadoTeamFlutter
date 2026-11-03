package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [批9b-5 耳机媒体键] HeadsetMediaButtonBridge / MediaButtonReceiver 纯逻辑单测。
 *
 * 纯 JVM JUnit（不触 Android 框架实例）：
 * - Dart 事件负载形状（keyCode/action/repeat）；
 * - 通道名与 Dart 侧一致；
 * - 无引擎时 deliver 安全返回 false + 日志，不崩溃、不积压；
 * - 接收器只转发 ACTION_DOWN 且非长按重复事件（对齐原版
 *   MediaButtonReceiver.kt:47-48）。
 *
 * MethodChannel 就绪后的真实投递依赖 Flutter 引擎，留给 APK 编译 + 真机链路。
 */
class HeadsetMediaButtonBridgeTest {

    private val logs = mutableListOf<String>()

    private companion object {
        // android.view.KeyEvent 常量值（避免 JVM 单测加载 Android stub）
        const val ACTION_DOWN = 0
        const val ACTION_UP = 1
        const val KEYCODE_MEDIA_PLAY_PAUSE = 85
    }

    @Before
    fun setUp() {
        HeadsetMediaButtonBridge.logger = { message -> logs.add(message) }
        HeadsetMediaButtonBridge.detach()
        logs.clear()
    }

    @Test
    fun `payload matches dart map contract`() {
        val payload = HeadsetMediaButtonBridge.payload(
            keyCode = KEYCODE_MEDIA_PLAY_PAUSE,
            action = ACTION_DOWN,
            repeatCount = 0,
        )
        assertEquals(KEYCODE_MEDIA_PLAY_PAUSE, payload["keyCode"])
        assertEquals(ACTION_DOWN, payload["action"])
        assertEquals(0, payload["repeat"])
        assertEquals(3, payload.size)
    }

    @Test
    fun `channel name matches dart side`() {
        assertEquals("legado/headset_media_button", HeadsetMediaButtonBridge.CHANNEL)
    }

    @Test
    fun `deliver without engine returns false logs and keeps no backlog`() {
        val delivered = HeadsetMediaButtonBridge.deliver(
            keyCode = KEYCODE_MEDIA_PLAY_PAUSE,
            action = ACTION_DOWN,
            repeatCount = 0,
        )
        assertFalse("无引擎必须返回 false（安全消费/忽略）", delivered)
        assertEquals(0, HeadsetMediaButtonBridge.pendingCount())
        assertTrue("无引擎需日志说明", logs.any { it.contains("引擎未就绪") })
        assertFalse(HeadsetMediaButtonBridge.hasChannel())
    }

    @Test
    fun `receiver forwards only key down without repeat`() {
        assertTrue(MediaButtonReceiver.shouldForward(ACTION_DOWN, 0))
        assertFalse(MediaButtonReceiver.shouldForward(ACTION_UP, 0))
        assertFalse(MediaButtonReceiver.shouldForward(ACTION_DOWN, 1))
        assertFalse(MediaButtonReceiver.shouldForward(ACTION_DOWN, 7))
    }
}
