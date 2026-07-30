package io.legado.flutter

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val webViewBridge = WebViewBridge()
    private val brightnessBridge = BrightnessBridge()
    private val ttsBridge = TtsBridge()
    private val filePickerBridge = FilePickerBridge()

    companion object {
        private const val CHANNEL_WEBVIEW = "legado/webview"
        private const val CHANNEL_TTS = "legado/tts"
        private const val CHANNEL_FILE_PICKER = "legado/file_picker"
        private const val CHANNEL_NOTIFICATION = "legado/notification"
        private const val CHANNEL_BRIGHTNESS = "io.legado.app/brightness"
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
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        filePickerBridge.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        super.onDestroy()
        ttsBridge.release()
        webViewBridge.destroy()
    }
}
