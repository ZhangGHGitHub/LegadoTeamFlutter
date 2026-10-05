package io.legado.flutter

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.view.Gravity
import android.view.MotionEvent
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.io.File
import kotlin.math.abs

/**
 * [V-B3] 视频悬浮窗服务 — 复刻原版 [io.legado.app.service.VideoPlayService]（641 行）
 *
 * ## 形态与播放器承载（技术选型结论）
 *
 * 原版悬浮窗 = SYSTEM_ALERT_WINDOW 全局 overlay，窗口内是完整的原生
 * GSYVideoPlayer（SurfaceView 画面 + 关闭/全屏/播放/底部进度条；
 * `FloatingPlayer.kt:16-171`、`video_layout_floating.xml`），**不是**画中画、
 * 也不是仅控制条的音频窗。Flutter 的 `video_player` 纹理归 Flutter 引擎渲染面，
 * 无法进入独立 WindowManager 窗口，因此在原生服务内自建 Media3 ExoPlayer +
 * SurfaceView，走与原版相同的「状态克隆」移交语义：Dart 侧保存
 * url/header/位置/倍速/播放态 → 本服务新建播放器续播；返回全屏时把原生
 * 位置交回 Dart 重建 Flutter 播放器（对齐原版 `VideoPlay.savePlayState/
 * clonePlayState`，VideoPlay.kt:386-398——原版同样是两个播放器实例之间复制
 * 状态，而非共享实例）。
 *
 * ## 与原版逐项对照
 * - 权限：`SYSTEM_ALERT_WINDOW`（原版 manifest:26）+ `Settings.canDrawOverlays`
 *   检查 → Dart 侧引导设置页（对齐原版 VideoPlayService.kt:206-211）
 * - 前台服务：mediaPlayback 类型（原版 manifest:555-557；Android 14 起
 *   需要 FOREGROUND_SERVICE_MEDIA_PLAYBACK 运行时类型，已在 manifest 声明）
 * - WindowManager：TYPE_APPLICATION_OVERLAY（API≥O）/ TYPE_PHONE 兜底
 *   （对齐 :474-486）；宽=竖屏视频屏宽 1/2、横屏 3/4，高按视频比例 16:9 兜底
 *   （:462-495、:560-576）
 * - 触摸：拖动（20px 阈值）+ 松手贴边动画 + 单击显隐控制（:497-541、:134-171）
 * - MediaStyle 通知：上一集/播放暂停/下一集/停止（:408-458，NotificationId 108
 *   对应本侧 0x1E61）；MediaSession 回调 seekTo/play/pause/prev/next/stop
 *   （:266-294）；耳机拔出暂停（:333-343）；0.5s 位置刷新（:383-392）
 * - 生命周期：进入全屏 = 保存状态 → 拉起 MainActivity（对齐 toggleFullScreen
 *   :599-607，本侧经 MethodChannel/Intent 把状态交回 Dart）；关闭 = 保存并停服
 *   （对齐 stop() :594-597 + onDestroy saveRead :621-639）
 *
 * ## 本侧暂未承接（本批登记差异）
 * - 悬浮窗内弹幕：原版 `video_layout_floating.xml` 本身无弹幕层，未找到 → 不做
 * - 自动连播/上一集下一集：原生层无章节数据链（章节正文经 Rust/书源解析），
 *   由本服务向 Dart 发 onCompleted/onSkipNext/onSkipPrevious 事件，Dart 解析
 *   下一集 URL 后经 ACTION_REPLACE 续播；Dart 引擎不可用（划掉任务）时
 *   原版可继续连播、本侧仅停止（登记差异）
 */
class VideoPlayService : Service() {

    companion object {
        /** 与 [VideoFloatWindowBridge] 共用的 Flutter 事件通道名 */
        const val CHANNEL = "legado/video_float"

        const val ACTION_START = "io.legado.flutter.action.VIDEO_FLOAT_START"
        const val ACTION_REPLACE = "io.legado.flutter.action.VIDEO_FLOAT_REPLACE"
        const val ACTION_TOGGLE = "io.legado.flutter.action.VIDEO_FLOAT_TOGGLE"
        const val ACTION_PREV = "io.legado.flutter.action.VIDEO_FLOAT_PREV"
        const val ACTION_NEXT = "io.legado.flutter.action.VIDEO_FLOAT_NEXT"
        const val ACTION_STOP = "io.legado.flutter.action.VIDEO_FLOAT_STOP"

        /** 通知点击：保存当前状态并回到 Flutter 播放页（对齐原版 contentIntent） */
        const val ACTION_OPEN = "io.legado.flutter.action.VIDEO_FLOAT_OPEN"

        /** 启动/替换内容时携带的状态 Bundle（键见 [VideoFloatState.toMap]） */
        const val EXTRA_STATE = "video_float_state"

        /** 回全屏时携带的状态 Bundle（MainActivity → Dart） */
        const val EXTRA_RETURN = "video_float_return"

        const val NOTIFICATION_ID = 0x1E61
        const val CHANNEL_ID = "legado_video_float"

        /** 播完等待 Dart 决定续播/关闭的窗口（对齐原版 upDurIndex 立即决策；本侧需异步解析） */
        const val COMPLETION_EXIT_DELAY_MS = 10_000L

        /** 拖动判定阈值（对齐原版 FloatingTouchListener :519） */
        const val DRAG_THRESHOLD_PX = 20f

        /** 贴边与上下的留白（对齐原版 startEdgeAnimation :143-154） */
        const val EDGE_MARGIN_PX = 30
        const val TOP_MARGIN_PX = 30
        const val BOTTOM_MARGIN_PX = 60

        /** 控制条自动隐藏延时（原版 GSY 默认约 3s） */
        const val CONTROLS_HIDE_DELAY_MS = 3_500L

        @Volatile
        var active: VideoPlayService? = null
            private set
    }

    private var player: ExoPlayer? = null
    private var mediaSession: MediaSessionCompat? = null
    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var surfaceView: SurfaceView? = null
    private var playPauseButton: ImageView? = null
    private var progressBar: ProgressBar? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var state: VideoFloatState? = null
    private var controls: List<View> = emptyList()
    private var controlsVisible = true
    private var deleteMpdOnDestroy = true
    private var noisyReceiver: BroadcastReceiver? = null
    private var completionExitRunnable: Runnable? = null
    private val handler = Handler(Looper.getMainLooper())

    private val progressRunnable = object : Runnable {
        override fun run() {
            updateProgress()
            handler.postDelayed(this, 500L)
        }
    }

    private val hideControlsRunnable = Runnable { setControlsVisible(false) }

    override fun onCreate() {
        super.onCreate()
        active = this
        createNotificationChannel()
        initMediaSession()
        initNoisyReceiver()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 前台服务 5s 约束：先 startForeground 再处理（首次经 startForegroundService 拉起）
        startForegroundCompat(if (intent?.action == ACTION_START || intent?.action == ACTION_REPLACE) {
            VideoFloatState.fromIntent(intent) ?: state
        } else {
            state
        })

        when (intent?.action) {
            ACTION_STOP -> {
                stopAndNotify()
                return START_NOT_STICKY
            }
            ACTION_TOGGLE -> {
                togglePlay()
                return START_NOT_STICKY
            }
            ACTION_PREV -> {
                emitSkipEvent("onSkipPrevious")
                return START_NOT_STICKY
            }
            ACTION_NEXT -> {
                emitSkipEvent("onSkipNext")
                return START_NOT_STICKY
            }
            ACTION_OPEN -> {
                returnToFullscreen()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_REPLACE -> {
                if (!canDrawOverlays()) {
                    // 对齐原版 :206-211：无权限时引导后停止（Dart 侧负责打开设置页）
                    VideoFloatWindowBridge.emit(
                        "onError",
                        mapOf("message" to "no_overlay_permission")
                    )
                    stopSelf()
                    return START_NOT_STICKY
                }
                val newState = VideoFloatState.fromIntent(intent)
                if (newState == null) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                applyContent(newState)
                return START_NOT_STICKY
            }
        }
        stopSelf()
        return START_NOT_STICKY
    }

    // ===================== 内容装载 =====================

    @OptIn(UnstableApi::class)
    private fun applyContent(newState: VideoFloatState) {
        cancelCompletionExit()
        // 换内容时清理旧 MPD 临时文件（所有权在本服务；交回 Dart 的场景已置 false）
        val previousMpd = state?.mpdTempPath
        if (deleteMpdOnDestroy && previousMpd != null && previousMpd != newState.mpdTempPath) {
            try {
                File(previousMpd).delete()
            } catch (_: Exception) {
            }
        }
        state = newState
        deleteMpdOnDestroy = newState.mpdTempPath != null
        if (!ensureOverlay()) return

        val httpFactory = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(newState.headers)
            .setAllowCrossProtocolRedirects(true)
        val dataSourceFactory = DefaultDataSource.Factory(this, httpFactory)
        val mediaSource = DefaultMediaSourceFactory(dataSourceFactory)
            .createMediaSource(MediaItem.fromUri(Uri.parse(newState.url)))

        val p = player ?: ExoPlayer.Builder(this)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                /* handleAudioFocus = */ true
            )
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
            .also {
                it.addListener(playerListener)
                player = it
            }

        p.stop()
        p.clearMediaItems()
        p.setMediaSource(mediaSource)
        p.setPlaybackParameters(PlaybackParameters(newState.speed.coerceIn(0.25f, 4f)))
        p.playWhenReady = newState.playing
        if (newState.positionMs > 0) p.seekTo(newState.positionMs)
        p.setVideoSurfaceView(surfaceView)
        p.prepare()

        updatePlayPauseIcon()
        updateMediaMetadata()
        updateMediaSessionState()
        upNotification()
        showControls()
    }

    // ===================== 播放控制 =====================

    private fun togglePlay() {
        val p = player ?: return
        if (p.isPlaying) p.pause() else p.play()
    }

    private fun onPlaybackEnded() {
        // 对齐原版 onAutoComplete（VideoPlayService.kt:577-581）：
        // 原版原生层直接 upDurIndex(1)；本侧无章节链，交 Dart 决策
        // （Dart 解析下一集 → ACTION_REPLACE；无下一集/引擎不可用 → 延时停服）
        VideoFloatWindowBridge.emit("onCompleted", currentStateMap())
        cancelCompletionExit()
        val runnable = Runnable {
            if (player?.playbackState == Player.STATE_ENDED) {
                stopAndNotify()
            }
        }
        completionExitRunnable = runnable
        handler.postDelayed(runnable, COMPLETION_EXIT_DELAY_MS)
    }

    private fun cancelCompletionExit() {
        completionExitRunnable?.let { handler.removeCallbacks(it) }
        completionExitRunnable = null
    }

    /** 关闭悬浮窗：保存状态通知 Dart 后停服（对齐原版 stop() :594-597） */
    private fun stopAndNotify() {
        VideoFloatWindowBridge.emit("onClosed", currentStateMap())
        stopSelf()
    }

    /** 内容播完且 Dart 无更多续播时由 Dart 调用：静默停服（不再发 onClosed） */
    fun dismiss() {
        cancelCompletionExit()
        stopSelf()
    }

    /** 回全屏：状态经 Intent 带回 MainActivity → Dart（对齐原版 toggleFullScreen :599-607） */
    private fun returnToFullscreen() {
        updateProgress()
        val map = currentStateMap()
        deleteMpdOnDestroy = false
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK
                        or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        or Intent.FLAG_ACTIVITY_CLEAR_TOP
            )
            putExtra(EXTRA_RETURN, bundleFromMap(map))
        }
        startActivity(intent)
        stopSelf()
    }

    /** 状态查询（Dart takeOver/getState）：返回当前状态并停服 */
    fun stateMapAndStop(): Map<String, Any?> {
        val map = currentStateMap()
        deleteMpdOnDestroy = false
        stopSelf()
        return map
    }

    fun currentStateMap(): Map<String, Any?> {
        val s = state ?: return emptyMap()
        val p = player
        val position = p?.let {
            if (it.currentPosition > 0) it.currentPosition else s.positionMs
        } ?: s.positionMs
        val playing = p?.isPlaying ?: s.playing
        return s.copy(positionMs = position, playing = playing).toMap()
    }

    private fun emitSkipEvent(method: String) {
        VideoFloatWindowBridge.emit(method, currentStateMap())
    }

    // ===================== 悬浮窗 =====================

    @SuppressLint("ClickableViewAccessibility")
    private fun ensureOverlay(): Boolean {
        val existing = rootView
        if (existing != null && existing.parent != null) return true

        val root = FrameLayout(this).apply {
            background = ContextCompat.getDrawable(this@VideoPlayService, R.drawable.video_float_background)
            clipToOutline = true
        }
        val surface = SurfaceView(this)
        root.addView(
            surface,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
            )
        )

        val close = ImageView(this).apply {
            setImageResource(R.drawable.video_float_close)
            contentDescription = "关闭悬浮窗"
            setPadding(dp(6), dp(6), dp(6), dp(6))
            setOnClickListener { stopAndNotify() }
        }
        root.addView(
            close,
            FrameLayout.LayoutParams(dp(36), dp(36), Gravity.TOP or Gravity.START)
        )

        val fullscreen = ImageView(this).apply {
            setImageResource(R.drawable.video_float_fullscreen)
            contentDescription = "回到全屏"
            setPadding(dp(6), dp(6), dp(6), dp(6))
            setOnClickListener { returnToFullscreen() }
        }
        root.addView(
            fullscreen,
            FrameLayout.LayoutParams(dp(36), dp(36), Gravity.TOP or Gravity.END)
        )

        val playPause = ImageView(this).apply {
            setImageResource(R.drawable.video_float_pause)
            contentDescription = "播放/暂停"
            setPadding(dp(6), dp(6), dp(6), dp(6))
            setOnClickListener { togglePlay() }
        }
        root.addView(
            playPause,
            FrameLayout.LayoutParams(dp(44), dp(44), Gravity.CENTER)
        )

        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
        }
        root.addView(
            progress,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(2),
                Gravity.BOTTOM
            )
        )

        root.setOnTouchListener(FloatingTouchListener())

        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val screenWidth = resources.displayMetrics.widthPixels
        val width = computeFloatWindowWidth(screenWidth, 0, 0)
        val height = computeFloatWindowHeight(width, 0, 0)
        val params = WindowManager.LayoutParams(
            width,
            height,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.START or Gravity.TOP
            x = EDGE_MARGIN_PX
            y = screenWidth / 10
        }

        try {
            windowManager?.addView(root, params)
        } catch (e: Exception) {
            // 权限被系统回收 / 窗口 token 失效：回报 Dart 并停服
            VideoFloatWindowBridge.emit(
                "onError",
                mapOf("message" to (e.message ?: "overlay_add_failed"))
            )
            stopSelf()
            return false
        }

        rootView = root
        surfaceView = surface
        playPauseButton = playPause
        progressBar = progress
        layoutParams = params
        controls = listOf(close, fullscreen, playPause)

        player?.setVideoSurfaceView(surface)
        handler.post(progressRunnable)
        return true
    }

    /** 悬浮窗权限：API<M 无需申请，M+ 需 Settings.canDrawOverlays（对齐原版 :206-211） */
    private fun canDrawOverlays(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun updateProgress() {
        val p = player ?: return
        val duration = p.duration
        if (duration > 0) {
            progressBar?.progress = ((p.currentPosition * 100) / duration).toInt()
        }
    }

    private fun updateViewLayoutSafe() {
        val root = rootView ?: return
        val params = layoutParams ?: return
        try {
            windowManager?.updateViewLayout(root, params)
        } catch (_: Exception) {
        }
    }

    private fun resizeOverlay(videoWidth: Int, videoHeight: Int) {
        if (videoWidth <= 0 || videoHeight <= 0) return
        val params = layoutParams ?: return
        val screenWidth = resources.displayMetrics.widthPixels
        val width = computeFloatWindowWidth(screenWidth, videoWidth, videoHeight)
        val height = computeFloatWindowHeight(width, videoWidth, videoHeight)
        if (params.width != width || params.height != height) {
            params.width = width
            params.height = height
            updateViewLayoutSafe()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private inner class FloatingTouchListener : View.OnTouchListener {
        private var initialTouchX = 0f
        private var initialTouchY = 0f
        private var initialX = 0
        private var initialY = 0
        private var isClick = true
        private var animator: ValueAnimator? = null

        override fun onTouch(v: View, event: MotionEvent): Boolean {
            val params = layoutParams ?: return false
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isClick = true
                    initialTouchX = event.rawX
                    initialTouchY = event.rawY
                    initialX = params.x
                    initialY = params.y
                    animator?.cancel()
                }
                MotionEvent.ACTION_MOVE -> {
                    val deltaX = event.rawX - initialTouchX
                    val deltaY = event.rawY - initialTouchY
                    if (abs(deltaX) > DRAG_THRESHOLD_PX || abs(deltaY) > DRAG_THRESHOLD_PX) {
                        isClick = false
                        params.x = (initialX + deltaX).toInt()
                        params.y = (initialY + deltaY).toInt()
                        updateViewLayoutSafe()
                    } else {
                        // 对齐原版 FloatingTouchListener :519-527：回到阈值内仍按点击
                        isClick = true
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (isClick) {
                        toggleControls()
                    } else {
                        startEdgeAnimation()
                    }
                }
            }
            return false
        }

        private fun startEdgeAnimation() {
            val params = layoutParams ?: return
            val view = rootView ?: return
            val screenWidth = resources.displayMetrics.widthPixels
            val screenHeight = resources.displayMetrics.heightPixels
            val viewWidth = if (view.width > 0) view.width else params.width
            val viewHeight = if (view.height > 0) view.height else params.height
            val startX = params.x
            val startY = params.y
            val endX = computeSnapEndX(startX, viewWidth, screenWidth)
            val endY = clampFloatWindowY(startY, viewHeight, screenHeight)
            animator?.cancel()
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 200
                interpolator = DecelerateInterpolator()
                addUpdateListener { animation ->
                    val fraction = animation.animatedFraction
                    params.x = (startX + (endX - startX) * fraction).toInt()
                    params.y = (startY + (endY - startY) * fraction).toInt()
                    updateViewLayoutSafe()
                }
                start()
            }
        }
    }

    private fun showControls() {
        setControlsVisible(true)
        handler.removeCallbacks(hideControlsRunnable)
        handler.postDelayed(hideControlsRunnable, CONTROLS_HIDE_DELAY_MS)
    }

    private fun toggleControls() {
        if (controlsVisible) {
            setControlsVisible(false)
        } else {
            showControls()
        }
    }

    private fun setControlsVisible(visible: Boolean) {
        controlsVisible = visible
        val visibility = if (visible) View.VISIBLE else View.GONE
        controls.forEach { it.visibility = visibility }
        if (!visible) handler.removeCallbacks(hideControlsRunnable)
    }

    private fun updatePlayPauseIcon() {
        val playing = player?.isPlaying ?: (state?.playing ?: false)
        playPauseButton?.setImageResource(
            if (playing) R.drawable.video_float_pause else R.drawable.video_float_play
        )
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    // ===================== 通知 / MediaSession =====================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "视频播放",
            NotificationManager.IMPORTANCE_LOW
        )
        manager.createNotificationChannel(channel)
    }

    private fun initMediaSession() {
        val session = MediaSessionCompat(this, "videoPlayService")
        session.setFlags(
            MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
        )
        session.setCallback(object : MediaSessionCompat.Callback() {
            override fun onSeekTo(pos: Long) {
                player?.seekTo(pos)
                updateProgress()
            }

            override fun onPlay() {
                player?.play()
            }

            override fun onPause() {
                player?.pause()
            }

            override fun onStop() {
                stopAndNotify()
            }

            override fun onSkipToPrevious() {
                emitSkipEvent("onSkipPrevious")
            }

            override fun onSkipToNext() {
                emitSkipEvent("onSkipNext")
            }
        })
        session.isActive = true
        mediaSession = session
    }

    private fun initNoisyReceiver() {
        // 对齐原版 :333-343：耳机拔出暂停
        noisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY == intent.action) {
                    player?.pause()
                }
            }
        }
        registerReceiver(
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        )
    }

    private fun updateMediaMetadata() {
        val s = state ?: return
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, s.title.ifBlank { "视频" })
            .putText(MediaMetadataCompat.METADATA_KEY_ARTIST, s.bookName.ifBlank { null })
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, player?.duration ?: 0L)
            .build()
        mediaSession?.setMetadata(metadata)
    }

    private fun updateMediaSessionState() {
        val p = player ?: return
        val playbackState = when {
            p.isPlaying -> PlaybackStateCompat.STATE_PLAYING
            p.playbackState == Player.STATE_ENDED -> PlaybackStateCompat.STATE_STOPPED
            else -> PlaybackStateCompat.STATE_PAUSED
        }
        val speed = p.playbackParameters.speed
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_SEEK_TO
                            or PlaybackStateCompat.ACTION_PLAY
                            or PlaybackStateCompat.ACTION_PAUSE
                            or PlaybackStateCompat.ACTION_PLAY_PAUSE
                            or PlaybackStateCompat.ACTION_STOP
                            or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                            or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
                )
                .setState(playbackState, p.currentPosition, speed)
                .build()
        )
    }

    private fun pendedServiceIntent(action: String): PendingIntent {
        val intent = Intent(this, VideoPlayService::class.java).setAction(action)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        // requestCode 用 action.hashCode 区分不同动作
        return PendingIntent.getService(this, action.hashCode(), intent, flags)
    }

    private fun buildNotification(): Notification {
        val (title, text) = resolveVideoNotificationTexts(state?.title)
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setSubText("视频")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pendedServiceIntent(ACTION_OPEN))
            .addAction(
                android.R.drawable.ic_media_previous,
                "上一集",
                pendedServiceIntent(ACTION_PREV)
            )
        if (player?.isPlaying == true) {
            builder.addAction(
                android.R.drawable.ic_media_pause,
                "暂停",
                pendedServiceIntent(ACTION_TOGGLE)
            )
        } else {
            builder.addAction(
                android.R.drawable.ic_media_play,
                "播放",
                pendedServiceIntent(ACTION_TOGGLE)
            )
        }
        builder.addAction(
            android.R.drawable.ic_media_next,
            "下一集",
            pendedServiceIntent(ACTION_NEXT)
        )
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            "关闭",
            pendedServiceIntent(ACTION_STOP)
        )
        builder.setStyle(
            androidx.media.app.NotificationCompat.MediaStyle()
                .setShowActionsInCompactView(0, 1, 2)
                .setMediaSession(mediaSession?.sessionToken)
        )
        builder.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        return builder.build()
    }

    private fun startForegroundCompat(snapshot: VideoFloatState?) {
        if (state == null && snapshot != null) state = snapshot
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun upNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            manager.notify(NOTIFICATION_ID, buildNotification())
        } catch (_: Exception) {
        }
    }

    // ===================== 播放器监听 =====================

    private val playerListener = object : Player.Listener {
        override fun onVideoSizeChanged(videoSize: VideoSize) {
            resizeOverlay(videoSize.width, videoSize.height)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            updatePlayPauseIcon()
            updateMediaSessionState()
            upNotification()
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
                Player.STATE_READY -> {
                    updateMediaMetadata()
                    updateMediaSessionState()
                }
                Player.STATE_ENDED -> onPlaybackEnded()
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            VideoFloatWindowBridge.emit(
                "onError",
                mapOf(
                    "message" to (error.message ?: "playback_error"),
                    "url" to (state?.url ?: "")
                )
            )
            stopAndNotify()
        }
    }

    // ===================== 生命周期 =====================

    override fun onDestroy() {
        super.onDestroy()
        active = null
        handler.removeCallbacksAndMessages(null)
        completionExitRunnable = null
        try {
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            noisyReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        noisyReceiver = null
        mediaSession?.release()
        mediaSession = null
        val root = rootView
        if (root != null) {
            try {
                windowManager?.removeView(root)
            } catch (_: Exception) {
            }
        }
        rootView = null
        layoutParams = null
        surfaceView = null
        playPauseButton = null
        progressBar = null
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        if (deleteMpdOnDestroy) {
            state?.mpdTempPath?.let { path ->
                try {
                    File(path).delete()
                } catch (_: Exception) {
                }
            }
        }
        state = null
    }
}

// ===================== 纯函数（JVM 单测覆盖） =====================

/**
 * 悬浮窗播放状态：Dart → 服务（ACTION_START/REPLACE）与服务 → Dart/Intent 共用。
 *
 * 键与原版 VideoPlay 静态状态对应：url/headers=videoUrl+AnalyzeUrl.headerMap、
 * positionMs=durChapterPos、bookUrl/bookName/chapterIndex/chapterTitle=书籍上下文、
 * directUrl=单链接模式的 video_pos_ 键、mpdTempPath=MPD 临时清单文件。
 */
internal data class VideoFloatState(
    val url: String,
    val title: String = "",
    val bookName: String = "",
    val headers: Map<String, String> = emptyMap(),
    val positionMs: Long = 0L,
    val playing: Boolean = true,
    val speed: Float = 1f,
    val bookUrl: String? = null,
    val chapterIndex: Int = -1,
    val chapterTitle: String? = null,
    val directUrl: String? = null,
    val hasPrev: Boolean = false,
    val hasNext: Boolean = false,
    val mpdTempPath: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "url" to url,
        "title" to title,
        "bookName" to bookName,
        "headers" to headers,
        "positionMs" to positionMs,
        "playing" to playing,
        "speed" to speed.toDouble(),
        "bookUrl" to bookUrl,
        "chapterIndex" to chapterIndex,
        "chapterTitle" to chapterTitle,
        "directUrl" to directUrl,
        "hasPrev" to hasPrev,
        "hasNext" to hasNext,
        "mpdTempPath" to mpdTempPath,
    )

    companion object {
        /** 从 MethodChannel 参数 / Intent Bundle 还原（脏值一律降级默认值） */
        fun fromMap(map: Map<*, *>?): VideoFloatState? {
            if (map == null) return null
            val url = map["url"] as? String
            if (url.isNullOrBlank()) return null
            val headers = (map["headers"] as? Map<*, *>)?.entries
                ?.associate { (it.key?.toString() ?: "") to (it.value?.toString() ?: "") }
                ?.filterKeys { it.isNotEmpty() }
                ?: emptyMap()
            return VideoFloatState(
                url = url,
                title = map["title"] as? String ?: "",
                bookName = map["bookName"] as? String ?: "",
                headers = headers,
                positionMs = (map["positionMs"] as? Number)?.toLong() ?: 0L,
                playing = map["playing"] as? Boolean ?: true,
                speed = (map["speed"] as? Number)?.toFloat() ?: 1f,
                bookUrl = map["bookUrl"] as? String,
                chapterIndex = (map["chapterIndex"] as? Number)?.toInt() ?: -1,
                chapterTitle = map["chapterTitle"] as? String,
                directUrl = map["directUrl"] as? String,
                hasPrev = map["hasPrev"] as? Boolean ?: false,
                hasNext = map["hasNext"] as? Boolean ?: false,
                mpdTempPath = map["mpdTempPath"] as? String,
            )
        }

        fun fromIntent(intent: Intent?): VideoFloatState? {
            val bundle = intent?.getBundleExtra(VideoPlayService.EXTRA_STATE) ?: return null
            val map = bundle.keySet().associateWith { bundle.get(it) }
            return fromMap(map)
        }
    }
}

internal fun bundleFromMap(map: Map<String, Any?>): Bundle {
    val bundle = Bundle()
    map.forEach { (key, value) ->
        when (value) {
            null -> bundle.putString(key, null)
            is String -> bundle.putString(key, value)
            is Boolean -> bundle.putBoolean(key, value)
            is Int -> bundle.putInt(key, value)
            is Long -> bundle.putLong(key, value)
            is Float -> bundle.putFloat(key, value)
            is Double -> bundle.putDouble(key, value)
            is Map<*, *> -> {
                val hash = HashMap<String, String>()
                value.forEach { (k, v) ->
                    hash[k?.toString() ?: ""] = v?.toString() ?: ""
                }
                bundle.putSerializable(key, hash)
            }
            else -> bundle.putString(key, value.toString())
        }
    }
    return bundle
}

/**
 * 通知标题/文本（原版 VideoPlayService.kt:408-421）：
 * 标题 = 「正在播放: <视频标题>」（标题空回退 R.string.video「视频」），
 * 文本 = R.string.audio_play_s「点击打开播放界面」。
 * 纯函数，JVM 单测覆盖。
 */
internal fun resolveVideoNotificationTexts(videoTitle: String?): Pair<String, String> {
    val name = videoTitle?.takeIf { it.isNotBlank() } ?: "视频"
    return "正在播放: $name" to "点击打开播放界面"
}

/**
 * 悬浮窗宽度（对齐原版 VideoPlayService.kt:462-472）：
 * 竖屏视频（高 > 宽×1.2）取屏宽 1/2，否则屏宽 3/4；未知尺寸按横屏 3/4。
 */
internal fun computeFloatWindowWidth(screenWidth: Int, videoWidth: Int, videoHeight: Int): Int =
    if (videoHeight > videoWidth * 1.2) screenWidth / 2 else screenWidth * 3 / 4

/**
 * 悬浮窗高度（对齐原版 :472）：已知视频尺寸按比例，未知 16:9 兜底。
 */
internal fun computeFloatWindowHeight(
    windowWidth: Int,
    videoWidth: Int,
    videoHeight: Int,
): Int =
    if (videoWidth > 0 && videoHeight > 0) {
        (windowWidth.toLong() * videoHeight / videoWidth).toInt()
    } else {
        windowWidth * 9 / 16
    }

/**
 * 松手贴边目标 X（对齐原版 startEdgeAnimation :141-147）：
 * 窗口占满全宽时归 0；否则按中线判定吸附左/右，留 30px。
 */
internal fun computeSnapEndX(currentX: Int, viewWidth: Int, screenWidth: Int): Int = when {
    viewWidth == screenWidth -> 0
    currentX + viewWidth / 2 > screenWidth / 2 -> screenWidth - viewWidth - EDGE_MARGIN_PX_FOR_TEST
    else -> EDGE_MARGIN_PX_FOR_TEST
}

/**
 * 松手贴边目标 Y（对齐原版 :148-154）：上留 30，下留 60。
 */
internal fun clampFloatWindowY(currentY: Int, viewHeight: Int, screenHeight: Int): Int = when {
    currentY < TOP_MARGIN_PX_FOR_TEST -> TOP_MARGIN_PX_FOR_TEST
    currentY > screenHeight - viewHeight - BOTTOM_MARGIN_PX_FOR_TEST ->
        screenHeight - viewHeight - BOTTOM_MARGIN_PX_FOR_TEST
    else -> currentY
}

/** 纯函数可见的边距常量（与 [VideoPlayService] companion 数值一致） */
internal const val EDGE_MARGIN_PX_FOR_TEST = 30
internal const val TOP_MARGIN_PX_FOR_TEST = 30
internal const val BOTTOM_MARGIN_PX_FOR_TEST = 60
