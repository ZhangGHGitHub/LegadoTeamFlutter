package io.legado.flutter

import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val webViewBridge = WebViewBridge()
    private val brightnessBridge = BrightnessBridge()
    private val ttsBridge = TtsBridge()
    private val filePickerBridge = FilePickerBridge()
    private val mediaSessionBridge = MediaSessionBridge()

    private var deepLinkChannel: MethodChannel? = null
    private var autoTaskJobChannel: MethodChannel? = null
    private var initialDeepLink: String? = null
    private var pendingAutoTaskDue = false
    private var pendingAutoTaskMinimize = false

    /** 最近一次 Dart 侧下发的系统栏配置（onPostResume 时复用，避免被主题色覆盖） */
    private var systemBarTransparent = true
    private var systemBarImmNav = true
    private var systemBarStatusColor = Color.TRANSPARENT
    private var systemBarNavColor = Color.TRANSPARENT
    private var systemBarLightIcons = false

    companion object {
        private const val CHANNEL_WEBVIEW = "legado/webview"
        private const val CHANNEL_TTS = "legado/tts"
        private const val CHANNEL_FILE_PICKER = "legado/file_picker"
        private const val CHANNEL_NOTIFICATION = "legado/notification"
        private const val CHANNEL_BRIGHTNESS = "io.legado.app/brightness"
        private const val CHANNEL_MEDIA_SESSION = "legado/media_session"
        private const val CHANNEL_DEEP_LINK = "legado/deep_link"
        private const val CHANNEL_SYSTEM_BAR = "legado/system_bar"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 WebView 通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_WEBVIEW)
            .setMethodCallHandler { call, result ->
                webViewBridge.handleMethodCall(call, result, this)
            }

        // 注册 TTS 通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_TTS)
            .setMethodCallHandler { call, result ->
                ttsBridge.handleMethodCall(call, result, this)
            }

        // 注册文件选择器通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_FILE_PICKER)
            .setMethodCallHandler { call, result ->
                filePickerBridge.handleMethodCall(call, result, this)
            }

        // 注册通知通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NOTIFICATION)
            .setMethodCallHandler { call, result ->
                NotificationService.handleMethodCall(call, result, this)
            }

        // 注册亮度控制通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_BRIGHTNESS)
            .setMethodCallHandler { call, result ->
                brightnessBridge.handleMethodCall(call, result, this)
            }

        // 注册媒体会话通道（后台播放 + 媒体按钮 + 音频焦点）
        val mediaSessionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL_MEDIA_SESSION
        )
        mediaSessionBridge.setMethodChannel(mediaSessionChannel)
        mediaSessionChannel.setMethodCallHandler { call, result ->
            mediaSessionBridge.handleMethodCall(call, result, this)
        }

        // P1-11：legado:// / yuedu:// 深链
        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL_DEEP_LINK
        )
        deepLinkChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> result.success(initialDeepLink)
                else -> result.notImplemented()
            }
        }

        // P1-16：定时任务 JobScheduler 真后台桥
        autoTaskJobChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, AutoTaskJobBridge.CHANNEL
        )
        AutoTaskJobBridge.setMethodChannel(autoTaskJobChannel)
        autoTaskJobChannel?.setMethodCallHandler { call, result ->
            AutoTaskJobBridge.handleMethodCall(call, result, this)
        }
        if (pendingAutoTaskDue) {
            pendingAutoTaskDue = false
            autoTaskJobChannel?.invokeMethod("onJobDue", null)
            maybeMinimizeAfterAutoTask()
        }

        // 沉浸式状态栏 / 导航栏（对标原版 BaseActivity.setupSystemBar）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SYSTEM_BAR)
            .setMethodCallHandler { call, result ->
                handleSystemBarCall(call, result)
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialDeepLink = intent?.dataString
        pendingAutoTaskDue =
            intent?.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_DUE, false) == true
        pendingAutoTaskMinimize =
            intent?.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_MINIMIZE, false) == true
        applySystemBarFromState()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString
        if (!link.isNullOrEmpty()) {
            deepLinkChannel?.invokeMethod("onLink", link)
        }
        if (intent.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_DUE, false)) {
            pendingAutoTaskMinimize =
                intent.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_MINIMIZE, false)
            autoTaskJobChannel?.invokeMethod("onJobDue", null)
                ?: run { pendingAutoTaskDue = true }
            maybeMinimizeAfterAutoTask()
        }
    }

    /** Job 冷启动拉起时尽快退到后台，减少打扰（F2） */
    private fun maybeMinimizeAfterAutoTask() {
        if (!pendingAutoTaskMinimize) return
        pendingAutoTaskMinimize = false
        window.decorView.post {
            try {
                moveTaskToBack(true)
            } catch (_: Exception) {
            }
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        // 从其他 Activity 返回时复用 Dart 侧最近一次配置
        applySystemBarFromState()
    }

    private fun handleSystemBarCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "apply" -> {
                systemBarTransparent =
                    call.argument<Boolean>("transparentStatusBar") ?: true
                systemBarImmNav =
                    call.argument<Boolean>("immNavigationBar") ?: true
                call.argument<Int>("statusBarColor")?.let {
                    systemBarStatusColor = it
                }
                call.argument<Int>("navigationBarColor")?.let {
                    systemBarNavColor = it
                }
                systemBarLightIcons =
                    call.argument<Boolean>("lightStatusBarIcons") ?: false
                applySystemBarFromState()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 应用系统栏样式（对标原版 ActivityExtensions.setStatusBarColorAuto /
     * setNavigationBarColorAuto + fullScreen）。
     *
     * 沉浸式开启时状态栏透明、内容延伸至状态栏区域；关闭时使用
     * status_bar_bag 实色条。不再强制 styles.xml 主题色，避免顶栏与
     * 状态栏出现灰白断层。
     */
    private fun applySystemBarFromState() {
        @Suppress("DEPRECATION")
        if (systemBarTransparent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(false)
            } else {
                window.decorView.systemUiVisibility =
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            }
            window.statusBarColor = Color.TRANSPARENT
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(true)
            } else {
                window.decorView.systemUiVisibility =
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            }
            window.statusBarColor = systemBarStatusColor
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
        window.navigationBarColor = systemBarNavColor

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let { controller ->
                if (systemBarLightIcons) {
                    controller.setSystemBarsAppearance(
                        WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
                        WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    )
                } else {
                    controller.setSystemBarsAppearance(
                        0,
                        WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    )
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            @Suppress("DEPRECATION")
            var flags = window.decorView.systemUiVisibility
            flags = if (systemBarLightIcons) {
                flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            } else {
                flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
            }
            window.decorView.systemUiVisibility = flags
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        filePickerBridge.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        super.onDestroy()
        ttsBridge.release()
        webViewBridge.destroy()
        mediaSessionBridge.release()
    }
}
