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
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = intent?.getStringExtra(EXTRA_STATE) ?: "playing"
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
                meta.getString(MediaMetadataCompat.METADATA_KEY_TITLE)?.let {
                    builder.setContentTitle(it)
                }
                meta.getString(MediaMetadataCompat.METADATA_KEY_ARTIST)?.let {
                    builder.setContentText(it)
                }
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
