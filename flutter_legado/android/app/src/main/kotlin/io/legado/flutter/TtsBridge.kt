package io.legado.flutter

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * TTS 桥接 — Flutter → Android TextToSpeech
 *
 * 支持方法：
 * - init: 初始化 TTS 引擎
 * - speak: 朗读文本
 * - stop: 停止朗读
 * - setLanguage: 设置朗读语言
 * - setSpeed: 设置语速
 * - setPitch: 设置音调
 * - isSpeaking: 查询是否正在朗读
 */
class TtsBridge : TextToSpeech.OnInitListener {

    private var tts: TextToSpeech? = null
    private var initialized = false
    private var initResult: MethodChannel.Result? = null
    private val utteranceIdCounter = AtomicLong(0L)

    // 朗读事件回调（通过 EventChannel 或 result 返回）
    private var speakResult: MethodChannel.Result? = null

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        when (call.method) {
            "init" -> initTts(context, result)
            "speak" -> {
                val text = call.argument<String>("text")
                    ?: return result.error("ARG_ERROR", "text is required", null)
                speak(text, result)
            }
            "stop" -> {
                tts?.stop()
                result.success(null)
            }
            "setLanguage" -> {
                val lang = call.argument<String>("language") ?: "zh-CN"
                setLanguage(lang, result)
            }
            "setSpeed" -> {
                val speed = call.argument<Float>("speed") ?: 1.0f
                tts?.setSpeechRate(speed)
                result.success(null)
            }
            "setPitch" -> {
                val pitch = call.argument<Float>("pitch") ?: 1.0f
                tts?.setPitch(pitch)
                result.success(null)
            }
            "isSpeaking" -> {
                result.success(tts?.isSpeaking ?: false)
            }
            else -> result.notImplemented()
        }
    }

    override fun onInit(status: Int) {
        initialized = (status == TextToSpeech.SUCCESS)
        if (initialized) {
            // 设置默认语言为中文
            tts?.language = Locale.CHINESE

            // 注册朗读进度监听器
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    // 朗读开始
                }

                @Deprecated("Deprecated in API 21")
                override fun onError(utteranceId: String?) {
                    speakResult?.error("TTS_ERROR", "Speech synthesis error", null)
                    speakResult = null
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    super.onError(utteranceId, errorCode)
                    speakResult?.error("TTS_ERROR", "Speech error code: $errorCode", null)
                    speakResult = null
                }

                override fun onDone(utteranceId: String?) {
                    speakResult?.success(true)
                    speakResult = null
                }

                override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) {
                    super.onRangeStart(utteranceId, start, end, frame)
                }
            })
        }
        initResult?.success(initialized)
        initResult = null
    }

    private fun initTts(context: Context, result: MethodChannel.Result) {
        if (tts != null) {
            // 已经初始化过
            result.success(initialized)
            return
        }
        initResult = result
        tts = TextToSpeech(context.applicationContext, this)
    }

    private fun speak(text: String, result: MethodChannel.Result) {
        if (!initialized || tts == null) {
            result.error("NOT_INITIALIZED", "TTS engine not initialized", null)
            return
        }

        // 停止当前朗读
        tts?.stop()

        speakResult = result
        val utteranceId = "legado_tts_${utteranceIdCounter.incrementAndGet()}"

        val params = Bundle().apply {
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, utteranceId)
        }

        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, utteranceId)
    }

    private fun setLanguage(langTag: String, result: MethodChannel.Result) {
        if (!initialized || tts == null) {
            result.error("NOT_INITIALIZED", "TTS engine not initialized", null)
            return
        }

        val locale = Locale.forLanguageTag(langTag)
        val availability = tts?.isLanguageAvailable(locale)

        when (availability) {
            TextToSpeech.LANG_AVAILABLE,
            TextToSpeech.LANG_COUNTRY_AVAILABLE,
            TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE -> {
                tts?.language = locale
                result.success(true)
            }
            TextToSpeech.LANG_MISSING_DATA -> {
                result.error("LANG_MISSING", "Language data missing for: $langTag", null)
            }
            TextToSpeech.LANG_NOT_SUPPORTED -> {
                result.error("LANG_NOT_SUPPORTED", "Language not supported: $langTag", null)
            }
            else -> {
                result.error("LANG_ERROR", "Unknown language error for: $langTag", null)
            }
        }
    }

    fun release() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        initialized = false
        speakResult = null
        initResult = null
    }
}
