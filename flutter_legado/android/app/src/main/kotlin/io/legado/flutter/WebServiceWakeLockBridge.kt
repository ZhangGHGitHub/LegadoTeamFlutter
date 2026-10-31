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
 * （参考版 `legado-with-MD3/.../service/WebService.kt:68,69-74,75-81,92-93,133-134,145-146`
 * 电源语义一致）：
 * - `:76` 偏好 `webServiceWakeLock`（默认 false），`:77-82` CPU 唤醒锁创建，
 *   `:83-89` 同 tag `WifiLock` 创建（`WIFI_MODE_FULL_HIGH_PERF`，
 *   tag `legado:WebService`，均 `setReferenceCounted(false)`）；
 * - `:105-106` / `:140-141` 服务创建 / 唤醒请求时成对 `acquire()`（均无超时）；
 * - `:160-161` 服务 `onDestroy` 时成对 `release()`。
 *
 * 实际持有/释放逻辑在 [WebServiceWakeLockSet]（与 Android 框架解耦，可用
 * fake 锁做 JVM 单测）：
 * - Wi-Fi 锁获取失败按原版 `wifiLock?.acquire()` 尽力而为降级为仅 CPU 锁，
 *   且**只在 acquire 成功后才缓存句柄**——否则字段非空但未持有会让
 *   `isHeld=false`，Dart 误判未持锁而跳过 release，CPU 锁残留；
 * - 释放严格「先 Wi-Fi 后 CPU」，成功后清空对应句柄；Wi-Fi 失败保留 CPU 锁
 *   并回 error，绝不留下「CPU 已放、Wi-Fi 仍持」的不可见单锁；
 *   CPU 失败保留句柄（`isHeld` 仍 true），Dart 可重试。
 *
 * 刻意不复用 `legado/media_session` 的 `setWakeLock`：那是听书
 * `audioPlayWakeLock` 语义（由播放态驱动，tag 不同），共用会互相踩停。
 *
 * 支持方法（Flutter → Android）：
 * - setEnabled: `{enabled: bool}` 幂等持有/释放；成功返回 `isHeld`，
 *   失败 `result.error("wake_lock_failed", ...)`
 * - isHeld: 返回当前是否完整持有（供 Dart 新引擎对账）
 */
object WebServiceWakeLockBridge {

    const val CHANNEL = "legado/web_service_wakelock"

    /** 唤醒锁 tag：与原版 `WebService.kt` 的 `"legado:WebService"` 逐字一致 */
    internal const val WAKE_LOCK_TAG = "legado:WebService"

    private const val TAG = "WebServiceWakeLock"

    /** 进程级锁状态机（首次调用时用 Application Context 建工厂） */
    private var lockSet: WebServiceWakeLockSet? = null

    /** 解析 enabled 参数（缺省/类型不符一律视为关闭，避免误持有） */
    @JvmStatic
    internal fun enabledFromArgument(raw: Any?): Boolean = raw as? Boolean ?: false

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "setEnabled" -> {
                val enabled = enabledFromArgument(call.argument("enabled"))
                val locks = lockSet(context)
                val failure = if (enabled) locks.acquire() else locks.release()
                if (failure == null) {
                    result.success(locks.isHeld())
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

    /** 是否处于完整持有态（未初始化过锁时为 false） */
    @Synchronized
    fun isHeld(): Boolean = lockSet?.isHeld() ?: false

    @Synchronized
    private fun lockSet(context: Context): WebServiceWakeLockSet {
        lockSet?.let { return it }
        val appContext = context.applicationContext
        return WebServiceWakeLockSet(
            createCpuLock = { createCpuLock(appContext) },
            createWifiLock = { createWifiLock(appContext) },
            logWarning = { message -> Log.w(TAG, message) },
        ).also { lockSet = it }
    }

    private fun createCpuLock(context: Context): WakeLockHandle {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: throw IllegalStateException("PowerManager 不可用")
        val lock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        lock.setReferenceCounted(false)
        return PowerWakeLockHandle(lock)
    }

    @Suppress("DEPRECATION")
    private fun createWifiLock(context: Context): WakeLockHandle? {
        val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        if (wifiManager == null) {
            Log.w(TAG, "WifiManager 不可用，跳过 Wi-Fi 锁（仅持 CPU 唤醒锁）")
            return null
        }
        val lock = wifiManager.createWifiLock(
            WifiManager.WIFI_MODE_FULL_HIGH_PERF,
            WAKE_LOCK_TAG,
        ) ?: return null
        lock.setReferenceCounted(false)
        return WifiWakeLockHandle(lock)
    }
}

/** 可测试的锁句柄：真实实现包装 PowerManager.WakeLock / WifiManager.WifiLock */
internal interface WakeLockHandle {
    val isHeld: Boolean
    fun acquire()
    fun release()
}

internal class PowerWakeLockHandle(
    private val lock: PowerManager.WakeLock,
) : WakeLockHandle {
    override val isHeld: Boolean get() = lock.isHeld

    @SuppressLint("WakelockTimeout")
    override fun acquire() = lock.acquire()

    override fun release() = lock.release()
}

internal class WifiWakeLockHandle(
    private val lock: WifiManager.WifiLock,
) : WakeLockHandle {
    override val isHeld: Boolean get() = lock.isHeld
    override fun acquire() = lock.acquire()
    override fun release() = lock.release()
}

/**
 * 两种锁的持有/释放状态机（与 Android 框架解耦，JVM 单测可注入 fake）。
 *
 * 不变量（审查 P2 边界）：
 * - Wi-Fi 句柄只在 acquire 成功后才缓存；获取失败保持 null，[isHeld] 只看
 *   CPU 锁（降级语义），避免「字段已缓存但未持有 → isHeld=false」导致 CPU
 *   锁对 Dart 不可见、停止时跳过 release；
 * - release 成功后清空对应句柄；CPU 释放失败保留句柄（[isHeld] 仍 true，
 *   Dart 会重试）；Wi-Fi 释放失败保留 CPU 锁并回 error，不留 Wi-Fi 单锁。
 */
internal class WebServiceWakeLockSet(
    private val createCpuLock: () -> WakeLockHandle,
    private val createWifiLock: () -> WakeLockHandle?,
    private val logWarning: (String) -> Unit = {},
) {
    private var cpuLock: WakeLockHandle? = null
    private var wifiLock: WakeLockHandle? = null

    /** 完整持有：CPU 必须持有；Wi-Fi 句柄存在时也必须持有 */
    @Synchronized
    fun isHeld(): Boolean {
        if (cpuLock?.isHeld != true) return false
        val wifi = wifiLock ?: return true
        return wifi.isHeld
    }

    /** 幂等持有；返回错误描述（null=成功，Wi-Fi 失败降级不报错） */
    @Synchronized
    fun acquire(): String? {
        return try {
            val cpu = cpuLock ?: createCpuLock().also { cpuLock = it }
            if (!cpu.isHeld) cpu.acquire()
            acquireWifiLock()
            null
        } catch (e: Exception) {
            logWarning("持有 Web 服务 CPU 唤醒锁失败：${e.message}")
            e.message ?: e.javaClass.simpleName
        }
    }

    /** 幂等释放；返回错误描述（null=成功，含本就没持有） */
    @Synchronized
    fun release(): String? {
        // 先 Wi-Fi 后 CPU：Wi-Fi 失败时保留 CPU 锁，避免单锁残留
        val wifi = wifiLock
        if (wifi != null) {
            try {
                if (wifi.isHeld) wifi.release()
                wifiLock = null
            } catch (e: Exception) {
                logWarning("释放 Wi-Fi 锁失败（保留 CPU 锁，避免 Wi-Fi 单锁）：${e.message}")
                return e.message ?: e.javaClass.simpleName
            }
        }
        val cpu = cpuLock
        if (cpu != null) {
            try {
                if (cpu.isHeld) cpu.release()
                cpuLock = null
            } catch (e: Exception) {
                logWarning("释放 CPU 唤醒锁失败：${e.message}")
                return e.message ?: e.javaClass.simpleName
            }
        }
        return null
    }

    /**
     * 尽力而为持有 Wi-Fi 锁（对齐原版 `wifiLock?.acquire()`）。
     *
     * 本地创建 → acquire 成功后才赋给字段；失败保持 null 并回滚本地句柄，
     * 保证 [isHeld] 退化为「只看 CPU 锁」，CPU 锁始终对 Dart 可见。
     */
    private fun acquireWifiLock() {
        try {
            val existing = wifiLock
            if (existing != null) {
                if (!existing.isHeld) existing.acquire()
                return
            }
            val created = createWifiLock() ?: return
            try {
                created.acquire()
            } catch (e: Exception) {
                // acquire 失败：回滚本地句柄（若已部分生效则释放），字段保持 null
                try {
                    created.release()
                } catch (_: Exception) {
                }
                throw e
            }
            wifiLock = created
        } catch (e: Exception) {
            logWarning("持有 Wi-Fi 锁失败（降级为仅 CPU 唤醒锁）：${e.message}")
        }
    }

    internal fun cpuLockForTest(): WakeLockHandle? = cpuLock

    internal fun wifiLockForTest(): WakeLockHandle? = wifiLock
}
