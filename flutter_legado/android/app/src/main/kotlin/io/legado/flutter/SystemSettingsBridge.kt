package io.legado.flutter

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统设置跳转桥（设置批5a-1）
 *
 * ## 职责
 * 「朗读设置」页需要两个系统级动作，Flutter 侧无法直接发起：
 * - `openTtsSettings`：打开系统「文字转语音（TTS）输出」设置页，让用户
 *   安装/切换系统 TTS 引擎（对齐原版 `IntentHelp.openSysTtsConfig`）；
 * - `openBatteryOptimizationSettings`：打开系统电池优化列表，供用户手动把
 *   本应用加入「不优化」名单（后台保活；不申请
 *   `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 权限，走列表页由用户决定）；
 * - `isIgnoringBatteryOptimizations`：查询本应用是否已豁免（页面副题展示）。
 *
 * 所有动作失败（Activity 不存在/安全异常）一律 `result.success(false)`，
 * 绝不崩溃；Dart 侧据此提示「请手动在系统设置中打开」。
 *
 * ## 可测试性
 * 纯函数（action 常量、豁免查询包装）与 Android 框架解耦，JVM 单测直接
 * 钉住；真实 `startActivity` 由设备验收覆盖。
 */
object SystemSettingsBridge {

    const val CHANNEL = "legado/system_settings"

    private const val TAG = "SystemSettings"

    /** 系统 TTS 输出设置页（Android 公开 action，无官方 Settings 常量） */
    internal const val ACTION_TTS_SETTINGS = "com.android.settings.TTS_SETTINGS"

    /** 电池优化列表页（API 23+；无需特殊权限） */
    internal const val ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS =
        "android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS"

    /** 兜底：系统设置首页 */
    internal const val ACTION_SETTINGS_FALLBACK = "android.settings.SETTINGS"

    /**
     * 豁免查询的纯函数内核（便于 JVM 单测注入 fake）。
     *
     * 任何异常（PowerManager 为空、系统不支持）按「未豁免」处理——
     * 页面只展示状态，不应因查询失败阻断设置项。
     */
    @JvmStatic
    internal fun isIgnoringBatteryOptimizations(check: () -> Boolean): Boolean =
        try {
            check()
        } catch (_: Exception) {
            false
        }

    fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context,
    ) {
        when (call.method) {
            "openTtsSettings" -> result.success(
                openSettings(context, ACTION_TTS_SETTINGS)
            )

            "openBatteryOptimizationSettings" -> result.success(
                openSettings(context, ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            )

            "isIgnoringBatteryOptimizations" -> {
                val powerManager = context.getSystemService(Context.POWER_SERVICE)
                    as? PowerManager
                val packageName = context.packageName
                result.success(
                    isIgnoringBatteryOptimizations {
                        powerManager?.isIgnoringBatteryOptimizations(packageName)
                            ?: false
                    }
                )
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 打开指定系统设置页；Activity 不存在时回退系统设置首页。
     *
     * @return true=已成功发起跳转（含回退页）；false=全部失败
     */
    private fun openSettings(context: Context, action: String): Boolean {
        val appContext = context.applicationContext ?: context
        if (startActivity(appContext, action)) return true
        Log.w(TAG, "打开系统设置失败（action=$action），回退系统设置首页")
        return startActivity(appContext, ACTION_SETTINGS_FALLBACK)
    }

    private fun startActivity(context: Context, action: String): Boolean {
        return try {
            val intent = Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            // ActivityNotFoundException / SecurityException 等：交由调用方提示
            Log.w(TAG, "startActivity 失败（action=$action）：${e.message}")
            false
        }
    }

    /** 电池优化豁免查询 URI 形态（供文档/测试核对包名拼接） */
    @JvmStatic
    internal fun batteryOptimizationPackageUri(packageName: String): String =
        "package:$packageName"
}
