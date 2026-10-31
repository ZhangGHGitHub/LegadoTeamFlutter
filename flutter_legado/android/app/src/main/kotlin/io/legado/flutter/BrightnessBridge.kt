package io.legado.flutter

import android.content.ContentResolver
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统亮度控制桥接
 * 
 * 提供 Flutter 访问 Android 系统亮度设置的能力
 */
class BrightnessBridge {

    companion object {
        private const val CHANNEL_BRIGHTNESS = "io.legado.app/brightness"
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: MainActivity) {
        when (call.method) {
            "getSystemBrightness" -> {
                try {
                    val brightness = getSystemBrightness(activity)
                    result.success(brightness)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "获取系统亮度失败: ${e.message}", null)
                }
            }
            "setSystemBrightness" -> {
                try {
                    val brightness = call.arguments as Int
                    setSystemBrightness(activity, brightness)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "设置系统亮度失败: ${e.message}", null)
                }
            }
            "isBrightnessSupported" -> {
                try {
                    val supported = isBrightnessSupported(activity)
                    result.success(supported)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "检查亮度支持失败: ${e.message}", null)
                }
            }
            "isAutoBrightness" -> {
                try {
                    val auto = isAutoBrightness(activity)
                    result.success(auto)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "获取自动亮度状态失败: ${e.message}", null)
                }
            }
            "setAutoBrightness" -> {
                try {
                    val auto = call.arguments as Boolean
                    setAutoBrightness(activity, auto)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "设置自动亮度失败: ${e.message}", null)
                }
            }
            // [批1b-1] keepLight 保持亮屏：阅读器进入/退出/设置变更时由 Dart
            // 调用，对 Activity window 增删 FLAG_KEEP_SCREEN_ON（对齐参考版
            // ReadBookController.keepScreenOn：退出阅读页即恢复系统息屏策略，
            // 非 PARTIAL_WAKE_LOCK、不引入 wakelock 包）。失败经 result.error
            // 回传，不向引擎抛未捕获异常（D2 教训：原生层异常主线程 FATAL）。
            "setKeepScreenOn" -> {
                try {
                    val enabled = call.arguments as? Boolean ?: false
                    setKeepScreenOn(activity, enabled)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("BRIGHTNESS_ERROR", "设置保持亮屏失败: ${e.message}", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * [批1b-1] 阅读页保持屏幕常亮（FLAG_KEEP_SCREEN_ON）
     *
     * FLAG_KEEP_SCREEN_ON 为 window 级最省电的常亮方式：仅 Activity 前台
     * 可见时生效，页面销毁/离开前台系统自动恢复息屏策略，无泄漏面
     * （对齐参考版 ReadBookController.keepScreenOn 与 upstream
     * ReadBookActivity 的 keepScreenOn 实现）。
     */
    private fun setKeepScreenOn(activity: MainActivity, enabled: Boolean) {
        val current =
            (activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0
        if (enabled == current) return
        if (enabled) {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /**
     * 获取系统亮度 (0-255)
     */
    private fun getSystemBrightness(activity: MainActivity): Int {
        val resolver: ContentResolver = activity.contentResolver
        return try {
            Settings.System.getInt(resolver, Settings.System.SCREEN_BRIGHTNESS)
        } catch (e: Settings.SettingNotFoundException) {
            // 如果找不到设置，尝试从窗口属性获取
            val layoutParams = activity.window.attributes
            val brightness = layoutParams.screenBrightness
            if (brightness < 0) {
                // 系统默认亮度
                128
            } else {
                (brightness * 255).toInt()
            }
        }
    }

    /**
     * 设置系统亮度 (0-255)
     */
    private fun setSystemBrightness(activity: MainActivity, brightness: Int) {
        val clampedBrightness = brightness.coerceIn(0, 255)
        
        // 方法 1: 设置系统全局亮度（需要 WRITE_SETTINGS 权限）
        try {
            val resolver: ContentResolver = activity.contentResolver
            Settings.System.putInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS,
                clampedBrightness
            )
        } catch (e: Exception) {
            // 如果没有权限，只设置当前窗口亮度
            val layoutParams = activity.window.attributes
            layoutParams.screenBrightness = clampedBrightness / 255f
            activity.window.attributes = layoutParams
        }
    }

    /**
     * 检查是否支持亮度调节
     */
    private fun isBrightnessSupported(activity: MainActivity): Boolean {
        return try {
            val resolver: ContentResolver = activity.contentResolver
            Settings.System.getInt(resolver, Settings.System.SCREEN_BRIGHTNESS)
            true
        } catch (e: Settings.SettingNotFoundException) {
            false
        }
    }

    /**
     * 获取自动亮度模式
     */
    private fun isAutoBrightness(activity: MainActivity): Boolean {
        return try {
            val resolver: ContentResolver = activity.contentResolver
            val mode = Settings.System.getInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE
            )
            mode == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
        } catch (e: Settings.SettingNotFoundException) {
            false
        }
    }

    /**
     * 设置自动亮度模式
     */
    private fun setAutoBrightness(activity: MainActivity, auto: Boolean) {
        val resolver: ContentResolver = activity.contentResolver
        val mode = if (auto) {
            Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
        } else {
            Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
        }
        
        try {
            Settings.System.putInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                mode
            )
        } catch (e: Exception) {
            // 如果没有权限，忽略
        }
    }
}
