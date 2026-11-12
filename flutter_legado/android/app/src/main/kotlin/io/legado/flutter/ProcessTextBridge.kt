package io.legado.flutter

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 「文字操作显示搜索」开关（pref 键 process_text）。
 *
 * 对齐原版 OtherConfigFragment.isProcessTextEnabled/setProcessTextEnable
 * （legado-upstream OtherConfigFragment.kt:444-460）：原版启停承载
 * ACTION_PROCESS_TEXT intent-filter 的 SharedReceiverActivity 组件；本工程
 * 用独立 activity-alias `.ProcessTextAlias`（targetActivity=.MainActivity）
 * 承载同一 intent-filter，启停它就等价于「系统文字操作菜单是否显示本应用」，
 * 且不会影响主 Activity/桌面入口。
 *
 * 组件状态语义：
 * - COMPONENT_ENABLED_STATE_DEFAULT（从未设置）→ manifest 中 enabled=true，
 *   视为启用；
 * - 仅 COMPONENT_ENABLED_STATE_DISABLED 视为关闭（与原版 isProcessTextEnabled
 *   `!= COMPONENT_ENABLED_STATE_DISABLED` 判定一致）。
 */
object ProcessTextBridge {
    const val CHANNEL = "legado/process_text"

    private const val TAG = "ProcessTextBridge"

    /** activity-alias 组件名（manifest `.ProcessTextAlias`，namespace io.legado.flutter） */
    private const val ALIAS_CLASS = "io.legado.flutter.ProcessTextAlias"

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "isEnabled" -> {
                try {
                    result.success(isEnabled(context))
                } catch (e: Exception) {
                    Log.e(TAG, "isEnabled failed", e)
                    result.error("PROCESS_TEXT_ERROR", e.message ?: "读取组件状态失败", null)
                }
            }
            "setEnabled" -> {
                val enabled = call.argument<Boolean>("enabled")
                if (enabled == null) {
                    result.error("INVALID_ARGS", "缺少 enabled 参数", null)
                    return
                }
                try {
                    setEnabled(context, enabled)
                    result.success(enabled)
                } catch (e: Exception) {
                    Log.e(TAG, "setEnabled failed enabled=$enabled", e)
                    result.error("PROCESS_TEXT_ERROR", e.message ?: "设置组件状态失败", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun isEnabled(context: Context): Boolean {
        val state = context.packageManager.getComponentEnabledSetting(component(context))
        return state != PackageManager.COMPONENT_ENABLED_STATE_DISABLED
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context.packageManager.setComponentEnabledSetting(
            component(context),
            desiredState(enabled),
            PackageManager.DONT_KILL_APP
        )
    }

    /**
     * 开关 → PackageManager 组件状态（纯函数，供 JVM 单测钉住映射方向）。
     */
    fun desiredState(enabled: Boolean): Int = if (enabled) {
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
    } else {
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED
    }

    private fun component(context: Context): ComponentName =
        ComponentName(context.packageName, ALIAS_CLASS)
}
