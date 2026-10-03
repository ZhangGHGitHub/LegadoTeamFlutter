package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [D2 回归 | 2026-10-03] MediaSessionBridge 数值参数解析兼容性单测。
 *
 * 背景（QA 真机证据 .tmp/tts_qa/logcat_focus_conflict.txt:11/57）：
 * java.lang.ClassCastException: java.lang.Integer cannot be cast to java.lang.Long
 * at MediaSessionBridge.handleMethodCall(MediaSessionBridge.kt:131)
 * —— Dart int 经 StandardMessageCodec 落地：小整数为 Java Integer，
 * 旧代码 call.argument<Long>("position") 的泛型 checkcast 必抛 CCE，
 * 导致系统 playbackState 未发布（真机 onSessionActiveStateChanged
 * playbackState=null）。
 *
 * 本测试钉住 longFromArgument 的原始值 `is` 解析：
 * 1. Integer（Dart 小整数主形态，position 默认 0）→ long；
 * 2. Long / Short / Byte / Double / Float 等 Number 形态 → long；
 * 3. null / 非数值 → 0，绝不抛 ClassCastException。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测纯函数内核，不触 Android 框架类。
 */
class MediaSessionBridgeArgumentTest {

    @Test
    fun `dart small int (Integer) parses to long without exception`() {
        // position 默认 0 即 Integer 形态（真机复现值）
        assertEquals(0L, MediaSessionBridge.longFromArgument(0))
        assertEquals(1234L, MediaSessionBridge.longFromArgument(1234))
    }

    @Test
    fun `java long passes through`() {
        assertEquals(Long.MAX_VALUE, MediaSessionBridge.longFromArgument(Long.MAX_VALUE))
        assertEquals(9_000_000_000L, MediaSessionBridge.longFromArgument(9_000_000_000L))
    }

    @Test
    fun `other number forms parse to long`() {
        assertEquals(7L, MediaSessionBridge.longFromArgument(7.toShort()))
        assertEquals(8L, MediaSessionBridge.longFromArgument(8.toByte()))
        assertEquals(9L, MediaSessionBridge.longFromArgument(9.0))
        assertEquals(10L, MediaSessionBridge.longFromArgument(10.0f))
    }

    @Test
    fun `null and non-number arguments fall back to zero`() {
        assertEquals(0L, MediaSessionBridge.longFromArgument(null))
        assertEquals(0L, MediaSessionBridge.longFromArgument("123"))
        assertEquals(0L, MediaSessionBridge.longFromArgument(true))
    }
}
