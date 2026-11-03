package io.legado.flutter

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/**
 * 耳机媒体键桥（批9b-5）
 *
 * ## 职责
 * 静态 [MediaButtonReceiver] 收到 `ACTION_MEDIA_BUTTON` 后，把 KeyEvent 经
 * MethodChannel `legado/headset_media_button` 转发给 Flutter Dart 侧
 * （`HeadsetMediaButtonService`）。渠道建立前（进程刚起、Flutter 引擎尚未
 * 配置）或引擎已销毁时**安全消费并日志**，绝不崩溃。
 *
 * ## 事件契约（Android → Flutter）
 * - method: `onMediaButton`
 * - arguments: `{keyCode: Int, action: Int, repeat: Int}`
 *   `action` 为 `KeyEvent.ACTION_DOWN`（0）/`ACTION_UP`（1），
 *   `repeat` 为长按重复次数。
 *
 * ## 就绪握手（Flutter → Android）
 * Dart 在注册 `setMethodCallHandler` 后调用 `ready`，桥随后清空积压事件。
 * 启动窗口内的事件最多缓存 [MAX_PENDING] 条（丢最旧），避免「引擎已配置
 * 但 Dart 尚未注册处理器」窗口内按键被静默丢弃。
 *
 * ## 与 MediaSession 的关系
 * 会话可控（活跃且播放状态为 PLAYING/PAUSED/BUFFERING/CONNECTING）时按键
 * 优先由 `MediaSessionBridge` 的 Callback 处理（[MediaButtonReceiver] 检测到
 * `MediaSessionBridge.hasControllableSession()` 即不转发），从结构上避免同一
 * 按键被会话与静态接收器双处理；会话活跃但已 stopped 时仍转发到本桥
 * （批9b-5 P2-2，避免陈旧会话吞键）。
 *
 * — 全栈工程师 ｜ 2026-11-04
 */
object HeadsetMediaButtonBridge {

    const val CHANNEL = "legado/headset_media_button"

    private const val TAG = "HeadsetMediaButton"

    /** 引擎未就绪时的最大积压条数（超出丢最旧） */
    internal const val MAX_PENDING = 8

    /** 可注入日志（JVM 单测替换为 no-op，Android Log 在纯 JVM 下不可用） */
    internal var logger: (String) -> Unit = { message -> Log.d(TAG, message) }

    private var channel: MethodChannel? = null
    private var handlerReady = false
    private val pending = ArrayDeque<Map<String, Any>>()

    /**
     * 绑定 Flutter 引擎的通道（`MainActivity.configureFlutterEngine`）。
     *
     * 新引擎一律从「未就绪」开始：旧引擎的 ready 握手不能复用。
     */
    @Synchronized
    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
        handlerReady = false
        pending.clear()
    }

    /** 引擎销毁（`cleanUpFlutterEngine`）：解除绑定并丢弃积压，避免投递到死通道 */
    @Synchronized
    fun detach() {
        channel = null
        handlerReady = false
        pending.clear()
    }

    /** 构造 Dart 侧事件负载（纯函数，供 JVM 单测钉住参数形状） */
    fun payload(keyCode: Int, action: Int, repeatCount: Int): Map<String, Any> =
        mapOf(
            "keyCode" to keyCode,
            "action" to action,
            "repeat" to repeatCount,
        )

    /**
     * 投递一次媒体键事件。
     *
     * @return true=已发送或已入队；false=无引擎（已日志，放弃消费）
     */
    @Synchronized
    fun deliver(keyCode: Int, action: Int, repeatCount: Int): Boolean {
        val event = payload(keyCode, action, repeatCount)
        val current = channel
        if (current == null) {
            logger("收到耳机键但 Flutter 引擎未就绪，忽略（keyCode=$keyCode）")
            return false
        }
        if (!handlerReady) {
            if (pending.size >= MAX_PENDING) {
                pending.removeFirst()
            }
            pending.addLast(event)
            logger("Dart 处理器未就绪，缓存耳机键（keyCode=$keyCode，pending=${pending.size}）")
            return true
        }
        return invoke(current, event)
    }

    /** 处理 Dart 侧调用（当前仅 ready 握手） */
    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                val flushed = markReadyAndFlush()
                result.success(flushed)
            }
            else -> result.notImplemented()
        }
    }

    /** Dart 处理器就绪：标记并投递积压事件，返回投递条数 */
    @Synchronized
    private fun markReadyAndFlush(): Int {
        handlerReady = true
        val current = channel ?: return 0
        var count = 0
        while (pending.isNotEmpty()) {
            if (!invoke(current, pending.removeFirst())) break
            count++
        }
        return count
    }

    private fun invoke(methodChannel: MethodChannel, event: Map<String, Any>): Boolean {
        return try {
            methodChannel.invokeMethod("onMediaButton", event)
            true
        } catch (e: Exception) {
            logger("转发耳机键失败（忽略）：${e.message}")
            false
        }
    }

    /** 当前是否有已绑定的引擎通道（诊断/单测用） */
    @Synchronized
    internal fun hasChannel(): Boolean = channel != null

    /** 当前积压条数（单测用） */
    @Synchronized
    internal fun pendingCount(): Int = pending.size
}
