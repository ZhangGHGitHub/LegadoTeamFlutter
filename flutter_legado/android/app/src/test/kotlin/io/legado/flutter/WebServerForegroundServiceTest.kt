package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [批9b-6c] Web 服务前台服务常量/桥契约 JVM 单测。
 *
 * 覆盖审查回修点：
 * - P1 通知 ID 唯一性（Web 服务改用 [LegadoNotificationIds.WEB_SERVER]，
 *   不得与听书/视频/旧通知相同）；
 * - P2 任务移除不停止 FGS：不得重写 `onTaskRemoved`（默认实现即不停止；
 *   与原版 BaseService.kt:67-71 的差异已在服务注释登记）；
 * - P3 通知权限结果只消费本桥 requestCode；ACTION_STOP 已删除（停止统一
 *   经 stopService，避免通知/外部 intent 与 Dart 状态不一致）。
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
    fun `bridge method names match dart invokeMethod contract`() {
        // Dart WebServiceForegroundService 的 invokeMethod 字面量（跨层断言）：
        // 单侧改名但另一侧未同步会在这里变红。
        assertEquals("start", WebServiceForegroundBridge.METHOD_START)
        assertEquals("stop", WebServiceForegroundBridge.METHOD_STOP)
        assertEquals("isRunning", WebServiceForegroundBridge.METHOD_IS_RUNNING)
        assertEquals(
            "hasNotificationPermission",
            WebServiceForegroundBridge.METHOD_HAS_NOTIFICATION_PERMISSION,
        )
        assertEquals(
            "requestNotificationPermission",
            WebServiceForegroundBridge.METHOD_REQUEST_NOTIFICATION_PERMISSION,
        )
    }

    @Test
    fun `service start action is explicit and namespaced`() {
        assertEquals(
            "io.legado.flutter.action.WEB_SERVER_START",
            WebServerForegroundService.ACTION_START,
        )
    }

    @Test
    fun `notification id uses central registry and does not collide`() {
        assertEquals(LegadoNotificationIds.WEB_SERVER, WebServerForegroundService.NOTIFICATION_ID)
        assertNotEquals(
            LegadoNotificationIds.PLAYBACK,
            WebServerForegroundService.NOTIFICATION_ID,
        )
        assertNotEquals(
            LegadoNotificationIds.VIDEO,
            WebServerForegroundService.NOTIFICATION_ID,
        )
    }

    @Test
    fun `notification contract matches batch spec`() {
        assertEquals("legado_web_server", WebServerForegroundService.CHANNEL_ID)
        assertEquals("Web 服务运行中", WebServerForegroundService.NOTIFICATION_TITLE)
        assertEquals("局域网可访问", WebServerForegroundService.NOTIFICATION_TEXT)
        assertEquals(0x1E62, WebServerForegroundService.NOTIFICATION_ID)
    }

    @Test
    fun `isRunning is false before service is created`() {
        assertFalse(WebServerForegroundService.isRunning)
    }

    @Test
    fun `service does not override onTaskRemoved`() {
        // 审查回修 P2：任务划掉后必须保留 FGS 与进程内 Rust server，
        // 不重写 onTaskRemoved（默认 no-op；android:stopWithTask 未开启）。
        val declared = WebServerForegroundService::class.java.declaredMethods
            .map { it.name }
        assertFalse(
            "WebServerForegroundService 不得重写 onTaskRemoved（会撤 FGS 留下孤儿 server）",
            declared.contains("onTaskRemoved"),
        )
    }

    @Test
    fun `permission result is consumed only for notification request code`() {
        assertFalse(
            WebServiceForegroundBridge.onRequestPermissionsResult(
                0x1234,
                intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED),
            ),
        )
        assertTrue(
            WebServiceForegroundBridge.onRequestPermissionsResult(
                WebServiceForegroundBridge.REQUEST_CODE_NOTIFICATION_PERMISSION,
                intArrayOf(android.content.pm.PackageManager.PERMISSION_GRANTED),
            ),
        )
    }
}
