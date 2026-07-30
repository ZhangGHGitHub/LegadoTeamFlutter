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
            else -> result.notImplemented()
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
