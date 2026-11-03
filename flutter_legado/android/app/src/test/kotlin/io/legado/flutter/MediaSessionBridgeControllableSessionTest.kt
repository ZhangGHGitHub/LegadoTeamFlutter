package io.legado.flutter

import android.support.v4.media.session.PlaybackStateCompat
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [批9b-5 P2-2] MediaSession 媒体键转发门控单测。
 *
 * 背景（设备验收 docs/DEVICE_ACCEPTANCE_20261104_BATCH9B5.md P2-2）：
 * `AudioNotifier.stop()` 只把 playbackState 置为 STOPPED，不释放会话；
 * `MediaButtonReceiver` 旧门控仅判断 `hasActiveSession()`，于是「会话活跃但
 * 已 stopped」时仍抑制转发。无实际音频时系统侧 `Media button session` 为
 * null，按键既不到会话也到不了 Flutter（按 85 无响应）。
 *
 * 本测试钉住纯函数门控：
 * - 无会话 / 未发布 playbackState → 不可控（转发给静态接收器）；
 * - active + PLAYING/PAUSED/BUFFERING/CONNECTING → 可控（交会话）；
 * - active + STOPPED/NONE/ERROR（及其它过渡态）→ 不可控；
 * - PAUSED 保持可控，保证「暂停中按播放键恢复」语义不变。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测纯函数内核，不构造 MediaSessionCompat。
 */
class MediaSessionBridgeControllableSessionTest {

    @Before
    fun setUp() {
        // companion `active` 是进程级静态引用；清空避免其它用例残留影响
        MediaSessionBridge.active = null
    }

    @Test
    fun `no session is not controllable`() {
        assertFalse(MediaSessionBridge.hasControllableSession())
        // 无会话时就算状态值看起来可控也不得交会话处理
        assertFalse(
            MediaSessionBridge.isControllableSession(
                isActive = false,
                playbackState = PlaybackStateCompat.STATE_PLAYING,
            ),
        )
    }

    @Test
    fun `active session with playing paused buffering or connecting is controllable`() {
        assertTrue(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_PLAYING,
            ),
        )
        assertTrue(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_PAUSED,
            ),
        )
        assertTrue(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_BUFFERING,
            ),
        )
        assertTrue(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_CONNECTING,
            ),
        )
    }

    @Test
    fun `active session stopped after stop is not controllable`() {
        // 复现路径：stop() → notifyStopped → updatePlaybackState("stopped")
        assertFalse(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_STOPPED,
            ),
        )
        assertFalse(MediaSessionBridge.isControllableState(PlaybackStateCompat.STATE_STOPPED))
    }

    @Test
    fun `active session none or error is not controllable`() {
        assertFalse(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_NONE,
            ),
        )
        assertFalse(
            MediaSessionBridge.isControllableSession(
                true,
                PlaybackStateCompat.STATE_ERROR,
            ),
        )
    }

    @Test
    fun `active session without published playback state is not controllable`() {
        assertFalse(MediaSessionBridge.isControllableSession(true, null))
    }

    @Test
    fun `other transitional states are not controllable`() {
        assertFalse(MediaSessionBridge.isControllableState(PlaybackStateCompat.STATE_FAST_FORWARDING))
        assertFalse(MediaSessionBridge.isControllableState(PlaybackStateCompat.STATE_REWINDING))
        assertFalse(MediaSessionBridge.isControllableState(PlaybackStateCompat.STATE_SKIPPING_TO_NEXT))
        assertFalse(MediaSessionBridge.isControllableState(PlaybackStateCompat.STATE_SKIPPING_TO_PREVIOUS))
    }
}
