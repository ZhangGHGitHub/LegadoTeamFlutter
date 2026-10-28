package io.legado.flutter

import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [D1 回修 | 2026-10-27，P1-1/P2-1/P2-2/P3-1/P3-5] SaveFileBridge 纯函数单测。
 *
 * 覆盖：
 * 1. 参数校验 / MIME 推断 / 文件名净化（与 Dart 侧 trim 口径一致）；
 * 2. 回退目标相对路径推导（`raw:` / `primary:` / RELATIVE_PATH / 无法确定），
 *    含显示名兜底结果的规范化（`Downloads/…` 拒绝）；
 * 3. 回退触发条件（openOutputStream 返回 null、权限/文件形态异常）；
 * 4. 失败后是否删除 SAF 文档（preSize 未知/负数/已有内容/空文档）；
 * 5. 回退读回大小严格校验（读不到即失败）；
 * 6. 错误码中文 reason 映射。
 *
 * 纯 JVM JUnit（无 Robolectric）：只测 companion 内的纯函数内核，
 * 不触 Android 框架类（与 StorageBridgeBytesArgumentTest 同风格）。
 */
class SaveFileBridgeTest {

    // ---------- 参数校验 / MIME / 文件名 ----------

    @Test
    fun `empty bytes is rejected before launching the save dialog`() {
        assertEquals(
            "EMPTY_BYTES",
            SaveFileBridge.validateArgs("bookSource.json", ByteArray(0))
        )
        assertEquals(
            "EMPTY_BYTES",
            SaveFileBridge.validateArgs("bookSource.json", byteArrayOf())
        )
    }

    @Test
    fun `pending timeout is five minutes`() {
        assertEquals(5 * 60 * 1000L, SaveFileBridge.PENDING_TIMEOUT_MS)
    }

    @Test
    fun `blank file name and null bytes are invalid arguments`() {
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs(null, byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("", byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("   ", byteArrayOf(1)))
        assertEquals("INVALID_ARGS", SaveFileBridge.validateArgs("a.json", null))
    }

    @Test
    fun `valid arguments pass validation`() {
        assertNull(SaveFileBridge.validateArgs("a.json", byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `mime type is inferred from extension`() {
        assertEquals("application/json", SaveFileBridge.mimeTypeOf("a.json"))
        assertEquals("application/json", SaveFileBridge.mimeTypeOf("A.JSON"))
        assertEquals("application/javascript", SaveFileBridge.mimeTypeOf("source.js"))
        assertEquals("application/zip", SaveFileBridge.mimeTypeOf("skin.zip"))
        assertEquals("text/plain", SaveFileBridge.mimeTypeOf("highlight.md"))
        assertEquals("image/png", SaveFileBridge.mimeTypeOf("cover.png"))
        assertEquals(
            "application/octet-stream",
            SaveFileBridge.mimeTypeOf("no-extension")
        )
        assertEquals(
            "application/octet-stream",
            SaveFileBridge.mimeTypeOf("unknown.bin2")
        )
    }

    @Test
    fun `declared mime type wins over extension inference`() {
        assertEquals(
            "text/javascript",
            SaveFileBridge.resolveMimeType("source.js", "text/javascript")
        )
        assertEquals(
            "application/javascript",
            SaveFileBridge.resolveMimeType("source.js", null)
        )
        assertEquals(
            "application/javascript",
            SaveFileBridge.resolveMimeType("source.js", "   ")
        )
    }

    @Test
    fun `illegal file name chars are normalized to underscore`() {
        assertEquals(
            "a_b_c_d_e_f_g_h_i_.json",
            SaveFileBridge.normalizeFileName("a/b\\c:d*e?f\"g<h>i|.json")
        )
        assertEquals(
            "bookSource_QA.json",
            SaveFileBridge.normalizeFileName("  bookSource_QA.json  ")
        )
    }

    @Test
    fun `normalize file name trims like the dart side`() {
        // Dart `ExportFileService.normalizeFileName` 同为「替换 + trim」，
        // 避免两端对首尾空白处理不一致（P3-5）
        assertEquals("a.json", SaveFileBridge.normalizeFileName("\t a.json \n"))
        assertEquals("", SaveFileBridge.normalizeFileName("   "))
        assertEquals("有 空格.json", SaveFileBridge.normalizeFileName(" 有 空格.json "))
        assertEquals("a_b.json", SaveFileBridge.normalizeFileName(" a?b.json "))
    }

    // ---------- P2-2：目录选择 flags 与只读目录 ----------

    @Test
    fun `persistable flags only keep read and write grants`() {
        val read = android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
        val write = android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        val persistable = android.content.Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
        assertEquals(
            read or write,
            SaveFileBridge.persistableFlags(read or write or persistable)
        )
        // 只读目录：系统可能只给 READ，不能凭空补 WRITE
        assertEquals(read, SaveFileBridge.persistableFlags(read))
        assertEquals(0, SaveFileBridge.persistableFlags(0))
    }

    @Test
    fun `tree grant requires write permission`() {
        val read = android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
        val write = android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        assertTrue(SaveFileBridge.hasWriteGrant(read or write))
        assertFalse(SaveFileBridge.hasWriteGrant(read))
        assertNull(SaveFileBridge.treeGrantErrorCode(read or write))
        // 无 WRITE → 明确不可写错误码，调用方不得写入「已记住」
        assertEquals("TREE_NOT_WRITABLE", SaveFileBridge.treeGrantErrorCode(read))
        assertEquals("TREE_NOT_WRITABLE", SaveFileBridge.treeGrantErrorCode(0))
    }

    // ---------- P1-1：回退目标相对路径推导 ----------

    @Test
    fun `raw document id derives the parent download sub directory`() {
        assertEquals(
            "Download/legado/",
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/Download/legado/x.json",
                null,
                null
            )
        )
        assertEquals(
            "Download/legado/deep/",
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/Download/legado/deep/x.json",
                null,
                null
            )
        )
        assertEquals(
            "Download/",
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/Download/x.json",
                null,
                null
            )
        )
    }

    @Test
    fun `raw document id outside download resolves to null`() {
        assertNull(
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/Books/x.json",
                null,
                null
            )
        )
        assertNull(
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/DownloadX/x.json",
                null,
                null
            )
        )
        // 外置 SD 卡无法用 MediaStore Downloads 表达 → 明确报错
        assertNull(
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/1A2B-3C4D/Download/legado/x.json",
                null,
                null
            )
        )
    }

    @Test
    fun `primary document id derives download sub directory`() {
        assertEquals(
            "Download/legado/",
            SaveFileBridge.resolveRelativePath(
                "primary:Download/legado/x.json",
                null,
                null
            )
        )
        assertEquals(
            "Download/",
            SaveFileBridge.resolveRelativePath(
                "primary:Download/x.json",
                null,
                null
            )
        )
        assertNull(
            SaveFileBridge.resolveRelativePath(
                "primary:Documents/x.json",
                null,
                null
            )
        )
    }

    @Test
    fun `queried relative path wins and is normalized`() {
        assertEquals(
            "Download/legado/",
            SaveFileBridge.resolveRelativePath(
                "msf:1000001418",
                null,
                "Download/legado/"
            )
        )
        // 无尾斜杠 / 前导斜杠 / 反斜杠都需要规范化
        assertEquals(
            "Download/legado/",
            SaveFileBridge.resolveRelativePath(null, null, "/Download/legado")
        )
        assertEquals(
            "Download/a/b/",
            SaveFileBridge.resolveRelativePath(null, null, "Download\\a\\b")
        )
        // 非「下载」目录：拒绝（不得把音乐/文档目录映射成下载回退）
        assertNull(SaveFileBridge.resolveRelativePath(null, null, "Music/legado/"))
        assertNull(SaveFileBridge.resolveRelativePath(null, null, "Downloads/x/"))
    }

    @Test
    fun `display name fallback path is normalized and rejects downloads`() {
        // P3-1：显示名兜底查到的 RELATIVE_PATH 与其它来源同口径规范化
        // （resolveDownloadRelativePath 内 normalizeDownloadRelativePath）。
        // `Downloads/x` 不在「下载」子树内 → 拒绝（报 FALLBACK_PATH_UNKNOWN），
        // 正常 `Download/legado/` 通过并补齐尾斜杠。
        assertEquals(
            "Download/legado/",
            SaveFileBridge.normalizeDownloadRelativePath("Download/legado/")
        )
        assertEquals(
            "Download/legado/",
            SaveFileBridge.normalizeDownloadRelativePath("Download/legado")
        )
        assertNull(SaveFileBridge.normalizeDownloadRelativePath("Downloads/x"))
        assertNull(SaveFileBridge.normalizeDownloadRelativePath("Downloads/x/"))
        assertNull(SaveFileBridge.normalizeDownloadRelativePath("Download/../Downloads/x/"))
    }

    @Test
    fun `resolved absolute path is used when document id has no path`() {
        assertEquals(
            "Download/legado/",
            SaveFileBridge.resolveRelativePath(
                "1000001418",
                "/storage/emulated/0/Download/legado/x.json",
                null
            )
        )
        assertEquals(
            "Download/",
            SaveFileBridge.resolveRelativePath(
                null,
                "/sdcard/Download/x.json",
                null
            )
        )
        assertNull(
            SaveFileBridge.resolveRelativePath(null, "/storage/emulated/0/Music/x.json", null)
        )
    }

    @Test
    fun `relative path traversal segments are rejected`() {
        assertNull(SaveFileBridge.resolveRelativePath(null, null, "Download/../../etc/"))
        assertNull(
            SaveFileBridge.resolveRelativePath(
                "raw:/storage/emulated/0/Download/../Download/x.json",
                null,
                null
            )
        )
    }

    @Test
    fun `unknown document id cannot be resolved`() {
        assertNull(SaveFileBridge.resolveRelativePath(null, null, null))
        assertNull(SaveFileBridge.resolveRelativePath("", "", ""))
        assertNull(SaveFileBridge.resolveRelativePath("msd:1000001321", null, null))
        assertNull(SaveFileBridge.resolveRelativePath("downloads", null, null))
    }

    @Test
    fun `media store id is parsed from msf document ids only`() {
        assertEquals(1000001418L, SaveFileBridge.mediaStoreIdOf("msf:1000001418"))
        assertEquals(1000001418L, SaveFileBridge.mediaStoreIdOf("MSF:1000001418"))
        // 纯数字是本 ROM DownloadsProvider 的 legacy downloads 行 id，与
        // MediaStore `_id` 不同域（document/7 ↔ 行 1000001407）→ 不解析
        assertNull(SaveFileBridge.mediaStoreIdOf(" 1000001418 "))
        assertNull(SaveFileBridge.mediaStoreIdOf("7"))
        // 目录 id / 非法值 / 0 均不当作 MediaStore 行 id
        assertNull(SaveFileBridge.mediaStoreIdOf("msd:1000001321"))
        assertNull(SaveFileBridge.mediaStoreIdOf("msf:abc"))
        assertNull(SaveFileBridge.mediaStoreIdOf("0"))
        assertNull(SaveFileBridge.mediaStoreIdOf(null))
    }

    // ---------- P3-1：回退触发条件 ----------

    @Test
    fun `security exception and file not found trigger fallback`() {
        assertTrue(SaveFileBridge.isPermissionFailure(SecurityException("denied")))
        assertTrue(SaveFileBridge.isPermissionFailure(FileNotFoundException("gone")))
    }

    @Test
    fun `permission denial and eacces messages trigger fallback`() {
        assertTrue(
            SaveFileBridge.isPermissionFailure(
                IOException(
                    "open failed: EACCES (Permission denied)",
                )
            )
        )
        assertTrue(
            SaveFileBridge.isPermissionFailure(
                IOException(
                    "Permission Denial: writing com.android.providers.downloads." +
                        "DownloadStorageProvider requires " +
                        "android.permission.MANAGE_DOCUMENTS"
                )
            )
        )
        assertTrue(SaveFileBridge.isPermissionFailure(IOException("EPERM: operation not permitted")))
    }

    @Test
    fun `nested causes are inspected`() {
        val nested = IOException(
            "open failed",
            SecurityException("Permission Denial: requires MANAGE_DOCUMENTS")
        )
        assertTrue(SaveFileBridge.isPermissionFailure(nested))
    }

    @Test
    fun `unrelated io errors do not trigger fallback`() {
        assertFalse(SaveFileBridge.isPermissionFailure(IOException("No space left on device")))
        assertFalse(SaveFileBridge.isPermissionFailure(IllegalStateException("closed")))
        assertFalse(SaveFileBridge.isPermissionFailure(null))
    }

    @Test
    fun `fallback requires an unopened stream`() {
        // openOutputStream 返回 null：即使没有异常也进入回退候选
        assertTrue(SaveFileBridge.shouldAttemptFallback(false, true, null))
        // 权限形态异常
        assertTrue(
            SaveFileBridge.shouldAttemptFallback(false, false, SecurityException("denied"))
        )
        // 写流已打开后失败：不回退（可能已写入部分内容）
        assertFalse(
            SaveFileBridge.shouldAttemptFallback(true, false, SecurityException("denied"))
        )
        // 非权限形态异常
        assertFalse(
            SaveFileBridge.shouldAttemptFallback(false, false, IOException("disk full"))
        )
    }

    // ---------- P2-2 / P2-4：失败后是否删除 SAF 文档 ----------

    @Test
    fun `existing file is never deleted on failure`() {
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = 2100L))
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = false, preSize = 2100L))
    }

    @Test
    fun `unknown size is never deleted`() {
        // preSize=null（provider 不提供 SIZE / 查询失败）视为不删
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = null))
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = false, preSize = null))
    }

    @Test
    fun `negative size is treated as unknown and never deleted`() {
        // P3-3：-1（provider 报不可知）不能被当成 0 删除；
        // 无论写流是否已打开都不能删（可能指向用户已有文件）
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = -1L))
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = false, preSize = -1L))
    }

    @Test
    fun `empty document is deleted whether opened or not`() {
        // opened=true：本次已新建/截断写流后失败 → 清理残留
        assertTrue(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = 0L))
        // opened=false：CREATE_DOCUMENT 新建、写流被拒的空文档（P2-4）
        assertTrue(SaveFileBridge.shouldDeleteAfterFailure(opened = false, preSize = 0L))
    }

    @Test
    fun `created document is cleaned when write stream throws`() {
        // P2-4 场景：createDocument 成功（新建 0 字节）→ openOutputStream
        // 抛异常（设备侧无法稳定构造，由本纯逻辑用例锁定决策）：
        // opened=false + preSize=0 → 删除本次文档，不残留 0 字节。
        assertTrue(SaveFileBridge.shouldDeleteAfterFailure(opened = false, preSize = 0L))
        // 写流已打开后失败（opened=true）同样清理本次 0 字节文档。
        assertTrue(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = 0L))
        // 用户已有内容（替换场景）绝不删除。
        assertFalse(SaveFileBridge.shouldDeleteAfterFailure(opened = true, preSize = 1L))
    }

    // ---------- P2-1：读回大小严格校验 ----------

    @Test
    fun `readback size must match exactly`() {
        assertTrue(SaveFileBridge.isReadbackSizeValid(2100, 2100L))
        assertTrue(SaveFileBridge.isReadbackSizeValid(0, 0L))
        assertFalse(SaveFileBridge.isReadbackSizeValid(2100, 2099L))
        assertFalse(SaveFileBridge.isReadbackSizeValid(2100, 2101L))
    }

    @Test
    fun `unreadable readback size fails verification`() {
        // -1（provider 报不可知）与 null（读不到）在**旧链路告警口径**中
        // 记为异常（只记 W 日志，不删除文件）；目录树链路由
        // `readbackSizeVerdict` / `verifyReadback` 降级为全文扫描（P1-1）。
        assertFalse(SaveFileBridge.isReadbackSizeValid(2100, -1L))
        assertFalse(SaveFileBridge.isReadbackSizeValid(2100, null))
    }

    // ---------- P1-1：SIZE 未知时降级全文比对 ----------

    @Test
    fun `unknown size with matching content passes readback verification`() {
        // 红→绿回归：provider 不报 SIZE（null）或报 -1 时，全文扫描
        // 长度与首字节一致必须判**成功**；修复前直接按 SIZE 失败 →
        // writeViaTree 删除刚写成功的文件。
        assertNull(SaveFileBridge.verifyReadback(2100, null, 2100L, true))
        assertNull(SaveFileBridge.verifyReadback(2100, -1L, 2100L, true))
        assertEquals(
            SaveFileBridge.ReadbackSizeVerdict.UNKNOWN,
            SaveFileBridge.readbackSizeVerdict(2100, null)
        )
        assertEquals(
            SaveFileBridge.ReadbackSizeVerdict.UNKNOWN,
            SaveFileBridge.readbackSizeVerdict(2100, -1L)
        )
    }

    @Test
    fun `unknown size with mismatched content still fails`() {
        // 降级不等于放行：全文长度/首字节不一致仍须失败
        assertEquals(
            "读回内容长度校验失败：期望 2100，实际 2099",
            SaveFileBridge.verifyReadback(2100, null, 2099L, true)
        )
        assertEquals(
            "读回内容长度不可知",
            SaveFileBridge.verifyReadback(2100, -1L, null, true)
        )
        assertEquals(
            "读回首字节不一致",
            SaveFileBridge.verifyReadback(2100, null, 2100L, false)
        )
    }

    @Test
    fun `known mismatched size fails without content scan`() {
        // 只有「已知且确实不等」才直接失败；已知相等不看扫描长度
        assertEquals(
            "读回大小校验失败：期望 2100，实际 2099",
            SaveFileBridge.verifyReadback(2100, 2099L, 2100L, true)
        )
        assertNull(SaveFileBridge.verifyReadback(2100, 2100L, null, true))
        assertEquals(
            "读回首字节不一致",
            SaveFileBridge.verifyReadback(2100, 2100L, null, false)
        )
    }

    // ---------- 批26：目录树显示路径（保存成功提示 / 换个位置入口） ----------

    @Test
    fun `downloads tree root displays as download directory`() {
        assertEquals(
            "下载",
            SaveFileBridge.treeDisplayPath(
                "downloads",
                SaveFileBridge.DOWNLOADS_AUTHORITY
            )
        )
    }

    @Test
    fun `primary tree document id displays with chinese download prefix`() {
        assertEquals("下载/legado", SaveFileBridge.treeDisplayPath("primary:Download/legado", null))
        assertEquals("下载/legado", SaveFileBridge.treeDisplayPath("primary:Download/legado/", null))
        assertEquals(
            "下载/legado",
            SaveFileBridge.treeDisplayPath("PRIMARY:Download/legado", null)
        )
        assertEquals("下载", SaveFileBridge.treeDisplayPath("primary:Download", null))
        // 非「下载」目录：原样展示（首段不是 Download 不中文化）
        assertEquals("Documents/导出", SaveFileBridge.treeDisplayPath("primary:Documents/导出", null))
    }

    @Test
    fun `internal storage root displays as internal storage`() {
        assertEquals("内部存储", SaveFileBridge.treeDisplayPath("primary:", null))
        assertEquals("内部存储", SaveFileBridge.treeDisplayPath("primary", null))
    }

    @Test
    fun `raw tree document id strips primary storage roots`() {
        assertEquals(
            "下载/legado",
            SaveFileBridge.treeDisplayPath(
                "raw:/storage/emulated/0/Download/legado",
                null
            )
        )
        assertEquals(
            "下载/legado",
            SaveFileBridge.treeDisplayPath("raw:/sdcard/Download/legado", null)
        )
        // 外置存储：去掉卷标识后，卷内 Download 段同口径中文化
        assertEquals(
            "下载/legado",
            SaveFileBridge.treeDisplayPath("raw:/storage/1A2B-3C4D/Download/legado", null)
        )
    }

    @Test
    fun `external volume sub directories keep their in volume path`() {
        // P3-6：外置卷只去掉 `/storage/<卷标识>/`，保留卷内完整相对路径
        assertEquals(
            "下载/deep/nested",
            SaveFileBridge.treeDisplayPath(
                "raw:/storage/1A2B-3C4D/Download/deep/nested",
                null
            )
        )
        assertEquals(
            "legado",
            SaveFileBridge.treeDisplayPath("raw:/storage/1A2B-3C4D/legado", null)
        )
        // 外置卷根本身（无子目录）→ 内部存储文案（与主存储根同口径）
        assertEquals(
            "内部存储",
            SaveFileBridge.treeDisplayPath("raw:/storage/1A2B-3C4D", null)
        )
    }

    @Test
    fun `downloads plural sub directory is not localized`() {
        // 仅标准 `Download` 首段中文化；`Downloads` 不是同一目录
        assertEquals(
            "Downloads/legado",
            SaveFileBridge.treeDisplayPath("primary:Downloads/legado", null)
        )
    }

    @Test
    fun `unknown provider or traversal tree id has no display path`() {
        assertNull(SaveFileBridge.treeDisplayPath("msd:1000001321", "com.google.android.apps.docs"))
        assertNull(SaveFileBridge.treeDisplayPath(null, null))
        assertNull(SaveFileBridge.treeDisplayPath("primary:Download/../etc", null))
        assertNull(SaveFileBridge.treeDisplayPath("primary:Download/./legado", null))
    }

    // ---------- 批26：目录树失效判定（清除记住目录 + 重选一次） ----------

    @Test
    fun `revoked grant and missing tree are unavailable`() {
        assertTrue(SaveFileBridge.isTreeUnavailable(SecurityException("revoked")))
        assertTrue(SaveFileBridge.isTreeUnavailable(FileNotFoundException("gone")))
        assertTrue(
            SaveFileBridge.isTreeUnavailable(
                IOException("Permission Denial: requires android.permission.MANAGE_DOCUMENTS")
            )
        )
        assertTrue(SaveFileBridge.isTreeUnavailable(IOException("open failed: EACCES")))
        assertTrue(SaveFileBridge.isTreeUnavailable(IOException("Failed to find tree")))
        assertTrue(SaveFileBridge.isTreeUnavailable(IOException("Volume unavailable")))
    }

    @Test
    fun `nested tree cause is inspected`() {
        val nested = IOException(
            "Failed to create document",
            SecurityException("Permission Denial: requires WRITE")
        )
        assertTrue(SaveFileBridge.isTreeUnavailable(nested))
    }

    @Test
    fun `disk full and verify failures are not tree unavailable`() {
        // 写入失败但目录仍可用：不触发重选（避免反复弹框）
        assertFalse(SaveFileBridge.isTreeUnavailable(IOException("No space left on device")))
        assertFalse(SaveFileBridge.isTreeUnavailable(IllegalStateException("closed")))
        assertFalse(SaveFileBridge.isTreeUnavailable(null))
    }

    // ---------- P2-3：中文 reason 映射 ----------

    @Test
    fun `fallback path unknown maps to a chinese reason`() {
        assertEquals(
            "无法确定所选文件夹，请选择内部存储 > Download 或子文件夹后重试",
            SaveFileBridge.reasonOf("FALLBACK_PATH_UNKNOWN")
        )
    }

    @Test
    fun `legacy api reason asks the user to pick another folder`() {
        assertEquals(
            "Android 10 以下暂不支持保存到下载目录，请选择其他位置",
            SaveFileBridge.reasonOf("LEGACY_NOT_SUPPORTED")
        )
    }

    @Test
    fun `verify failure and save failure map to chinese reasons`() {
        assertEquals(
            "写入校验失败，文件未保存，请重试或换一个文件夹",
            SaveFileBridge.reasonOf("SAVE_VERIFY_FAILED")
        )
        assertEquals(
            "无法写入所选位置，请换一个文件夹重试",
            SaveFileBridge.reasonOf("SAVE_FAILED")
        )
        assertEquals("保存失败，请重试", SaveFileBridge.reasonOf("UNKNOWN_CODE"))
    }

    @Test
    fun `tree failures map to chinese reasons`() {
        assertEquals(
            "保存文件夹不可用，请重新选择文件夹后重试",
            SaveFileBridge.reasonOf("TREE_UNAVAILABLE")
        )
        assertEquals(
            "无法写入所选文件夹，请换一个文件夹重试",
            SaveFileBridge.reasonOf("TREE_WRITE_FAILED")
        )
        // P2-2：无写授权/持久授权失败时的明确中文原因
        assertEquals(
            "该文件夹不可写，请换一个",
            SaveFileBridge.reasonOf("TREE_NOT_WRITABLE")
        )
        assertEquals(
            "当前系统不支持选择文件夹，请改用系统另存对话框",
            SaveFileBridge.reasonOf("TREE_UNSUPPORTED")
        )
    }

    @Test
    fun `all user facing reasons are chinese`() {
        val codes = listOf(
            "INVALID_ARGS", "EMPTY_BYTES", "ALREADY_PENDING", "SAVE_START_FAILED",
            "NO_URI", "TIMEOUT", "ACTIVITY_DESTROYED", "SAVE_VERIFY_FAILED",
            "TREE_UNAVAILABLE", "TREE_WRITE_FAILED", "TREE_NOT_WRITABLE",
            "TREE_UNSUPPORTED",
            "FALLBACK_PATH_UNKNOWN", "LEGACY_NOT_SUPPORTED", "SAVE_FAILED"
        )
        val cjk = Regex("[\\u4e00-\\u9fff]")
        for (code in codes) {
            val reason = SaveFileBridge.reasonOf(code)
            assertTrue("$code 缺少中文文案：$reason", cjk.containsMatchIn(reason))
        }
    }
}
