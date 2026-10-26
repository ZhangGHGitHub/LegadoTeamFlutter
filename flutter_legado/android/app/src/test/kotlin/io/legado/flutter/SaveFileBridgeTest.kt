package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [D1 回修 | 2026-10-27] SaveFileBridge 纯函数单测。
 *
 * 覆盖 P3-4 要求的最小面：
 * 1. 空字节 / 空文件名在弹对话框前被拒绝（不创建 0 字节文档）；
 * 2. MIME 推断（JSON/JS/压缩包/未知扩展名）；
 * 3. 声明 MIME 优先于扩展名推断；
 * 4. 文件名净化（P3-5：`[\\/:*?"<>|]` → `_`）。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测 companion 内的纯函数内核，
 * 不触 Android 框架类（与 StorageBridgeBytesArgumentTest 同风格）。
 */
class SaveFileBridgeTest {

    @Test
    fun `empty bytes is rejected before launching the save dialog`() {
        assertEquals(
            "EMPTY_BYTES",
            SaveFileBridge.validateArgs("bookSource.json", ByteArray(0))
        )
        assertEquals(
            "EMPTY_BYTES",
            SaveFileBridge.validateArgs("bookSource.json", byteArrayOf())
        )
    }

    @Test
    fun `pending timeout is five minutes`() {
        assertEquals(5 * 60 * 1000L, SaveFileBridge.PENDING_TIMEOUT_MS)
    }

    @Test
    fun `blank file name and null bytes are invalid arguments`() {
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs(null, byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("", byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("   ", byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("a.json", null))
    }

    @Test
    fun `valid arguments pass validation`() {
        assertNull(SaveFileBridge.validateArgs("a.json", byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `mime type is inferred from extension`() {
        assertEquals("application/json", SaveFileBridge.mimeTypeOf("a.json"))
        assertEquals("application/json", SaveFileBridge.mimeTypeOf("A.JSON"))
        assertEquals("application/javascript", SaveFileBridge.mimeTypeOf("source.js"))
        assertEquals("application/zip", SaveFileBridge.mimeTypeOf("skin.zip"))
        assertEquals("text/plain", SaveFileBridge.mimeTypeOf("highlight.md"))
        assertEquals("image/png", SaveFileBridge.mimeTypeOf("cover.png"))
        assertEquals(
            "application/octet-stream",
            SaveFileBridge.mimeTypeOf("no-extension")
        )
        assertEquals(
            "application/octet-stream",
            SaveFileBridge.mimeTypeOf("unknown.bin2")
        )
    }

    @Test
    fun `declared mime type wins over extension inference`() {
        assertEquals(
            "text/javascript",
            SaveFileBridge.resolveMimeType("source.js", "text/javascript")
        )
        assertEquals(
            "application/javascript",
            SaveFileBridge.resolveMimeType("source.js", null)
        )
        assertEquals(
            "application/javascript",
            SaveFileBridge.resolveMimeType("source.js", "   ")
        )
    }

    @Test
    fun `illegal file name chars are normalized to underscore`() {
        assertEquals(
            "a_b_c_d_e_f_g_h_i_.json",
            SaveFileBridge.normalizeFileName("a/b\\c:d*e?f\"g<h>i|.json")
        )
        assertEquals(
            "bookSource_QA.json",
            SaveFileBridge.normalizeFileName("  bookSource_QA.json  ")
        )
    }
}
