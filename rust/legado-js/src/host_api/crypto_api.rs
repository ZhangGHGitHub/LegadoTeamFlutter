//! Crypto JS 桥接
//!
//! 封装 `legado_core::crypto` 为 JS 可调用函数。
//! 对应 Kotlin `JsEncodeUtils.kt` 的 `createSymmetricCrypto` 及
//! `JsExtensions` 中的 AES/DES/RC4 加解密方法。
//!
//! 所有函数返回 `Result<String, String>`，错误信息为人类可读字符串，
//! 便于在 JS 侧直接抛出。

use legado_core::crypto;

// ---------------------------------------------------------------------------
// createSymmetricCrypto
// ---------------------------------------------------------------------------

/// createSymmetricCrypto(transformation, key, iv)
///
/// 解析 transformation 并验证算法是否受支持。
/// 返回格式化的算法描述符（如 "AES/CBC"），供后续 encrypt/decrypt 调用参考。
///
/// 支持的 transformation:
/// - "AES/CBC/PKCS5Padding", "AES/ECB/PKCS5Padding"
/// - "DES/CBC/PKCS5Padding"
/// - "DESede/CBC/PKCS5Padding"（3DES，16/24 字节密钥）
/// - "RC4"
pub fn create_symmetric_crypto(
    transformation: &str,
    _key: &str,
    _iv: Option<&str>,
) -> Result<String, String> {
    let (algo, mode, _padding) = crypto::parse_transformation(transformation)?;
    match algo.as_str() {
        "AES" => {
            if mode != "CBC" && mode != "ECB" && mode != "NONE" {
                return Err(format!(
                    "Unsupported AES mode: {}. Supported: CBC, ECB",
                    mode
                ));
            }
            Ok(format!("AES/{}", mode))
        }
        "DES" => {
            if mode != "CBC" && mode != "NONE" {
                return Err(format!("Unsupported DES mode: {}. Supported: CBC", mode));
            }
            Ok(format!("DES/{}", mode))
        }
        "DESEDE" => {
            if mode != "CBC" && mode != "ECB" {
                return Err(format!(
                    "Unsupported DESede mode: {}. Supported: CBC, ECB",
                    mode
                ));
            }
            Ok(format!("DESede/{}", mode))
        }
        "RC4" => Ok("RC4".to_string()),
        _ => Err(format!("Unsupported algorithm: {}", algo)),
    }
}

// ---------------------------------------------------------------------------
// AES 加解密
// ---------------------------------------------------------------------------

/// aesEncrypt(data, key, iv) — AES-CBC 加密，返回 Base64 密文
///
/// 对应 Kotlin: `aesEncrypt(data, key, iv)`
pub fn aes_encrypt(data: &str, key: &str, iv: Option<&str>) -> Result<String, String> {
    let iv_str = iv.unwrap_or("0000000000000000");
    crypto::aes_encrypt_base64(key, iv_str, data).map_err(|e| e.to_string())
}

/// aesDecrypt(data, key, iv) — AES-CBC 解密 Base64 密文
///
/// 对应 Kotlin: `aesDecrypt(data, key, iv)`
pub fn aes_decrypt(data: &str, key: &str, iv: Option<&str>) -> Result<String, String> {
    let iv_str = iv.unwrap_or("0000000000000000");
    crypto::aes_decrypt_base64(key, iv_str, data).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// DES 加解密
// ---------------------------------------------------------------------------

/// desEncrypt(data, key, iv) — DES-CBC 加密，返回 Base64 密文
///
/// 对应 Kotlin: `desEncrypt(data, key, iv)`
pub fn des_encrypt(data: &str, key: &str, iv: Option<&str>) -> Result<String, String> {
    let iv_str = iv.unwrap_or("00000000");
    crypto::des_encrypt_base64(key, iv_str, data).map_err(|e| e.to_string())
}

/// desDecrypt(data, key, iv) — DES-CBC 解密 Base64 密文
///
/// 对应 Kotlin: `desDecrypt(data, key, iv)`
pub fn des_decrypt(data: &str, key: &str, iv: Option<&str>) -> Result<String, String> {
    let iv_str = iv.unwrap_or("00000000");
    crypto::des_decrypt_base64(key, iv_str, data).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// 3DES (DESede) 加解密
// ---------------------------------------------------------------------------

/// tripleDESEncodeBase64Str(data, key, mode, padding, iv)
///
/// 对应 Kotlin `JsEncodeUtils.tripleDESEncodeBase64Str`：
/// `createSymmetricCrypto("DESede/{mode}/{padding}", key, iv).encryptBase64(data)`。
/// key/iv 为原始字符串字节（UTF-8），返回标准 Base64 密文。
pub fn triple_des_encode_base64_str(
    data: &str,
    key: &str,
    mode: &str,
    padding: &str,
    iv: &str,
) -> Result<String, String> {
    crypto::triple_des_encrypt_base64(key, mode, padding, iv, data).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// RC4 加解密
// ---------------------------------------------------------------------------

/// rc4Encrypt(data, key) — RC4 加密，返回 Base64 密文
///
/// 对应 Kotlin: `rc4Encrypt(data, key)`
pub fn rc4_encrypt(data: &str, key: &str) -> Result<String, String> {
    crypto::rc4_encrypt_base64(key, data).map_err(|e| e.to_string())
}

/// rc4Decrypt(data, key) — RC4 解密 Base64 密文
///
/// 对应 Kotlin: `rc4Decrypt(data, key)`
pub fn rc4_decrypt(data: &str, key: &str) -> Result<String, String> {
    crypto::rc4_decrypt_base64(key, data).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // ---- AES 往返 ----

    #[test]
    fn test_aes_encrypt_decrypt_roundtrip() {
        let key = "0123456789abcdef"; // 16 bytes
        let iv = "fedcba9876543210";
        let plaintext = "Hello, Legado Crypto API!";

        let encrypted = aes_encrypt(plaintext, key, Some(iv)).expect("encrypt");
        let decrypted = aes_decrypt(&encrypted, key, Some(iv)).expect("decrypt");
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_aes_encrypt_decrypt_default_iv() {
        let key = "0123456789abcdef";
        let plaintext = "Default IV test";

        let encrypted = aes_encrypt(plaintext, key, None).expect("encrypt");
        let decrypted = aes_decrypt(&encrypted, key, None).expect("decrypt");
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_aes_wrong_key_fails() {
        let key = "0123456789abcdef";
        let iv = "fedcba9876543210";
        let encrypted = aes_encrypt("secret", key, Some(iv)).unwrap();
        // 用错误 key 解密应失败（padding 错误或 UTF-8 错误）
        let result = aes_decrypt(&encrypted, "wrongkeywrongkey", Some(iv));
        assert!(result.is_err());
    }

    // ---- DES 往返 ----

    #[test]
    fn test_des_encrypt_decrypt_roundtrip() {
        let key = "deskey01"; // 8 bytes
        let iv = "initvec0";
        let plaintext = "DES crypto API test data";

        let encrypted = des_encrypt(plaintext, key, Some(iv)).expect("encrypt");
        let decrypted = des_decrypt(&encrypted, key, Some(iv)).expect("decrypt");
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_des_bad_key_length() {
        let result = des_encrypt("data", "short", Some("initvec0"));
        assert!(result.is_err());
    }

    // ---- RC4 往返 ----

    #[test]
    fn test_rc4_encrypt_decrypt_roundtrip() {
        let key = "rc4secretkey";
        let plaintext = "RC4 stream cipher test 中文测试";

        let encrypted = rc4_encrypt(plaintext, key).expect("encrypt");
        let decrypted = rc4_decrypt(&encrypted, key).expect("decrypt");
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_rc4_different_keys_differ() {
        let plaintext = "same data";
        let enc1 = rc4_encrypt(plaintext, "key1").unwrap();
        let enc2 = rc4_encrypt(plaintext, "key2").unwrap();
        assert_ne!(enc1, enc2);
    }

    // ---- create_symmetric_crypto ----

    #[test]
    fn test_create_symmetric_crypto_aes_cbc() {
        let result = create_symmetric_crypto("AES/CBC/PKCS5Padding", "key", Some("iv"));
        assert_eq!(result.unwrap(), "AES/CBC");
    }

    #[test]
    fn test_create_symmetric_crypto_aes_ecb() {
        let result = create_symmetric_crypto("AES/ECB/PKCS5Padding", "key", None);
        assert_eq!(result.unwrap(), "AES/ECB");
    }

    #[test]
    fn test_create_symmetric_crypto_des() {
        let result = create_symmetric_crypto("DES/CBC/PKCS5Padding", "key", Some("iv"));
        assert_eq!(result.unwrap(), "DES/CBC");
    }

    #[test]
    fn test_create_symmetric_crypto_desede() {
        let result = create_symmetric_crypto("DESede/CBC/PKCS5Padding", "key", Some("iv"));
        assert_eq!(result.unwrap(), "DESede/CBC");
        let result = create_symmetric_crypto("DESede/ECB/NoPadding", "key", None);
        assert_eq!(result.unwrap(), "DESede/ECB");
    }

    #[test]
    fn test_create_symmetric_crypto_desede_bad_mode() {
        let result = create_symmetric_crypto("DESede/OFB/NoPadding", "key", None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Unsupported DESede mode"));
    }

    #[test]
    fn test_triple_des_encode_base64_str_roundtrip() {
        use base64::Engine;

        let key = "0123456789abcdef"; // 16 bytes → 双密钥 EDE
        let iv = "00000000";
        let data = "QDSign payload 中文";

        let b64 = triple_des_encode_base64_str(data, key, "CBC", "PKCS5Padding", iv)
            .expect("triple des encode");
        assert!(!b64.is_empty());

        // 经对称 API 还原（#135 的 createSymmetricCrypto 解密链路同走此分发）
        let pt = crypto::symmetric_decrypt(
            "DESede/CBC/PKCS5Padding",
            key.as_bytes(),
            Some(iv.as_bytes()),
            &base64::engine::general_purpose::STANDARD
                .decode(&b64)
                .expect("b64"),
        )
        .expect("decrypt");
        assert_eq!(pt, data.as_bytes());
    }

    #[test]
    fn test_create_symmetric_crypto_rc4() {
        let result = create_symmetric_crypto("RC4", "key", None);
        assert_eq!(result.unwrap(), "RC4");
    }

    #[test]
    fn test_create_symmetric_crypto_unsupported_algo() {
        let result = create_symmetric_crypto("BLOWFISH/CBC/PKCS5Padding", "key", None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Unsupported algorithm"));
    }

    #[test]
    fn test_create_symmetric_crypto_invalid_transformation() {
        let result = create_symmetric_crypto("AES/CBC", "key", None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Invalid transformation"));
    }
}
