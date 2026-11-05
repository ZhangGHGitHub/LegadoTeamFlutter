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
            // [审查 P2-2] 不再要求 VALIDATED/INTERNET：局域网 Wi-Fi、未完成
            // 联网校验的热点也属于 Wi-Fi，应允许加载封面。
            val activeCaps = manager.activeNetwork?.let {
                manager.getNetworkCapabilities(it)
            }
            if (activeCaps != null &&
                isWifiCapability(
                    activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                )
            ) {
                return true
            }
            // VPN/非默认网络：activeNetwork 可能是 VPN transport，但底层仍是
            // Wi-Fi；遍历当前所有网络，任一「已连接（有 LinkProperties）」且
            // 具备 WIFI transport 即视为 Wi-Fi。
            return manager.allNetworks.any { network ->
                val caps = manager.getNetworkCapabilities(network) ?: return@any false
                val link = manager.getLinkProperties(network)
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    link?.interfaceName != null
            }
        }
        @Suppress("DEPRECATION")
        val info = manager.activeNetworkInfo ?: return false
        @Suppress("DEPRECATION")
        return isWifiType(type = info.type, connected = info.isConnected)
    }

    /**
     * 纯函数（JVM 单测可覆盖）：具备 Wi-Fi transport 即为 Wi-Fi。
     *
     * 不叠加 NET_CAPABILITY_VALIDATED/INTERNET：参考版「仅 Wi-Fi」语义是
     * 省流（蜂窝不加载），局域网/内网 Wi-Fi 无外网也应放行。
     */
    internal fun isWifiCapability(hasWifiTransport: Boolean): Boolean =
        hasWifiTransport

    /** 纯函数（JVM 单测可覆盖）：旧 API 的 Wi-Fi 类型 + 已连接判定 */
    @Suppress("DEPRECATION")
    internal fun isWifiType(type: Int, connected: Boolean): Boolean =
        type == ConnectivityManager.TYPE_WIFI && connected
}
