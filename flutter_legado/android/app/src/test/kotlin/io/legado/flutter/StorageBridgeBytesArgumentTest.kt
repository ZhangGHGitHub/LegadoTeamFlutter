package io.legado.flutter

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [P1-2 回归 | 2026-10-03] StorageBridge bytes 参数解析兼容性单测。
 *
 * 背景（QA 真机证据 .tmp/cbz_qa/logcat_full.txt:1619/2385）：
 * java.lang.ClassCastException: byte[] cannot be cast to java.util.List
 * at StorageBridge.saveImageToDownloads(StorageBridge.kt:75)
 * —— Dart Uint8List 经 StandardMessageCodec 落地为 Java byte[]，
 * 旧代码 call.argument<List<Int>>("bytes") 的泛型 checkcast 必抛 CCE，
 * 保存图片恒失败并回退文档目录。
 *
 * 本测试钉住 StorageBridge.bytesFromArgument 的两种形态：
 * 1. byte[]（Dart Uint8List 主形态）原样透传，绝不抛异常；
 * 2. List<Number>（历史/测试形态）逐元素转 byte；
 * 3. 非法形态返回 null（调用方回 INVALID_ARGS），而非 CCE。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测纯函数内核，不触 Android 框架类。
 */
class StorageBridgeBytesArgumentTest {

    @Test
    fun `byte array from Dart Uint8List passes through without exception`() {
        // PNG 魔数 + cbz 首部（PK\x03\x04）风格字节；>127 覆盖 toByte 符号语义
        val input = byteArrayOf(
            0x50, 0x4B, 0x03, 0x04, 0x00, 0x01, 0x02, 0x03,
            0x89.toByte(), 0x7F, 0x80.toByte(), 0xFF.toByte()
        )
        val parsed = StorageBridge.bytesFromArgument(input)
        assertArrayEquals(input, parsed)
    }

    @Test
    fun `list of numbers is converted element-wise`() {
        val list = listOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF)
        val expected = byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF.toByte()
        )
        assertArrayEquals(expected, StorageBridge.bytesFromArgument(list))
    }

    @Test
    fun `empty list yields empty byte array`() {
        assertEquals(0, StorageBridge.bytesFromArgument(emptyList<Int>())!!.size)
    }

    @Test
    fun `list with non-number element returns null instead of ClassCastException`() {
        assertNull(StorageBridge.bytesFromArgument(listOf(1, "x", 3)))
    }

    @Test
    fun `null and unsupported argument types return null`() {
        assertNull(StorageBridge.bytesFromArgument(null))
        assertNull(StorageBridge.bytesFromArgument("not-bytes"))
        assertNull(StorageBridge.bytesFromArgument(42))
    }
}
