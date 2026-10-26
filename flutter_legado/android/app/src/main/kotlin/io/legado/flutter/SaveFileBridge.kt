package io.legado.flutter

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream

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
 * 4. **原崩溃入口（DownloadsProvider）回退**（2026-10-27 P1-1 定点复验）：
 *    该 provider 对 CREATE_DOCUMENT 返回的 URI 同样拒写（requires
 *    MANAGE_DOCUMENTS），`openOutputStream` 失败时回退为 MediaStore
 *    Downloads 直写（API 29+，`IS_PENDING` 保护，写完清除），文件仍落在
 *    用户选择的「下载」目录，且无需 MANAGE_DOCUMENTS；
 * 5. 失败清理只删「本次已成功 openOutputStream（文档已被创建/截断）」的
 *    文档；`openOutputStream` 失败时绝不删除（可能是用户已有文件，P2-2）；
 * 6. 写后读回校验大小：SAF 路径不一致只记警告并返回成功（内容可能已写入；
 *    不删文件，P2-2），MediaStore 回退路径不一致视为失败并清理（防幻影写入）；
 * 7. 持久化 URI 授权仅在 take 成功时回收（P2-1，最小权限）；
 * 8. 用户取消（RESULT_CANCELED）回 `result.success(null)`；RESULT_OK 但
 *    无 URI 回 `NO_URI` 错误（P3-3）；等待结果超过 5 分钟复位 pending（P3-3）。
 *
 * 支持方法：
 * - `saveFile`: 参数 {fileName: String, bytes: ByteArray|List<Int>, mimeType: String?}；
 *   成功返回 `{uri: String, name: String, fallback: "none"|"mediastore"}`
 *   （`name` 为 provider 实际落盘名，重名时可能带 `(1)`）；
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

        /** 文件名非法字符（与 Dart `ExportFileService.normalizeFileName` 同口径） */
        private val INVALID_FILE_NAME_CHARS = Regex("[\\\\/:*?\"<>|]")

        /** 净化文件名：非法字符替换为 `_` 并去首尾空白（P3-5） */
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
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingActivity: Activity? = null
    private var pendingBytes: ByteArray? = null
    private var pendingFileName: String? = null
    private var pendingMimeType: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** P3-3 超时复位（仅在 pending 期间挂载，结果/销毁时移除） */
    private val pendingTimeout = Runnable {
        val result = pendingResult
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
     * 回 NO_URI（P3-3），不再与「取消」混为一谈。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE_SAVE_FILE) return
        val result = pendingResult ?: return
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
            val outcome = writeOnBackground(activity, uri, bytes, fileName, mimeType)
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
                            }
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

    private class SavedDoc(
        val uri: Uri,
        val displayName: String,
        val viaMediaStore: Boolean
    )

    /**
     * 后台线程写字节（含回退与授权回收）。
     *
     * 清理规则（P2-2）：本次已成功 openOutputStream（文档已被创建/截断）
     * 才允许 deleteDocument；openOutputStream 抛异常时绝不删除——该 URI
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
        // P2-1：仅当 take 成功时才在 finally 回收（最小权限，避免授权泄漏）
        var persisted = false
        var opened = false
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
            try {
                val output = resolver.openOutputStream(uri)
                    ?: throw IOException("openOutputStream 返回 null：$uri")
                opened = true
                output.use { stream ->
                    stream.write(bytes)
                    stream.flush()
                }
                // 读回校验（P2-2）：大小不一致只告警并返回成功——文件可能已写入，
                // 删除会让用户拿不到内容；不一致作为排障线索记日志。
                val writtenSize = readBackSize(resolver, uri)
                if (writtenSize >= 0 && writtenSize != bytes.size.toLong()) {
                    Log.w(
                        TAG,
                        "读回大小不一致（返回成功，不删除）：期望 ${bytes.size}，" +
                            "实际 $writtenSize，uri=$uri"
                    )
                }
                val actualName = queryDisplayName(resolver, uri) ?: fileName
                return WriteOutcome(
                    saved = SavedDoc(uri, actualName, viaMediaStore = false)
                )
            } catch (t: Throwable) {
                val detail = technicalDetail(t)
                if (!opened && isPermissionDenied(t) && isDownloadsProvider(uri)) {
                    // P1-1：原崩溃入口（DownloadsProvider 根）拒写 → MediaStore 回退。
                    // 文件仍落在用户选择的「下载」目录，无需 MANAGE_DOCUMENTS。
                    return try {
                        val saved = writeToMediaStoreDownloads(
                            resolver,
                            fileName,
                            mimeType ?: mimeTypeOf(fileName),
                            bytes
                        )
                        // 注意（P2-2）：这里**不删除** SAF 返回的文档。
                        // openOutputStream 从未成功，无法确认该 URI 是本次
                        // 新建的空文档，还是用户选择「替换」的已有文件——
                        // 删除可能丢掉用户原内容，故宁可在「下载」根留一个
                        // 未写入的文档也不冒险。
                        WriteOutcome(saved = saved)
                    } catch (fallbackError: Throwable) {
                        Log.e(
                            TAG,
                            "MediaStore 回退失败：${technicalDetail(fallbackError)}",
                            fallbackError
                        )
                        WriteOutcome(
                            code = "SAVE_FAILED",
                            detail = "$detail；回退写入「下载」目录失败：" +
                                technicalDetail(fallbackError)
                        )
                    }
                }
                // P2-2：仅当本次已成功 openOutputStream（文档被创建/截断）才清理
                if (opened) {
                    deleteDocument(resolver, uri)
                }
                return WriteOutcome(code = "SAVE_FAILED", detail = detail)
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
     * MediaStore Downloads 直写回退（API 29+）。
     *
     * 用 `IS_PENDING=1` 保护未完成写入，写完清除 pending；写后严格读回
     * 校验（部分 ROM 会静默丢弃 MediaStore 写入，见 StorageBridge D3 教训），
     * 校验失败清理本次 insert 的行并上抛，绝不假成功。
     */
    private fun writeToMediaStoreDownloads(
        resolver: ContentResolver,
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
            put(
                MediaStore.Downloads.RELATIVE_PATH,
                "${Environment.DIRECTORY_DOWNLOADS}/"
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )
        val uri = resolver.insert(collection, values)
            ?: throw IOException("MediaStore insert 返回 null")
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
            val writtenSize = readBackSize(resolver, uri)
            if (writtenSize >= 0 && writtenSize != bytes.size.toLong()) {
                throw IOException(
                    "MediaStore 读回大小不一致：期望 ${bytes.size}，实际 $writtenSize"
                )
            }
            val actualName = queryDisplayName(resolver, uri) ?: fileName
            success = true
            return SavedDoc(uri, actualName, viaMediaStore = true)
        } finally {
            if (!success) {
                deleteDocument(resolver, uri)
            }
        }
    }

    /** 读回大小；provider 不支持 statSize（-1）或读取失败视为不可校验 */
    private fun readBackSize(resolver: ContentResolver, uri: Uri): Long = try {
        resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
    } catch (e: Exception) {
        Log.w(TAG, "读回大小失败（跳过校验）：${e.message}")
        -1L
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

    /** 删除本次失败路径残留的文档（双路径兜底，均不抛异常） */
    private fun deleteDocument(resolver: ContentResolver, uri: Uri) {
        try {
            DocumentsContract.deleteDocument(resolver, uri)
            return
        } catch (e: Exception) {
            Log.w(TAG, "DocumentsContract.deleteDocument 失败：${e.message}")
        }
        try {
            resolver.delete(uri, null, null)
        } catch (e: Exception) {
            Log.w(TAG, "ContentResolver.delete 失败：${e.message}")
        }
    }

    /** 是否权限拒绝（含 cause 链上的 SecurityException / MANAGE_DOCUMENTS 文案） */
    private fun isPermissionDenied(t: Throwable): Boolean {
        var cause: Throwable? = t
        while (cause != null) {
            if (cause is SecurityException) return true
            val message = cause.message?.lowercase().orEmpty()
            if (message.contains("permission denial") ||
                message.contains("requires android.permission")
            ) {
                return true
            }
            cause = cause.cause
        }
        return false
    }

    private fun isDownloadsProvider(uri: Uri): Boolean =
        uri.authority == DOWNLOADS_AUTHORITY

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

    /** 错误码 → 面向用户的中文短句（P2-3） */
    private fun reasonOf(code: String): String = when (code) {
        "INVALID_ARGS" -> "文件名或导出内容无效"
        "EMPTY_BYTES" -> "导出内容为空，未创建文件"
        "ALREADY_PENDING" -> "已有另存请求进行中，请稍候重试"
        "SAVE_START_FAILED" -> "无法打开系统保存对话框，请重试"
        "NO_URI" -> "系统未返回保存位置，请重试"
        "TIMEOUT" -> "等待系统保存对话框超时，请重试"
        "ACTIVITY_DESTROYED" -> "页面已销毁，另存请求中断"
        "SAVE_FAILED" -> "无法写入所选位置，请换一个文件夹重试"
        else -> "保存失败，请重试"
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
