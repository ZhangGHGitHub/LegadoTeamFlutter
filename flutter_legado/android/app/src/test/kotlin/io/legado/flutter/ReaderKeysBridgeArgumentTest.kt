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

    @Test
    fun `custom keys take priority over volume`() {
        val resolved = ReaderKeysBridge.directionForKey(
            keyCode = KEYCODE_VOLUME_UP,
            prevKeys = setOf(KEYCODE_VOLUME_UP),
            nextKeys = emptySet(),
            volumeEnabled = true,
            hardcodedEnabled = true,
        )
        assertEquals("up" to "custom", resolved)

        val next = ReaderKeysBridge.directionForKey(
            keyCode = KEYCODE_VOLUME_DOWN,
            prevKeys = emptySet(),
            nextKeys = setOf(KEYCODE_VOLUME_DOWN),
            volumeEnabled = true,
            hardcodedEnabled = false,
        )
        assertEquals("down" to "custom", next)
    }

    @Test
    fun `volume source follows volumeEnabled`() {
        assertEquals(
            "up" to "volume",
            ReaderKeysBridge.directionForKey(
                24, emptySet(), emptySet(), true, true,
            ),
        )
        assertEquals(
            "down" to "volume",
            ReaderKeysBridge.directionForKey(
                25, emptySet(), emptySet(), true, true,
            ),
        )
        assertNull(
            ReaderKeysBridge.directionForKey(
                24, emptySet(), emptySet(), false, true,
            ),
        )
    }

    @Test
    fun `hardcoded page keys map directions`() {
        val upKeys = listOf(92, 19, 21)
        val downKeys = listOf(93, 62, 20, 22)
        for (key in upKeys) {
            assertEquals(
                "key $key",
                "up" to "hardcoded",
                ReaderKeysBridge.directionForKey(
                    key, emptySet(), emptySet(), false, true,
                ),
            )
        }
        for (key in downKeys) {
            assertEquals(
                "key $key",
                "down" to "hardcoded",
                ReaderKeysBridge.directionForKey(
                    key, emptySet(), emptySet(), false, true,
                ),
            )
        }
        assertNull(
            ReaderKeysBridge.directionForKey(
                92, emptySet(), emptySet(), false, false,
            ),
        )
        assertNull(
            ReaderKeysBridge.directionForKey(
                0, emptySet(), emptySet(), true, true,
            ),
        )
    }

    @Test
    fun `parse key codes ignores invalid back and del`() {
        assertEquals(
            setOf(24, 25, 92),
            ReaderKeysBridge.parseKeyCodes("24, 25,4,67,abc,-1,24,92"),
        )
        assertEquals(emptySet<Int>(), ReaderKeysBridge.parseKeyCodes(null))
        assertEquals(emptySet<Int>(), ReaderKeysBridge.parseKeyCodes("  "))
        assertEquals(
            setOf(62),
            ReaderKeysBridge.parseKeyCodes("\n62\t"),
        )
    }

    @Test
    fun `recording excludes back and del`() {
        assertFalse(ReaderKeysBridge.isRecordableKey(4))
        assertFalse(ReaderKeysBridge.isRecordableKey(67))
        assertTrue(ReaderKeysBridge.isRecordableKey(92))
        assertTrue(ReaderKeysBridge.isRecordableKey(24))
        assertFalse(ReaderKeysBridge.isRecordableKey(0))
    }

    @Test
    fun `legacy volume channel only before page config`() {
        assertTrue(ReaderKeysBridge.useLegacyVolumeChannel(false, "volume"))
        assertFalse(ReaderKeysBridge.useLegacyVolumeChannel(true, "volume"))
        assertFalse(ReaderKeysBridge.useLegacyVolumeChannel(false, "custom"))
        assertFalse(ReaderKeysBridge.useLegacyVolumeChannel(false, "hardcoded"))
    }

    @Test
    fun `page and record payload shapes match dart`() {
        val page = ReaderKeysBridge.pageKeyPayload("down", true, "custom")
        assertEquals("down", page["direction"])
        assertEquals(true, page["longPress"])
        assertEquals("custom", page["source"])
        assertEquals(3, page.size)
        assertEquals(92, ReaderKeysBridge.recordKeyPayload(92)["keyCode"])
    }
}
