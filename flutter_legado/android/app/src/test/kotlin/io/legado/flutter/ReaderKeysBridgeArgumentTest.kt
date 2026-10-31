package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [批1b-2a 审查回修 P3-3] ReaderKeysBridge 参数解析/事件形状单测。
 *
 * 纯 JVM JUnit（不触 Android 框架实例）：只测 companion 中的纯函数——
 * keyCode→方向、repeatCount→longPress、Dart 侧 Map 负载形状。
 * channel 未注册的 fail-open 行为由 handleKeyDown 的 `channel ?: return false`
 * 保证（需 MethodChannel 实例，留给 APK 编译 + 真机链路验证）。
 */
class ReaderKeysBridgeArgumentTest {

    private companion object {
        // android.view.KeyEvent 常量值（避免 JVM 单测加载 Android stub）
        const val KEYCODE_VOLUME_UP = 24
        const val KEYCODE_VOLUME_DOWN = 25
    }

    @Test
    fun `volume key codes map to up and down directions`() {
        assertEquals("up", ReaderKeysBridge.volumeDirection(KEYCODE_VOLUME_UP))
        assertEquals("down", ReaderKeysBridge.volumeDirection(KEYCODE_VOLUME_DOWN))
    }

    @Test
    fun `non volume key code yields null`() {
        assertNull(ReaderKeysBridge.volumeDirection(0))
        assertNull(ReaderKeysBridge.volumeDirection(26)) // KEYCODE_POWER
        assertNull(ReaderKeysBridge.volumeDirection(-1))
    }

    @Test
    fun `repeat count above zero is long press`() {
        assertFalse(ReaderKeysBridge.longPressFromRepeatCount(0))
        assertTrue(ReaderKeysBridge.longPressFromRepeatCount(1))
        assertTrue(ReaderKeysBridge.longPressFromRepeatCount(12))
        assertFalse(ReaderKeysBridge.longPressFromRepeatCount(-1))
    }

    @Test
    fun `payload matches dart map contract`() {
        val payload = ReaderKeysBridge.volumeKeyPayload("down", true)
        assertEquals("down", payload["direction"])
        assertEquals(true, payload["longPress"])
        assertEquals(2, payload.size)

        val shortPress = ReaderKeysBridge.volumeKeyPayload("up", false)
        assertEquals("up", shortPress["direction"])
        assertEquals(false, shortPress["longPress"])
    }

    @Test
    fun `channel name matches dart side`() {
        assertEquals("legado/reader_keys", ReaderKeysBridge.CHANNEL)
    }
}
