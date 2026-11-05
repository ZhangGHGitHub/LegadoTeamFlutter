package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [设置批5a-1] SystemSettingsBridge 纯逻辑 JVM 单测。
 *
 * 不触 Android 框架实例（无 Robolectric）：只钉住
 * - 通道名与 Dart 侧一致；
 * - 系统设置 action 字符串（TTS/电池优化/兜底）；
 * - 电池优化豁免查询的纯函数内核：正常返回、异常按「未豁免」安全回落；
 * - 包名 URI 拼接。
 *
 * 真实 startActivity 跳转与 PowerManager 查询由设备验收覆盖（MuMu 无 TTS
 * 引擎，系统 TTS 设置页跳转只能验「不崩溃/可回退」）。
 */
class SystemSettingsBridgeTest {

    @Test
    fun `channel name matches dart side`() {
        assertEquals("legado/system_settings", SystemSettingsBridge.CHANNEL)
    }

    @Test
    fun `tts settings action is android public action`() {
        assertEquals(
            "com.android.settings.TTS_SETTINGS",
            SystemSettingsBridge.ACTION_TTS_SETTINGS,
        )
    }

    @Test
    fun `battery optimization action is api23 list page`() {
        assertEquals(
            "android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS",
            SystemSettingsBridge.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
        )
    }

    @Test
    fun `fallback action is system settings home`() {
        assertEquals(
            "android.settings.SETTINGS",
            SystemSettingsBridge.ACTION_SETTINGS_FALLBACK,
        )
    }

    @Test
    fun `isIgnoringBatteryOptimizations returns underlying value`() {
        assertTrue(
            SystemSettingsBridge.isIgnoringBatteryOptimizations { true },
        )
        assertFalse(
            SystemSettingsBridge.isIgnoringBatteryOptimizations { false },
        )
    }

    @Test
    fun `isIgnoringBatteryOptimizations falls back to false on exception`() {
        assertFalse(
            "查询异常不得崩溃/阻断设置页（按未豁免处理）",
            SystemSettingsBridge.isIgnoringBatteryOptimizations {
                throw IllegalStateException("PowerManager unavailable")
            },
        )
    }

    @Test
    fun `battery optimization package uri uses package scheme`() {
        assertEquals(
            "package:io.legado.flutter_legado",
            SystemSettingsBridge.batteryOptimizationPackageUri(
                "io.legado.flutter_legado",
            ),
        )
    }
}
