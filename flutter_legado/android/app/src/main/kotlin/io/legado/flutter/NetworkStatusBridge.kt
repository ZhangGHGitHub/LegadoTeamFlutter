package io.legado.flutter

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 网络状态桥（设置批6b-1「仅 WiFi 加载封面」）。
 *
 * Dart 侧 `legado/network_status` / `isWifi` 返回当前是否为 Wi-Fi：
 * - Android 6.0+（API 23）：NetworkCapabilities.hasTransport(WIFI)；
 * - 旧版本：activeNetworkInfo.type == TYPE_WIFI && isConnected。
 *
 * 任一异常（权限缺失/系统服务不可用/查询失败）一律 fail-open 返回 true：
 * 「仅 WiFi」是省流偏好，误判为蜂窝会导致封面整屏空白，宁可多加载。
 * ACCESS_NETWORK_STATE 已在 AndroidManifest 声明。
 */
object NetworkStatusBridge {
    const val CHANNEL = "legado/network_status"
    private const val TAG = "NetworkStatusBridge"

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "isWifi" -> {
                val isWifi = try {
                    queryIsWifi(context)
                } catch (e: Exception) {
                    Log.e(TAG, "isWifi 查询失败，按 WiFi 处理（fail-open）", e)
                    true
                }
                result.success(isWifi)
            }
            else -> result.notImplemented()
        }
    }

    private fun queryIsWifi(context: Context): Boolean {
        val manager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = manager.activeNetwork ?: return false
            val capabilities = manager.getNetworkCapabilities(network) ?: return false
            return isWifiCapability(
                hasWifiTransport = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            )
        }
        @Suppress("DEPRECATION")
        val info = manager.activeNetworkInfo ?: return false
        @Suppress("DEPRECATION")
        return isWifiType(type = info.type, connected = info.isConnected)
    }

    /**
     * 纯函数（JVM 单测可覆盖）：Wi-Fi 传输能力优先；
     * 未验证但具备 Internet 能力的 Wi-Fi 也算（部分局域网/热点场景），
     * 避免刚连上尚未完成验证时被误判为蜂窝。
     */
    internal fun isWifiCapability(
        hasWifiTransport: Boolean,
        validated: Boolean,
        hasInternet: Boolean,
    ): Boolean = hasWifiTransport && (validated || hasInternet)

    /** 纯函数（JVM 单测可覆盖）：旧 API 的 Wi-Fi 类型 + 已连接判定 */
    @Suppress("DEPRECATION")
    internal fun isWifiType(type: Int, connected: Boolean): Boolean =
        type == ConnectivityManager.TYPE_WIFI && connected
}
