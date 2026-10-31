package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Web 服务唤醒锁桥（批9b-6）
 *
 * ## 进程级持有（审查回修）
 * Kotlin `object` 单例：锁用 Application Context 创建，跨 Activity / Flutter
 * 引擎重建保持持有（Launcher1-6 变体、Activity 重建、旋转都不换进程）。
 * 释放**只**由 Dart 显式 `setEnabled(false)`（停服 / 关开关）触发，进程被系统
 * 回收时锁随进程消失。因此 Activity.onDestroy 不释放本锁。
 *
 * ## 语义基准
 * 原版 `legado-upstream/app/src/main/java/io/legado/app/service/WebService.kt`
 * （参考版 `legado-with-MD3` 同实现）：
 * - `:76-78` 偏好 `webServiceWakeLock`（默认 false）开 → 同时创建
 *   `PowerManager.PARTIAL_WAKE_LOCK` 与 `WifiManager.WifiLock`
 *   （`WIFI_MODE_FULL_HIGH_PERF`，tag `legado:WebService`，
 *   `setReferenceCounted(false)`）；
 * - `:105` / `:140` 服务创建 / 唤醒请求时 `acquire()`（均无超时）；
 * - `:160` 服务 `onDestroy` 时 `release()`。
 *
 * 本桥成对持有/释放两种锁；Wi-Fi 锁按原版 `wifiLock?.acquire()` 的尽力而为
 * 语义处理（WifiManager 不可用或创建失败时降级为仅 CPU 唤醒锁，不阻断），
 * CPU 唤醒锁失败则向 Dart 回 `result.error`。
 *
 * 刻意不复用 `legado/media_session` 的 `setWakeLock`：那是听书
 * `audioPlayWakeLock` 语义（由播放态驱动，tag `legado:AudioPlayWakeLock`），
 * 共用会与 Web 服务保活互相踩停。
 *
 * 支持方法（Flutter → Android）：
 * - setEnabled: `{enabled: bool}` 幂等持有/释放；成功返回 `isHeld`，
 *   失败 `result.error("wake_lock_failed", ...)`
 * - isHeld: 返回当前是否完整持有（供 Dart 新引擎对账）
 */
object WebServiceWakeLockBridge {

    const val CHANNEL = "legado/web_service_wakelock"

    private const val TAG = "WebServiceWakeLock"

    /** 唤醒锁 tag：与原版 `WebService.kt:77` 逐字一致（CPU 锁与 Wi-Fi 锁共用） */
    internal const val WAKE_LOCK_TAG = "legado:WebService"

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    /** 解析 enabled 参数（缺省/类型不符一律视为关闭，避免误持有） */
    @JvmStatic
    internal fun enabledFromArgument(raw: Any?): Boolean = raw as? Boolean ?: false

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val appContext = context.applicationContext
        when (call.method) {
            "setEnabled" -> {
                val enabled = enabledFromArgument(call.argument("enabled"))
                val failure = if (enabled) acquire(appContext) else release()
                if (failure == null) {
                    result.success(isHeld())
                } else {
                    val action = if (enabled) "获取" else "释放"
                    result.error(
                        "wake_lock_failed",
                        "Web 服务唤醒锁${action}失败：$failure",
                        null,
                    )
                }
            }

            "isHeld" -> result.success(isHeld())

            else -> result.notImplemented()
        }
    }

    /**
     * 是否处于完整持有态：CPU 唤醒锁必须持有；Wi-Fi 锁存在时也必须持有。
     *
     * `wifiLock == null`（WifiManager 不可用 / 创建失败）时只看 CPU 锁，
     * 与原版 `wifiLock?.acquire()` 的可空语义一致。
     */
    @Synchronized
    fun isHeld(): Boolean {
        if (wakeLock?.isHeld != true) return false
        val wifi = wifiLock ?: return true
        return wifi.isHeld
    }

    /**
     * 幂等持有两种锁：已持有则跳过，否则 acquire（无超时，对齐原版）。
     *
     * @return 错误描述；null 表示成功
     */
    @SuppressLint("WakelockTimeout")
    @Synchronized
    private fun acquire(context: Context): String? {
        return try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                ?: return "PowerManager 不可用"
            val lock = wakeLock ?: powerManager
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
            if (!lock.isHeld) lock.acquire()
            acquireWifiLock(context)
            null
        } catch (e: Exception) {
            Log.w(TAG, "持有 Web 服务唤醒锁失败：${e.message}")
            e.message ?: e.javaClass.simpleName
        }
    }

    /**
     * 幂等释放两种锁：未持有安全跳过。
     *
     * @return 错误描述；null 表示成功（含本就没持有）
     */
    @Synchronized
    private fun release(): String? {
        var failure: String? = null
        try {
            val lock = wakeLock
            if (lock?.isHeld == true) lock.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 Web 服务 CPU 唤醒锁失败：${e.message}")
            failure = e.message ?: e.javaClass.simpleName
        }
        try {
            val lock = wifiLock
            if (lock?.isHeld == true) lock.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 Web 服务 Wi-Fi 锁失败：${e.message}")
            failure = failure ?: (e.message ?: e.javaClass.simpleName)
        }
        return failure
    }

    /**
     * 尽力而为地持有 Wi-Fi 锁（对齐原版 `wifiLock?.acquire()`）。
     *
     * 失败只降级为「仅 CPU 唤醒锁」，不计入 setEnabled 失败——Wi-Fi 锁是
     * 原版的附加省电项，CPU 锁才是「Web 服务不被休眠」的主保障。
     */
    @Suppress("DEPRECATION")
    private fun acquireWifiLock(context: Context) {
        try {
            val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager == null) {
                Log.w(TAG, "WifiManager 不可用，跳过 Wi-Fi 锁（仅持 CPU 唤醒锁）")
                return
            }
            val lock = wifiLock ?: wifiManager
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, WAKE_LOCK_TAG)
                ?.apply { setReferenceCounted(false) }
                ?.also { wifiLock = it }
            if (lock != null && !lock.isHeld) lock.acquire()
        } catch (e: Exception) {
            Log.w(TAG, "持有 Wi-Fi 锁失败（降级为仅 CPU 唤醒锁）：${e.message}")
        }
    }
}
