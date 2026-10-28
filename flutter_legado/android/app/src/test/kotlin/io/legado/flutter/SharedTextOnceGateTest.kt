package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 批25b P2-2：分享文本一次性消费判定单测。
 *
 * 覆盖：指纹稳定性、跨进程消费窗口（含时钟回拨）、热路径短窗口去重。
 */
class SharedTextOnceGateTest {

    @Test
    fun fingerprint_isStableAndContentSensitive() {
        val text = "复制口令到阅读导入#L:example电com/a！sy©0¥Legado^"
        assertEquals(64, SharedTextOnceGate.fingerprint(text).length)
        assertEquals(
            SharedTextOnceGate.fingerprint(text),
            SharedTextOnceGate.fingerprint(text),
        )
        assertFalse(
            SharedTextOnceGate.fingerprint(text) ==
                SharedTextOnceGate.fingerprint("$text#"),
        )
    }

    @Test
    fun consumed_withinWindow_isSuppressed() {
        val text = "https://example.com/a"
        val hash = SharedTextOnceGate.fingerprint(text)
        assertTrue(
            SharedTextOnceGate.isRecentlyConsumed(
                text = text,
                storedHash = hash,
                consumedAt = 1_000L,
                now = 1_000L + SharedTextOnceGate.CONSUMED_WINDOW_MS,
            ),
        )
    }

    @Test
    fun consumed_afterWindow_isNotSuppressed() {
        val text = "https://example.com/a"
        val hash = SharedTextOnceGate.fingerprint(text)
        assertFalse(
            SharedTextOnceGate.isRecentlyConsumed(
                text = text,
                storedHash = hash,
                consumedAt = 1_000L,
                now = 1_001L + SharedTextOnceGate.CONSUMED_WINDOW_MS,
            ),
        )
    }

    @Test
    fun consumed_differentText_isNotSuppressed() {
        assertFalse(
            SharedTextOnceGate.isRecentlyConsumed(
                text = "https://example.com/b",
                storedHash = SharedTextOnceGate.fingerprint(
                    "https://example.com/a",
                ),
                consumedAt = 1_000L,
                now = 1_000L,
            ),
        )
        assertFalse(
            SharedTextOnceGate.isRecentlyConsumed(
                text = "https://example.com/a",
                storedHash = null,
                consumedAt = 0L,
                now = 1_000L,
            ),
        )
    }

    @Test
    fun consumed_clockRollbackStillSuppressed() {
        val text = "https://example.com/a"
        assertTrue(
            SharedTextOnceGate.isRecentlyConsumed(
                text = text,
                storedHash = SharedTextOnceGate.fingerprint(text),
                consumedAt = 10_000L,
                now = 9_000L,
            ),
        )
    }

    @Test
    fun historyLaunchFlag_isDetectedAmongOtherFlags() {
        assertTrue(SharedTextOnceGate.isHistoryLaunch(0x00100000))
        assertTrue(
            SharedTextOnceGate.isHistoryLaunch(
                0x04000000 or 0x00100000 or 0x00000004,
            ),
        )
        assertFalse(SharedTextOnceGate.isHistoryLaunch(0))
        assertFalse(SharedTextOnceGate.isHistoryLaunch(0x04000000))
    }

    @Test
    fun duplicate_sameTextWithinWindow() {
        assertTrue(
            SharedTextOnceGate.isDuplicate(
                text = "hello",
                recentText = "hello",
                recentAt = 1_000L,
                now = 1_000L + SharedTextOnceGate.DEDUPE_WINDOW_MS,
            ),
        )
        assertFalse(
            SharedTextOnceGate.isDuplicate(
                text = "hello",
                recentText = "hello",
                recentAt = 1_000L,
                now = 1_001L + SharedTextOnceGate.DEDUPE_WINDOW_MS,
            ),
        )
        assertFalse(
            SharedTextOnceGate.isDuplicate(
                text = "hello",
                recentText = "world",
                recentAt = 1_000L,
                now = 1_000L,
            ),
        )
        assertFalse(
            SharedTextOnceGate.isDuplicate(
                text = "hello",
                recentText = null,
                recentAt = 0L,
                now = 1_000L,
            ),
        )
    }
}
