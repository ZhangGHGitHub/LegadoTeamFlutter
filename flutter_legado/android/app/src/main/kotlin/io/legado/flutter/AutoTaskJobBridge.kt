package io.legado.flutter

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 定时任务真后台调度（对齐原版 AutoTaskScheduler + AutoTaskJobService）。
 *
 * - 使用 Android [JobScheduler] + [setPersisted]，进程被杀后仍可唤醒。
 * - Job 到期时经 MethodChannel 回调 Flutter，由 Dart 侧执行 due 规则（复用 FFI）。
 * - Flutter 前台 Timer 仍保留作补充；本桥负责「真后台」槽位。
 */
object AutoTaskJobBridge {
    private const val TAG = "AutoTaskJob"
    const val CHANNEL = "legado/auto_task_job"
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

    /** JobService 到期：通知 Flutter；通道未就绪则拉起 MainActivity */
    fun notifyJobDue(context: Context) {
        val ch = methodChannel
        if (ch != null) {
            try {
                ch.invokeMethod("onJobDue", null)
                return
            } catch (e: Exception) {
                Log.e(TAG, "onJobDue invoke failed", e)
            }
        }
        Log.w(TAG, "Flutter channel not ready; launching MainActivity for due tasks")
        try {
            val intent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_AUTO_TASK_DUE, true)
            }
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "launch MainActivity failed", e)
        }
    }

    const val EXTRA_AUTO_TASK_DUE = "auto_task_due"
}

class AutoTaskJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        AutoTaskJobBridge.notifyJobDue(this)
        jobFinished(params, false)
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = true
}
