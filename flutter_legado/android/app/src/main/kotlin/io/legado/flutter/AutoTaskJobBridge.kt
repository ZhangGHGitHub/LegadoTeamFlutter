package io.legado.flutter

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 定时任务真后台调度（对齐原版 AutoTaskScheduler + AutoTaskJobService）。
 *
 * - 使用 Android [JobScheduler] + [setPersisted]，进程被杀后仍可唤醒。
 * - Job 到期时经 MethodChannel 回调 Flutter，由 Dart 侧执行 due 规则（复用 FFI）。
 * - Flutter 前台 Timer 仍保留作补充；本桥负责「真后台」槽位。
 *
 * 冷启动策略（F2）：
 * 1. 已有 MethodChannel → 直接 onJobDue（无 UI）
 * 2. 尝试缓存/无头 FlutterEngine 执行（尽量不弹 Activity）
 * 3. 仍失败才拉起 MainActivity（NO_ANIMATION + 尽快移到后台）
 */
object AutoTaskJobBridge {
    private const val TAG = "AutoTaskJob"
    const val CHANNEL = "legado/auto_task_job"
    const val ENGINE_CACHE_ID = "legado_auto_task_engine"
    const val JOB_ID_FIRST = 0x41555401
    const val JOB_ID_SECOND = 0x41555402
    private const val RETRY_BACKOFF_MS = 60_000L

    @Volatile
    private var methodChannel: MethodChannel? = null

    fun setMethodChannel(channel: MethodChannel?) {
        methodChannel = channel
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "schedule" -> {
                val delayMs = (call.argument<Number>("delayMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                val ok = schedule(context, delayMs)
                result.success(ok)
            }
            "cancelAll" -> {
                cancelAll(context)
                result.success(null)
            }
            "isSupported" -> result.success(true)
            else -> result.notImplemented()
        }
    }

    fun schedule(context: Context, delayMs: Long): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return false
        cancelPending(scheduler)
        val info = JobInfo.Builder(
            JOB_ID_FIRST,
            ComponentName(context, AutoTaskJobService::class.java)
        )
            .setMinimumLatency(delayMs)
            .setBackoffCriteria(RETRY_BACKOFF_MS, JobInfo.BACKOFF_POLICY_LINEAR)
            .setPersisted(true)
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setImportantWhileForeground(true)
                }
            }
            .build()
        return try {
            scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
        } catch (e: RuntimeException) {
            Log.e(TAG, "schedule failed", e)
            false
        }
    }

    fun cancelAll(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        scheduler.cancel(JOB_ID_FIRST)
        scheduler.cancel(JOB_ID_SECOND)
    }

    private fun cancelPending(scheduler: JobScheduler) {
        scheduler.cancel(JOB_ID_FIRST)
        scheduler.cancel(JOB_ID_SECOND)
    }

    /**
     * JobService 到期通知。
     * @return true 已投递到 Flutter；false 需 JobService 自行收尾（已排队拉起 Activity）
     */
    fun notifyJobDue(context: Context): Boolean {
        val ch = methodChannel
        if (ch != null) {
            try {
                Handler(Looper.getMainLooper()).post {
                    try {
                        ch.invokeMethod("onJobDue", null)
                    } catch (e: Exception) {
                        Log.e(TAG, "onJobDue invoke failed", e)
                    }
                }
                return true
            } catch (e: Exception) {
                Log.e(TAG, "onJobDue post failed", e)
            }
        }

        // 尝试无头引擎（不弹 UI）
        if (tryHeadlessNotify(context)) {
            return true
        }

        Log.w(TAG, "Flutter channel not ready; launching MainActivity for due tasks (minimized)")
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION
                )
                putExtra(EXTRA_AUTO_TASK_DUE, true)
                putExtra(EXTRA_AUTO_TASK_MINIMIZE, true)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "launch MainActivity failed", e)
        }
        return false
    }

    /** 缓存或新建无头 FlutterEngine，注册通道后触发 onJobDue */
    private fun tryHeadlessNotify(context: Context): Boolean {
        return try {
            val app = context.applicationContext
            var engine = FlutterEngineCache.getInstance().get(ENGINE_CACHE_ID)
            if (engine == null) {
                engine = FlutterEngine(app)
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault()
                )
                FlutterEngineCache.getInstance().put(ENGINE_CACHE_ID, engine)
            }
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            // 无头引擎侧 Dart 需自行监听；同时保留桥接引用供后续 Job 复用
            methodChannel = channel
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    channel.invokeMethod("onJobDue", null)
                } catch (e: Exception) {
                    Log.e(TAG, "headless onJobDue failed", e)
                }
            }, 800)
            true
        } catch (e: Exception) {
            Log.w(TAG, "headless engine unavailable: ${e.message}")
            false
        }
    }

    const val EXTRA_AUTO_TASK_DUE = "auto_task_due"
    const val EXTRA_AUTO_TASK_MINIMIZE = "auto_task_minimize"
}

class AutoTaskJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        AutoTaskJobBridge.notifyJobDue(this)
        // 无头/通道投递均为异步；短暂保留 Job 后结束
        Handler(Looper.getMainLooper()).postDelayed({
            jobFinished(params, false)
        }, 1500)
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean = true
}
