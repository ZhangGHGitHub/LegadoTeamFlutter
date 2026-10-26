package io.legado.flutter

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
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
 * 系统另存桥接（D1）— 自建 ACTION_CREATE_DOCUMENT + 受控写流链路
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
 * 6. **严格读回校验（P2-1）**：MediaStore 回退写入后 SIZE 必须与实际写入
 *    字节数精确相等且首 [HEAD_VERIFY_BYTES] 字节一致（参照 StorageBridge
 *    `verifyWritten`），读不到（-1/异常）即判失败并清理本次 insert 行；
 * 7. **失败清理安全（P2-2/P2-4）**：open 前查询文档大小（COLUMN_SIZE），
 *    仅 0 字节文档（本次新建/截断，或 CREATE_DOCUMENT 刚建的空文档）允许
 *    删除；`preSize > 0`（用户选择「替换」的已有文件）失败只报错不删；
 * 8. 持久化 URI 授权仅在 take 成功时回收（最小权限）；
 * 9. 用户取消（RESULT_CANCELED）回 `result.success(null)`；RESULT_OK 但
 *    无 URI 回 `NO_URI` 错误（P3-3）；等待结果超过 5 分钟复位 pending
 *    （P3-3），超时后迟到的回调写日志而非静默丢弃（P3-6）。
 *
 * 支持方法：
 * - `saveFile`: 参数 {fileName: String, bytes: ByteArray|List<Int>, mimeType: String?}；
 *   成功返回 `{uri: String, name: String, fallback: "none"|"mediastore",
 *   relativeDir: String?}`（`name` 为 provider 实际落盘名，重名时可能带
 *   `(1)`；`relativeDir` 为回退时的「下载」相对目录，如 `Download/legado/`）；
 *   空字节/参数缺失返回 error，不创建文档。
 */
class SaveFileBridge {

    companion object {
        const val CHANNEL = "legado/file_save"

        private const val TAG = "SaveFileBridge"

        /** 与 Flutter 插件请求码错开（file_picker 使用类 hashCode 派生值） */
        private const val REQUEST_CODE_SAVE_FILE = 10201

        private const val METHOD_SAVE_FILE = "saveFile"

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
         * - preSize == 0 → 删除：opened=true 为本次已新建/截断写流，
         *   opened=false 为 `CREATE_DOCUMENT` 刚建、写流被拒的空文档
         *   （P2-4，消除重名漂移）。0 字节文档不含用户内容。
         */
        internal fun shouldDeleteAfterFailure(opened: Boolean, preSize: Long?): Boolean {
            val size = preSize ?: return false
            if (size > 0L) return false
            return opened || size == 0L
        }

        /**
         * 读回大小是否通过严格校验（P2-1 纯函数）。
         *
         * 读不到（null）或 provider 报不可知（负数）一律判失败；读到的大小
         * 必须与实际写入字节数精确相等。
         */
        internal fun isReadbackSizeValid(expected: Int, actual: Long?): Boolean =
            actual != null && actual >= 0L && actual == expected.toLong()

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
            "FALLBACK_PATH_UNKNOWN" ->
                "无法确定所选文件夹，请选择内部存储 > Download 或子文件夹后重试"
            "LEGACY_NOT_SUPPORTED" ->
                "Android 10 以下暂不支持保存到下载目录，请选择其他位置"
            "SAVE_FAILED" -> "无法写入所选位置，请换一个文件夹重试"
            else -> "保存失败，请重试"
        }
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingActivity: Activity? = null
    private var pendingBytes: ByteArray? = null
    private var pendingFileName: String? = null
    private var pendingMimeType: String? = null

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
            else -> result.notImplemented()
        }
    }

    /** 启动系统另存对话框（校验参数后注册 pending 请求） */
    private fun saveFile(
        call: MethodCall,
        result: MethodChannel.Result,
        activity: Activity
    ) {
        if (pendingResult != null) {
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

        pendingResult = result
        pendingActivity = activity
        pendingBytes = bytes
        pendingFileName = fileName
        pendingMimeType = mimeType
        timedOutPending = false
        mainHandler.removeCallbacks(pendingTimeout)
        mainHandler.postDelayed(pendingTimeout, PENDING_TIMEOUT_MS)

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
     * Activity 结果回调（由 MainActivity 转发）
     *
     * 只处理本桥接的请求码；用户取消回 success(null)；RESULT_OK 但无 URI
     * 回 NO_URI（P3-3），不再与「取消」混为一谈。超时/复位后迟到的回调
     * 记录日志（P3-6），不静默丢弃。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE_SAVE_FILE) return
        val result = pendingResult
        if (result == null) {
            val lateUri = data?.data
            if (timedOutPending) {
                // P3-6：已向 Dart 回过 TIMEOUT，迟到的真实结果只记日志
                //（可能已由系统创建文档，保留 uri 供排障与残留清理定位）
                Log.w(
                    TAG,
                    "另存结果迟到（已回 TIMEOUT，忽略写入）：resultCode=$resultCode, uri=$lateUri"
                )
                timedOutPending = false
            } else {
                Log.w(
                    TAG,
                    "收到无 pending 的另存回调（可能 Activity 重建，忽略）：" +
                        "resultCode=$resultCode, uri=$lateUri"
                )
            }
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

        // 写流 + 授权回收全部在后台线程，主线程只负责回 result
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
                if (outcome.saved != null) {
                    result.success(
                        mapOf(
                            "uri" to outcome.saved.uri.toString(),
                            "name" to outcome.saved.displayName,
                            "fallback" to if (outcome.saved.viaMediaStore) {
                                "mediastore"
                            } else {
                                "none"
                            },
                            "relativeDir" to outcome.saved.relativeDir
                        )
                    )
                } else {
                    replyError(
                        result,
                        outcome.code,
                        outcome.detail,
                        uri
                    )
                }
            }
        }.start()
    }

    /** 后台线程写流结果（`saved` 与 `code/detail` 二选一） */
    private class WriteOutcome(
        val saved: SavedDoc? = null,
        val code: String = "SAVE_FAILED",
        val detail: String? = null
    )

    /** 落盘结果（[relativeDir] 仅回退路径有值，如 `Download/legado/`） */
    private class SavedDoc(
        val uri: Uri,
        val displayName: String,
        val viaMediaStore: Boolean,
        val relativeDir: String? = null
    )

    /** 读回校验失败（区分普通 IO 失败，便于回 SAVE_VERIFY_FAILED） */
    private class VerifyException(message: String) : IOException(message)

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
            deleteEmptySafDocument(resolver, safUri, preSize, null)
            return WriteOutcome(
                code = "LEGACY_NOT_SUPPORTED",
                detail = "MediaStore 回退需要 Android 10+（当前 API " +
                    "${Build.VERSION.SDK_INT}）：$causeDetail"
            )
        }
        val relativeDir = resolveDownloadRelativePath(resolver, safUri)
        if (relativeDir == null) {
            deleteEmptySafDocument(resolver, safUri, preSize, null)
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
            deleteEmptySafDocument(resolver, safUri, preSize, relativeDir)
            return WriteOutcome(
                code = if (t is VerifyException) "SAVE_VERIFY_FAILED" else "SAVE_FAILED",
                detail = "$causeDetail；回退写入「$relativeDir」失败：${technicalDetail(t)}"
            )
        }
        // 回退成功：清理本次 SAF 新建的 0 字节文档（P2-4），避免重名漂移
        deleteEmptySafDocument(resolver, safUri, preSize, relativeDir)
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
        preSize: Long?,
        relativeDir: String?
    ) {
        if (!shouldDeleteAfterFailure(opened = false, preSize = preSize)) return
        Log.i(TAG, "清理本次新建的空文档：uri=$uri, dir=$relativeDir")
        if (deleteDocument(resolver, uri)) return
        deleteEmptyMediaStoreRow(resolver, uri, relativeDir)
    }

    /** 删除与空文档对应的 MediaStore 行（显示名/大小/目录三项精确匹配） */
    private fun deleteEmptyMediaStoreRow(
        resolver: ContentResolver,
        safUri: Uri,
        relativeDir: String?
    ) {
        if (relativeDir == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val displayName = queryDisplayName(resolver, safUri) ?: return
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
        if (resolved == null) {
            // 4. 显示名兜底：按「文档显示名 + 最新修改」定位 MediaStore 行
            val displayName = queryDisplayName(resolver, uri)
            if (displayName != null) {
                resolved = queryRelativePathByDisplayName(resolver, displayName)
                if (resolved != null) {
                    Log.i(TAG, "按显示名 $displayName 定位到回退目录：$resolved")
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
            verifyMediaStoreWrite(resolver, uri, bytes)
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
     * 严格读回校验（P2-1，参照 StorageBridge.verifyWritten）。
     *
     * 两项须同时成立，任一失败抛 [VerifyException]：
     * 1. 查询到的 SIZE 与实际写入字节数精确相等（读不到/负数同样失败）；
     * 2. openInputStream 读回首 [HEAD_VERIFY_BYTES] 字节（不足则全量）一致。
     */
    private fun verifyMediaStoreWrite(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
        val size = queryLongColumn(resolver, uri, MediaStore.MediaColumns.SIZE)
        if (!isReadbackSizeValid(bytes.size, size)) {
            throw VerifyException("读回大小校验失败：期望 ${bytes.size}，实际 $size")
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
                if (read < 0) break
                total += read
            }
            if (total < headLen) {
                throw VerifyException("读回字节不足：期望 $headLen，实际 $total")
            }
            for (i in 0 until headLen) {
                if (head[i] != bytes[i]) {
                    throw VerifyException("读回首 $headLen 字节不一致")
                }
            }
        }
    }

    /** 查询 SAF 文档大小（`COLUMN_SIZE`）；查询失败/provider 不支持返回 null */
    private fun queryDocumentSize(resolver: ContentResolver, uri: Uri): Long? =
        queryLongColumn(resolver, uri, DocumentsContract.Document.COLUMN_SIZE)

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
     * 「下载」子树内。多行同名且同为最新时可能取错目录，故仅作为最后兜底。
     */
    private fun queryRelativePathByDisplayName(
        resolver: ContentResolver,
        displayName: String
    ): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE 'Download%'"
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

    /** 释放 pending 请求（Activity 销毁时避免 Dart Future 永久挂起） */
    fun dispose() {
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
        mainHandler.removeCallbacks(pendingTimeout)
    }
}
