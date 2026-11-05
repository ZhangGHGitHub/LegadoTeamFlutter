package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [设置批6b-1] NetworkStatusBridge 纯逻辑单测（JVM，不触 Android 框架实例）。
 *
 * 覆盖：通道名与 Dart 侧一致；Wi-Fi transport 判定（局域网/未验证 Wi-Fi 也
 * 放行，[审查 P2-2]）；旧 API 的 Wi-Fi 类型 + 已连接判定；蜂窝不误判为 Wi-Fi。
 */
class NetworkStatusBridgeTest {

    @Test
    fun `channel name matches dart side`() {
        assertEquals("legado/network_status", NetworkStatusBridge.CHANNEL)
    }

    @Test
    fun `wifi transport counts as wifi even without internet validation`() {
        // 局域网/未完成联网校验的 Wi-Fi（无 VALIDATED/INTERNET）仍应放行
        assertTrue("局域网 Wi-Fi 也属于 Wi-Fi", NetworkStatusBridge.isWifiCapability(true))
    }

    @Test
    fun `cellular transport is not wifi`() {
        assertFalse(NetworkStatusBridge.isWifiCapability(false))
    }

    @Test
    fun `legacy wifi type requires connected`() {
        // ConnectivityManager.TYPE_WIFI = 1（编译期常量，JVM 单测可直接断言）
        assertTrue(NetworkStatusBridge.isWifiType(1, true))
        assertFalse(NetworkStatusBridge.isWifiType(1, false))
        assertFalse("TYPE_MOBILE = 0", NetworkStatusBridge.isWifiType(0, true))
    }
}
