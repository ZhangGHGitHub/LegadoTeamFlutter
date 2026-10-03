package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [听书定时第2项 | 2026-10-03] 通知标题/文本映射纯函数单测。
 *
 * 形态依据（原版）：
 * - BaseReadAloudService.kt:780-805（TTS 通知：标题 = “Speaking[(N chapters
 *   left|%d min left)]: 书名”，文本 = 章节标题）；
 * - AudioPlayService.kt:872-895（音频书通知：标题 = “Playing[(N chapters
 *   left|%d min left)]: 书名”，文本 = 章节标题）。
 *
 * 纯 JVM JUnit（不触 Android 框架类）：只测纯函数内核。
 */
class PlaybackNotificationTextsTest {

    @Test
    fun `timer label becomes notification title and chapter stays text`() {
        val (title, text) = resolvePlaybackNotificationTexts(
            chapterTitle = "第3章 风起",
            playbackLabel = "正在朗读(剩余 12 分钟): 测试书",
        )
        assertEquals("正在朗读(剩余 12 分钟): 测试书", title)
        assertEquals("第3章 风起", text)
    }

    @Test
    fun `chapter stop label becomes notification title`() {
        val (title, text) = resolvePlaybackNotificationTexts(
            chapterTitle = "第1章",
            playbackLabel = "正在播放(剩余 2 章): 测试书",
        )
        assertEquals("正在播放(剩余 2 章): 测试书", title)
        assertEquals("第1章", text)
    }

    @Test
    fun `timer off label keeps original form`() {
        val (title, text) = resolvePlaybackNotificationTexts(
            chapterTitle = "第1章",
            playbackLabel = "正在播放: 测试书",
        )
        assertEquals("正在播放: 测试书", title)
        assertEquals("第1章", text)
    }

    @Test
    fun `empty label falls back to chapter title`() {
        val (title, text) = resolvePlaybackNotificationTexts(
            chapterTitle = "第1章",
            playbackLabel = "",
        )
        assertEquals("第1章", title)
        assertEquals("", text)
    }

    @Test
    fun `null inputs are safe`() {
        val (title, text) = resolvePlaybackNotificationTexts(
            chapterTitle = null,
            playbackLabel = null,
        )
        assertEquals("", title)
        assertEquals("", text)
    }
}
