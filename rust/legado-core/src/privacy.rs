//! 隐私密码凭据（PBKDF2-HMAC-SHA256）
//!
//! 契约 §2.53（批9a）：本模块只负责密码派生与校验，不碰数据库/UI。
//! 对齐参考版 `help/security/PrivatePasswordCipher.kt`：
//! - 随机 16 字节 salt；
//! - PBKDF2WithHmacSHA256 迭代 210000 次派生 32 字节 verifier；
//! - salt / verifier 以标准 Base64 存储，**不存明文密码**；
//! - 校验使用定长 XOR 比较（常量时间），salt/verifier 非法时返回 false。
//!
//! [批9d] 生物识别快捷解锁令牌：平台 Keystore/Keychain 只封装 **32 字节
//! 随机令牌**（不封装密码），本模块提供令牌的 SHA-256 摘要与常量时间校验。
//! 令牌摘要以标准 Base64 存 caches `config:private_biometric_token_hash`，
//! 本模块不接触数据库/平台。
//!
//! 用户已授权实现隐私完整版（仅数据层；UI/生物识别属后续批次）。

use base64::Engine;
use rand::RngCore;
use sha2::Digest;

/// PBKDF2 迭代次数（对齐参考版 `PrivatePasswordCipher.PBKDF2_ITERATIONS`）
pub const PBKDF2_ITERATIONS: u32 = 210_000;
/// verifier 长度（32 字节 = 256 bit，对齐参考版 `PBKDF2_KEY_BITS`）
pub const VERIFIER_LEN: usize = 32;
/// salt 长度（16 字节，对齐参考版 `SALT_LENGTH_BYTES`）
pub const SALT_LEN: usize = 16;

/// 生物识别快捷解锁令牌长度（32 字节随机令牌，契约 §2.53 批9d）
pub const BIOMETRIC_TOKEN_LEN: usize = 32;
/// 生物识别令牌摘要长度（SHA-256，32 字节）
pub const BIOMETRIC_TOKEN_HASH_LEN: usize = 32;

/// 生成 16 字节随机 salt（操作系统 CSPRNG）
pub fn generate_salt() -> [u8; SALT_LEN] {
    let mut salt = [0u8; SALT_LEN];
    rand::rngs::OsRng.fill_bytes(&mut salt);
    salt
}

/// 派生 verifier 原始字节
///
/// 抽成独立函数便于用已知 PBKDF2 向量做单测；正常调用方应使用
/// [`hash_password`] / [`verify_password`]。
fn derive_verifier(password: &str, salt: &[u8]) -> [u8; VERIFIER_LEN] {
    let mut output = [0u8; VERIFIER_LEN];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password.as_bytes(), salt, PBKDF2_ITERATIONS, &mut output);
    output
}

/// 生成新凭据：返回 `(salt_b64, verifier_b64)`
///
/// 每次调用都生成新 salt；同一密码的两次结果不同属预期行为。
pub fn hash_password(password: &str) -> (String, String) {
    let salt = generate_salt();
    let verifier = derive_verifier(password, &salt);
    let engine = base64::engine::general_purpose::STANDARD;
    (engine.encode(salt), engine.encode(verifier))
}

/// 校验密码
///
/// - salt/verifier 为空、Base64 非法或长度不符 → false；
/// - salt 长度必须为 16 字节、verifier 长度必须为 32 字节，否则 false；
/// - 正常路径派生后做定长 XOR 比较，避免按字节提前返回的时间差。
pub fn verify_password(password: &str, salt_b64: &str, verifier_b64: &str) -> bool {
    if salt_b64.is_empty() || verifier_b64.is_empty() {
        return false;
    }
    let engine = base64::engine::general_purpose::STANDARD;
    let Ok(salt) = engine.decode(salt_b64) else {
        return false;
    };
    let Ok(expected) = engine.decode(verifier_b64) else {
        return false;
    };
    if salt.len() != SALT_LEN || expected.len() != VERIFIER_LEN {
        return false;
    }

    let actual = derive_verifier(password, &salt);
    constant_time_eq(&actual, &expected)
}

/// 定长 XOR 比较（两侧等长时无提前返回；长度不等直接 false）
fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}

/// 生物识别令牌 SHA-256 摘要原始字节
///
/// 令牌由 Dart `Random.secure()` 生成（32 字节 → 标准 Base64），平台层只
/// 负责认证后加密/解密该令牌；摘要留在 Rust 侧用于校验，避免配置表出现
/// 可直接使用的令牌明文。
pub fn hash_biometric_token(token: &[u8]) -> [u8; BIOMETRIC_TOKEN_HASH_LEN] {
    let digest = sha2::Sha256::digest(token);
    let mut output = [0u8; BIOMETRIC_TOKEN_HASH_LEN];
    output.copy_from_slice(&digest);
    output
}

/// 生物识别令牌摘要（标准 Base64，存 `config:private_biometric_token_hash`）
pub fn hash_biometric_token_base64(token: &[u8]) -> String {
    let engine = base64::engine::general_purpose::STANDARD;
    engine.encode(hash_biometric_token(token))
}

/// 校验生物识别令牌与已存摘要
///
/// - 摘要为空、Base64 非法或解码后不是 32 字节 → false；
/// - 正常路径对原始摘要做常量时间比较。
///
/// 令牌长度校验由调用方（FFI 层）负责；本函数只回答「摘要是否匹配」。
pub fn verify_biometric_token(token: &[u8], token_hash_b64: &str) -> bool {
    if token_hash_b64.trim().is_empty() {
        return false;
    }
    let engine = base64::engine::general_purpose::STANDARD;
    let Ok(expected) = engine.decode(token_hash_b64) else {
        return false;
    };
    if expected.len() != BIOMETRIC_TOKEN_HASH_LEN {
        return false;
    }
    constant_time_eq(&hash_biometric_token(token), &expected)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        const DIGITS: &[u8; 16] = b"0123456789abcdef";
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push(DIGITS[(b >> 4) as usize] as char);
            out.push(DIGITS[(b & 0x0f) as usize] as char);
        }
        out
    }

    /// 已知 PBKDF2-HMAC-SHA256 向量（RFC 7914 附录 / 常见测试向量）：
    /// password="password", salt="salt", iterations=1, dkLen=32 → 120fb6cf...
    ///
    /// 另钉死生产参数的 210000 次向量（来源：Python `hashlib.pbkdf2_hmac`，
    /// 与 OpenSSL PBKDF2 同实现，password="password", salt="salt",
    /// iterations=210000, dkLen=32），防止迭代次数被悄悄改动。
    #[test]
    fn test_pbkdf2_known_vector() {
        assert_eq!(PBKDF2_ITERATIONS, 210_000);
        assert_eq!(VERIFIER_LEN, 32);
        assert_eq!(SALT_LEN, 16);

        let mut one_iter = [0u8; VERIFIER_LEN];
        pbkdf2::pbkdf2_hmac::<sha2::Sha256>(b"password", b"salt", 1, &mut one_iter);
        assert_eq!(
            hex(&one_iter),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
        );

        let production = derive_verifier("password", b"salt");
        assert_eq!(
            hex(&production),
            "9d5f68774306eaee6c79c5b4d3a263907f81c55d4daa1c50585e1e849065e090",
            "210000 次 PBKDF2-HMAC-SHA256 固定向量"
        );
    }

    /// 210k 次往返：正确密码通过，错误密码失败
    #[test]
    fn test_hash_and_verify_roundtrip() {
        let (salt, verifier) = hash_password("正确的马");
        assert_ne!(salt, verifier);
        assert!(verify_password("正确的马", &salt, &verifier));
        assert!(!verify_password("错误的马", &salt, &verifier));
    }

    /// 同一密码两次生成的 salt/verifier 不同（随机 salt），但都能验证通过
    #[test]
    fn test_hash_password_uses_random_salt() {
        let (salt1, verifier1) = hash_password("same-password");
        let (salt2, verifier2) = hash_password("same-password");
        assert_ne!(salt1, salt2, "每次应生成新的随机 salt");
        assert_ne!(verifier1, verifier2, "salt 不同则 verifier 不同");
        assert!(verify_password("same-password", &salt1, &verifier1));
        assert!(verify_password("same-password", &salt2, &verifier2));
    }

    /// 空密码：派生与校验本身可用（FFI 层负责拒绝空新密码）
    #[test]
    fn test_empty_password_roundtrip() {
        let (salt, verifier) = hash_password("");
        assert!(verify_password("", &salt, &verifier));
        assert!(!verify_password("x", &salt, &verifier));
    }

    /// 非法/缺失/长度不符凭据一律 false，不 panic
    #[test]
    fn test_verify_rejects_invalid_credentials() {
        assert!(!verify_password("p", "", ""));
        assert!(!verify_password("p", "not-base64!!", "also-not"));
        let (salt, _) = hash_password("p");
        assert!(!verify_password("p", &salt, "AAAA"));

        let engine = base64::engine::general_purpose::STANDARD;
        // 合法 Base64 但 verifier 长度不是 32 字节
        let short = engine.encode([0u8; 16]);
        assert!(!verify_password("p", &salt, &short));

        // salt 必须恰好 16 字节：15/17 字节即使 verifier 能对上也不接受
        for salt_len in [15usize, 17] {
            let bad_salt = engine.encode(vec![3u8; salt_len]);
            let matching_verifier = engine.encode(derive_verifier("p", &vec![3u8; salt_len]));
            assert!(
                !verify_password("p", &bad_salt, &matching_verifier),
                "salt_len={salt_len} 应拒绝"
            );
        }

        // 正确长度的错误 salt 必然校验失败
        let (_, verifier) = hash_password("p");
        let other_salt = engine.encode([9u8; SALT_LEN]);
        assert!(!verify_password("p", &other_salt, &verifier));
    }

    /// constant_time_eq 语义：等长逐字节比较、长度不等 false
    #[test]
    fn test_constant_time_eq() {
        assert!(constant_time_eq(&[1, 2, 3], &[1, 2, 3]));
        assert!(!constant_time_eq(&[1, 2, 3], &[1, 2, 4]));
        assert!(!constant_time_eq(&[1, 2], &[1, 2, 3]));
    }

    /// [批9d] 令牌摘要：已知 SHA-256 向量 + 往返 + 非法摘要一律 false
    #[test]
    fn test_biometric_token_hash_and_verify() {
        assert_eq!(
            hex(&hash_biometric_token(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA-256(\"abc\") 标准向量"
        );

        let token = [7u8; BIOMETRIC_TOKEN_LEN];
        let digest = hash_biometric_token_base64(&token);
        assert!(verify_biometric_token(&token, &digest));
        assert!(!verify_biometric_token(
            &[8u8; BIOMETRIC_TOKEN_LEN],
            &digest
        ));

        // 空/非法 Base64/长度不符（16/31/33 字节）摘要一律 false，不 panic
        assert!(!verify_biometric_token(&token, ""));
        assert!(!verify_biometric_token(&token, "  "));
        assert!(!verify_biometric_token(&token, "not-base64!!"));
        let engine = base64::engine::general_purpose::STANDARD;
        for len in [0usize, 16, 31, 33] {
            let bad = engine.encode(vec![0u8; len]);
            assert!(!verify_biometric_token(&token, &bad), "hash_len={len}");
        }
    }
}
