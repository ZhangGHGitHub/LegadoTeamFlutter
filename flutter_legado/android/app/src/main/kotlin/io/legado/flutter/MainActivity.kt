package io.legado.flutter

import android.content.Intent
import android.database.Cursor
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

// open：供图标变体桩类 Launcher1~6 继承（对齐原版 WelcomeActivity ×6 子类机制）
open class MainActivity : FlutterActivity() {

    private val webViewBridge = WebViewBridge()
    private val brightnessBridge = BrightnessBridge()
    private val ttsBridge = TtsBridge()
    private val filePickerBridge = FilePickerBridge()
    private val saveFileBridge = SaveFileBridge()
    private val mediaSessionBridge = MediaSessionBridge()
    private val cookieBridge = CookieBridge()
    private val storageBridge = StorageBridge()
    private val readerKeysBridge = ReaderKeysBridge()
    private val videoFloatBridge = VideoFloatWindowBridge()

    private var deepLinkChannel: MethodChannel? = null
    private var autoTaskJobChannel: MethodChannel? = null
    private var initialDeepLink: String? = null

    /** P1-4：外部书籍文件 VIEW intent（content:// / file://），冷启动暂存待 Dart 拉取 */
    private var initialFileUri: String? = null

    /** 批25：ACTION_SEND / PROCESS_TEXT 分享文本，冷启动暂存待 Dart 拉取（取后清空） */
    private var initialSharedText: String? = null
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
        private const val CHANNEL_DEVICE_ID = "legado/device_id"
        private const val CHANNEL_COOKIE = "legado/cookie"
        private const val CHANNEL_LAUNCHER_ICON = LauncherIconBridge.CHANNEL
        private const val CHANNEL_HEAP_DUMP = "legado/heap_dump"

        /** 批25b P2-2：分享文本一次性消费标记（SharedPreferences 文件与键） */
        private const val PREFS_SHARED_TEXT_ONCE = "shared_text_once"
        private const val KEY_CONSUMED_HASH = "consumed_hash"
        private const val KEY_CONSUMED_AT = "consumed_at"

        /** 进程级 one-shot holder：最近一次提取/投递的分享文本 */
        private var recentSharedText: String? = null
        private var recentSharedTextAt: Long = 0L
    }

    /**
     * 批25b P3-5：Dart 侧 deep_link 通道处理器是否已注册。
     *
     * 以 Dart `getInitialSharedText` 首次调用为界（Dart 在 `attach()` 内先
     * `setMethodCallHandler`，再拉取初始数据，主线程调用串行）。未就绪时
     * `onNewIntent` 只暂存不投递，避免「引擎已配置但 Dart 尚未注册处理器」
     * 的启动窗口内分享文本被静默丢弃。
     */
    private var dartSharedHandlerReady = false

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

        // [D1] 系统另存通道：ACTION_CREATE_DOCUMENT + 自建受控写流
        //（替代 file_picker 在 onActivityResult 内裸写 URI 的崩溃链路，
        // 异常全部回 result.error，不穿透主线程）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SaveFileBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                saveFileBridge.handleMethodCall(call, result, this)
            }

        // 注册存储通道（[D2] MediaStore 直写 Download/legado/，绕开
        // file_picker SAF 链路：MuMu DownloadStorageProvider 拒写时
        // SecurityException 经 file_picker 未捕获路径主线程 FATAL）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, StorageBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                storageBridge.handleMethodCall(call, result, this)
            }

        // 注册阅读器按键通道（[M5] 音量键翻页：捕获开启时 onKeyDown
        // 拦截音量键通知 Dart 翻页并消费，不调系统音量；对齐原版
        // ReadMangaActivity.onKeyDown L894-902）
        val readerKeysChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, ReaderKeysBridge.CHANNEL
        )
        readerKeysBridge.setMethodChannel(readerKeysChannel)
        readerKeysChannel.setMethodCallHandler { call, result ->
            readerKeysBridge.handleMethodCall(call, result)
        }

        // 注册 Cookie 通道（WebView 登录页读取系统 CookieManager，对齐
        // 原版 WebViewLoginFragment 的 CookieManager.getCookie 链路）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_COOKIE)
            .setMethodCallHandler { call, result ->
                cookieBridge.handleMethodCall(call, result, this)
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
                // P1-4：冷启动外部书籍文件 URI 拉取
                "getInitialFileUri" -> result.success(initialFileUri)
                // 批25：冷启动分享文本拉取（取后清空，避免热重启重复消费）
                // 批25b P2-2：清空与一次性消费标记（hash + 时间）同步落盘，
                // 进程被杀后从最近任务恢复时不再重复投递同一 SEND 文本
                "getInitialSharedText" -> {
                    // 该调用同时标志 Dart 处理器已注册（见 dartSharedHandlerReady）
                    dartSharedHandlerReady = true
                    val text = initialSharedText
                    initialSharedText = null
                    if (!text.isNullOrEmpty()) {
                        markSharedTextConsumed(text)
                        rememberRecentSharedText(text)
                    }
                    result.success(text)
                }
                // P1-4：content:// / file:// 经 ContentResolver 拷入应用
                // 私有持久目录（files/external_import），返回落盘路径供导入链
                "copyContentUri" -> handleCopyContentUri(call, result)
                else -> result.notImplemented()
            }
        }

        // P1-5：创建堆转储（对齐原版 AboutFragment.createHeapDump →
        // CrashHandler.doHeapDump：Debug.dumpHprofData 落应用缓存目录，
        // 每次清空 heapDump 目录重建、文件名 heap-dump-manually-<时间戳>.hprof）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_HEAP_DUMP)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dump" -> handleHeapDump(result)
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

        // 设备 ID 通道：返回 Settings.Secure.ANDROID_ID（书山聚合等源
        // 登录登记设备 + 正文 X-Device-Id 校验；对齐原版 AppConst.androidId）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_DEVICE_ID)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidId" -> {
                        @Suppress("DEPRECATION")
                        val id = android.provider.Settings.Secure.getString(
                            contentResolver,
                            android.provider.Settings.Secure.ANDROID_ID
                        )
                        result.success(id ?: "")
                    }
                    else -> result.notImplemented()
                }
            }

        // 更换桌面启动图标（对齐原版 LauncherIconHelp.changeIcon）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_LAUNCHER_ICON)
            .setMethodCallHandler { call, result ->
                LauncherIconBridge.handleMethodCall(call, result, this)
            }

        // [V-B3] 视频悬浮窗通道（原生服务承载 overlay + Media3 ExoPlayer；
        // 回全屏经 MainActivity Intent → onReturnToFullscreen）
        videoFloatBridge.register(flutterEngine, this)

        // 批9b-6：Web 服务唤醒锁通道（偏好开 + 服务运行 → PARTIAL_WAKE_LOCK +
        // Wi-Fi 锁，tag "legado:WebService" 与原版一致）。桥为进程级单例，
        // Activity/引擎重建不丢锁，故 onDestroy 不释放，仅由 Dart 停服/关开关释放。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WebServiceWakeLockBridge.CHANNEL,
        ).setMethodCallHandler { call, result ->
            WebServiceWakeLockBridge.handleMethodCall(call, result, this)
        }

        // 批9b-6c：Web 服务前台服务通道（锁屏/切后台维持 UID 网络可见性）。
        // 随 Web 服务启停，与唤醒锁偏好解耦（唤醒锁只影响 CPU/Wi-Fi 休眠）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WebServiceForegroundBridge.CHANNEL,
        ).setMethodCallHandler { call, result ->
            WebServiceForegroundBridge.handleMethodCall(call, result, this)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // P1-4：VIEW intent 区分深链与外部书籍文件——legado:// / yuedu://
        // 走深链（getInitialLink），content:// / file:// 走文件打开
        //（getInitialFileUri），互不串扰（DeepLinkService 分别消费）
        when (val dataString = intent?.dataString) {
            null -> {}
            else -> if (isImportSchemeUri(dataString)) {
                initialDeepLink = dataString
            } else if (intent?.action == Intent.ACTION_VIEW) {
                initialFileUri = dataString
            }
        }
        pendingAutoTaskDue =
            intent?.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_DUE, false) == true
        pendingAutoTaskMinimize =
            intent?.getBooleanExtra(AutoTaskJobBridge.EXTRA_AUTO_TASK_MINIMIZE, false) == true
        // 批25：ACTION_SEND / ACTION_PROCESS_TEXT 冷启动暂存（Dart 首帧后拉取）
        // 批25b P2-2：仅在「全新创建」时提取。进程被杀后从最近任务恢复时，
        // 系统会重放同一 SEND/PROCESS_TEXT intent（savedInstanceState != null，
        // 且通常带 FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY），无条件提取会导致
        // 每次恢复都重复弹出导入确认框；已由 Dart 消费过的同一文本再用
        // 持久化 hash + 时间窗口兜底一次（不提供 savedInstanceState 的机型）。
        if (savedInstanceState == null && !isLaunchedFromHistory(intent)) {
            val sharedText = extractSharedText(intent)
            if (!sharedText.isNullOrEmpty()) {
                rememberRecentSharedText(sharedText)
                if (!isSharedTextRecentlyConsumed(sharedText)) {
                    initialSharedText = sharedText
                }
            }
        }
        // [V-B3] 冷启动：悬浮窗「全屏」拉起 MainActivity 时携带播放状态
        videoFloatBridge.setPendingReturn(intent)
        applySystemBarFromState()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // 批25：应用已存活时接收 ACTION_SEND / ACTION_PROCESS_TEXT
        // 批25b P2-2：同一文本在短窗口内重复投递时忽略（防止同一 intent
        // 被系统重复分发导致重复弹框）；从最近任务恢复时系统重放的旧
        // intent（LAUNCHED_FROM_HISTORY）一律不当作新分享。
        // P3-5：Dart 处理器未就绪时先暂存，由 attach 后经
        // getInitialSharedText 拉取兜底。
        val sharedText =
            if (isLaunchedFromHistory(intent)) null else extractSharedText(intent)
        if (!sharedText.isNullOrEmpty() && !isRecentSharedTextDuplicate(sharedText)) {
            // 已交付（或已暂存待交付）即视为一次性消费，供跨进程恢复兜底
            markSharedTextConsumed(sharedText)
            val channel = deepLinkChannel
            if (channel != null && dartSharedHandlerReady) {
                channel.invokeMethod("onSharedText", sharedText)
            } else {
                initialSharedText = sharedText
            }
        }
        val link = intent.dataString
        if (!link.isNullOrEmpty()) {
            if (isImportSchemeUri(link)) {
                deepLinkChannel?.invokeMethod("onLink", link)
            } else if (intent.action == Intent.ACTION_VIEW) {
                // P1-4：外部书籍文件（文件管理器「用阅读打开」热路径）
                deepLinkChannel?.invokeMethod("onFileUri", link)
            }
        }
        // [V-B3] 悬浮窗「全屏」/通知点击回到已存活 Activity
        videoFloatBridge.deliverReturn(intent)
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

    /** P1-4：是否 legado:// / yuedu:// 关联导入协议（与 Dart LegadoDeepLink.isImportScheme 同判） */
    private fun isImportSchemeUri(uri: String): Boolean {
        val lower = uri.trim().lowercase()
        return lower.startsWith("legado://") || lower.startsWith("yuedu://")
    }

    /**
     * 批25：提取 ACTION_SEND / ACTION_PROCESS_TEXT 的 text/plain 文本。
     *
     * 对齐原版 SharedReceiverActivity：仅接收 `text/plain`（不接收 text 通配），
     * PROCESS_TEXT 仅 API 23+ 存在。EXTRA_TEXT 可能是 CharSequence（如
     * Spanned），统一 toString。
     */
    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        return when {
            intent.action == Intent.ACTION_SEND && intent.type == "text/plain" ->
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                intent.action == Intent.ACTION_PROCESS_TEXT &&
                intent.type == "text/plain" ->
                intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
            else -> null
        }?.takeIf { it.isNotBlank() }
    }

    /**
     * 批25b P2-2：intent 是否来自「最近任务/历史」恢复。
     *
     * 系统从历史记录重放任务时会给 intent 打
     * [Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY]；此类 intent 里的
     * SEND/PROCESS_TEXT 文本是上次的旧内容，不得再次作为新分享消费。
     */
    private fun isLaunchedFromHistory(intent: Intent?): Boolean {
        return intent != null &&
            SharedTextOnceGate.isHistoryLaunch(intent.flags)
    }

    /** 批25b P2-2：记录进程级 one-shot holder（最近一次提取/投递的文本） */
    private fun rememberRecentSharedText(text: String) {
        recentSharedText = text
        recentSharedTextAt = System.currentTimeMillis()
    }

    /** 批25b P2-2：热路径短窗口去重；返回 true 表示重复投递 */
    private fun isRecentSharedTextDuplicate(text: String): Boolean {
        val duplicate = SharedTextOnceGate.isDuplicate(
            text = text,
            recentText = recentSharedText,
            recentAt = recentSharedTextAt,
            now = System.currentTimeMillis(),
        )
        if (!duplicate) rememberRecentSharedText(text)
        return duplicate
    }

    /**
     * 批25b P2-2：该文本是否已在防重窗口内被 Dart 消费。
     *
     * 用于兜底「系统未提供 savedInstanceState 却重放同一 SEND intent」的
     * 机型；正常恢复路径由 onCreate 的 savedInstanceState 判定拦截。
     */
    private fun isSharedTextRecentlyConsumed(text: String): Boolean {
        val prefs = getSharedPreferences(PREFS_SHARED_TEXT_ONCE, MODE_PRIVATE)
        return SharedTextOnceGate.isRecentlyConsumed(
            text = text,
            storedHash = prefs.getString(KEY_CONSUMED_HASH, null),
            consumedAt = prefs.getLong(KEY_CONSUMED_AT, 0L),
            now = System.currentTimeMillis(),
        )
    }

    /** 批25b P2-2：记录一次性消费（hash + 时间）；与 initialSharedText 清空同步 */
    private fun markSharedTextConsumed(text: String) {
        // 用 commit 同步落盘：标记的目的就是扛进程被杀，apply 的异步写盘
        // 在随即 SIGKILL 时可能丢失（单个小键值写入，主线程开销可忽略）
        getSharedPreferences(PREFS_SHARED_TEXT_ONCE, MODE_PRIVATE)
            .edit()
            .putString(KEY_CONSUMED_HASH, SharedTextOnceGate.fingerprint(text))
            .putLong(KEY_CONSUMED_AT, System.currentTimeMillis())
            .commit()
    }

    /**
     * P1-5：创建堆转储（对齐原版 CrashHandler.doHeapDump(manually=true)）。
     *
     * 落点 externalCacheDir/heapDump（原版 appCtx.externalCache/heapDump），
     * 每次清空目录重建（对齐 createFolderReplace）；dumpHprofData 为阻塞 IO，
     * 放后台线程，结果回主线程。
     */
    private fun handleHeapDump(result: MethodChannel.Result) {
        Thread {
            var failure: Pair<String, String>? = null
            var dumpPath: String? = null
            try {
                val heapDir = File(externalCacheDir ?: cacheDir, "heapDump")
                heapDir.deleteRecursively()
                heapDir.mkdirs()
                val heapFile = File(heapDir, "heap-dump-manually-${System.currentTimeMillis()}.hprof")
                android.os.Debug.dumpHprofData(heapFile.absolutePath)
                dumpPath = heapFile.absolutePath
            } catch (e: Throwable) {
                failure = "EDUMP" to (e.message ?: e.javaClass.simpleName)
            }
            val finalPath = dumpPath
            val finalFailure = failure
            runOnUiThread {
                if (finalFailure != null) {
                    result.error(finalFailure.first, finalFailure.second, null)
                } else {
                    result.success(finalPath)
                }
            }
        }.start()
    }

    /**
     * P1-4 / P2-6：把 content:// / file:// 外部文件拷入应用私有目录。
     *
     * 拷贝在后台线程执行（MethodChannel.Result 须回主线程）。目标目录由
     * `persistent` 参数决定：
     * - true（书籍文件）→ filesDir/external_import：导入链以该路径作为
     *   bookUrl 落库，系统清缓存不应使已导入书籍断链；
     * - false（JSON/压缩包/不支持等一次性导入）→ cacheDir/external_import，
     *   Dart 分支用后删除。
     * 同名文件覆盖（重复打开同一文件时刷新内容，对齐原版
     * FileAssociationActivity lastModified 比较后覆盖写入的语义）。
     */
    private fun handleCopyContentUri(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        if (uriStr.isNullOrEmpty()) {
            result.error("EINVAL", "uri 参数缺失", null)
            return
        }
        val persistent = call.argument<Boolean>("persistent") ?: true
        Thread {
            var failure: Pair<String, String>? = null
            var copiedPath: String? = null
            try {
                val uri = Uri.parse(uriStr)
                val fileName = queryContentFileName(uri)
                    ?: "external-book-${System.currentTimeMillis()}"
                // 文件名净化：拦截路径分隔与非法字符
                val safeName = fileName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
                val baseDir = if (persistent) filesDir else cacheDir
                val dir = File(baseDir, "external_import").apply { mkdirs() }
                val dest = File(dir, safeName)
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(dest).use { output ->
                        input.copyTo(output)
                        output.flush()
                    }
                } ?: throw IllegalStateException("无法读取所选文件")
                copiedPath = dest.absolutePath
            } catch (e: Exception) {
                failure = "ECOPY" to (e.message ?: e.javaClass.simpleName)
            }
            val finalPath = copiedPath
            val finalFailure = failure
            runOnUiThread {
                if (finalFailure != null) {
                    result.error(finalFailure.first, finalFailure.second, null)
                } else {
                    result.success(finalPath)
                }
            }
        }.start()
    }

    /** P1-4：查询 content URI 显示文件名（OpenableColumns；file:// 取路径段） */
    private fun queryContentFileName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.path?.let { File(it).name }?.takeIf { it.isNotBlank() }
        }
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor: Cursor ->
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
                }?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        // 从其他 Activity 返回时复用 Dart 侧最近一次配置
        applySystemBarFromState()
    }


    /** Dart MethodChannel 在部分 API 上传 32 位 ARGB 为 Long，避免 argument<Int> ClassCastException。 */
    private fun intArgFromCall(call: MethodCall, key: String): Int? {
        return when (val raw = call.argument<Any>(key)) {
            is Int -> raw
            is Long -> raw.toInt()
            is Number -> raw.toInt()
            else -> null
        }
    }

    private fun handleSystemBarCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "apply" -> {
                systemBarTransparent =
                    call.argument<Boolean>("transparentStatusBar") ?: true
                systemBarImmNav =
                    call.argument<Boolean>("immNavigationBar") ?: true
                // MethodChannel 可能将 32 位 ARGB 以 Long 传递，勿直接 argument<Int>
                intArgFromCall(call, "statusBarColor")?.let {
                    systemBarStatusColor = it
                }
                intArgFromCall(call, "navigationBarColor")?.let {
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
        // [D1 防御] 第三方插件（如 file_picker 8.3.7）在 onActivityResult 内
        // 直接写 SAF URI，MuMu Android 15 的 DownloadStorageProvider 会抛
        // SecurityException 且插件未捕获 → 异常穿透到 ActivityThread 直接
        // FATAL（进程强杀）。正常另存链路已改走 SaveFileBridge（异常全部
        // 捕获），此处再兜一层，确保任何插件的回调异常都不会杀死进程。
        try {
            super.onActivityResult(requestCode, resultCode, data)
        } catch (e: Throwable) {
            android.util.Log.e(
                "MainActivity",
                "onActivityResult 插件异常已拦截（D1 防御）：${e.message}",
                e
            )
        }
        filePickerBridge.onActivityResult(requestCode, resultCode, data)
        saveFileBridge.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * [M5] 音量键翻页：漫画阅读器活跃且捕获开启时消费音量键并通知
     * Dart 翻页（对齐原版 ReadMangaActivity.onKeyDown L894-902）；
     * 其余情况交还系统（全局音量键行为不变）。
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (readerKeysBridge.handleKeyDown(keyCode)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        super.onDestroy()
        ttsBridge.release()
        webViewBridge.destroy()
        mediaSessionBridge.release()
        videoFloatBridge.dispose()
        // [D1] 释放未完成的另存请求，避免 Dart Future 永久挂起
        saveFileBridge.dispose()
    }
}
