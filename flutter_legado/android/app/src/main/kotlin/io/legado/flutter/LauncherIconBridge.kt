package io.legado.flutter

import android.app.Activity
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 更换桌面启动图标（对齐原版 io.legado.app.help.LauncherIconHelp.changeIcon）。
 *
 * 机制：manifest 中声明 6 个默认禁用的 Launcher1~6 Activity，各自携带
 * launcher1~6 图标；切换时用 PackageManager.setComponentEnabledSetting
 * 启用选中项、禁用其余项（选变体时同时禁用 MainActivity，选默认时反之）。
 * Android 8.0（API 26）以下不支持矢量自适应图标，拒绝并回报错误。
 */
object LauncherIconBridge {
    const val CHANNEL = "legado/launcher_icon"

    /** Dart 侧可选值：iconMain（默认）、icon1~icon6（对齐原版 icon_names 数组） */
    private val launcherIndexes = listOf("icon1", "icon2", "icon3", "icon4", "icon5", "icon6")

    /** 变体 Activity 真实类名（namespace io.legado.flutter，与 manifest .LauncherN 一致） */
    private val launcherClasses = listOf(
        Launcher1::class.java,
        Launcher2::class.java,
        Launcher3::class.java,
        Launcher4::class.java,
        Launcher5::class.java,
        Launcher6::class.java
    )

    private const val TAG = "LauncherIconBridge"

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "set" -> {
                val icon = call.argument<String>("icon")
                try {
                    changeIcon(activity, icon)
                    result.success(null)
                } catch (e: Exception) {
                    Log.e(TAG, "changeIcon failed icon=$icon", e)
                    result.error("LAUNCHER_ICON_ERROR", e.message ?: "更换图标失败", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun changeIcon(activity: Activity, icon: String?) {
        if (Build.VERSION.SDK_INT < 26) {
            // 对齐原版 change_icon_error：矢量图标在 Android 8.0 以下不支持
            throw IllegalStateException("Android 8.0 以下不支持更换图标")
        }
        val pm = activity.packageManager
        var hasEnabled = false
        launcherIndexes.forEachIndexed { i, name ->
            // 注意：Class.name 取类全名；勿写 .javaClass.name（会取到
            // java.lang.Class 自身的名字，导致组件不存在异常）
            val component = ComponentName(activity, launcherClasses[i].name)
            if (name == icon) {
                hasEnabled = true
                // 启用选中的变体 Activity
                pm.setComponentEnabledSetting(
                    component,
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP
                )
            } else {
                // 禁用其余变体
                pm.setComponentEnabledSetting(
                    component,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP
                )
            }
        }
        // 选变体时禁用主 Activity（默认图标），选默认时恢复
        val main = ComponentName(activity, MainActivity::class.java.name)
        pm.setComponentEnabledSetting(
            main,
            if (hasEnabled) {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            },
            PackageManager.DONT_KILL_APP
        )
    }
}
