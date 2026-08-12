package io.legado.flutter

import android.content.Intent
import android.os.Bundle
import android.util.TypedValue
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val webViewBridge = WebViewBridge()
    private val brightnessBridge = BrightnessBridge()
    private val ttsBridge = TtsBridge()
    private val filePickerBridge = FilePickerBridge()
    private val mediaSessionBridge = MediaSessionBridge()

    private var deepLinkChannel: MethodChannel? = null
    private var initialDeepLink: String? = null

    companion object {
        private const val CHANNEL_WEBVIEW = "legado/webview"
        private const val CHANNEL_TTS = "legado/tts"
        private const val CHANNEL_FILE_PICKER = "legado/file_picker"
        private const val CHANNEL_NOTIFICATION = "legado/notification"
        private const val CHANNEL_BRIGHTNESS = "io.legado.app/brightness"
        private const val CHANNEL_MEDIA_SESSION = "legado/media_session"
        private const val CHANNEL_DEEP_LINK = "legado/deep_link"
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
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialDeepLink = intent?.dataString
        applyThemeStatusBarColor()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString
        if (!link.isNullOrEmpty()) {
            deepLinkChannel?.invokeMethod("onLink", link)
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        // 从其他 Activity（WebView/文件选择器等）返回时也需重新应用，
        // 防止系统恢复默认的半透明状态栏底色
        applyThemeStatusBarColor()
    }

    /**
     * 恢复 styles.xml 中定义的状态栏底色（亮色 #0288D1 / 暗色 #455A64）。
     *
     * Flutter 引擎在 FlutterActivity.onCreate 中硬编码
     * window.setStatusBarColor(0x40000000)（半透明黑），会覆盖主题色，
     * 导致顶部出现灰白条（白窗口背景 + 25% 黑遮罩）。
     * Dart 侧的 SystemUiOverlayStyle 不再下发 statusBarColor，
     * 由这里统一固化为主题色，不受路由切换影响。
     */
    private fun applyThemeStatusBarColor() {
        val typedValue = TypedValue()
        if (theme.resolveAttribute(android.R.attr.statusBarColor, typedValue, true)) {
            window.statusBarColor = typedValue.data
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
