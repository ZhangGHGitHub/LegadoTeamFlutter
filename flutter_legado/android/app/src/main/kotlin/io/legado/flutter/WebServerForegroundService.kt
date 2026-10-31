package io.legado.flutter

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Web 服务前台服务（批9b-6c）—— 锁屏/切后台时保持局域网可访问
 *
 * ## 为什么需要（9b-6 设备验收 FAIL 结论）
 * 唤醒锁只影响 CPU/屏幕休眠，**不能改变网络策略**：息屏后应用 UID 落入
 * `APP_BACKGROUND`（`netpolicy` 实测），宿主 curl 全部超时。Android 原版靠
 * `WebService` 前台服务把进程提升为可见前台，从而维持网络可用性。
 *
 * ## 语义基准（原版 `app/src/main/java/io/legado/app/service/WebService.kt`）
 * - `:50-57` `start` / `startForeground`：后者经 `startForegroundServiceCompat`
 *   拉起服务；
 * - `:101-132` `onCreate` 建立通知地址列表；
 * - `:135-152` `onStartCommand` 处理 stop / serve / 默认（启动 server）；
 * - `:154-169` `onDestroy` 释放唤醒锁、停 server；
 * - `:254-257` `startForegroundNotification` → `startForeground(id, notif)`；
 * - `:259-295` 通知：`setOngoing(true)`、公开可见、点击复制地址（原版交互）；
 * - `BaseService.kt:67-71` `onTaskRemoved` → `stopSelf()`（最近任务划掉即停）；
 * - manifest `:554-556` 声明 `foregroundServiceType="dataSync"`。
 * 参考版 `legado-with-MD3/.../service/WebService.kt:52-55,89-94` 与
 * `legado-with-MD3/app/src/main/AndroidManifest.xml:408-410` 同构（同为 dataSync）。
 *
 * ## 与本仓库架构的差异（如实登记）
 * 原版把 HTTP/WebSocket server 直接跑在 Service 内，Service 即 server 宿主；
 * 本仓库 server 是 Flutter 进程内的 Rust 服务（Dart 经 FFI 启停），Service
 * 只负责把进程提升为前台，**不承载 server 生命周期**。由此：
 * - 返回 `START_NOT_STICKY`：进程被杀后系统重拉本服务只会得到一条「运行中」
 *   的假通知（Rust server 并不存在），与真实状态冲突；原版的 START_STICKY
 *   在其架构下成立，这里不适用；
 * - 通知点击打开 App（任务给出），不提供原版「点击复制地址」「停止按钮」：
 *   本服务的停止权在 Dart（Web 服务开关），通知单独停服会造成「通知消失但
 *   server 仍在跑」的可见状态不一致；
 * - 前台服务类型用 `specialUse`（任务指定）而非原版 `dataSync`：Android 15
 *   对 dataSync 有累计 6 小时超时，而本地 LAN 服务需要长期驻留，
 *   `specialUse` + `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 是更贴切的声明。
 *
 * ## 生命周期
 * - Dart `start` → [start]（`ContextCompat.startForegroundService`）→
 *   `onCreate` 建渠道 + `startForeground`；
 * - Dart `stop` → [stop]（`stopService`）→ `onDestroy` 移出前台并清理通知；
 * - 通知权限未授予（Android 13+）不阻断、不请求：FGS 仍生效，通知仅出现在
 *   系统任务管理器（记录降级日志），绝不因权限崩溃。
 *
 * — 全栈工程师 ｜ 2026-11-01
 */
class WebServerForegroundService : Service() {

    companion object {
        /** 启动动作（内容与 `WebServiceForegroundBridge.CHANNEL` 分属两层，勿混用） */
        const val ACTION_START = "io.legado.flutter.action.WEB_SERVER_START"

        /** 停止动作（桥直接 stopService；保留该 action 供系统/测试显式停止） */
        const val ACTION_STOP = "io.legado.flutter.action.WEB_SERVER_STOP"

        /** 通知渠道：低重要性、不响铃、不震动（对齐原版常驻静默通知） */
        const val CHANNEL_ID = "legado_web_server"

        /** 通知标题/正文（任务指定文案，原版对应 R.string.web_service_live_started） */
        const val NOTIFICATION_TITLE = "Web 服务运行中"
        const val NOTIFICATION_TEXT = "局域网可访问"

        /** 通知 id（避开听书 0x1E60 与旧通知服务 1001-1003） */
        const val NOTIFICATION_ID = 0x1E61

        private const val TAG = "WebServerFgs"

        /** 通知点击 PendingIntent 请求码（同域内唯一即可） */
        private const val REQUEST_CODE_OPEN_APP = 0x1E61

        /**
         * 服务进程内运行标志（`isRunning` 通道与 Dart 初始化对账使用）。
         *
         * 只反映**本进程内**的服务实例：系统重拉会重新走 `onCreate`；进程被
         * 回收后静态值随进程消失，Dart 新引擎查询得到 false 属预期。
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** 拉起前台服务：Android 12+ 后台启动限制由调用方（UI 前台交互）规避 */
        fun start(context: Context) {
            val intent = Intent(context, WebServerForegroundService::class.java)
                .setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        /** 停止前台服务（幂等：未运行时为 no-op） */
        fun stop(context: Context) {
            context.stopService(Intent(context, WebServerForegroundService::class.java))
        }
    }

    /** 通知权限降级日志只记一次，避免重复拉起刷屏 */
    private var notificationDegradationLogged = false

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        if (!startForegroundCompat()) {
            // 前台化失败（类型/权限/后台限制）：不得留下无前台服务的进程占用
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> if (!startForegroundCompat()) {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * 最近任务划掉即停（对齐原版 `BaseService.kt:67-71`）。
     *
     * 进程内 Rust server 与宿主进程同生命周期，任务移除后即使保留前台服务
     * 也无法继续提供 LAN 访问；停掉可避免「通知在、服务已死」的假象。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        stopSelf()
    }

    override fun onDestroy() {
        isRunning = false
        // 移出前台并移除通知（低版本经 ServiceCompat 走 stopForeground(true)）
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /** 建渠道：低重要性 + 无声音/震动（用户可在系统设置中调整） */
    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Web 服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "局域网 Web 服务运行通知（锁屏/后台保持可访问）"
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * 启动前台（Android 14+ 显式携带 `specialUse` 类型；低版本 2 参兼容）。
     *
     * 任何异常（后台启动限制 / 类型未声明 / 权限缺失）都收敛为 false，
     * 由调用方 stopSelf，绝不让服务异常上抛到主线程崩溃。
     */
    private fun startForegroundCompat(): Boolean {
        return try {
            logIfNotificationsDegraded()
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            isRunning = true
            true
        } catch (e: Exception) {
            Log.w(TAG, "启动 Web 服务前台通知失败（降级为无前台服务）：${e.message}", e)
            false
        }
    }

    /** Android 13+ 未授予 POST_NOTIFICATIONS：仅记录降级，不请求、不阻断 */
    private fun logIfNotificationsDegraded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (notificationDegradationLogged) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            notificationDegradationLogged = true
            Log.w(
                TAG,
                "POST_NOTIFICATIONS 未授予：前台服务继续运行，通知仅见系统任务管理器（降级）",
            )
        }
    }

    /** 常驻通知：点击打开 App（当前启用的启动图标 activity），不响铃 */
    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(NOTIFICATION_TITLE)
            .setContentText(NOTIFICATION_TEXT)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
        packageManager.getLaunchIntentForPackage(packageName)?.let { launchIntent ->
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    REQUEST_CODE_OPEN_APP,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        }
        return builder.build()
    }
}
