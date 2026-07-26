package io.legado.flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 通知服务 — 前台服务通知（下载进度、阅读通知等）
 *
 * 支持方法：
 * - showDownloadProgress: 显示下载进度通知
 * - showReadingNotification: 显示阅读状态通知
 * - cancelNotification: 取消指定通知
 * - startForegroundService: 启动前台服务
 * - stopForegroundService: 停止前台服务
 */
object NotificationService {

    private const val CHANNEL_ID_DOWNLOAD = "legado_download"
    private const val CHANNEL_ID_READING = "legado_reading"
    private const val CHANNEL_ID_SERVICE = "legado_service"

    private const val NOTIFICATION_ID_DOWNLOAD = 1001
    private const val NOTIFICATION_ID_READING = 1002
    private const val NOTIFICATION_ID_SERVICE = 1003

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "showDownloadProgress" -> {
                val bookName = call.argument<String>("bookName") ?: "未知书籍"
                val progress = call.argument<Int>("progress") ?: 0
                val total = call.argument<Int>("total") ?: 100
                showDownloadProgress(bookName, progress, total, context)
                result.success(null)
            }
            "showReadingNotification" -> {
                val bookName = call.argument<String>("bookName") ?: "阅读中"
                val chapterName = call.argument<String>("chapterName") ?: ""
                showReadingNotification(bookName, chapterName, context)
                result.success(null)
            }
            "cancelNotification" -> {
                val id = call.argument<Int>("id")
                cancelNotification(id, context)
                result.success(null)
            }
            "startForegroundService" -> {
                val title = call.argument<String>("title") ?: "阅读服务"
                val content = call.argument<String>("content") ?: "正在后台运行"
                startForegroundService(title, content, context)
                result.success(null)
            }
            "stopForegroundService" -> {
                stopForegroundService(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)

            val downloadChannel = NotificationChannel(
                CHANNEL_ID_DOWNLOAD,
                "下载通知",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "书籍下载进度通知"
                setShowBadge(false)
            }

            val readingChannel = NotificationChannel(
                CHANNEL_ID_READING,
                "阅读通知",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "当前阅读状态通知"
                setShowBadge(false)
            }

            val serviceChannel = NotificationChannel(
                CHANNEL_ID_SERVICE,
                "前台服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台阅读服务"
                setShowBadge(false)
            }

            manager.createNotificationChannels(
                listOf(downloadChannel, readingChannel, serviceChannel)
            )
        }
    }

    private fun showDownloadProgress(
        bookName: String,
        progress: Int,
        total: Int,
        context: Context
    ) {
        ensureChannels(context)
        val manager = context.getSystemService(NotificationManager::class.java)

        val notification = NotificationCompat.Builder(context, CHANNEL_ID_DOWNLOAD)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("正在下载：$bookName")
            .setContentText("$progress / $total")
            .setProgress(total, progress, false)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        manager.notify(NOTIFICATION_ID_DOWNLOAD, notification)

        // 下载完成时取消进度条
        if (progress >= total && total > 0) {
            val doneNotification = NotificationCompat.Builder(context, CHANNEL_ID_DOWNLOAD)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("下载完成")
                .setContentText(bookName)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            manager.notify(NOTIFICATION_ID_DOWNLOAD, doneNotification)
        }
    }

    private fun showReadingNotification(
        bookName: String,
        chapterName: String,
        context: Context
    ) {
        ensureChannels(context)
        val manager = context.getSystemService(NotificationManager::class.java)

        // 点击通知回到应用
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_ID_READING)
            .setSmallIcon(android.R.drawable.ic_menu_edit)
            .setContentTitle(bookName)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        if (chapterName.isNotEmpty()) {
            builder.setContentText(chapterName)
        }

        manager.notify(NOTIFICATION_ID_READING, builder.build())
    }

    private fun cancelNotification(id: Int?, context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (id != null) {
            manager.cancel(id)
        } else {
            manager.cancelAll()
        }
    }

    private fun startForegroundService(title: String, content: String, context: Context) {
        ensureChannels(context)

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID_SERVICE)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(content)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        // 注意：前台服务需要实际的 Service 类来承载
        // 这里仅创建通知，实际前台服务启动需要额外的 Service 实现
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID_SERVICE, notification)
    }

    private fun stopForegroundService(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(NOTIFICATION_ID_SERVICE)
    }
}
