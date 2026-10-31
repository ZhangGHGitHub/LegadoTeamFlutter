package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [批9b-6 审查回修] WebServiceWakeLockBridge 纯函数/常量单测。
 *
 * 只测不依赖 Android 框架实例的部分（参数解析、通道名、唤醒锁 tag、
 * 空态 isHeld）；真实 WakeLock/WifiLock 获取与跨 Activity 保持由
 * 进程级单例设计保证，待 Android 真机验证批覆盖。
 */
class WebServiceWakeLockBridgeArgumentTest {

    @Test
    fun `only boolean true enables the lock`() {
        assertTrue(WebServiceWakeLockBridge.enabledFromArgument(true))
        assertFalse(WebServiceWakeLockBridge.enabledFromArgument(false))
    }

    @Test
    fun `missing or non boolean argument falls back to false`() {
        assertFalse(WebServiceWakeLockBridge.enabledFromArgument(null))
        assertFalse(WebServiceWakeLockBridge.enabledFromArgument("true"))
        assertFalse(WebServiceWakeLockBridge.enabledFromArgument(1))
    }

    @Test
    fun `channel name and wake lock tag match upstream`() {
        assertEquals("legado/web_service_wakelock", WebServiceWakeLockBridge.CHANNEL)
        assertEquals("legado:WebService", WebServiceWakeLockBridge.WAKE_LOCK_TAG)
    }

    @Test
    fun `isHeld is false before any acquire`() {
        assertFalse(WebServiceWakeLockBridge.isHeld())
    }
}
