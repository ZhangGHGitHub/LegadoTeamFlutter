package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [V-B3] 视频悬浮窗纯函数 JVM 单测（不触 Android 框架类）。
 *
 * 形态依据（原版）：
 * - 通知文案：VideoPlayService.kt:408-421（标题 = 「正在播放: <标题>」、
 *   文本 = R.string.audio_play_s「点击打开播放界面」，标题空回退「视频」）；
 * - 窗口尺寸：同文件 :462-495 / :560-576（竖屏视频屏宽 1/2、横屏 3/4，
 *   高按视频比例、16:9 兜底）；
 * - 贴边：同文件 :141-154（中线判左右、左右留 30、上 30 下 60）。
 */
class VideoPlayServiceLogicTest {

    @Test
    fun `notification title keeps video title and text matches original`() {
        assertEquals(
            "正在播放: 第3集" to "点击打开播放界面",
            resolveVideoNotificationTexts("第3集")
        )
    }

    @Test
    fun `notification falls back to default video name`() {
        assertEquals("正在播放: 视频" to "点击打开播放界面", resolveVideoNotificationTexts(null))
        assertEquals("正在播放: 视频" to "点击打开播放界面", resolveVideoNotificationTexts("   "))
    }

    @Test
    fun `portrait video takes half of screen width`() {
        // 高 > 宽 * 1.2 → 竖屏
        assertEquals(540, computeFloatWindowWidth(1080, 720, 1280))
        // 边界：恰好 1.2 倍不算竖屏（原版严格大于）
        assertEquals(810, computeFloatWindowWidth(1080, 1000, 1200))
    }

    @Test
    fun `landscape and unknown size take three quarter width`() {
        assertEquals(810, computeFloatWindowWidth(1080, 1920, 1080))
        assertEquals(810, computeFloatWindowWidth(1080, 0, 0))
    }

    @Test
    fun `height follows aspect ratio and defaults to 16 by 9`() {
        assertEquals(506, computeFloatWindowHeight(900, 1920, 1080))
        assertEquals(506, computeFloatWindowHeight(900, 0, 0))
        // 竖屏视频按比例
        assertEquals(1350, computeFloatWindowHeight(540, 720, 1800))
    }

    @Test
    fun `snap end x picks nearest edge with margin`() {
        // 窗口 540 宽、屏 1080：中线右侧 → 右贴边 1080-540-30
        assertEquals(510, computeSnapEndX(600, 540, 1080))
        assertEquals(30, computeSnapEndX(0, 540, 1080))
        // 窗口占满全宽 → 归 0（原版 viewWidth == screenWidth 分支）
        assertEquals(0, computeSnapEndX(100, 1080, 1080))
    }

    @Test
    fun `snap end y clamps top and bottom`() {
        assertEquals(30, clampFloatWindowY(0, 300, 1920))
        assertEquals(1560, clampFloatWindowY(1900, 300, 1920))
        assertEquals(500, clampFloatWindowY(500, 300, 1920))
    }

    @Test
    fun `state from map parses channel payload`() {
        val state = VideoFloatState.fromMap(
            mapOf(
                "url" to "https://example.com/a.m3u8",
                "title" to "第1集",
                "bookName" to "测试书",
                "headers" to mapOf("Referer" to "https://example.com"),
                "positionMs" to 12345L,
                "playing" to false,
                "speed" to 1.5,
                "bookUrl" to "book://1",
                "chapterIndex" to 2,
                "chapterTitle" to "第1集",
                "directUrl" to null,
                "hasPrev" to true,
                "hasNext" to true,
                "mpdTempPath" to null,
            )
        )
        requireNotNull(state)
        assertEquals("https://example.com/a.m3u8", state.url)
        assertEquals(12345L, state.positionMs)
        assertEquals(false, state.playing)
        assertEquals(1.5f, state.speed, 0.0001f)
        assertEquals(2, state.chapterIndex)
        assertEquals(mapOf("Referer" to "https://example.com"), state.headers)
        assertNull(state.directUrl)
    }

    @Test
    fun `state from map rejects blank url and tolerates missing fields`() {
        assertNull(VideoFloatState.fromMap(null))
        assertNull(VideoFloatState.fromMap(mapOf("url" to "")))
        assertNull(VideoFloatState.fromMap(mapOf("title" to "无地址")))
        val minimal = VideoFloatState.fromMap(mapOf("url" to "file:///tmp/a.mpd"))
        requireNotNull(minimal)
        assertEquals(0L, minimal.positionMs)
        assertEquals(true, minimal.playing)
        assertEquals(1f, minimal.speed, 0.0001f)
        assertEquals(-1, minimal.chapterIndex)
        assertEquals(emptyMap<String, String>(), minimal.headers)
    }

    @Test
    fun `state to map roundtrip preserves all fields`() {
        val state = VideoFloatState(
            url = "https://example.com/v.m3u8",
            title = "第2集",
            bookName = "书",
            headers = mapOf("User-Agent" to "ua"),
            positionMs = 5000L,
            playing = false,
            speed = 2.0f,
            bookUrl = "book://1",
            chapterIndex = 1,
            chapterTitle = "第2集",
            directUrl = "https://example.com/direct",
            hasPrev = true,
            hasNext = false,
            mpdTempPath = "/tmp/x.mpd",
        )
        assertEquals(state, VideoFloatState.fromMap(state.toMap()))
    }
}
