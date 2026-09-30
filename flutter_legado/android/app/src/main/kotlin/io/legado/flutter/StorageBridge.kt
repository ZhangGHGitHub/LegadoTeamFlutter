package io.legado.flutter

import android.app.Activity
import android.content.ContentResolver
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
 * [D3] 写后读回校验：部分 ROM（如 MuMu，M4c 证据
 * m4c_ls_legado_1.txt）对 MediaStore 写入**静默丢弃**——
 * insert/openOutputStream/write/flush 全链路无异常，但目录不存在、
 * 表无新行、文件未落盘（幻影写入）。故写入 close 后必须经
 * query SIZE（与字节数精确相等）+ 首 8 字节比对确认真实落盘，
 * 校验失败回 error("SAVE_VERIFY_FAILED") 并清理残留 uri，
 * Dart 侧回退文档目录兜底——永远不假成功。
 *
 * 支持方法：
 * - saveImageToDownloads: 参数 {fileName: String, bytes: List<Int>}；
 *   成功（已读回校验）返回相对路径 "Download/legado/<fileName>"；
 *   API < 29 / 参数错误 / 写入失败 / 读回校验失败均返回 error
 *   （调用方回退文档目录）。
 */
class StorageBridge {

    companion object {
        const val CHANNEL = "legado/storage"

        /// MediaStore 相对目录（对齐原版「保存到 Download」语义）
        private const val RELATIVE_DIR = "Download/legado/"

        /// [D3] 读回校验的首部比对字节数
        private const val HEAD_VERIFY_BYTES = 8
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
        val data = ByteArray(bytes.size) { i -> bytes[i].toByte() }
        var uri: Uri? = null
        var output: OutputStream? = null
        var written = false
        var succeeded = false
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
            output.write(data)
            output.flush()
            output.close()
            output = null
            written = true
            // [D3] 写后读回校验：部分 ROM 对 MediaStore 写入静默丢弃（幻影写入，
            // 全链路无异常但文件未落盘）→ 校验不通过必须回 error，不得假成功
            verifyWritten(resolver, uri, data)
            result.success("$RELATIVE_DIR$fileName")
            succeeded = true
        } catch (e: Exception) {
            // 绝不向外抛：provider 拒写（SecurityException 等）/ 读回校验
            // 失败仅回错误码（Dart 侧 catch 后回退文档目录兜底）
            result.error(
                if (written) "SAVE_VERIFY_FAILED" else "SAVE_FAILED",
                "Failed to save image to Downloads: ${e.message}",
                null
            )
        } finally {
            try {
                output?.close()
            } catch (_: Exception) {
            }
            if (!succeeded && uri != null) {
                // 清理失败时已创建的残留 uri（0 字节 / 幻影文档，D2/D3 证据）
                try {
                    resolver.delete(uri, null, null)
                } catch (_: Exception) {
                }
            }
        }
    }

    /**
     * [D3] 读回校验：确认写入内容已真实落盘（防 ROM 级幻影写入）。
     *
     * 部分 ROM（如 MuMu）对 MediaStore 写入静默丢弃——insert /
     * openOutputStream / write / flush 全链路无异常，但目录不存在、
     * 表无新行、文件未落盘。校验两项须同时成立，任一失败抛
     * [IOException] 触发 SAVE_VERIFY_FAILED error + 残留清理：
     * 1. query uri 的 SIZE 字段非 null 且与 [data] 字节数精确相等；
     * 2. openInputStream 读回的首 [HEAD_VERIFY_BYTES] 字节（不足则
     *    全量）与 [data] 一致（防 provider SIZE 虚报）。
     */
    private fun verifyWritten(resolver: ContentResolver, uri: Uri, data: ByteArray) {
        val size: Long? = resolver
            .query(uri, arrayOf(MediaStore.Downloads.SIZE), null, null, null)
            ?.use { cursor ->
                if (!cursor.moveToFirst()) null else cursor.getLong(0)
            }
        if (size != data.size.toLong()) {
            throw IOException(
                "readback size mismatch: expected ${data.size}, actual $size"
            )
        }
        val input = resolver.openInputStream(uri)
            ?: throw IOException("openInputStream returned null")
        input.use { stream ->
            val headLen = minOf(HEAD_VERIFY_BYTES, data.size)
            val head = ByteArray(headLen)
            var total = 0
            while (total < headLen) {
                val read = stream.read(head, total, headLen - total)
                if (read < 0) break
                total += read
            }
            if (total < headLen) {
                throw IOException("readback truncated: expected $headLen, actual $total")
            }
            for (i in 0 until headLen) {
                if (head[i] != data[i]) {
                    throw IOException("readback head bytes mismatch")
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
