package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Web 服务唤醒锁桥（批9b-6）
 *
 * 对齐原版 `legado-upstream/app/src/main/java/io/legado/app/service/WebService.kt`
 * （参考版 `legado-with-MD3` 同实现）：
 * - `:76-78` 偏好 `webServiceWakeLock`（默认 false）开 → `PowerManager`
 *   `newWakeLock(PARTIAL_WAKE_LOCK, "legado:WebService")` +
 *   `setReferenceCounted(false)`；
 * - `:104` / `:139` 服务创建 / 唤醒请求时 `acquire()`（不带超时）；
 * - `:159` 服务 `onDestroy` 时 `release()`。
 *
 * 本仓库 Web 服务由进程内 Rust server 承载（无 Android 前台服务），因此这里只
 * 复刻「服务运行 + 开关开 → 持 CPU 唤醒锁」的电源语义，不含 Wi-Fi 锁
 *（参考版未在该桥引入 Wi-Fi 锁差异，按原版 `PowerManager` 部分对齐即可）。
 *
 * 刻意不复用 `legado/media_session` 的 `setWakeLock`：那是听书
 * `audioPlayWakeLock` 语义（由播放态驱动，tag `legado:AudioPlayWakeLock`），
 * 共用会与 Web 服务保活互相踩停。
 *
 * 支持方法（Flutter → Android）：
 * - setEnabled: `{enabled: bool}` 幂等设置持有/释放
 */
class WebServiceWakeLockBridge {

    companion object {
        const val CHANNEL = "legado/web_service_wakelock"

        private const val TAG = "WebServiceWakeLock"

        /** 唤醒锁 tag：与原版 `WebService.kt:77` 逐字一致 */
        internal const val WAKE_LOCK_TAG = "legado:WebService"

        /** 解析 enabled 参数（缺省/类型不符一律视为关闭，避免误持有） */
        @JvmStatic
        internal fun enabledFromArgument(raw: Any?): Boolean = raw as? Boolean ?: false
    }

    private var wakeLock: PowerManager.WakeLock? = null

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "setEnabled" -> {
                setEnabled(
                    context.applicationContext,
                    enabledFromArgument(call.argument("enabled")),
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 幂等设置唤醒锁：
     * - `true`：已持有则跳过，否则 `acquire()`（无超时，对齐原版）；
     * - `false`：未持有安全返回，持有则 `release()`。
     *
     * 任何平台异常（缺 `WAKE_LOCK` 权限 / 系统限制）只记日志，不让异常穿透
     * MethodChannel 主线程。`setReferenceCounted(false)` 下重复 acquire/release
     * 不会计数失衡。
     */
    @SuppressLint("WakelockTimeout")
    fun setEnabled(context: Context, enabled: Boolean) {
        if (!enabled) {
            releaseQuietly()
            return
        }
        try {
            val lock = wakeLock ?: newWakeLock(context).also { wakeLock = it }
            if (!lock.isHeld) lock.acquire()
        } catch (e: Exception) {
            Log.w(TAG, "持有 Web 服务唤醒锁失败：${e.message}")
        }
    }

    /** 释放唤醒锁（未持有时为空操作；Activity 销毁 / 引擎卸载兜底调用） */
    fun releaseQuietly() {
        try {
            val lock = wakeLock ?: return
            if (lock.isHeld) lock.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 Web 服务唤醒锁失败：${e.message}")
        }
    }

    private fun newWakeLock(context: Context): PowerManager.WakeLock {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
        }
    }
}
