package io.legado.flutter

import java.security.MessageDigest

/**
 * 批25b P2-2：分享文本一次性消费判定（纯 JVM 逻辑，便于单测）。
 *
 * 背景：进程被杀后从最近任务恢复时，系统会重放同一 SEND/PROCESS_TEXT
 * intent。Activity 侧以 `savedInstanceState != null` 为主判据，本对象提供
 * 两个补充判据：
 * 1. 跨进程持久化：同一文本的 SHA-256 指纹在 [CONSUMED_WINDOW_MS] 内已被
 *    Dart 消费过，则冷启动不再重复投递（兜底不提供 savedInstanceState 的机型）；
 * 2. 进程内短窗口：同一文本在 [DEDUPE_WINDOW_MS] 内被重复投递则忽略，
 *    防止系统重复分发同一 intent 导致重复弹框。
 */
internal object SharedTextOnceGate {

    /** 跨进程恢复防重窗口（仅冷启动兜底，热路径 onNewIntent 不受限） */
    const val CONSUMED_WINDOW_MS = 30_000L

    /** 热路径同文本短窗口去重 */
    const val DEDUPE_WINDOW_MS = 3_000L

    /**
     * `Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY` 的镜像值（0x00100000）。
     *
     * 用本地常量参与纯 JVM 单测，避免测试依赖 Android 桩。
     */
    const val FLAG_LAUNCHED_FROM_HISTORY = 0x00100000

    /** intent flags 是否标记「从最近任务/历史恢复」 */
    fun isHistoryLaunch(flags: Int): Boolean {
        return (flags and FLAG_LAUNCHED_FROM_HISTORY) != 0
    }

    /** 分享文本 SHA-256 指纹（避免在偏好设置中存全文） */
    fun fingerprint(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    /**
     * 该文本是否已在窗口内被 Dart 消费。
     *
     * [storedHash] / [consumedAt] 来自 SharedPreferences；时间戳非法（未来
     * 时间导致 elapsed < 0）同样按「已消费」处理，避免时钟回拨造成重复投递。
     */
    fun isRecentlyConsumed(
        text: String,
        storedHash: String?,
        consumedAt: Long,
        now: Long,
        windowMs: Long = CONSUMED_WINDOW_MS,
    ): Boolean {
        if (storedHash.isNullOrEmpty() || storedHash != fingerprint(text)) {
            return false
        }
        val elapsed = now - consumedAt
        return elapsed <= windowMs
    }

    /** 同一文本是否在短窗口内重复投递（进程内 one-shot 判据） */
    fun isDuplicate(
        text: String,
        recentText: String?,
        recentAt: Long,
        now: Long,
        windowMs: Long = DEDUPE_WINDOW_MS,
    ): Boolean {
        if (recentText != text) return false
        val elapsed = now - recentAt
        return elapsed <= windowMs
    }
}
