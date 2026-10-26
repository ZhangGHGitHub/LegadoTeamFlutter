package io.legado.flutter

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
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
 * 1. `ACTION_CREATE_DOCUMENT` + `EXTRA_TITLE` + MIME，由用户选择保存位置；
 * 2. 结果回到 [onActivityResult] 后，在**后台线程**打开 URI 写字节；
 * 3. 所有异常（含 SecurityException / RuntimeException / Throwable）均被
 *    捕获并回 `result.error`，绝不向 Flutter 引擎或主线程抛出；
 * 4. 写失败时删除对话框已创建的空文档（[DocumentsContract.deleteDocument]
 *    失败再回退 `ContentResolver.delete`），不留 0 字节残留；
 * 5. 用户取消（RESULT_CANCELED）回 `result.success(null)`，与 Dart 侧
 *    「取消不提示」语义一致；
 * 6. 写后读回校验大小（provider 报 -1 视为不可校验而放行），防 ROM 级
 *    静默丢弃（参照 [StorageBridge] 的幻影写入教训）。
 *
 * 支持方法：
 * - `saveFile`: 参数 {fileName: String, bytes: ByteArray|List<Int>, mimeType: String?}；
 *   成功返回实际保存的 `uri.toString()`（移动端提示只用文件名，不用该值
 *   展示路径）；空字节/参数缺失返回 error，不创建文档。
 */
class SaveFileBridge {

    companion object {
        const val CHANNEL = "legado/file_save"

        /** 与 Flutter 插件请求码错开（file_picker 使用类 hashCode 派生值） */
        private const val REQUEST_CODE_SAVE_FILE = 10201

        private const val METHOD_SAVE_FILE = "saveFile"
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingActivity: Activity? = null
    private var pendingBytes: ByteArray? = null
    private var pendingFileName: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())

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
            result.error("ALREADY_PENDING", "已有另存请求进行中", null)
            return
        }
        val fileName = call.argument<String>("fileName")?.trim().orEmpty()
        // Dart Uint8List 经 StandardMessageCodec 落地为 byte[]；兼容整数列表
        val bytes = StorageBridge.bytesFromArgument(call.argument("bytes"))
        if (fileName.isEmpty() || bytes == null) {
            result.error("INVALID_ARGS", "fileName 与 bytes 不能为空", null)
            return
        }
        if (bytes.isEmpty()) {
            // 空内容不弹对话框：避免系统先创建 0 字节文档再失败，留下残留
            result.error("EMPTY_BYTES", "导出内容为空，未创建文件", null)
            return
        }
        val mimeType = call.argument<String>("mimeType")
            ?.takeIf { it.isNotBlank() }
            ?: mimeTypeOf(fileName)

        pendingResult = result
        pendingActivity = activity
        pendingBytes = bytes
        pendingFileName = fileName

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE_SAVE_FILE)
        } catch (e: Exception) {
            clearPending()
            result.error(
                "SAVE_START_FAILED",
                "无法打开系统保存对话框：${e.message ?: e.javaClass.simpleName}",
                null
            )
        }
    }

    /**
     * Activity 结果回调（由 MainActivity 转发）
     *
     * 只处理本桥接的请求码；用户取消回 success(null)。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE_SAVE_FILE) return
        val result = pendingResult ?: return
        val activity = pendingActivity
        val bytes = pendingBytes
        val fileName = pendingFileName
        clearPending()

        val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (activity == null || uri == null || bytes == null) {
            // 用户取消（或结果缺失）：与「取消不提示」语义一致
            result.success(null)
            return
        }

        try {
            // 部分 ROM 的临时授权不可靠，尽量固化为持久授权；
            // 不支持/被拒不影响本次写入（后续写流若仍被拒会走错误分支）
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
        }

        Thread {
            var failure: Throwable? = null
            try {
                writeBytes(activity.contentResolver, uri, bytes)
            } catch (t: Throwable) {
                failure = t
            }
            val error = failure
            mainHandler.post {
                if (error != null) {
                    // 删除对话框已创建的空文档，避免 0 字节残留（D1 副作用）
                    deleteDocument(activity.contentResolver, uri)
                    result.error(
                        "SAVE_FAILED",
                        "写入文件失败（${fileName ?: "未知文件"}）：" +
                            "${error.message ?: error.javaClass.simpleName}",
                        uri.toString()
                    )
                } else {
                    result.success(uri.toString())
                }
            }
        }.start()
    }

    /** 后台线程写流 + 关闭 + 读回校验（异常向上抛给 [onActivityResult] 分支） */
    private fun writeBytes(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
        val output = resolver.openOutputStream(uri)
            ?: throw IOException("openOutputStream 返回 null：$uri")
        output.use { stream ->
            stream.write(bytes)
            stream.flush()
        }
        // 读回校验：仅当 provider 能给出大小（>=0）时比对，防静默丢弃
        val writtenSize = try {
            resolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L
        } catch (_: Exception) {
            -1L
        }
        if (writtenSize >= 0 && writtenSize != bytes.size.toLong()) {
            throw IOException(
                "读回大小不一致：期望 ${bytes.size}，实际 $writtenSize"
            )
        }
    }

    /** 删除失败时残留的空文档（双路径兜底，均不抛异常） */
    private fun deleteDocument(resolver: ContentResolver, uri: Uri) {
        try {
            DocumentsContract.deleteDocument(resolver, uri)
            return
        } catch (_: Exception) {
        }
        try {
            resolver.delete(uri, null, null)
        } catch (_: Exception) {
        }
    }

    /** 释放 pending 请求（Activity 销毁时避免 Dart Future 永久挂起） */
    fun dispose() {
        val result = pendingResult
        clearPending()
        if (result != null) {
            try {
                result.error("ACTIVITY_DESTROYED", "页面已销毁，另存请求中断", null)
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
    }

    /** 按扩展名推断 MIME（与 StorageBridge 口径一致，补 JSON/文本/压缩包） */
    private fun mimeTypeOf(fileName: String): String {
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
}
