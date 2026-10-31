package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * [批9b-6c 审查回修 P1] 通知 ID 全量唯一性断言。
 *
 * 修前红：初版 Web 服务通知与视频悬浮窗同为 `0x1E61`，[LegadoNotificationIds.all]
 * 出现重复 → `size != toSet().size`。修后 Web 服务为 `0x1E62`。
 *
 * 同进程内 `NotificationManager` 的 ID 命名空间全局共享，任何新增常驻通知
 * 都必须登记到 [LegadoNotificationIds] 并由本测试兜底。
 */
class LegadoNotificationIdsTest {

    @Test
    fun `all registered notification ids are unique`() {
        val ids = LegadoNotificationIds.all
        assertEquals(
            "通知 ID 重复会让通知互相覆盖/撤销，新增通知必须先登记",
            ids.size,
            ids.toSet().size,
        )
    }

    @Test
    fun `foreground service ids are distinct`() {
        assertNotEquals(LegadoNotificationIds.PLAYBACK, LegadoNotificationIds.VIDEO)
        assertNotEquals(LegadoNotificationIds.PLAYBACK, LegadoNotificationIds.WEB_SERVER)
        assertNotEquals(LegadoNotificationIds.VIDEO, LegadoNotificationIds.WEB_SERVER)
    }

    @Test
    fun `registered ids match batch contract`() {
        assertEquals(0x1E60, LegadoNotificationIds.PLAYBACK)
        assertEquals(0x1E61, LegadoNotificationIds.VIDEO)
        assertEquals(0x1E62, LegadoNotificationIds.WEB_SERVER)
        assertEquals(1001, LegadoNotificationIds.LEGACY_DOWNLOAD)
        assertEquals(1002, LegadoNotificationIds.LEGACY_READING)
        assertEquals(1003, LegadoNotificationIds.LEGACY_SERVICE)
    }
}
