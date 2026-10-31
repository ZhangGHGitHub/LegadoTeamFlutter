package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * [批9b-6c] Web 服务前台服务常量/桥契约 JVM 单测。
 *
 * 只测不依赖 Android 框架实例的部分：通道名（须与 Dart
 * `WebServiceForegroundService.channel` 同名）、服务 action（Intent 过滤用）、
 * 通知文案/渠道/ID 稳定性、未创建时的 `isRunning` 空态。
 *
 * 真实 startForeground / 通知展示 / 息屏 LAN 可达性属于设备验证范围
 * （真机后台 LAN 另批），不在 JVM 单测内伪造。
 */
class WebServerForegroundServiceTest {

    @Test
    fun `bridge channel matches dart channel name`() {
        assertEquals("legado/web_service_foreground", WebServiceForegroundBridge.CHANNEL)
    }

    @Test
    fun `service actions are explicit and namespaced`() {
        assertEquals(
            "io.legado.flutter.action.WEB_SERVER_START",
            WebServerForegroundService.ACTION_START,
        )
        assertEquals(
            "io.legado.flutter.action.WEB_SERVER_STOP",
            WebServerForegroundService.ACTION_STOP,
        )
    }

    @Test
    fun `notification contract matches batch spec`() {
        assertEquals("legado_web_server", WebServerForegroundService.CHANNEL_ID)
        assertEquals("Web 服务运行中", WebServerForegroundService.NOTIFICATION_TITLE)
        assertEquals("局域网可访问", WebServerForegroundService.NOTIFICATION_TEXT)
        assertEquals(0x1E61, WebServerForegroundService.NOTIFICATION_ID)
    }

    @Test
    fun `isRunning is false before service is created`() {
        assertFalse(WebServerForegroundService.isRunning)
    }
}
