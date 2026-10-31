package io.legado.flutter

/**
 * 通知 ID 集中登记（批9b-6c 审查回修 P1）
 *
 * `NotificationManager.notify` / `Service.startForeground` 共用进程级 ID
 * 命名空间：**任何两个同时存在的通知使用同一 ID 都会互相覆盖**，前台服务
 * 停服时还会把同 ID 的其他通知一起撤销。9b-6c 初版 Web 服务通知误用
 * `0x1E61` 与视频悬浮窗相同，二者可同时运行（听书/视频/Web 服务彼此独立），
 * 属于真实冲突，故集中到本对象登记。
 *
 * 分配规则：
 * - `0x1E60-0x1E6F`：前台服务常驻通知（必须唯一）；
 * - `1001-1003`：旧 `NotificationService` 短时通知（下载/阅读/占位服务）。
 *
 * 新增通知必须在此登记，并由 `LegadoNotificationIdsTest` 断言全量唯一。
 *
 * — 全栈工程师 ｜ 2026-11-01
 */
internal object LegadoNotificationIds {

    /** 听书/媒体播放前台服务（PlaybackForegroundService） */
    const val PLAYBACK = 0x1E60

    /** 视频悬浮窗前台服务（VideoPlayService） */
    const val VIDEO = 0x1E61

    /** Web 服务前台服务（WebServerForegroundService，批9b-6c） */
    const val WEB_SERVER = 0x1E62

    // ── 旧 NotificationService（非前台，短时通知） ──
    const val LEGACY_DOWNLOAD = 1001
    const val LEGACY_READING = 1002
    const val LEGACY_SERVICE = 1003

    /** 全部登记值（唯一性单测的数据源） */
    val all: List<Int> = listOf(
        PLAYBACK,
        VIDEO,
        WEB_SERVER,
        LEGACY_DOWNLOAD,
        LEGACY_READING,
        LEGACY_SERVICE,
    )
}
