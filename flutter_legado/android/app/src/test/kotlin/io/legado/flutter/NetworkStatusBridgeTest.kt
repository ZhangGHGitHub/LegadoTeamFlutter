package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [设置批6b-1] NetworkStatusBridge 纯逻辑单测（JVM，不触 Android 框架实例）。
 *
 * 覆盖：通道名与 Dart 侧一致；Wi-Fi 能力判定（已验证/有 Internet 能力）；
 * 旧 API 的 Wi-Fi 类型 + 已连接判定；蜂窝/无网不误判为 Wi-Fi。
 */
class NetworkStatusBridgeTest {

    @Test
    fun `channel name matches dart side`() {
        assertEquals("legado/network_status", NetworkStatusBridge.CHANNEL)
    }

    @Test
    fun `wifi transport with validated or internet counts as wifi`() {
        assertTrue(NetworkStatusBridge.isWifiCapability(true, true, true))
        assertTrue("刚连上尚未验证但具备 Internet 能力也算", NetworkStatusBridge.isWifiCapability(true, false, true))
    }

    @Test
    fun `cellular transport is not wifi`() {
        assertFalse(NetworkStatusBridge.isWifiCapability(false, true, true))
        assertFalse(NetworkStatusBridge.isWifiCapability(false, false, false))
    }

    @Test
    fun `wifi transport without internet capability is not wifi`() {
        assertFalse(NetworkStatusBridge.isWifiCapability(true, false, false))
    }

    @Test
    fun `legacy wifi type requires connected`() {
        // ConnectivityManager.TYPE_WIFI = 1（编译期常量，JVM 单测可直接断言）
        assertTrue(NetworkStatusBridge.isWifiType(1, true))
        assertFalse(NetworkStatusBridge.isWifiType(1, false))
        assertFalse("TYPE_MOBILE = 0", NetworkStatusBridge.isWifiType(0, true))
    }
}
