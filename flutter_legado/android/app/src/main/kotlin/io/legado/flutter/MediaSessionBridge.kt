package io.legado.flutter

import android.annotation.SuppressLint
import android.content.Context
import android.os.PowerManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 媒体会话桥接 — Flutter ↔ Android MediaSession + 音频焦点管理
 *
 * 复刻原版 BaseReadAloudService 中的 MediaSession 和焦点管理逻辑：
 * - initMediaSession: 初始化 MediaSession 并注册回调
 * - requestAudioFocus / abandonAudioFocus: 音频焦点请求与释放
 * - updatePlaybackState: 更新播放状态（STATE_PLAYING / STATE_PAUSED）
 * - updateMetadata: 更新媒体元数据（标题、艺术家等）
 *
 * 支持方法（Flutter → Android）：
 * - init: 初始化 MediaSession
 * - requestAudioFocus: 请求音频焦点
 * - abandonAudioFocus: 放弃音频焦点
 * - updatePlaybackState: 更新播放状态
 * - updateMetadata: 更新媒体元数据
 * - release: 释放资源
 *
 * 回调事件（Android → Flutter）：
 * - onPlay: 媒体按钮播放
 * - onPause: 媒体按钮暂停
 * - onSkipToNext: 下一首
 * - onSkipToPrevious: 上一首
 * - onStop: 停止
 * - onAudioFocusChange: 焦点变化（gain/loss/lossTransient/lossTransientCanDuck）
 */
class MediaSessionBridge {

    private var mediaSession: MediaSessionCompat? = null
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var methodChannel: MethodChannel? = null

    /// 焦点丢失前是否正在播放（用于恢复判断）
    private var needResumeOnAudioFocusGain = false

    /// 当前是否正在播放
    private var isPlaying = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var wakeLockEnabled = false

    /// MediaSession 支持的操作（复刻原版 MediaHelp.MEDIA_SESSION_ACTIONS）
    private val mediaSessionActions = (
        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
            or PlaybackStateCompat.ACTION_REWIND
            or PlaybackStateCompat.ACTION_PLAY
            or PlaybackStateCompat.ACTION_PLAY_PAUSE
            or PlaybackStateCompat.ACTION_PAUSE
            or PlaybackStateCompat.ACTION_STOP
            or PlaybackStateCompat.ACTION_FAST_FORWARD
            or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
            or PlaybackStateCompat.ACTION_SEEK_TO
            or PlaybackStateCompat.ACTION_SET_RATING
            or PlaybackStateCompat.ACTION_PLAY_FROM_MEDIA_ID
            or PlaybackStateCompat.ACTION_PLAY_FROM_SEARCH
            or PlaybackStateCompat.ACTION_SKIP_TO_QUEUE_ITEM
            or PlaybackStateCompat.ACTION_PLAY_FROM_URI
            or PlaybackStateCompat.ACTION_PREPARE
            or PlaybackStateCompat.ACTION_PREPARE_FROM_MEDIA_ID
            or PlaybackStateCompat.ACTION_PREPARE_FROM_SEARCH
            or PlaybackStateCompat.ACTION_PREPARE_FROM_URI
            or PlaybackStateCompat.ACTION_SET_REPEAT_MODE
            or PlaybackStateCompat.ACTION_SET_SHUFFLE_MODE
            or PlaybackStateCompat.ACTION_SET_CAPTIONING_ENABLED
    )

    /// 音频焦点变化监听器（复刻原版 BaseReadAloudService.onAudioFocusChange）
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                // 重新获得焦点
                if (needResumeOnAudioFocusGain) {
                    needResumeOnAudioFocusGain = false
                    invokeFlutter("onAudioFocusChange", "gain")
                } else {
                    invokeFlutter("onAudioFocusChange", "gain")
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> {
                // 永久丢失焦点，暂停播放
                needResumeOnAudioFocusGain = false
                invokeFlutter("onAudioFocusChange", "loss")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // 暂时丢失焦点，暂停并标记需要恢复
                if (isPlaying) {
                    needResumeOnAudioFocusGain = true
                }
                invokeFlutter("onAudioFocusChange", "lossTransient")
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // 短暂丢失焦点（可降低音量），通知 Flutter 侧
                invokeFlutter("onAudioFocusChange", "lossTransientCanDuck")
            }
        }
    }

    /**
     * 处理 Flutter 侧方法调用
     */
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "init" -> initMediaSession(context, result)
            "requestAudioFocus" -> requestAudioFocus(result)
            "abandonAudioFocus" -> abandonAudioFocus(result)
            "updatePlaybackState" -> {
                val state = call.argument<String>("state") ?: "paused"
                val position = call.argument<Long>("position") ?: 0L
                updatePlaybackState(state, position)
                result.success(null)
            }
            "updateMetadata" -> {
                val title = call.argument<String>("title") ?: ""
                val artist = call.argument<String>("artist") ?: ""
                val album = call.argument<String>("album") ?: ""
                updateMetadata(title, artist, album)
                result.success(null)
            }
            "setPlaying" -> {
                isPlaying = call.argument<Boolean>("playing") ?: false
                syncWakeLockWithPlayback()
                result.success(null)
            }
            "setWakeLock" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                setWakeLock(context, enabled)
                result.success(null)
            }
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun setMethodChannel(channel: MethodChannel) {
        this.methodChannel = channel
    }

    @SuppressLint("WakelockTimeout")
    private fun setWakeLock(context: Context, enabled: Boolean) {
        wakeLockEnabled = enabled
        if (!enabled) {
            try {
                if (wakeLock?.isHeld == true) wakeLock?.release()
            } catch (_: Exception) {
            }
            wakeLock = null
            return
        }
        if (wakeLock == null) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "legado:AudioPlayWakeLock")
            wakeLock?.setReferenceCounted(false)
        }
        if (isPlaying && wakeLock?.isHeld != true) {
            wakeLock?.acquire()
        }
    }

    private fun syncWakeLockWithPlayback() {
        if (!wakeLockEnabled) return
        try {
            if (isPlaying) {
                if (wakeLock?.isHeld != true) wakeLock?.acquire()
            } else if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {
        }
    }

    /**
     * 初始化 MediaSession（复刻原版 initMediaSession）
     */
    private fun initMediaSession(context: Context, result: MethodChannel.Result) {
        if (mediaSession != null) {
            result.success(true)
            return
        }

        audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        mediaSession = MediaSessionCompat(context, "legado_flutter_media").apply {
            // 设置标志：处理媒体按钮和传输控制
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )

            // 注册回调（复刻原版 MediaSessionCompat.Callback）
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    invokeFlutter("onPlay", null)
                }

                override fun onPause() {
                    invokeFlutter("onPause", null)
                }

                override fun onSkipToNext() {
                    invokeFlutter("onSkipToNext", null)
                }

                override fun onSkipToPrevious() {
                    invokeFlutter("onSkipToPrevious", null)
                }

                override fun onStop() {
                    invokeFlutter("onStop", null)
                }

                override fun onCustomAction(action: String, extras: Bundle?) {
                    invokeFlutter("onCustomAction", action)
                }
            })

            // 激活 MediaSession
            isActive = true
        }

        result.success(true)
    }

    /**
     * 请求音频焦点（复刻原版 requestFocus）
     */
    private fun requestAudioFocus(result: MethodChannel.Result) {
        val am = audioManager
        if (am == null) {
            result.error("NOT_INITIALIZED", "AudioManager 未初始化", null)
            return
        }

        val focusResult = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Android 8.0+ 使用 AudioFocusRequest
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build()

            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build()

            audioFocusRequest = request
            am.requestAudioFocus(request)
        } else {
            // 低版本使用旧 API
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }

        result.success(focusResult == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
    }

    /**
     * 放弃音频焦点（复刻原版 abandonFocus）
     */
    private fun abandonAudioFocus(result: MethodChannel.Result) {
        val am = audioManager
        if (am == null) {
            result.success(null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(audioFocusChangeListener)
        }

        needResumeOnAudioFocusGain = false
        result.success(null)
    }

    /**
     * 更新播放状态（复刻原版 upMediaSessionPlaybackState）
     */
    private fun updatePlaybackState(state: String, position: Long) {
        val playbackState = when (state) {
            "playing" -> PlaybackStateCompat.STATE_PLAYING
            "paused" -> PlaybackStateCompat.STATE_PAUSED
            "stopped" -> PlaybackStateCompat.STATE_STOPPED
            "buffering" -> PlaybackStateCompat.STATE_BUFFERING
            else -> PlaybackStateCompat.STATE_NONE
        }

        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(mediaSessionActions)
                .setState(playbackState, position, 1f)
                .build()
        )
    }

    /**
     * 更新媒体元数据（复刻原版 upMediaMetadata）
     */
    private fun updateMetadata(title: String, artist: String, album: String) {
        val metadata = MediaMetadataCompat.Builder()
            .putText(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putText(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .putText(MediaMetadataCompat.METADATA_KEY_ALBUM, album)
            .build()
        mediaSession?.setMetadata(metadata)
    }

    /**
     * 向 Flutter 侧发送回调事件
     */
    private fun invokeFlutter(method: String, arguments: Any?) {
        methodChannel?.invokeMethod(method, arguments)
    }

    /**
     * 释放所有资源
     */
    fun release() {
        // 放弃焦点
        audioManager?.let { am ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(audioFocusChangeListener)
            }
        }
        audioFocusRequest = null

        // 释放 MediaSession
        mediaSession?.apply {
            isActive = false
            release()
        }
        mediaSession = null

        needResumeOnAudioFocusGain = false
        isPlaying = false
    }
}
