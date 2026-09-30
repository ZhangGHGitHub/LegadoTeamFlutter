package io.legado.flutter

import android.app.Activity
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream

/**
 * 存储桥接 — [D2] MediaStore 直写系统下载目录
 *
 * 背景（docs/materials_1301/evidence/m4b_fatal_stack_d2.txt）：
 * file_picker 8.x 的 saveFile 走 SAF 对话框，MuMu 的
 * DownloadStorageProvider 拒写（SecurityException: requires
 * MANAGE_DOCUMENTS），而插件仅 catch IOException → SecurityException
 * 抛到主线程 FATAL，进程被强杀（0 字节空文档残留）。
 *
 * 本桥接绕开 SAF：API 29+ 用 MediaStore.Downloads 直写
 * Download/legado/，无需存储权限、无需 SAF；全部异常捕获后经
 * result.error 返回，绝不向 Flutter 引擎抛未捕获异常。
 *
 * 支持方法：
 * - saveImageToDownloads: 参数 {fileName: String, bytes: List<Int>}；
 *   成功返回相对路径 "Download/legado/<fileName>"；
 *   API < 29 / 参数错误 / 写入失败均返回 error（调用方回退文档目录）。
 */
class StorageBridge {

    companion object {
        const val CHANNEL = "legado/storage"

        /// MediaStore 相对目录（对齐原版「保存到 Download」语义）
        private const val RELATIVE_DIR = "Download/legado/"
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "saveImageToDownloads" -> saveImageToDownloads(call, result, activity)
            else -> result.notImplemented()
        }
    }

    private fun saveImageToDownloads(
        call: MethodCall,
        result: MethodChannel.Result,
        activity: Activity
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // minSdk 24：API 24-28 设备走 Dart 侧文档目录兜底
            result.error(
                "UNSUPPORTED_API",
                "MediaStore 直写需要 Android 10 (API 29)+",
                null
            )
            return
        }
        val fileName = call.argument<String>("fileName")
        val bytes = call.argument<List<Int>>("bytes")
        if (fileName.isNullOrEmpty() || bytes.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "fileName and bytes are required", null)
            return
        }

        val resolver = activity.contentResolver
        var uri: Uri? = null
        var output: OutputStream? = null
        var failed = false
        try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, mimeTypeOf(fileName))
                put(MediaStore.Downloads.RELATIVE_PATH, RELATIVE_DIR)
            }
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("MediaStore insert returned null")
            output = resolver.openOutputStream(uri)
                ?: throw IOException("openOutputStream returned null for $uri")
            output.write(ByteArray(bytes.size) { i -> bytes[i].toByte() })
            output.flush()
            result.success("$RELATIVE_DIR$fileName")
        } catch (e: Exception) {
            failed = true
            // 绝不向外抛：provider 拒写（SecurityException 等）仅回错误码
            result.error("SAVE_FAILED", "Failed to save image to Downloads: ${e.message}", null)
        } finally {
            try {
                output?.close()
            } catch (_: Exception) {
            }
            if (failed && uri != null) {
                // 清理写入失败时已创建的 0 字节残留文档（D2 证据残留问题）
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun mimeTypeOf(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "bmp" -> "image/bmp"
            else -> "application/octet-stream"
        }
    }
}
