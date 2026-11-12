package io.legado.flutter

import android.content.pm.PackageManager
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 「文字操作显示搜索」组件启停映射单测。
 *
 * 钉住 Dart 开关值 → PackageManager 组件状态的映射方向：
 * true 必须走 COMPONENT_ENABLED_STATE_ENABLED、false 必须走
 * COMPONENT_ENABLED_STATE_DISABLED（与原版 OtherConfigFragment
 * setProcessTextEnable 一致；反向映射会让开关语义颠倒）。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测纯函数内核，不触 PackageManager 实例。
 */
class ProcessTextBridgeTest {

    @Test
    fun `enabled maps to COMPONENT_ENABLED_STATE_ENABLED`() {
        assertEquals(
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            ProcessTextBridge.desiredState(true)
        )
    }

    @Test
    fun `disabled maps to COMPONENT_ENABLED_STATE_DISABLED`() {
        assertEquals(
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            ProcessTextBridge.desiredState(false)
        )
    }
}
