package io.legado.flutter

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.io.IOException

/**
 * 系统另存桥接（批26）— SAF 目录树 + 受控写流链路
 *
 * [批26 2026-10-27] 默认改为 **ACTION_OPEN_DOCUMENT_TREE 目录树**
 * （对齐原版 `HandleFileViewModel.saveToLocal(uri, ...)`：
 * `DocumentFile.fromTreeUri(...).createFile(...).writeBytes(...)`）：
 * 1. 首次另存弹目录选择器（`ACTION_OPEN_DOCUMENT_TREE` +
 *    READ/WRITE/PERSISTABLE），结果 `takePersistableUriPermission` 后把
 *    tree URI 记住（SharedPreferences，含 authority / 显示路径）；
 * 2. 之后直接在该树内 `DocumentsContract.createDocument` 建文件 +
 *    `openOutputStream` 写入 + 严格读回校验（大小/首字节），**不再弹框**；
 * 3. 失败只删除**本次创建**的文档（树授权内删除可用），0 字节占位不再残留；
 * 4. 「换个位置」由 `chooseTree` 主动重选目录并记住。
 *
 * 背景（docs/DEVICE_ACCEPTANCE_20261027_16X.md §五 D1）：
 * `file_picker 8.3.7` 的 `saveFile` 在 `onActivityResult` 内直接
 * `ContentResolver.openOutputStream(uri)` 写字节，且只 catch IOException；
 * MuMu Android 15 的 `DownloadStorageProvider` 对 Downloads 文档 URI 抛
 * `SecurityException`（requires MANAGE_DOCUMENTS），异常穿透
 * `Activity.onActivityResult` → 主线程 FATAL，进程被强杀，并残留 0 字节文档。
 *
 * 本桥接把「选位置」与「写字节」拆开且全程由我们掌控：
 * 1. `ACTION_CREATE_DOCUMENT` + `EXTRA_TITLE`（文件名先经 [normalizeFileName]
 *    净化）+ MIME，由用户选择保存位置；
 * 2. 结果回到 [onActivityResult] 后，在**后台线程**打开 URI 写字节；
 * 3. 所有异常（含 SecurityException / RuntimeException / Throwable）均被
 *    捕获并回结构化 `{code, reason, detail}`，绝不向 Flutter 引擎或主线程抛出；
 * 4. **DownloadsProvider 拒写回退**：`openOutputStream` 失败（权限拒绝 /
 *    FileNotFoundException / 返回 null）时回退为 MediaStore Downloads 直写
 *    （API 29+，`IS_PENDING` 保护，写完清除），无需 MANAGE_DOCUMENTS；
 * 5. **回退必须落在用户选择的子目录（P1-1）**：回退前从 SAF 文档 uri 推导
 *    目标 `RELATIVE_PATH`（`raw:`/`primary:` 路径、`msf:` 走 MediaStore.Files
 *    按 `_id` 查询、数字 id 走显示名查询），推导不出时**明确报错**，
 *    绝不静默写「下载」根；
 * 6. **严格读回校验（P2-1）**：目录树与 MediaStore 回退写入后 SIZE 必须与
 *    实际写入字节数精确相等且首 [HEAD_VERIFY_BYTES] 字节一致；
 *    [P1-1] provider 不报 SIZE（null/负数）或写入成功后短暂报 0 时
 *    **降级为全文读取字节数比对**（见 [verifyReadback]），只有已知且
 *    确实不等才判失败并清理，绝不把刚写成功的文件误删；
 * 7. **失败清理安全（P2-2/P2-4）**：open 前查询文档大小（COLUMN_SIZE），
 *    仅 0 字节文档（本次新建/截断，或 CREATE_DOCUMENT 刚建的空文档）允许
 *    删除；`preSize > 0`（用户选择「替换」的已有文件）失败只报错不删；
 * 8. [P2-2] 目录选择结果只按系统**实际授予**的 flags 取持久授权：无
 *    WRITE 或 take 失败时**不记住目录**并回 `TREE_NOT_WRITABLE`
 *    （中文「该文件夹不可写，请换一个」），避免只读目录每次保存循环失败；
 *    记住前另查 `COLUMN_FLAGS & FLAG_DIR_SUPPORTS_CREATE`（provider 明确
 *    不支持创建时同样拒绝，查询不到则按未知放行）；
 * 9. 持久化 URI 授权仅在 take 成功时回收（最小权限）；目录失效清除记录
 *    （[clearTree]）时按记录 URI **逐位**释放 READ/WRITE 持久授权
 *    （只持有其一时整次释放会失败），避免 grant 累积；
 * 10. 用户取消（RESULT_CANCELED）回 `result.success(null)`；RESULT_OK 但
 *    无 URI 回 `NO_URI` 错误（P3-3）；等待结果超过 5 分钟复位 pending
 *    （P3-3），超时后迟到的回调写日志而非静默丢弃（P3-6）。
 * 11. [P3-1] `createDocument` 按 Android SAF 常规行为视为**本次新建**文档
 *     （同名时 provider 自动改名而非返回已有文档），失败清理只删该文档；
 *     该假设同时记录在 Dart 通道契约
 *     `flutter_legado/lib/src/services/file_save_channel.dart`。
 *
 * 支持方法：
 * - `saveFile`: 参数 {fileName: String, bytes: ByteArray|List<Int>, mimeType: String?,
 *   useTree: Boolean = true, chooseTree: Boolean = false}；
 *   - `useTree=true`（Android 默认）：已记住目录 → 直接树内建文件写入；
 *     未记住或 `chooseTree=true` → 先弹目录选择器再写入；
 *   - `useTree=false`：走旧 `ACTION_CREATE_DOCUMENT` 链路（回退用）；
 *   成功返回 `{uri, name, fallback: "none"|"mediastore", relativeDir: String?,
 *   viaTree: Boolean, displayPath: String?}`（`name` 为 provider 实际落盘名，
 *   重名时可能带 `(N)`；`displayPath` 形如 `下载/legado`）；
 *   空字节/参数缺失返回 error，不创建文档。
 * - `chooseTree`: 主动「换个位置」，仅选择并记住文件夹，返回
 *   `{uri, displayPath, authority}`；用户取消返回 null；
 * - `getSavedTree`: 查询已记住的保存文件夹（同样结构；未记住返回 null）。
 */
class SaveFileBridge {

    companion object {
        const val CHANNEL = "legado/file_save"

        private const val TAG = "SaveFileBridge"

        /** 与 Flutter 插件请求码错开（file_picker 使用类 hashCode 派生值） */
        private const val REQUEST_CODE_SAVE_FILE = 10201

        /** 目录树选择请求码（保存前的首次选择 / 「换个位置」共用） */
        private const val REQUEST_CODE_PICK_TREE = 10202

        private const val METHOD_SAVE_FILE = "saveFile"

        /** 主动选择保存文件夹（仅记住，不写文件） */
        private const val METHOD_CHOOSE_TREE = "chooseTree"

        /** 查询已记住的保存文件夹 */
        private const val METHOD_GET_SAVED_TREE = "getSavedTree"

        /** 记住的目录树持久化（原生侧，Dart 重启后仍生效） */
        internal const val PREFS_NAME = "legado_file_save"
        internal const val KEY_TREE_URI = "tree_uri"
        internal const val KEY_TREE_DISPLAY_PATH = "tree_display_path"
        internal const val KEY_TREE_AUTHORITY = "tree_authority"

        /** 「下载」目录树 / 内部存储根的显示名（提示文案用） */
        internal const val DOWNLOADS_TREE_DISPLAY = "下载"
        internal const val INTERNAL_STORAGE_DISPLAY = "内部存储"

        /** 主存储绝对路径前缀（`raw:` 目录树 id 归一化用） */
        private val PRIMARY_STORAGE_ROOTS = listOf(
            "/storage/emulated/0",
            "/storage/self/primary",
            "/sdcard",
            "/mnt/sdcard"
        )

        /**
         * 等待系统对话框回传的上限（P3-3）：超时复位 pending，
         * 避免 Dart Future 永久挂起（对话框被系统回收/回调丢失时）。
         */
        internal const val PENDING_TIMEOUT_MS = 5 * 60 * 1000L

        /** DownloadsProvider authority（原崩溃入口，写流被拒时回退 MediaStore） */
        internal const val DOWNLOADS_AUTHORITY =
            "com.android.providers.downloads.documents"

        /** 「下载」根相对路径（MediaStore RELATIVE_PATH 口径，带尾斜杠） */
        internal const val DOWNLOAD_RELATIVE_ROOT = "Download/"

        /** 读回校验比对的头部字节数（与 StorageBridge 同口径） */
        private const val HEAD_VERIFY_BYTES = 8

        /** SIZE 未知时全文扫描的缓冲大小（P1-1） */
        private const val VERIFY_SCAN_BUFFER_BYTES = 8 * 1024

        /**
         * 主存储「下载」根的绝对路径前缀（含 `/sdcard` 等历史别名）。
         * 仅主存储；外置 SD 卡（`/storage/XXXX-XXXX/...`）无法用
         * MediaStore Downloads 表达，按「无法确定」报错。
         */
        private val PRIMARY_DOWNLOAD_ROOTS = listOf(
            "/storage/emulated/0/Download",
            "/storage/self/primary/Download",
            "/sdcard/Download",
            "/mnt/sdcard/Download"
        )

        /** 文件名非法字符（与 Dart `ExportFileService.normalizeFileName` 同口径） */
        private val INVALID_FILE_NAME_CHARS = Regex("[\\\\/:*?\"<>|]")

        /** 净化文件名：非法字符替换为 `_` 并去首尾空白（P3-5，与 Dart 侧对齐） */
        internal fun normalizeFileName(raw: String): String =
            raw.replace(INVALID_FILE_NAME_CHARS, "_").trim()

        /** 按扩展名推断 MIME（与 StorageBridge 口径一致，补 JSON/文本/压缩包） */
        internal fun mimeTypeOf(fileName: String): String {
            val ext = fileName.substringAfterLast('.', "").lowercase()
            return when (ext) {
                "json" -> "application/json"
                "txt", "log", "md" -> "text/plain"
                "js" -> "application/javascript"
                "xml", "html", "htm" -> "text/xml"
                "zip" -> "application/zip"
                "epub" -> "application/epub+zip"
                "pdf" -> "application/pdf"
                "jpg", "jpeg" -> "image/jpeg"
                "png" -> "image/png"
                "gif" -> "image/gif"
                "webp" -> "image/webp"
                "bmp" -> "image/bmp"
                else -> "application/octet-stream"
            }
        }

        /** 调用方声明的 MIME 优先，缺失/空白时按扩展名推断 */
        internal fun resolveMimeType(fileName: String, declared: String?): String =
            declared?.takeIf { it.isNotBlank() } ?: mimeTypeOf(fileName)

        /**
         * 从目录选择结果 Intent 的 flags 中提取可持久化的读写授权位（P2-2）。
         *
         * 只使用系统**实际授予**的位：硬编码 READ|WRITE 会在只读目录上
         * 申请到不存在的写授权（take 失败后仍记住目录 → 每次保存循环
         * 失败），也可能多拿不需要的权限。
         */
        internal fun persistableFlags(intentFlags: Int): Int =
            intentFlags and (
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )

        /** 目录树必须拿到写授权才能记住并写入（P2-2） */
        internal fun hasWriteGrant(flags: Int): Boolean =
            flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0

        /**
         * 目录选择结果是否可被记住（P2-2 纯函数）：null = 可记住，
         * 否则返回面向用户的错误码。无写授权直接判不可写，绝不写入
         * 「已记住」记录。
         */
        internal fun treeGrantErrorCode(intentFlags: Int): String? =
            if (hasWriteGrant(persistableFlags(intentFlags))) null else "TREE_NOT_WRITABLE"

        /**
         * 目录文档 flags → 是否声明支持创建子项（P3-6 纯函数）。
         *
         * [flags] 为 `DocumentsContract.Document.COLUMN_FLAGS` 查询结果：
         * - null / 负数 → null（provider 未提供或不可知，调用方按未知放行）；
         * - 否则按 `FLAG_DIR_SUPPORTS_CREATE` 位判断。
         *
         * 仅作「记住目录前」的补充判据：大量第三方 provider 不返回该位，
         * 因此只有明确的 false 才拒绝，null 不能当 false。
         */
        internal fun supportsCreateFromFlags(flags: Long?): Boolean? = when {
            flags == null || flags < 0L -> null
            else -> flags and
                DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L
        }

        /**
         * 参数校验纯函数（JVM 单测覆盖）：返回错误码，null 表示通过。
         *
         * 空字节在弹对话框前拒绝，避免系统先创建 0 字节文档再失败。
         */
        internal fun validateArgs(fileName: String?, bytes: ByteArray?): String? =
            when {
                fileName.isNullOrBlank() || bytes == null -> "INVALID_ARGS"
                bytes.isEmpty() -> "EMPTY_BYTES"
                else -> null
            }

        /**
         * 目录树 → 面向用户的目录文案（纯函数，JVM 单测覆盖）。
         *
         * 用于保存成功提示与「换个位置」入口展示，避免直接回显
         * `content://…/tree/primary%3ADownload` 这类 URI：
         * - DownloadsProvider 的 `downloads` 树根 → 「下载」；
         * - `primary:Download/legado` → 「下载/legado」（首段 Download 中文化）；
         * - 内部存储根（`primary:`）→ 「内部存储」；
         * - `raw:` 绝对路径去掉主存储前缀后同口径处理；
         * - 其他 provider、含 `.`/`..` 越界段 → null（调用方回落显示 URI）。
         */
        internal fun treeDisplayPath(documentId: String?, authority: String?): String? {
            val id = documentId?.trim() ?: return null
            if (authority == DOWNLOADS_AUTHORITY) return DOWNLOADS_TREE_DISPLAY
            if (id.equals("primary", ignoreCase = true) ||
                id.equals("primary:", ignoreCase = true)
            ) {
                return INTERNAL_STORAGE_DISPLAY
            }
            val relative = when {
                id.startsWith("primary:", ignoreCase = true) -> id.substring(8)
                id.startsWith("raw:", ignoreCase = true) -> {
                    var path = id.substring(4).trim().replace('\\', '/')
                    var stripped = false
                    for (root in PRIMARY_STORAGE_ROOTS) {
                        if (path == root) {
                            path = ""
                            stripped = true
                            break
                        }
                        if (path.startsWith("$root/")) {
                            path = path.removePrefix("$root/")
                            stripped = true
                            break
                        }
                    }
                    // 外置卷（/storage/XXXX-XXXX/...）：去掉卷标识，保留卷内结构
                    if (!stripped && path.startsWith("/storage/")) {
                        val rest = path.removePrefix("/storage/")
                        val slash = rest.indexOf('/')
                        path = if (slash >= 0) rest.substring(slash + 1) else ""
                    }
                    path
                }
                else -> return null
            }
            val segments = relative.split('/').filter { it.isNotEmpty() }
            if (segments.any { it == "." || it == ".." }) return null
            if (segments.isEmpty()) return INTERNAL_STORAGE_DISPLAY
            val display = segments.toMutableList()
            if (display.first().equals("Download", ignoreCase = true)) {
                display[0] = DOWNLOADS_TREE_DISPLAY
            }
            return display.joinToString("/")
        }

        /**
         * 是否「记住的目录树已不可用」（纯函数，JVM 单测覆盖）。
         *
         * 判定为不可用时调用方会清除记住的目录并让用户重选一次：
         * - SecurityException（持久授权被系统回收）；
         * - FileNotFoundException（目录被删除 / 卷卸载）；
         * - 消息含 permission denial / EACCES / no such file / unavailable。
         *
         * 与 [isPermissionFailure] 分开：后者用于旧链路的 MediaStore 回退
         * 决策，目录树模式不写 MediaStore。
         */
        internal fun isTreeUnavailable(error: Throwable?): Boolean {
            var cause: Throwable? = error
            while (cause != null) {
                if (cause is SecurityException || cause is FileNotFoundException) return true
                val message = cause.message?.lowercase().orEmpty()
                if (message.contains("permission denial") ||
                    message.contains("permission denied") ||
                    message.contains("eacces") ||
                    message.contains("no such file") ||
                    message.contains("not found") ||
                    message.contains("failed to find") ||
                    message.contains("unavailable")
                ) {
                    return true
                }
                cause = cause.cause
            }
            return false
        }

        /**
         * 从 SAF 文档推导 MediaStore Downloads 的目标相对路径（P1-1，纯函数）。
         *
         * 回退写必须落在用户刚选择的子目录（如 `下载/legado/`），否则用户
         * 在系统对话框里选的是 A、实际文件却出现在「下载」根，提示只显示
         * 文件名时根本无法定位。
         *
         * 数据来源优先级（调用方按此顺序收集后传入）：
         * 1. [queriedRelativePath]：provider / MediaStore 查询到的 RELATIVE_PATH
         *    （`msf:` 走 `MediaStore.Files` 按 `_id` 查询；数字 id 走显示名查询）；
         * 2. [documentId]：`raw:` 绝对路径或 `primary:` 存储根相对路径；
         * 3. [resolvedPath]：查询到的绝对文件路径（如 provider 的 `_data`）。
         *
         * 返回带尾斜杠的 `Download/…/`；无法确定或不在「下载」子树内返回
         * null —— 调用方必须明确报错，**绝不静默写「下载」根**。
         */
        internal fun resolveRelativePath(
            documentId: String?,
            resolvedPath: String?,
            queriedRelativePath: String?
        ): String? {
            normalizeDownloadRelativePath(queriedRelativePath)?.let { return it }
            relativePathOfDocumentId(documentId)?.let { return it }
            return downloadRelativePathOfFile(resolvedPath)
        }

        /**
         * 规范化 provider 给出的 RELATIVE_PATH：仅接受「下载」子树，输出带
         * 尾斜杠的 `Download/…/`；空串、越界段（`.`/`..`）、非「下载」目录
         * 返回 null。
         */
        internal fun normalizeDownloadRelativePath(raw: String?): String? {
            val text = raw?.trim()?.replace('\\', '/') ?: return null
            if (text.isEmpty()) return null
            val segments = text.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty()) return null
            // 仅认 MediaStore 标准「Download」目录（大小写敏感，避免新建
            // 出 downloads/ 之类的重复目录）
            if (segments.first() != "Download") return null
            if (segments.any { it == "." || it == ".." }) return null
            return segments.joinToString("/") + "/"
        }

        /** `raw:` / `primary:` 文档 id → 「下载」相对路径；其他形态返回 null */
        internal fun relativePathOfDocumentId(documentId: String?): String? {
            val id = documentId?.trim() ?: return null
            return when {
                id.startsWith("raw:", ignoreCase = true) ->
                    downloadRelativePathOfFile(id.substring(4))
                id.startsWith("primary:", ignoreCase = true) ->
                    downloadRelativePathOfRelativeDocPath(id.substring(8))
                else -> null
            }
        }

        /**
         * 绝对文件路径 → 「下载」相对目录（取文件所在目录）。
         *
         * 仅支持主存储；文件直接把「下载」根当父目录时返回 `Download/`。
         * 路径含 `.`/`..` 段、不在「下载」子树或非主存储均返回 null。
         */
        internal fun downloadRelativePathOfFile(filePath: String?): String? {
            val path = filePath?.trim()?.replace('\\', '/') ?: return null
            if (path.isEmpty() || !path.contains('/')) return null
            val parent = path.substringBeforeLast('/', "")
            if (parent.isEmpty()) return null
            for (root in PRIMARY_DOWNLOAD_ROOTS) {
                if (parent == root) return DOWNLOAD_RELATIVE_ROOT
                if (parent.startsWith("$root/")) {
                    return subDirectoryRelativePath(parent.removePrefix("$root/"))
                }
            }
            return null
        }

        /**
         * 存储根相对文档路径（`primary:` 之后，如 `Download/legado/x.json`）
         * → 「下载」相对目录。文档路径必须是文件（取父目录）；非「下载」
         * 子树返回 null。
         */
        internal fun downloadRelativePathOfRelativeDocPath(docPath: String?): String? {
            val path = docPath?.trim()?.replace('\\', '/') ?: return null
            if (path.isEmpty()) return null
            val parent = path.substringBeforeLast('/', "")
            if (parent.isEmpty()) return null
            val segments = parent.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty() || segments.first() != "Download") return null
            if (segments.any { it == "." || it == ".." }) return null
            return segments.joinToString("/") + "/"
        }

        /** 「下载」下的子目录（存储根相对）→ 带尾斜杠的相对路径 */
        private fun subDirectoryRelativePath(sub: String): String? {
            val segments = sub.split('/').filter { it.isNotEmpty() }
            if (segments.isEmpty()) return DOWNLOAD_RELATIVE_ROOT
            if (segments.any { it == "." || it == ".." }) return null
            return DOWNLOAD_RELATIVE_ROOT + segments.joinToString("/") + "/"
        }

        /**
         * 文档 id → MediaStore 行 id（纯函数）。
         *
         * 仅解析 `msf:<id>`（MediaStore 行 id）。纯数字文档 id 不在此处理：
         * 本 ROM 的 DownloadsProvider 用 legacy downloads 表的**行 id**（与
         * MediaStore `_id` 不在同一 id 空间，实测 document/7 对应
         * MediaStore 行 1000001407），按 `_id` 查会命中无关文件；数字 id
         * 改走「显示名 + 最近修改」查询。
         */
        internal fun mediaStoreIdOf(documentId: String?): Long? {
            val id = documentId?.trim() ?: return null
            if (!id.startsWith("msf:", ignoreCase = true)) return null
            return id.substring(4).trim().toLongOrNull()?.takeIf { it > 0L }
        }

        /**
         * 是否「权限/文件形态」失败（P3-1 纯函数）。
         *
         * 回退触发条件在原有 SecurityException / permission denial 之上放宽：
         * FileNotFoundException（含 `open failed: EACCES`）、消息含
         * `permission denied` / `EACCES` / `operation not permitted` 均视为
         * provider 拒写候选（异常链逐层检查）。
         */
        internal fun isPermissionFailure(error: Throwable?): Boolean {
            var cause: Throwable? = error
            while (cause != null) {
                if (cause is SecurityException || cause is FileNotFoundException) return true
                val message = cause.message?.lowercase().orEmpty()
                if (message.contains("permission denial") ||
                    message.contains("permission denied") ||
                    message.contains("requires android.permission") ||
                    message.contains("eacces") ||
                    message.contains("operation not permitted")
                ) {
                    return true
                }
                cause = cause.cause
            }
            return false
        }

        /**
         * 是否进入「下载」回退候选（P3-1）：
         * 写流从未打开，且 openOutputStream 返回 null 或异常呈权限/文件形态。
         */
        internal fun shouldAttemptFallback(
            opened: Boolean,
            openReturnedNull: Boolean,
            error: Throwable?
        ): Boolean = !opened && (openReturnedNull || isPermissionFailure(error))

        /**
         * 失败后是否删除 SAF 文档（P2-2 / P2-4 纯函数）。
         *
         * - preSize == null（provider 无 SIZE 或查询失败）→ 不删（无法确认
         *   是否含用户内容）；
         * - preSize > 0（用户选择「替换」的已有文件）→ 不删，只报错；
         * - preSize < 0（provider 报不可知，如 -1）→ 并入「未知」不删（P3-3）；
         * - preSize == 0 → 删除：opened=true 为本次已新建/截断写流，
         *   opened=false 为 `CREATE_DOCUMENT` 刚建、写流被拒的空文档
         *   （P2-4，消除重名漂移）。0 字节文档不含用户内容。
         */
        internal fun shouldDeleteAfterFailure(opened: Boolean, preSize: Long?): Boolean {
            val size = preSize ?: return false
            // P3-3：-1 等负数是 provider 的「不可知」语义，绝不当成 0 删除
            if (size != 0L) return false
            // size == 0：opened=true 为本次已新建/截断写流，opened=false 为
            // CREATE_DOCUMENT 刚建、写流被拒的空文档；两者都不含用户内容。
            return true
        }

        /**
         * 读回大小是否通过严格校验（旧 `useTree=false` 链路告警口径）。
         *
         * 读不到（null）或 provider 报不可知（负数）一律视为异常并记 W
         * 日志，但旧链路**返回成功不删除**（文件可能已写入）。目录树链路
         * 改用 [readbackSizeVerdict] / [verifyReadback]：SIZE 未知时降级
         * 为全文扫描，绝不因 provider 不报 SIZE 就删掉刚写成功的文件。
         */
        internal fun isReadbackSizeValid(expected: Int, actual: Long?): Boolean =
            actual != null && actual >= 0L && actual == expected.toLong()

        /**
         * 读回 SIZE 判定（P1-1 / 批26c P2-1 纯函数，枚举放在类层级以便
         * 测试直接引用）。
         *
         * [P2-1] `expected > 0 && actual == 0` 同样降级为
         * [ReadbackSizeVerdict.UNKNOWN]：部分第三方 provider 在写入成功后
         * **短暂**上报 `COLUMN_SIZE=0`（索引/落盘延迟、pending 状态等）。
         * 若把 0 当可信值直接判 MISMATCH，`writeViaTree` /
         * `writeToMediaStoreDownloads` 的失败清理会删除刚写成功的文件。
         * 降级后由 [verifyWritten] 全文扫描（openInputStream 实际字节数）
         * 终判：长度一致仍算成功；长度不一致仍失败，不放行。
         *
         * 顺序说明：`expected == actual` 先判，故 `expected == 0 && actual == 0`
         * 仍是 MATCH；只有「期望非 0 而实际 0」才降级。
         */
        internal fun readbackSizeVerdict(
            expected: Int,
            actual: Long?
        ): ReadbackSizeVerdict = when {
            actual == null || actual < 0L -> ReadbackSizeVerdict.UNKNOWN
            actual == expected.toLong() -> ReadbackSizeVerdict.MATCH
            // P2-1：SIZE=0 不可信 → 降级全文扫描，绝不因它误删已写文件
            expected > 0 && actual == 0L -> ReadbackSizeVerdict.UNKNOWN
            else -> ReadbackSizeVerdict.MISMATCH
        }

        /**
         * 读回校验结论（P1-1 / P2-1 纯函数）：null = 通过，非 null = 失败原因。
         *
         * - SIZE 已知且不等 → 失败（不读取内容）；
         * - SIZE 已知且相等 → 只校验首字节；
         * - SIZE 未知（null/负数/期望非 0 却报 0）→ 用 [scannedLength]
         *   （openInputStream 全文读取的字节数）替代 SIZE，仍须与写入长度
         *   相等且首字节一致。
         *
         * 该函数是 P1-1/P2-1 的判定核心：修复前 null/负数/0 直接判失败，
         * 导致 provider 不报 SIZE 或短暂报 0 时刚写成功的文件被误删。
         */
        internal fun verifyReadback(
            expected: Int,
            declaredSize: Long?,
            scannedLength: Long?,
            headMatches: Boolean
        ): String? = when (readbackSizeVerdict(expected, declaredSize)) {
            ReadbackSizeVerdict.MISMATCH ->
                "读回大小校验失败：期望 $expected，实际 $declaredSize"
            ReadbackSizeVerdict.MATCH ->
                if (headMatches) null else "读回首字节不一致"
            ReadbackSizeVerdict.UNKNOWN -> when {
                scannedLength == null -> "读回内容长度不可知"
                scannedLength != expected.toLong() ->
                    "读回内容长度校验失败：期望 $expected，实际 $scannedLength"
                !headMatches -> "读回首字节不一致"
                else -> null
            }
        }

        /** 错误码 → 面向用户的中文短句（P2-3；Dart 侧 `_friendlyReason` 同口径） */
        internal fun reasonOf(code: String): String = when (code) {
            "INVALID_ARGS" -> "文件名或导出内容无效"
            "EMPTY_BYTES" -> "导出内容为空，未创建文件"
            "ALREADY_PENDING" -> "已有另存请求进行中，请稍候重试"
            "SAVE_START_FAILED" -> "无法打开系统保存对话框，请重试"
            "NO_URI" -> "系统未返回保存位置，请重试"
            "TIMEOUT" -> "等待系统保存对话框超时，请重试"
            "ACTIVITY_DESTROYED" -> "页面已销毁，另存请求中断"
            "SAVE_VERIFY_FAILED" -> "写入校验失败，文件未保存，请重试或换一个文件夹"
            "TREE_UNAVAILABLE" -> "保存文件夹不可用，请重新选择文件夹后重试"
            "TREE_WRITE_FAILED" -> "无法写入所选文件夹，请换一个文件夹重试"
            "TREE_NOT_WRITABLE" -> "该文件夹不可写，请换一个"
            "TREE_UNSUPPORTED" -> "当前系统不支持选择文件夹，请改用系统另存对话框"
            "FALLBACK_PATH_UNKNOWN" ->
                "无法确定所选文件夹，请选择内部存储 > Download 或子文件夹后重试"
            "LEGACY_NOT_SUPPORTED" ->
                "Android 10 以下暂不支持保存到下载目录，请选择其他位置"
            "SAVE_FAILED" -> "无法写入所选位置，请换一个文件夹重试"
            else -> "保存失败，请重试"
        }
    }

    /**
     * 读回 SIZE 判定（P1-1 / P2-1 纯函数）：null/负数（SAF 允许 provider
     * 不报大小）与「期望非 0 却报 0」（第三方 provider 写入后短暂上报）
     * 均 → UNKNOWN，调用方必须降级为内容扫描；只有已知且确实不相等
     * 才算 MISMATCH。定义在类层级便于 JVM 单测直接引用。
     */
    internal enum class ReadbackSizeVerdict { MATCH, MISMATCH, UNKNOWN }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingActivity: Activity? = null
    private var pendingBytes: ByteArray? = null
    private var pendingFileName: String? = null
    private var pendingMimeType: String? = null

    /** 本次 pending 是否只是选目录（`chooseTree`），不写字节 */
    private var pendingPickOnly = false

    /**
     * 后台写流进行中（目录树直存 / 旧 CREATE_DOCUMENT 链路共用）。
     *
     * 旧链路在 `onActivityResult` 入口已清除 pending，若无该标志，后台
     * 写线程期间 `isBusy()` 会短暂返回 false，允许并发另存（P3-3）。
     */
    private var writeInFlight = false

    /** P3-6：是否刚发生过超时（用于区分「迟到的结果」与「无主的回调」） */
    private var timedOutPending = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /** P3-3 超时复位（仅在 pending 期间挂载，结果/销毁时移除） */
    private val pendingTimeout = Runnable {
        val result = pendingResult
        timedOutPending = true
        clearPending()
        if (result != null) {
            try {
                replyError(
                    result,
                    "TIMEOUT",
                    "等待系统保存对话框超过 ${PENDING_TIMEOUT_MS / 1000} 秒未返回"
                )
            } catch (_: Exception) {
                // 引擎/通道已销毁时回复可能失败，忽略
            }
        }
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            METHOD_SAVE_FILE -> saveFile(call, result, activity)
            METHOD_CHOOSE_TREE -> chooseTree(result, activity)
            METHOD_GET_SAVED_TREE -> result.success(readTree(activity)?.toMap())
            else -> result.notImplemented()
        }
    }

    /** 是否已有请求在途（含目录树直存与旧链路后台写流） */
    private fun isBusy(): Boolean = pendingResult != null || writeInFlight

    /**
     * 启动系统另存（批26：目录树优先）
     *
     * - `useTree=false`：旧 `ACTION_CREATE_DOCUMENT` 链路（回退）；
     * - `useTree=true` + 已记住目录：直接后台建文件写入，不弹框；
     * - 未记住目录 / `chooseTree=true`：先弹目录选择器再写入。
     */
    private fun saveFile(
        call: MethodCall,
        result: MethodChannel.Result,
        activity: Activity
    ) {
        if (isBusy()) {
            replyError(result, "ALREADY_PENDING", "已有另存请求进行中")
            return
        }
        val rawFileName = call.argument<String>("fileName")
        // Dart Uint8List 经 StandardMessageCodec 落地为 byte[]；兼容整数列表
        val bytes = StorageBridge.bytesFromArgument(call.argument("bytes"))
        val invalidCode = validateArgs(rawFileName, bytes)
        if (invalidCode != null) {
            replyError(
                result,
                invalidCode,
                if (invalidCode == "EMPTY_BYTES") {
                    "bytes 长度 0"
                } else {
                    "fileName=${rawFileName ?: "null"}, bytes=${bytes?.size ?: "null"}"
                }
            )
            return
        }
        // P3-5：非法字符净化后再交给系统对话框（provider 可能拒绝含 / : ? 等名字）
        val fileName = normalizeFileName(rawFileName!!)
        if (fileName.isEmpty()) {
            replyError(result, "INVALID_ARGS", "fileName 净化后为空：$rawFileName")
            return
        }
        val mimeType = resolveMimeType(fileName, call.argument<String>("mimeType"))
        val useTree = call.argument<Boolean>("useTree") ?: true
        val chooseTree = call.argument<Boolean>("chooseTree") ?: false
        // validateArgs 已拒绝 null；显式解包以满足非空参数
        val payload = bytes!!

        if (!useTree) {
            // 回退链路：保留 ACTION_CREATE_DOCUMENT（tree 不可用/用户显式选择）
            startCreateDocumentSave(result, activity, payload, fileName, mimeType)
            return
        }
        val remembered = readTree(activity)
        if (chooseTree || remembered == null) {
            startTreePickForSave(result, activity, payload, fileName, mimeType)
            return
        }
        // 已记住目录：直接建文件写入；目录失效时清除记录并重选一次
        writeWithRememberedTree(
            result, activity, remembered, payload, fileName, mimeType, allowRepick = true
        )
    }

    /**
     * 已记住目录的直接写入（后台线程；不弹系统对话框）。
     *
     * [allowRepick] 仅对「记住的目录」为 true：目录失效（持久授权被回收/
     * 目录被删）时清除记录并弹一次目录选择器；用户刚选的目录再失败则按
     * 结构化错误返回（避免反复弹框）。
     */
    private fun writeWithRememberedTree(
        result: MethodChannel.Result,
        activity: Activity,
        tree: TreeRecord,
        bytes: ByteArray,
        fileName: String,
        mimeType: String,
        allowRepick: Boolean
    ) {
        writeInFlight = true
        Thread {
            // 最外层兜底（含 Error）：后台线程任何逃逸异常都不能让 Dart
            // Future 永久挂起
            val outcome = try {
                writeViaTree(activity, tree, bytes, fileName, mimeType)
            } catch (t: Throwable) {
                Log.e(TAG, "目录树另存后台任务异常：${technicalDetail(t)}", t)
                WriteOutcome(code = "TREE_WRITE_FAILED", detail = technicalDetail(t))
            }
            mainHandler.post {
                writeInFlight = false
                if (outcome.saved != null) {
                    result.success(outcome.saved.toMap())
                    return@post
                }
                if (allowRepick &&
                    outcome.code == "TREE_UNAVAILABLE" &&
                    isActivityAlive(activity)
                ) {
                    Log.w(TAG, "记住的保存目录不可用，清除后重选一次：${tree.uri}")
                    clearTree(activity)
                    startTreePickForSave(result, activity, bytes, fileName, mimeType)
                    return@post
                }
                replyError(result, outcome.code, outcome.detail, treeUriOrNull(tree.uri))
            }
        }.start()
    }

    /** Activity 是否仍可启动系统对话框（避免在销毁后 startActivityForResult） */
    private fun isActivityAlive(activity: Activity): Boolean =
        !activity.isFinishing && !activity.isDestroyed

    /** 旧链路：ACTION_CREATE_DOCUMENT（注册 pending 后启动系统保存对话框） */
    private fun startCreateDocumentSave(
        result: MethodChannel.Result,
        activity: Activity,
        bytes: ByteArray,
        fileName: String,
        mimeType: String
    ) {
        registerPending(result, activity, bytes, fileName, mimeType, pickOnly = false)
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE_SAVE_FILE)
        } catch (e: Exception) {
            clearPending()
            replyError(
                result,
                "SAVE_START_FAILED",
                e.message ?: e.javaClass.simpleName
            )
        }
    }

    /**
     * 目录树选择（保存前首次选择）
     *
     * 系统没有目录选择器时**自动回退** ACTION_CREATE_DOCUMENT 并记日志；
     * 启动异常同样回退（不能把保存流程卡死在不可用入口）。
     */
    private fun startTreePickForSave(
        result: MethodChannel.Result,
        activity: Activity,
        bytes: ByteArray,
        fileName: String,
        mimeType: String
    ) {
        registerPending(result, activity, bytes, fileName, mimeType, pickOnly = false)
        try {
            activity.startActivityForResult(buildTreePickerIntent(activity), REQUEST_CODE_PICK_TREE)
        } catch (e: Exception) {
            clearPending()
            Log.w(TAG, "打开目录选择器失败，回退 ACTION_CREATE_DOCUMENT：${e.message}")
            startCreateDocumentSave(result, activity, bytes, fileName, mimeType)
        }
    }

    /** 主动「换个位置」：仅选择并记住目录，不写文件 */
    private fun chooseTree(result: MethodChannel.Result, activity: Activity) {
        if (isBusy()) {
            replyError(result, "ALREADY_PENDING", "已有另存请求进行中")
            return
        }
        registerPending(result, activity, null, null, null, pickOnly = true)
        try {
            activity.startActivityForResult(buildTreePickerIntent(activity), REQUEST_CODE_PICK_TREE)
        } catch (e: ActivityNotFoundException) {
            clearPending()
            replyError(result, "TREE_UNSUPPORTED", e.message ?: e.javaClass.simpleName)
        } catch (e: Exception) {
            clearPending()
            replyError(result, "SAVE_START_FAILED", e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * 构造目录选择 Intent
     *
     * 带上 READ/WRITE/PERSISTABLE 授权标志（持久授权必须显式申请）；
     * 已记住目录时以其为初始位置，方便用户在原目录附近换位置。
     *
     * 不做 `resolveActivity` 预检：Android 11+ 包可见性过滤会让系统
     * DocumentsUI 探测为 null（假阴性），改为启动时捕获
     * `ActivityNotFoundException` 再决定回退。
     */
    private fun buildTreePickerIntent(activity: Activity): Intent {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            // EXTRA_INITIAL_URI 自 API 26 起可用；低版本忽略即可
            readTree(activity)?.uri?.let { uri ->
                runCatching {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(uri))
                }.onFailure {
                    Log.w(TAG, "设置目录选择初始位置失败：${it.message}")
                }
            }
        }
        return intent
    }

    /** 注册 pending（系统对话框等待 + 超时复位） */
    private fun registerPending(
        result: MethodChannel.Result,
        activity: Activity,
        bytes: ByteArray?,
        fileName: String?,
        mimeType: String?,
        pickOnly: Boolean
    ) {
        pendingResult = result
        pendingActivity = activity
        pendingBytes = bytes
        pendingFileName = fileName
        pendingMimeType = mimeType
        pendingPickOnly = pickOnly
        timedOutPending = false
        mainHandler.removeCallbacks(pendingTimeout)
        mainHandler.postDelayed(pendingTimeout, PENDING_TIMEOUT_MS)
    }

    /**
     * Activity 结果回调（由 MainActivity 转发）
     *
     * 目录选择（保存前 / 换个位置）与旧 CREATE_DOCUMENT 分别处理；用户取消
     * 回 success(null)；RESULT_OK 但无 URI 回 NO_URI（P3-3）。超时/复位后
     * 迟到的回调记录日志（P3-6），不静默丢弃。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQUEST_CODE_PICK_TREE -> onTreePickResult(resultCode, data)
            REQUEST_CODE_SAVE_FILE -> onCreateDocumentResult(resultCode, data)
        }
    }

    /**
     * 目录树选择结果：持久授权 + 记住目录；`pickOnly` 直接回选择结果，
     * 保存请求则继续在后台建文件写入。
     */
    private fun onTreePickResult(resultCode: Int, data: Intent?) {
        val result = pendingResult
        if (result == null) {
            logLateResult("目录选择", resultCode, data?.data)
            return
        }
        val activity = pendingActivity
        val bytes = pendingBytes
        val fileName = pendingFileName
        val mimeType = pendingMimeType
        val pickOnly = pendingPickOnly
        clearPending()

        if (resultCode != Activity.RESULT_OK) {
            // 用户取消：与「取消不提示」语义一致
            result.success(null)
            return
        }
        val treeUri: Uri? = data?.data
        if (treeUri == null) {
            replyError(result, "NO_URI", "RESULT_OK 但目录树 data.data 为空")
            return
        }
        if (activity == null) {
            replyError(result, "SAVE_FAILED", "pending 请求参数已丢失（activity）")
            return
        }
        // P2-2：只按系统实际授予的 flags 取持久授权；无 WRITE 或 take 失败
        // 不记住目录，直接回「该文件夹不可写，请换一个」。
        val persisted = persistTree(activity, treeUri, data?.flags ?: 0)
        val tree = persisted.tree
        if (tree == null) {
            replyError(
                result,
                persisted.code ?: "TREE_NOT_WRITABLE",
                persisted.detail,
                treeUri
            )
            return
        }
        if (pickOnly) {
            result.success(tree.toMap())
            return
        }
        if (bytes == null || fileName == null || mimeType == null) {
            replyError(result, "SAVE_FAILED", "pending 请求参数已丢失")
            return
        }
        // 写流在后台线程；主线程只负责回 result（含失败重选逻辑）
        writeWithRememberedTree(
            result, activity, tree, bytes, fileName, mimeType, allowRepick = false
        )
    }

    /** 旧链路 CREATE_DOCUMENT 结果（行为保持不变，仅抽出方法） */
    private fun onCreateDocumentResult(resultCode: Int, data: Intent?) {
        val result = pendingResult
        if (result == null) {
            logLateResult("另存", resultCode, data?.data)
            return
        }
        val activity = pendingActivity
        val bytes = pendingBytes
        val fileName = pendingFileName
        val mimeType = pendingMimeType
        clearPending()

        if (resultCode != Activity.RESULT_OK) {
            // 用户取消：与「取消不提示」语义一致
            result.success(null)
            return
        }
        val uri: Uri? = data?.data
        if (uri == null) {
            replyError(result, "NO_URI", "RESULT_OK 但 data.data 为空")
            return
        }
        if (activity == null || bytes == null || fileName == null) {
            replyError(result, "SAVE_FAILED", "pending 请求参数已丢失")
            return
        }

        // 写流 + 授权回收全部在后台线程，主线程只负责回 result。
        // P3-3：pending 已清除，用 writeInFlight 让后台写期间的 isBusy
        // 与目录树直存保持同一口径（拒绝并发另存）。
        writeInFlight = true
        Thread {
            // 最外层兜底（含 Error）：后台线程任何逃逸异常都不能让 Dart
            // Future 永久挂起（pending 已在回调入口清除，5 分钟超时不再生效）
            val outcome = try {
                writeOnBackground(activity, uri, bytes, fileName, mimeType)
            } catch (t: Throwable) {
                Log.e(TAG, "另存后台任务异常：${technicalDetail(t)}", t)
                WriteOutcome(code = "SAVE_FAILED", detail = technicalDetail(t))
            }
            mainHandler.post {
                writeInFlight = false
                reportWriteOutcome(result, outcome, uri)
            }
        }.start()
    }

    /** 无 pending 的回调：区分超时迟到与 Activity 重建（P3-6） */
    private fun logLateResult(scene: String, resultCode: Int, uri: Uri?) {
        if (timedOutPending) {
            Log.w(TAG, "${scene}结果迟到（已回 TIMEOUT，忽略写入）：resultCode=$resultCode, uri=$uri")
            timedOutPending = false
        } else {
            Log.w(
                TAG,
                "收到无 pending 的${scene}回调（可能 Activity 重建，忽略）：" +
                    "resultCode=$resultCode, uri=$uri"
            )
        }
    }

    /** 统一回写结果：成功转 Map，失败回结构化错误 */
    private fun reportWriteOutcome(
        result: MethodChannel.Result,
        outcome: WriteOutcome,
        requestUri: Uri?
    ) {
        val saved = outcome.saved
        if (saved != null) {
            result.success(saved.toMap())
        } else {
            replyError(result, outcome.code, outcome.detail, requestUri)
        }
    }

    /** 后台线程写流结果（`saved` 与 `code/detail` 二选一） */
    private class WriteOutcome(
        val saved: SavedDoc? = null,
        val code: String = "SAVE_FAILED",
        val detail: String? = null
    )

    /** 落盘结果（[relativeDir] 仅 MediaStore 回退有值，如 `Download/legado/`） */
    private class SavedDoc(
        val uri: Uri,
        val displayName: String,
        val viaMediaStore: Boolean,
        val relativeDir: String? = null,
        /** 批26：经 SAF 目录树写入 */
        val viaTree: Boolean = false,
        /** 批26：目录树显示路径（如 `下载/legado`） */
        val displayPath: String? = null
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "uri" to uri.toString(),
            "name" to displayName,
            "fallback" to if (viaMediaStore) "mediastore" else "none",
            "relativeDir" to relativeDir,
            "viaTree" to viaTree,
            "displayPath" to displayPath
        )
    }

    /**
     * 记住的保存目录（SharedPreferences 记录 uri + 显示路径 + authority）
     *
     * 显示路径用于保存成功提示与「换个位置」入口；authority 便于排障
     * （不同 ROM 的 DocumentsProvider 实现差异较大）。
     */
    private class TreeRecord(
        val uri: String,
        val displayPath: String?,
        val authority: String?
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "uri" to uri,
            "displayPath" to displayPath,
            "authority" to authority
        )
    }

    /**
     * 目录树持久授权结果（P2-2）：[tree] 非 null 表示已记住；
     * 否则 [code]/[detail] 说明为何不能记住（不写入 prefs）。
     */
    private class TreePersistResult(
        val tree: TreeRecord? = null,
        val code: String? = null,
        val detail: String? = null
    )

    /** 读回校验失败（区分普通 IO 失败，便于回 SAVE_VERIFY_FAILED） */
    private class VerifyException(message: String) : IOException(message)

    /**
     * 目录树内建文件 + 写入 + 严格读回（批26 主路径，对齐原版
     * `DocumentFile.fromTreeUri(...).createFile(...).writeBytes(...)`）。
     *
     * [P3-1] `createDocument` 按 Android SAF 常规行为返回**本次新建**的
     * 文档（同名时 provider 自动追加 ` (N)`，而不是返回已有文档）；本方法
     * 的失败清理因此只删 `created`，不会误删目录中的其他文件。该假设
     * 同步记录在 Dart 通道契约 `file_save_channel.dart` 的 `saveFile` 注释。
     *
     * 失败清理规则：**只删除本次 createDocument 创建的那个文档**
     * （`created`），绝不碰目录里的其他文件；树授权内删除可用，因此
     * 不会再留下 0 字节占位（旧 CREATE_DOCUMENT 链路在该 ROM 上删不掉）。
     *
     * 错误码分派：
     * - `SAVE_VERIFY_FAILED`：写入后大小/首字节校验失败（已删除本次文件）；
     * - `TREE_UNAVAILABLE`：记住的目录失效（授权回收/目录被删），调用方
     *   清除记录并重选一次；
     * - `TREE_WRITE_FAILED`：provider 拒绝创建/写入（磁盘满、只读目录等）。
     */
    private fun writeViaTree(
        activity: Activity,
        tree: TreeRecord,
        bytes: ByteArray,
        fileName: String,
        mimeType: String
    ): WriteOutcome {
        val resolver = activity.contentResolver
        val treeUri = Uri.parse(tree.uri)
        var created: Uri? = null
        try {
            val parentDocId = DocumentsContract.getTreeDocumentId(treeUri)
            val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDocId)
            val docUri = DocumentsContract.createDocument(
                resolver,
                parentUri,
                mimeType,
                fileName
            ) ?: throw IOException("createDocument 返回 null（tree=$treeUri, name=$fileName）")
            created = docUri
            Log.i(TAG, "目录树建文件：tree=$treeUri, doc=$docUri, name=$fileName")
            val output = resolver.openOutputStream(docUri)
                ?: throw IOException("openOutputStream 返回 null：$docUri")
            output.use { stream ->
                stream.write(bytes)
                stream.flush()
            }
            // 严格读回（大小精确 + 首字节一致），失败即删除本次文件
            verifyWritten(resolver, docUri, bytes)
            // provider 重名时可能返回 `xxx (1).json`，以查询到的实际名为准
            val actualName = queryDisplayName(resolver, docUri) ?: fileName
            Log.i(
                TAG,
                "目录树写入成功：uri=$docUri, name=$actualName, display=${tree.displayPath}"
            )
            return WriteOutcome(
                saved = SavedDoc(
                    uri = docUri,
                    displayName = actualName,
                    viaMediaStore = false,
                    relativeDir = null,
                    viaTree = true,
                    displayPath = tree.displayPath
                )
            )
        } catch (t: Throwable) {
            val detail = technicalDetail(t)
            val code = when {
                // 校验失败优先：文件刚创建却读回不一致，重选目录未必有帮助
                t is VerifyException -> "SAVE_VERIFY_FAILED"
                isTreeUnavailable(t) -> "TREE_UNAVAILABLE"
                else -> "TREE_WRITE_FAILED"
            }
            Log.e(TAG, "目录树保存失败（$code）：tree=$treeUri, doc=$created, detail=$detail", t)
            // 只删本次创建的文件；删除失败只记日志（provider 可能拒绝）
            created?.let { deleteDocument(resolver, it) }
            return WriteOutcome(code = code, detail = detail)
        }
    }

    // ---------- 记住的保存目录（SharedPreferences） ----------

    /** 读取已记住的目录树；未记住/记录损坏返回 null */
    private fun readTree(context: Context): TreeRecord? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val uri = prefs.getString(KEY_TREE_URI, null)?.trim()?.takeIf { it.isNotEmpty() }
            ?: return null
        return TreeRecord(
            uri = uri,
            displayPath = prefs.getString(KEY_TREE_DISPLAY_PATH, null),
            authority = prefs.getString(KEY_TREE_AUTHORITY, null)
        )
    }

    /**
     * 记住用户选择的目录树（并申请持久授权）。
     *
     * [P2-2] `intentFlags` 必须是系统回传的 `Intent.flags`：只取实际授予的
     * READ/WRITE 位。无写授权或 `takePersistableUriPermission` 失败时
     * **不写入 prefs**，返回 `TREE_NOT_WRITABLE`（中文「该文件夹不可写，
     * 请换一个」）——否则只读目录会被记住，之后每次保存都循环失败。
     *
     * [P3-6] take 成功后再查目录文档的 `COLUMN_FLAGS`：provider 明确未
     * 声明 `FLAG_DIR_SUPPORTS_CREATE` 时同样拒绝并回收刚取得的授权
     * （查询不到时按未知放行，兼容不实现该位的第三方 provider）。
     *
     * [P3-2] prefs 写入改用 `commit()` 同步落盘：`take` 是同步生效的，
     * 若进程在 `apply()` 异步写盘前被杀，会出现「持久授权在、记录不在」
     * 的孤儿 grant。commit 失败时回收刚取得的授权，避免 grant 泄漏。
     *
     * 换目录成功时释放旧目录的持久授权，避免 grant 累积。
     */
    private fun persistTree(
        activity: Activity,
        treeUri: Uri,
        intentFlags: Int
    ): TreePersistResult {
        val takeFlags = persistableFlags(intentFlags)
        val grantError = treeGrantErrorCode(intentFlags)
        if (grantError != null) {
            Log.w(
                TAG,
                "目录选择结果无写授权，未记住目录：uri=$treeUri, " +
                    "intentFlags=0x${Integer.toHexString(intentFlags)}"
            )
            return TreePersistResult(
                code = grantError,
                detail = "系统未授予写权限（intentFlags=" +
                    "0x${Integer.toHexString(intentFlags)}）"
            )
        }
        try {
            activity.contentResolver.takePersistableUriPermission(treeUri, takeFlags)
        } catch (e: Exception) {
            Log.w(TAG, "takePersistableUriPermission 失败（不记住目录）：${e.message}")
            return TreePersistResult(
                code = "TREE_NOT_WRITABLE",
                detail = "无法取得持久写入授权：" +
                    (e.message ?: e.javaClass.simpleName)
            )
        }
        // P3-6：provider 明确声明不支持创建子项 → 不记住（否则每次保存
        // 都到写入阶段才失败）；查询不到按未知放行。
        if (queryTreeSupportsCreate(activity.contentResolver, treeUri) == false) {
            Log.w(TAG, "目录声明不支持创建子项，未记住目录：$treeUri")
            releaseTreePermission(
                activity.contentResolver, treeUri.toString(), "目录不支持创建"
            )
            return TreePersistResult(
                code = "TREE_NOT_WRITABLE",
                detail = "目录 COLUMN_FLAGS 未声明 FLAG_DIR_SUPPORTS_CREATE"
            )
        }
        val documentId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            Log.w(TAG, "解析目录树 documentId 失败：${e.message}")
            null
        }
        val displayPath = treeDisplayPath(documentId, treeUri.authority)
        // 换目录时释放旧目录的持久授权，避免授权累积
        val previous = readTree(activity)
        if (previous != null && previous.uri != treeUri.toString()) {
            releaseTreePermission(activity.contentResolver, previous.uri, "换目录")
        }
        // P3-2：commit 同步落盘，与 take 的同步生效对齐（防孤儿 grant）
        val committed = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TREE_URI, treeUri.toString())
            .putString(KEY_TREE_DISPLAY_PATH, displayPath)
            .putString(KEY_TREE_AUTHORITY, treeUri.authority)
            .commit()
        if (!committed) {
            Log.w(TAG, "记住保存目录写入 prefs 失败（commit=false），回收授权：$treeUri")
            releaseTreePermission(
                activity.contentResolver, treeUri.toString(), "prefs 写入失败"
            )
        }
        Log.i(
            TAG,
            "已记住保存目录：uri=$treeUri, display=$displayPath, " +
                "authority=${treeUri.authority}, committed=$committed"
        )
        return TreePersistResult(
            tree = TreeRecord(treeUri.toString(), displayPath, treeUri.authority)
        )
    }

    /** 清除记住的目录（目录失效时调用，下次保存重新弹选择器） */
    private fun clearTree(context: Context) {
        // P2-1：目录失效/换目录失败时清除记录，同时释放该 URI 的持久
        // 授权，避免反复失效累积 grant（`dumpsys uri_grants` 可核对）。
        readTree(context)?.let { previous ->
            releaseTreePermission(context.contentResolver, previous.uri, "清除记住目录")
        }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_TREE_URI)
            .remove(KEY_TREE_DISPLAY_PATH)
            .remove(KEY_TREE_AUTHORITY)
            .apply()
        Log.i(TAG, "已清除记住的保存目录")
    }

    /**
     * 释放目录树的持久授权（P3-1：READ / WRITE **逐位**释放，各自 catch）。
     *
     * `releasePersistableUriPermission` 要求传入的 flags 是**当前实际持有**
     * 授权位的子集；把 READ|WRITE 一起传入时，只持有其一（例如只读目录
     * 只有 READ，或历史遗留的单 READ grant）会整次抛
     * SecurityException，连已持有的那位也释放不掉。逐位释放互不影响。
     *
     * 与 [clearTree] / 换目录 / 记住失败回收共用；个别 ROM 未持有对应
     * 授权位时异常属于预期情况，只记日志不影响业务。
     */
    private fun releaseTreePermission(
        resolver: ContentResolver,
        treeUri: String,
        scene: String
    ) {
        val uri = Uri.parse(treeUri)
        var released = 0
        for ((flag, name) in listOf(
            Intent.FLAG_GRANT_READ_URI_PERMISSION to "READ",
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION to "WRITE"
        )) {
            try {
                resolver.releasePersistableUriPermission(uri, flag)
                released++
            } catch (e: Exception) {
                // 未持有该位（或 provider 拒绝）——另一位仍继续尝试
                Log.w(TAG, "释放目录持久授权失败（$scene，$name）：${e.message}")
            }
        }
        if (released > 0) {
            Log.i(TAG, "已释放目录持久授权（$scene，$released/2 位）：$treeUri")
        } else {
            Log.w(TAG, "目录持久授权未释放（$scene，可能未持有）：$treeUri")
        }
    }

    /** 错误回传带的 URI（记录损坏时为 null，不影响结构化错误） */
    private fun treeUriOrNull(uri: String?): Uri? =
        uri?.let { runCatching { Uri.parse(it) }.getOrNull() }

    /**
     * 后台线程写字节（含回退与授权回收）。
     *
     * 清理规则（P2-2）：open 前先查文档大小，仅 0 字节文档允许
     * deleteDocument；`preSize > 0` 或大小不可知时绝不删除——该 URI
     * 可能指向用户已有文件（选择了「替换」），误删会丢掉用户原内容。
     */
    private fun writeOnBackground(
        activity: Activity,
        uri: Uri,
        bytes: ByteArray,
        fileName: String,
        mimeType: String?
    ): WriteOutcome {
        val resolver = activity.contentResolver
        // 最小权限，避免授权泄漏；仅 take 成功时才在 finally 回收
        var persisted = false
        var opened = false
        var openReturnedNull = false
        try {
            persisted = try {
                resolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                true
            } catch (_: Exception) {
                // 部分 ROM/URI 不支持持久授权：临时授权足够本次写入
                false
            }
            // P2-2：open 前记录文档大小——>0 说明用户选择「替换」的是已有文件，
            // 失败后不得删除（0 字节为空文档才可安全清理，见 shouldDeleteAfterFailure）
            val preSize = queryDocumentSize(resolver, uri)
            Log.i(TAG, "另存开始：uri=$uri, authority=${uri.authority}, preSize=$preSize")
            try {
                val output = resolver.openOutputStream(uri)
                if (output == null) {
                    openReturnedNull = true
                    throw IOException("openOutputStream 返回 null：$uri")
                }
                opened = true
                output.use { stream ->
                    stream.write(bytes)
                    stream.flush()
                }
                // SAF 直写路径：读回大小不一致只告警并返回成功——文件可能已写入，
                // 删除会让用户拿不到内容；不一致作为排障线索记日志。
                val writtenSize = queryLongColumn(resolver, uri, MediaStore.MediaColumns.SIZE)
                if (!isReadbackSizeValid(bytes.size, writtenSize)) {
                    Log.w(
                        TAG,
                        "SIZE 读回异常（SAF 直写，返回成功不删除）：期望 ${bytes.size}，" +
                            "实际 $writtenSize，uri=$uri"
                    )
                }
                val actualName = queryDisplayName(resolver, uri) ?: fileName
                return WriteOutcome(
                    saved = SavedDoc(uri, actualName, viaMediaStore = false)
                )
            } catch (t: Throwable) {
                return handleWriteFailure(
                    resolver = resolver,
                    uri = uri,
                    fileName = fileName,
                    mimeType = mimeType,
                    bytes = bytes,
                    error = t,
                    opened = opened,
                    openReturnedNull = openReturnedNull,
                    preSize = preSize
                )
            }
        } finally {
            if (persisted) {
                try {
                    resolver.releasePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "释放持久化 URI 授权失败：${e.message}")
                }
            }
        }
    }

    /**
     * SAF 写入失败后的分派：可回退则走 MediaStore（P3-1），否则按安全规则
     * 清理残留并回错误（P2-2/P2-4）。
     */
    private fun handleWriteFailure(
        resolver: ContentResolver,
        uri: Uri,
        fileName: String,
        mimeType: String?,
        bytes: ByteArray,
        error: Throwable,
        opened: Boolean,
        openReturnedNull: Boolean,
        preSize: Long?
    ): WriteOutcome {
        val detail = technicalDetail(error)
        if (shouldAttemptFallback(opened, openReturnedNull, error)) {
            Log.i(
                TAG,
                "SAF 写流被拒（openReturnedNull=$openReturnedNull），尝试「下载」回退：" +
                    "authority=${uri.authority}（原崩溃入口 $DOWNLOADS_AUTHORITY）"
            )
            return writeViaDownloadsFallback(
                resolver, uri, fileName, mimeType, bytes, detail, preSize
            )
        }
        val shouldDelete = shouldDeleteAfterFailure(opened, preSize)
        Log.i(
            TAG,
            "另存失败：opened=$opened, preSize=$preSize, 清理=$shouldDelete, " +
                "uri=$uri, detail=$detail"
        )
        if (shouldDelete) deleteDocument(resolver, uri)
        return WriteOutcome(code = "SAVE_FAILED", detail = detail)
    }

    /**
     * MediaStore Downloads 回退（P1-1：目标目录由 SAF 文档推导）。
     *
     * 流程：SDK 门槛 → 推导相对路径（推导不出明确报错）→ MediaStore insert
     * + 写入 + 严格读回（P2-1）→ 清理本次新建的 0 字节 SAF 文档（P2-4）。
     */
    private fun writeViaDownloadsFallback(
        resolver: ContentResolver,
        safUri: Uri,
        fileName: String,
        mimeType: String?,
        bytes: ByteArray,
        causeDetail: String,
        preSize: Long?
    ): WriteOutcome {
        // P2-3：API<29 需运行时 WRITE_EXTERNAL_STORAGE 才能写公开下载目录，
        // 当前无该档位设备可复验（见 docs/DEVICE_ACCEPTANCE_20261027_16X.md
        // §七）→ 明确中文原因引导换位置，绝不静默写别处。
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            deleteEmptySafDocument(resolver, safUri, fileName, preSize, null)
            return WriteOutcome(
                code = "LEGACY_NOT_SUPPORTED",
                detail = "MediaStore 回退需要 Android 10+（当前 API " +
                    "${Build.VERSION.SDK_INT}）：$causeDetail"
            )
        }
        val relativeDir = resolveDownloadRelativePath(resolver, safUri)
        if (relativeDir == null) {
            deleteEmptySafDocument(resolver, safUri, fileName, preSize, null)
            return WriteOutcome(
                code = "FALLBACK_PATH_UNKNOWN",
                detail = "无法从 $safUri 推导「下载」子目录（已拒绝写根目录）：$causeDetail"
            )
        }
        val saved = try {
            writeToMediaStoreDownloads(
                resolver = resolver,
                relativeDir = relativeDir,
                fileName = fileName,
                mimeType = mimeType ?: mimeTypeOf(fileName),
                bytes = bytes
            )
        } catch (t: Throwable) {
            Log.e(TAG, "MediaStore 回退失败（$relativeDir）：${technicalDetail(t)}", t)
            deleteEmptySafDocument(resolver, safUri, fileName, preSize, relativeDir)
            return WriteOutcome(
                code = if (t is VerifyException) "SAVE_VERIFY_FAILED" else "SAVE_FAILED",
                detail = "$causeDetail；回退写入「$relativeDir」失败：${technicalDetail(t)}"
            )
        }
        // 回退成功：清理本次 SAF 新建的 0 字节文档（P2-4），避免重名漂移
        deleteEmptySafDocument(resolver, safUri, fileName, preSize, relativeDir)
        return WriteOutcome(saved = saved)
    }

    /**
     * 按 P2-2/P2-4 规则清理「写流被拒」时残留的空文档。
     *
     * 先走 DocumentsProvider 删除；本 ROM 的 DownloadsProvider 对**删除**
     * 同样抛 `MANAGE_DOCUMENTS`（实测 2026-10-27），因此再尝试按
     * 「显示名 + 0 字节 + 同一目录」删除对应 MediaStore 行（MediaProvider
     * 也可能因非本应用属主拒绝，失败只记日志，不影响已成功的保存）。
     */
    private fun deleteEmptySafDocument(
        resolver: ContentResolver,
        uri: Uri,
        fileName: String,
        preSize: Long?,
        relativeDir: String?
    ) {
        if (!shouldDeleteAfterFailure(opened = false, preSize = preSize)) return
        Log.i(TAG, "清理本次新建的空文档：uri=$uri, name=$fileName, dir=$relativeDir")
        if (deleteDocument(resolver, uri)) return
        deleteEmptyMediaStoreRow(resolver, uri, fileName, relativeDir)
    }

    /**
     * 删除与空文档对应的 MediaStore 行（显示名/大小/目录三项精确匹配）。
     *
     * P3-2：SAF 文档显示名查询为空时不再静默返回——记 W 日志并改用请求
     * `fileName` 兜底查询；仍无可删行时同样记 W（与
     * docs/DEVICE_ACCEPTANCE_20261027_16X.md §7.3.1 的日志链一致）。
     */
    private fun deleteEmptyMediaStoreRow(
        resolver: ContentResolver,
        safUri: Uri,
        fileName: String,
        relativeDir: String?
    ) {
        if (relativeDir == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val queriedName = queryDisplayName(resolver, safUri)
        if (queriedName == null) {
            Log.w(
                TAG,
                "查询 SAF 文档显示名为空，改用请求文件名兜底：uri=$safUri, name=$fileName"
            )
        }
        val displayName = queriedName ?: fileName
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
            "${MediaStore.MediaColumns.SIZE} = 0 AND " +
            "${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        val args = arrayOf(displayName, relativeDir)
        try {
            val rows = resolver.delete(
                MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
                selection,
                args
            )
            if (rows > 0) {
                Log.i(TAG, "已删除 MediaStore 空行：name=$displayName, dir=$relativeDir, rows=$rows")
            } else {
                Log.w(TAG, "未找到可删除的 MediaStore 空行：name=$displayName, dir=$relativeDir")
            }
        } catch (e: Exception) {
            Log.w(TAG, "删除 MediaStore 空行被拒/失败：${e.message}")
        }
    }

    /**
     * 推导 MediaStore Downloads 的目标相对路径（P1-1 运行时部分）。
     *
     * 查询层次（任一命中即用，全部失败返回 null）：
     * 1. 文档 uri 的 `relative_path`（部分 provider 暴露该列）；
     * 2. 文档 uri 的 `_data`（绝对路径）；
     * 3. `msf:<id>` → `MediaStore.Files` 按 `_id` 查 `relative_path`/`_data`
     *    （实测 MuMu Android 15：子目录新建文档返回 `msf:<id>`，行 owner 为空，
     *    `relative_path=Download/legado/`）；
     * 4. 文档显示名 → `MediaStore.Files` 按 `_display_name` 查最新行的
     *    `relative_path`（`CREATE_DOCUMENT` 刚创建的行最新；本 ROM 的
     *    legacy 数字 id 行不在 MediaStore `_id` 空间，也走这一层）。
     *
     * 未命中时：本 ROM 的 DownloadsProvider 对「下载」根新建文档返回 legacy
     * downloads 行的纯数字 id（实测 document/7..11；子目录新建文档为
     * `msf:`），此类 id 只对应根目录文档 → 返回根路径；其余形态返回 null
     * （调用方报错，绝不猜测目录）。
     */
    private fun resolveDownloadRelativePath(resolver: ContentResolver, uri: Uri): String? {
        val documentId = try {
            DocumentsContract.getDocumentId(uri)
        } catch (e: Exception) {
            Log.w(TAG, "解析文档 id 失败（$uri）：${e.message}")
            null
        }
        val docRelative = queryStringColumn(
            resolver, uri, MediaStore.MediaColumns.RELATIVE_PATH
        )
        val docPath = queryStringColumn(resolver, uri, MediaStore.MediaColumns.DATA)
        val mediaStoreId = mediaStoreIdOf(documentId)
        var storeRelative: String? = null
        var storePath: String? = null
        if (mediaStoreId != null) {
            queryMediaStoreRow(resolver, mediaStoreId)?.let { (relative, path) ->
                storeRelative = relative
                storePath = path
            }
        }
        var resolved = resolveRelativePath(
            documentId = documentId,
            resolvedPath = docPath ?: storePath,
            queriedRelativePath = docRelative ?: storeRelative
        )
        // P3-1：显示名兜底查询结果与其它来源同口径规范化；查到 `Downloads/…`
        // 之类非「下载」子树时视为「无法确定」，不猜测目录。
        var rejectedRelative: String? = null
        if (resolved == null) {
            // 4. 显示名兜底：按「文档显示名 + 最新修改」定位 MediaStore 行
            val displayName = queryDisplayName(resolver, uri)
            if (displayName != null) {
                val rawRelative = queryRelativePathByDisplayName(resolver, displayName)
                resolved = normalizeDownloadRelativePath(rawRelative)
                if (resolved != null) {
                    Log.i(TAG, "按显示名 $displayName 定位到回退目录：$resolved")
                } else if (rawRelative != null) {
                    rejectedRelative = rawRelative
                    Log.w(
                        TAG,
                        "按显示名 $displayName 查询到的相对路径不可用（非「下载」子树）：$rawRelative"
                    )
                }
            }
        }
        Log.i(
            TAG,
            "回退目录推导：docId=$documentId, 文档relative_path=$docRelative, " +
                "文档_data=$docPath, MediaStoreId=$mediaStoreId, " +
                "行relative_path=$storeRelative, 行_data=$storePath → $resolved"
        )
        if (resolved != null) return resolved
        // P3-1：显示名兜底查到路径但不合规（如 `Downloads/…`）→ 直接报
        // 「无法确定」，不再回落到 legacy 数字 id 的「下载」根启发式
        if (rejectedRelative != null) return null
        // legacy 数字 id：本 ROM 的 DownloadsProvider 仅对「下载」根文档返回，
        // 子目录文档为 msf:（设备实测），据此确定为根目录；其余情况报错。
        if (uri.authority == DOWNLOADS_AUTHORITY &&
            documentId != null &&
            documentId.toLongOrNull() != null
        ) {
            Log.i(TAG, "legacy downloads 行 id（$documentId）仅对应「下载」根文档 → $DOWNLOAD_RELATIVE_ROOT")
            return DOWNLOAD_RELATIVE_ROOT
        }
        return null
    }

    /**
     * MediaStore Downloads 直写（API 29+，目标目录由调用方推导）。
     *
     * 用 `IS_PENDING=1` 保护未完成写入，写完清除 pending；写后严格读回
     * 校验（P2-1：SIZE 精确相等 + 首 [HEAD_VERIFY_BYTES] 字节一致），
     * 校验失败清理本次 insert 的行并上抛，绝不假成功。
     */
    private fun writeToMediaStoreDownloads(
        resolver: ContentResolver,
        relativeDir: String,
        fileName: String,
        mimeType: String,
        bytes: ByteArray
    ): SavedDoc {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IOException("MediaStore 回退需要 Android 10 (API 29)+")
        }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, relativeDir)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )
        val uri = resolver.insert(collection, values)
            ?: throw IOException("MediaStore insert 返回 null（$relativeDir）")
        var success = false
        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IOException("MediaStore openOutputStream 返回 null：$uri")
            output.use { stream ->
                stream.write(bytes)
                stream.flush()
            }
            // 写入完成：清除 pending，使文件对文件管理器/其他应用可见。
            // 清除失败视为写入失败（pending 文档对其他应用不可见且可能被
            // 系统回收，不能向用户报成功）。
            val done = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            val updated = try {
                resolver.update(uri, done, null, null)
            } catch (e: Exception) {
                throw IOException("清除 IS_PENDING 失败：${e.message}")
            }
            if (updated <= 0) {
                throw IOException("清除 IS_PENDING 未生效（updated=$updated）：$uri")
            }
            // P2-1：严格读回（SIZE 精确 + 首字节一致），失败即清理并上抛
            verifyWritten(resolver, uri, bytes)
            val actualName = queryDisplayName(resolver, uri) ?: fileName
            success = true
            Log.i(TAG, "MediaStore 回退写入成功：uri=$uri, relativeDir=$relativeDir, name=$actualName")
            return SavedDoc(uri, actualName, viaMediaStore = true, relativeDir = relativeDir)
        } finally {
            if (!success) {
                deleteDocument(resolver, uri)
            }
        }
    }

    /**
     * 严格读回校验（P2-1 / P1-1，参照 StorageBridge.verifyWritten）。
     *
     * 目录树与 MediaStore 回退共用：
     * 1. SIZE 已知且 `!=` 写入字节数 → 直接抛 [VerifyException]；
     * 2. SIZE 已知且相等 → 只校验首 [HEAD_VERIFY_BYTES] 字节（不足则全量）；
     * 3. SIZE 未知（null/负数）或「期望非 0 却报 0」→ **降级为
     *    openInputStream 全文读取**：用实际读到的字节数替代 SIZE，仍须与
     *    写入长度精确相等且首字节一致。
     *
     * [P2-1] 部分第三方 provider 写入成功后短暂上报 `COLUMN_SIZE=0`；
     * 修复前 0 被当作已知值判 MISMATCH，`writeViaTree` 的失败清理随即
     * 删除刚写成功的文件。现在 0 与 null/负数同属「不可信 SIZE」。
     */
    private fun verifyWritten(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
        val declaredSize = queryDocumentSize(resolver, uri)
        val verdict = readbackSizeVerdict(bytes.size, declaredSize)
        // 只有「已知且确实不等」才立即失败；SIZE 未知/不可信继续做内容扫描
        if (verdict == ReadbackSizeVerdict.MISMATCH) {
            throw VerifyException(
                "读回大小校验失败：期望 ${bytes.size}，实际 $declaredSize"
            )
        }
        val headLen = minOf(HEAD_VERIFY_BYTES, bytes.size)
        if (headLen <= 0) return
        val input = resolver.openInputStream(uri)
            ?: throw VerifyException("读回 openInputStream 返回 null：$uri")
        input.use { stream ->
            val head = ByteArray(headLen)
            var total = 0
            while (total < headLen) {
                val read = stream.read(head, total, headLen - total)
                // P3-3：0 与 -1 都视为无进展，避免 provider 返回 0 时空转
                if (read <= 0) break
                total += read
            }
            if (total < headLen) {
                throw VerifyException("读回字节不足：期望 $headLen，实际 $total")
            }
            var headMatches = true
            for (i in 0 until headLen) {
                if (head[i] != bytes[i]) {
                    headMatches = false
                    break
                }
            }
            // P1-1：SIZE 未知时才需要读全文统计字节数（已知相等只看头部）
            var scannedLength: Long? = null
            if (verdict == ReadbackSizeVerdict.UNKNOWN) {
                var consumed = total.toLong()
                val buffer = ByteArray(VERIFY_SCAN_BUFFER_BYTES)
                while (true) {
                    val read = stream.read(buffer)
                    // P3-3：`read == 0` 不代表 EOF，但 provider 反复返回 0
                    // 会让循环空转；按无进展结束（后续长度校验兜底）。
                    if (read <= 0) break
                    consumed += read
                }
                scannedLength = consumed
            }
            val failure = verifyReadback(
                expected = bytes.size,
                declaredSize = declaredSize,
                scannedLength = scannedLength,
                headMatches = headMatches
            )
            if (failure != null) throw VerifyException(failure)
        }
    }

    /** 查询 SAF 文档大小（`COLUMN_SIZE`）；查询失败/provider 不支持返回 null */
    private fun queryDocumentSize(resolver: ContentResolver, uri: Uri): Long? =
        queryLongColumn(resolver, uri, DocumentsContract.Document.COLUMN_SIZE)

    /**
     * 查询目录树根文档是否声明支持创建子项（P3-6）。
     *
     * 返回 null 表示 provider 未提供/查询失败（按未知放行）；false 表示
     * provider 明确未声明 `FLAG_DIR_SUPPORTS_CREATE`，记住前即可拒绝，
     * 避免之后每次保存都在写入阶段失败。
     */
    private fun queryTreeSupportsCreate(
        resolver: ContentResolver,
        treeUri: Uri
    ): Boolean? = try {
        val documentId = DocumentsContract.getTreeDocumentId(treeUri)
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        supportsCreateFromFlags(
            queryLongColumn(
                resolver,
                documentUri,
                DocumentsContract.Document.COLUMN_FLAGS
            )
        )
    } catch (e: Exception) {
        Log.w(TAG, "查询目录 FLAG_DIR_SUPPORTS_CREATE 失败（$treeUri）：${e.message}")
        null
    }

    /** 查询单列 Long 值（读不到/空值返回 null；异常记日志后返回 null） */
    private fun queryLongColumn(resolver: ContentResolver, uri: Uri, column: String): Long? = try {
        resolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(column)
            if (idx < 0 || !cursor.moveToFirst() || cursor.isNull(idx)) {
                null
            } else {
                cursor.getLong(idx)
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "查询 $column 失败（$uri）：${e.message}")
        null
    }

    /** 查询单列 String 值（空白/空值返回 null；异常记日志后返回 null） */
    private fun queryStringColumn(
        resolver: ContentResolver,
        uri: Uri,
        column: String,
        selection: String? = null,
        selectionArgs: Array<String>? = null
    ): String? = try {
        resolver.query(uri, arrayOf(column), selection, selectionArgs, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(column)
            if (idx < 0 || !cursor.moveToFirst()) {
                null
            } else {
                cursor.getString(idx)?.takeIf { it.isNotBlank() }
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "查询 $column 失败（$uri）：${e.message}")
        null
    }

    /** 按 MediaStore 行 id 查询 `(relative_path, _data)`；查不到返回 null */
    private fun queryMediaStoreRow(
        resolver: ContentResolver,
        id: Long
    ): Pair<String?, String?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val projection = arrayOf(
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.DATA
        )
        val selection = "${MediaStore.MediaColumns._ID} = ?"
        val args = arrayOf(id.toString())
        // 先查合并卷（external），再查主卷（external_primary）：部分 ROM 仅
        // 其中一种允许应用按 id 访问。
        val collections = listOf(
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        )
        for (collection in collections) {
            try {
                resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val relative = cursor.getString(0)
                        val path = cursor.getString(1)
                        if (relative != null || path != null) {
                            return Pair(relative, path)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "查询 MediaStore 行失败（$collection, id=$id）：${e.message}")
            }
        }
        return null
    }

    /**
     * 按显示名定位 MediaStore 行并取 `relative_path`（兜底）。
     *
     * 取「最近修改」的最新一行：`CREATE_DOCUMENT` 刚创建的行最新；限制在
     * 「下载」子树内（P3-1：前缀收紧为 `Download/`，排除 `Downloads/…`）。
     * 多行同名且同为最新时可能取错目录，故仅作为最后兜底。
     */
    private fun queryRelativePathByDisplayName(
        resolver: ContentResolver,
        displayName: String
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE 'Download/%'"
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC, " +
            "${MediaStore.MediaColumns._ID} DESC"
        return try {
            resolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns.RELATIVE_PATH),
                selection,
                arrayOf(displayName),
                sortOrder
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "按显示名查询 MediaStore 失败（$displayName）：${e.message}")
            null
        }
    }

    /** 查询 provider 实际文件名（重名时系统可能返回 `xxx (1).json`） */
    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? = try {
        resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) {
                cursor.getString(idx)?.takeIf { it.isNotBlank() }
            } else {
                null
            }
        }
    } catch (e: Exception) {
        Log.w(TAG, "查询实际文件名失败（回落请求名）：${e.message}")
        null
    }

    /**
     * 删除本次失败路径残留的文档（双路径兜底，均不抛异常）。
     *
     * @return true 表示已删除（DocumentsProvider 或 ContentResolver 任一路径成功）
     */
    private fun deleteDocument(resolver: ContentResolver, uri: Uri): Boolean {
        try {
            if (DocumentsContract.deleteDocument(resolver, uri)) {
                Log.i(TAG, "已删除残留文档：$uri")
                return true
            }
            Log.w(TAG, "DocumentsContract.deleteDocument 返回 false：$uri")
        } catch (e: Exception) {
            Log.w(TAG, "DocumentsContract.deleteDocument 失败：${e.message}")
        }
        try {
            val deleted = resolver.delete(uri, null, null)
            Log.i(TAG, "ContentResolver.delete 删除残留文档：uri=$uri, rows=$deleted")
            return deleted > 0
        } catch (e: Exception) {
            Log.w(TAG, "ContentResolver.delete 失败：${e.message}")
        }
        return false
    }

    /** 技术详情（回车/复制排障用，绝不直接作为主文案） */
    private fun technicalDetail(t: Throwable): String =
        t.message?.takeIf { it.isNotBlank() } ?: t.javaClass.simpleName

    /** 结构化错误：code + 中文 reason（主文案）+ detail（技术详情） */
    private fun replyError(
        result: MethodChannel.Result,
        code: String,
        detail: String?,
        uri: Uri? = null
    ) {
        val reason = reasonOf(code)
        result.error(
            code,
            reason,
            mapOf(
                "code" to code,
                "reason" to reason,
                "detail" to (detail ?: ""),
                "uri" to (uri?.toString() ?: "")
            )
        )
    }

    /**
     * 释放 pending 请求（Activity 销毁时避免 Dart Future 永久挂起）。
     *
     * [P3-2] 后台写线程无法在 dispose 内同步中断：这里保守复位
     * [writeInFlight]，避免 Activity 重建后新实例误判「仍在忙」。
     * 旧线程结束时会在主线程回调中再次置 false（幂等），不会影响新请求。
     */
    fun dispose() {
        writeInFlight = false
        val result = pendingResult
        clearPending()
        if (result != null) {
            try {
                replyError(result, "ACTIVITY_DESTROYED", "页面已销毁")
            } catch (_: Exception) {
                // 引擎/通道已销毁时回复可能失败，忽略
            }
        }
    }

    private fun clearPending() {
        pendingResult = null
        pendingActivity = null
        pendingBytes = null
        pendingFileName = null
        pendingMimeType = null
        pendingPickOnly = false
        mainHandler.removeCallbacks(pendingTimeout)
    }
}
