package io.legado.flutter

import android.app.Activity
import android.content.Intent
import android.content.Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
import android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
import android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 文件选择器桥接 — 用于导入本地书籍文件
 *
 * 支持方法：
 * - pickFile: 选择文件（支持指定 MIME 类型过滤）
 * - pickDirectory: 选择目录（SAF DocumentTree，持久化读写权限）
 */
class FilePickerBridge {

    companion object {
        private const val REQUEST_CODE_PICK_FILE = 10101
        private const val REQUEST_CODE_PICK_DIR = 10102
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingActivity: Activity? = null

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "pickFile" -> {
                val types = call.argument<List<String>>("mimeTypes")
                    ?: listOf("application/epub+zip", "text/plain", "application/pdf")
                pickFile(types, result, activity)
            }
            "pickDirectory" -> {
                pickDirectory(result, activity)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFile(mimeTypes: List<String>, result: MethodChannel.Result, activity: Activity) {
        if (pendingResult != null) {
            result.error("ALREADY_PENDING", "Another file picker request is in progress", null)
            return
        }
        pendingResult = result
        pendingActivity = activity

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 设置多个 MIME 类型
            if (mimeTypes.size == 1) {
                type = mimeTypes[0]
            } else {
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
            // 允许多选
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
        }

        try {
            activity.startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
        } catch (e: Exception) {
            pendingResult = null
            pendingActivity = null
            result.error("PICK_ERROR", "Failed to open file picker: ${e.message}", null)
        }
    }

    private fun pickDirectory(result: MethodChannel.Result, activity: Activity) {
        if (pendingResult != null) {
            result.error("ALREADY_PENDING", "Another file picker request is in progress", null)
            return
        }
        pendingResult = result
        pendingActivity = activity

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                FLAG_GRANT_READ_URI_PERMISSION or
                    FLAG_GRANT_WRITE_URI_PERMISSION or
                    FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }

        try {
            activity.startActivityForResult(intent, REQUEST_CODE_PICK_DIR)
        } catch (e: Exception) {
            pendingResult = null
            pendingActivity = null
            result.error("PICK_ERROR", "Failed to open directory picker: ${e.message}", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        val result = pendingResult ?: return
        val activity = pendingActivity

        when (requestCode) {
            REQUEST_CODE_PICK_FILE -> {
                pendingResult = null
                pendingActivity = null
                if (resultCode == Activity.RESULT_OK && data != null) {
                    val uri = data.data
                    if (uri != null) {
                        result.success(uri.toString())
                    } else {
                        result.error("NO_FILE", "No file selected", null)
                    }
                } else {
                    // 用户取消选择
                    result.success(null)
                }
            }
            REQUEST_CODE_PICK_DIR -> {
                pendingResult = null
                pendingActivity = null
                if (resultCode == Activity.RESULT_OK && data != null) {
                    val treeUri = data.data
                    if (treeUri != null) {
                        // 持久化读写权限，供听书缓存等后续 DocumentFile 落盘
                        if (activity != null) {
                            val takeFlags = (data.flags and
                                (FLAG_GRANT_READ_URI_PERMISSION or FLAG_GRANT_WRITE_URI_PERMISSION))
                            try {
                                activity.contentResolver.takePersistableUriPermission(
                                    treeUri,
                                    takeFlags or FLAG_GRANT_READ_URI_PERMISSION or
                                        FLAG_GRANT_WRITE_URI_PERMISSION
                                )
                            } catch (_: SecurityException) {
                                // 部分 provider 不支持 persistable；仍返回 URI 供当次会话使用
                            }
                        }
                        result.success(treeUri.toString())
                    } else {
                        result.error("NO_DIR", "No directory selected", null)
                    }
                } else {
                    result.success(null)
                }
            }
        }
    }
}
