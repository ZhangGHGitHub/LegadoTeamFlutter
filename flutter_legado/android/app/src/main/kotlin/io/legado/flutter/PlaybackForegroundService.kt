package io.legado.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.NotificationCompat

/**
 * 听书/媒体播放前台服务 — [体检 §一.2] 发布硬伤修复
 *
 * 后台听书时持有一个 mediaPlayback 类型的前台服务通知，防止应用退后台或
 * 锁屏后播放进程被系统冻结（A2 验收矩阵：听书流媒体+后台续播的前置条件）。
 *
 * 生命周期由 [MediaSessionBridge] 驱动：
 * - 播放态变化（playing/paused/buffering）→ startForegroundService 携带状态
 * - stopped / release → stopService
 *
 * 通知内容从活跃 [MediaSessionBridge.active] 的 MediaSession 元数据构建；
 * 点击通知回到 MainActivity。
 */
class PlaybackForegroundService : Service() {

    companion object {
        const val EXTRA_STATE = "state"
        private const val CHANNEL_ID = "legado_playback_foreground"
        private const val NOTIFICATION_ID = 0x1E60

        /** 运行中服务实例（元数据变化时由 [MediaSessionBridge] 触发通知刷新） */
        @Volatile
        private var instance: PlaybackForegroundService? = null

        /**
         * [听书定时第2项 | 2026-10-03] 媒体元数据（如定时停止剩余量）变化时
         * 重发前台通知；服务未运行则忽略。
         *
         * 复刻原版 upMediaMetadata + notificationManager.notify 的耦合
         * （BaseReadAloudService.kt:768-777：先刷新元数据再重发通知），
         * 保证通知标题随剩余量整数变化刷新，而不必等待播放态变化。
         */
        @JvmStatic
        fun refreshNotification() {
            val service = instance ?: return
            service.startForegroundCompat(service.lastState)
        }
    }

    /** 最近一次播放态（刷新通知时复用，避免刷新把状态重置为默认值） */
    private var lastState = "playing"

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = intent?.getStringExtra(EXTRA_STATE) ?: lastState
        lastState = state
        startForegroundCompat(state)

        // stopped 状态：通知已展示后即可结束服务
        if (state == "stopped") {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(state: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "听书播放",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setSilent(true)

        // 复用活跃媒体会话的元数据与 token（点击通知回到应用，样式为媒体样式）
        MediaSessionBridge.active?.let { bridge ->
            bridge.sessionToken()?.let { token ->
                builder.setStyle(
                    androidx.media.app.NotificationCompat.MediaStyle()
                        .setMediaSession(token)
                )
            }
            bridge.currentMetadata()?.let { meta ->
                // [听书定时第2项] 原版通知形态（BaseReadAloudService.kt:780-805 /
                // AudioPlayService.kt:872-895）：标题 = 「正在播放/朗读[(剩余
                // N 章|分钟)]: 书名」（Dart 侧组合后写入 METADATA_KEY_ARTIST），
                // 文本 = 章节标题（METADATA_KEY_TITLE）；锁屏标题语义不变。
                val (contentTitle, contentText) = resolvePlaybackNotificationTexts(
                    chapterTitle = meta.getString(MediaMetadataCompat.METADATA_KEY_TITLE),
                    playbackLabel = meta.getString(MediaMetadataCompat.METADATA_KEY_ARTIST),
                )
                if (contentTitle.isNotEmpty()) builder.setContentTitle(contentTitle)
                if (contentText.isNotEmpty()) builder.setContentText(contentText)
            }
            bridge.contentIntent()?.let { pi ->
                builder.setContentIntent(pi)
            }
        }

        val notification: Notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

/**
 * [听书定时第2项 | 2026-10-03] 通知标题/文本映射（纯函数，JVM 单测覆盖）。
 *
 * 复刻原版通知形态（BaseReadAloudService.kt:780-805 /
 * AudioPlayService.kt:872-895）：
 * - 通知标题 = 「正在播放/朗读[(剩余 N 章|分钟)]: 书名」（Dart 侧组合后写入
 *   MediaMetadataCompat.METADATA_KEY_ARTIST，对齐原版 TTS upMediaMetadata
 *   的 ARTIST 语义，BaseReadAloudService.kt:715）；
 * - 通知文本 = 章节标题（METADATA_KEY_TITLE）。
 *
 * [playbackLabel] 为空（未绑定书名）时回退标题为章节标题，文本留空，
 * 与既有降级行为一致。
 */
internal fun resolvePlaybackNotificationTexts(
    chapterTitle: String?,
    playbackLabel: String?,
): Pair<String, String> {
    val chapter = chapterTitle.orEmpty()
    val label = playbackLabel.orEmpty()
    return if (label.isNotEmpty()) label to chapter else chapter to ""
}
