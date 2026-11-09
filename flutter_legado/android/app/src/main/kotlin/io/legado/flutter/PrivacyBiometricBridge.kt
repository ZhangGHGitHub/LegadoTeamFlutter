package io.legado.flutter

import android.app.Activity
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 生物识别快捷解锁桥（契约 §2.53 批9d）
 *
 * 安全模型：平台只负责认证并加/解密 **32B 随机令牌**（Dart 生成），
 * 绝不封装密码。Rust 侧保存令牌 SHA-256 摘要与加密信封/IV；本桥只持有
 * Android Keystore 中 auth-per-use 的 AES-GCM 密钥。
 *
 * 通道协议（`legado/privacy_biometric`）：
 * - `getStatus` → `{available: Boolean, hasKey: Boolean, reason: String?}`
 * - `enable({token})` → `{envelope: String, iv: String}`（Base64）
 * - `unlock({envelope, iv})` → `String`（令牌 Base64）
 * - `deleteKey` → void
 *
 * 错误码（`result.error(code, ...)`）：unsupported / no_hardware /
 * not_enrolled / locked_out / permanently_locked_out / key_invalidated /
 * cancelled / failed，与 Dart `PrivacyBiometricErrorCode` 逐字一致。
 *
 * 密钥策略：AES/GCM/NoPadding、256 bit、`setUserAuthenticationParameters(0,
 * AUTH_BIOMETRIC_STRONG)`（每次认证授权一次）、
 * `setInvalidatedByBiometricEnrollment(true)`（新增/变更指纹即失效）。
 * API < 30 无法使用该认证参数组合，统一返回 unsupported。
 *
 * 编写：全栈工程师（批9d） ｜ 2026-11-10
 */
class PrivacyBiometricBridge {

    companion object {
        const val CHANNEL = "legado/privacy_biometric"
        private const val KEY_ALIAS = "legado_private_biometric_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val TOKEN_BYTES = 32
        private const val IV_BYTES = 12

        private const val CODE_UNSUPPORTED = "unsupported"
        private const val CODE_NO_HARDWARE = "no_hardware"
        private const val CODE_NOT_ENROLLED = "not_enrolled"
        private const val CODE_LOCKED_OUT = "locked_out"
        private const val CODE_PERMANENTLY_LOCKED_OUT = "permanently_locked_out"
        private const val CODE_KEY_INVALIDATED = "key_invalidated"
        private const val CODE_CANCELLED = "cancelled"
        private const val CODE_FAILED = "failed"
    }

    /** 同一时刻只允许一个认证会话（否则后一次会覆盖前一次回调） */
    private var pendingResult: MethodChannel.Result? = null

    /** 认证成功后要执行的操作（加密/解密 + 返回结果） */
    private var pendingAction: ((Cipher) -> Unit)? = null

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "getStatus" -> result.success(status(activity))
            "enable" -> enable(call, result, activity)
            "unlock" -> unlock(call, result, activity)
            "deleteKey" -> {
                deleteKey()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ===== 状态 =====

    private fun status(activity: Activity): Map<String, Any?> {
        val hasKey = hasKey()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return mapOf(
                "available" to false,
                "hasKey" to hasKey,
                "reason" to CODE_UNSUPPORTED
            )
        }
        val manager = activity.getSystemService(BiometricManager::class.java)
            ?: return mapOf(
                "available" to false,
                "hasKey" to hasKey,
                "reason" to CODE_UNSUPPORTED
            )
        val reason = when (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> null
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> CODE_NO_HARDWARE
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> CODE_NOT_ENROLLED
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> CODE_LOCKED_OUT
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> CODE_UNSUPPORTED
            else -> CODE_FAILED
        }
        return mapOf(
            "available" to (reason == null),
            "hasKey" to hasKey,
            "reason" to reason
        )
    }

    // ===== 开启：认证后加密令牌 =====

    private fun enable(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error(CODE_UNSUPPORTED, "系统版本过低（需 Android 11+）", null)
            return
        }
        if (isBusy()) {
            result.error(CODE_FAILED, "已有进行中的生物识别认证", null)
            return
        }
        val tokenBase64 = call.argument<String>("token")
        val tokenBytes = try {
            Base64.decode(tokenBase64 ?: "", Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            null
        }
        if (tokenBytes == null || tokenBytes.size != TOKEN_BYTES) {
            result.error(CODE_FAILED, "令牌必须为 32 字节 Base64", null)
            return
        }

        val unavailable = availabilityError(activity)
        if (unavailable != null) {
            result.error(unavailable, statusMessage(unavailable), null)
            return
        }

        val key = try {
            getOrCreateKey()
        } catch (e: Exception) {
            deleteKey()
            result.error(CODE_FAILED, "创建生物识别密钥失败：${e.message}", null)
            return
        }
        val cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key) }
        } catch (e: KeyPermanentlyInvalidatedException) {
            deleteKey()
            result.error(CODE_KEY_INVALIDATED, "生物识别密钥已失效", null)
            return
        } catch (e: Exception) {
            result.error(CODE_FAILED, "初始化加密失败：${e.message}", null)
            return
        }

        authenticate(activity, result, cipher, "开启生物快捷解锁") { authedCipher ->
            try {
                val envelope = authedCipher.doFinal(tokenBytes)
                val iv = authedCipher.iv
                if (iv == null || iv.size != IV_BYTES) {
                    result.error(CODE_FAILED, "加密 IV 长度异常", null)
                } else {
                    result.success(
                        mapOf(
                            "envelope" to Base64.encodeToString(envelope, Base64.NO_WRAP),
                            "iv" to Base64.encodeToString(iv, Base64.NO_WRAP)
                        )
                    )
                }
            } catch (e: Exception) {
                result.error(CODE_FAILED, "加密令牌失败：${e.message}", null)
            }
        }
    }

    // ===== 解锁：认证后解密信封 =====

    private fun unlock(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.error(CODE_UNSUPPORTED, "系统版本过低（需 Android 11+）", null)
            return
        }
        if (isBusy()) {
            result.error(CODE_FAILED, "已有进行中的生物识别认证", null)
            return
        }
        val envelopeBytes = decodeBase64(call.argument<String>("envelope"))
        val ivBytes = decodeBase64(call.argument<String>("iv"))
        if (envelopeBytes == null || envelopeBytes.isEmpty() || envelopeBytes.size > 4096) {
            result.error(CODE_FAILED, "信封参数非法", null)
            return
        }
        if (ivBytes == null || ivBytes.size != IV_BYTES) {
            result.error(CODE_FAILED, "IV 参数非法", null)
            return
        }

        val unavailable = availabilityError(activity)
        if (unavailable != null) {
            result.error(unavailable, statusMessage(unavailable), null)
            return
        }

        val key = try {
            loadKey()
        } catch (e: Exception) {
            null
        } ?: run {
            // 密钥不存在（卸载重装/系统清密钥）：按失效处理，Dart 会清理信封
            result.error(CODE_KEY_INVALIDATED, "生物识别密钥不存在", null)
            return
        }
        val cipher = try {
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, ivBytes))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            deleteKey()
            result.error(CODE_KEY_INVALIDATED, "生物识别密钥已失效", null)
            return
        } catch (e: Exception) {
            result.error(CODE_FAILED, "初始化解密失败：${e.message}", null)
            return
        }

        authenticate(activity, result, cipher, "使用生物识别解锁") { authedCipher ->
            try {
                val token = authedCipher.doFinal(envelopeBytes)
                if (token.size != TOKEN_BYTES) {
                    result.error(CODE_FAILED, "解封令牌长度异常", null)
                } else {
                    result.success(Base64.encodeToString(token, Base64.NO_WRAP))
                }
            } catch (e: Exception) {
                result.error(CODE_FAILED, "解封令牌失败：${e.message}", null)
            }
        }
    }

    // ===== BiometricPrompt =====

    private fun authenticate(
        activity: Activity,
        result: MethodChannel.Result,
        cipher: Cipher,
        title: String,
        onSuccess: (Cipher) -> Unit
    ) {
        pendingResult = result
        pendingAction = onSuccess

        val cancellationSignal = CancellationSignal()
        try {
            BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setNegativeButton("取消", activity.mainExecutor) { _, _ ->
                    completeError(CODE_CANCELLED, "用户取消")
                }
                .build()
                .authenticate(
                    BiometricPrompt.CryptoObject(cipher),
                    cancellationSignal,
                    activity.mainExecutor,
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(
                            authResult: BiometricPrompt.AuthenticationResult
                        ) {
                            val authed = authResult.cryptoObject?.cipher
                            if (authed == null) {
                                completeError(CODE_FAILED, "认证结果缺少 Cipher")
                            } else {
                                completeSuccess(authed)
                            }
                        }

                        override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                            completeError(mapErrorCode(errorCode), errString.toString())
                        }

                        override fun onAuthenticationFailed() {
                            // 单次指纹不匹配：提示保留，等待系统允许重试
                        }
                    }
                )
        } catch (e: Exception) {
            clearPending()
            result.error(CODE_FAILED, "启动生物识别失败：${e.message}", null)
        }
    }

    private fun completeSuccess(cipher: Cipher) {
        val action = pendingAction
        clearPending()
        action?.invoke(cipher)
    }

    private fun completeError(code: String, message: String) {
        val result = pendingResult
        clearPending()
        result?.error(code, message, null)
    }

    private fun clearPending() {
        pendingResult = null
        pendingAction = null
    }

    private fun isBusy(): Boolean = pendingResult != null

    private fun mapErrorCode(errorCode: Int): String = when (errorCode) {
        BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> CODE_CANCELLED
        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED -> CODE_CANCELLED
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT -> CODE_LOCKED_OUT
        BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> CODE_PERMANENTLY_LOCKED_OUT
        BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS -> CODE_NOT_ENROLLED
        BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT -> CODE_NO_HARDWARE
        BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE -> CODE_LOCKED_OUT
        BiometricPrompt.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> CODE_UNSUPPORTED
        else -> CODE_FAILED
    }

    private fun availabilityError(activity: Activity): String? {
        val manager = activity.getSystemService(BiometricManager::class.java) ?: return CODE_UNSUPPORTED
        return when (manager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> null
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> CODE_NO_HARDWARE
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> CODE_NOT_ENROLLED
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> CODE_LOCKED_OUT
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> CODE_UNSUPPORTED
            else -> CODE_FAILED
        }
    }

    private fun statusMessage(code: String): String = when (code) {
        CODE_UNSUPPORTED -> "当前系统不支持生物识别"
        CODE_NO_HARDWARE -> "设备不支持指纹或面容识别"
        CODE_NOT_ENROLLED -> "尚未录入指纹或面容"
        CODE_LOCKED_OUT -> "生物识别暂时锁定"
        CODE_PERMANENTLY_LOCKED_OUT -> "生物识别已被系统锁定"
        CODE_KEY_INVALIDATED -> "生物识别密钥已失效"
        CODE_CANCELLED -> "用户取消"
        else -> "生物识别失败"
    }

    // ===== Keystore =====

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun hasKey(): Boolean = try {
        keyStore().containsAlias(KEY_ALIAS)
    } catch (e: Exception) {
        false
    }

    private fun loadKey(): SecretKey? = try {
        keyStore().getKey(KEY_ALIAS, null) as? SecretKey
    } catch (e: UnrecoverableKeyException) {
        null
    }

    private fun getOrCreateKey(): SecretKey {
        loadKey()?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            // 每次认证只授权一次加/解密（auth-per-use，等价参考版 setUserAuthenticationRequired）
            .setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
            // 新增/变更指纹/面容后旧密钥立即失效
            .setInvalidatedByBiometricEnrollment(true)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun deleteKey() {
        try {
            val store = keyStore()
            if (store.containsAlias(KEY_ALIAS)) {
                store.deleteEntry(KEY_ALIAS)
            }
        } catch (e: Exception) {
            // 删除失败不阻断 Dart 侧流程：Rust 凭据已清，残留密钥无可用信封
        }
    }

    private fun decodeBase64(value: String?): ByteArray? = try {
        Base64.decode(value ?: "", Base64.NO_WRAP)
    } catch (e: IllegalArgumentException) {
        null
    }
}
