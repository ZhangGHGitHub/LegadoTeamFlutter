//! 隐私密码凭据（PBKDF2-HMAC-SHA256）
//!
//! 契约 §2.53（批9a）：本模块只负责密码派生与校验，不碰数据库/UI。
//! 对齐参考版 `help/security/PrivatePasswordCipher.kt`：
//! - 随机 16 字节 salt；
//! - PBKDF2WithHmacSHA256 迭代 210000 次派生 32 字节 verifier；
//! - salt / verifier 以标准 Base64 存储，**不存明文密码**；
//! - 校验使用定长 XOR 比较（常量时间），salt/verifier 非法时返回 false。
//!
//! 用户已授权实现隐私完整版（仅数据层；UI/生物识别属后续批次）。

use base64::Engine;
use rand::RngCore;

/// PBKDF2 迭代次数（对齐参考版 `PrivatePasswordCipher.PBKDF2_ITERATIONS`）
pub const PBKDF2_ITERATIONS: u32 = 210_000;
/// verifier 长度（32 字节 = 256 bit，对齐参考版 `PBKDF2_KEY_BITS`）
pub const VERIFIER_LEN: usize = 32;
/// salt 长度（16 字节，对齐参考版 `SALT_LENGTH_BYTES`）
pub const SALT_LEN: usize = 16;

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
/// - verifier 长度不是 32 字节 → false；
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
    if expected.len() != VERIFIER_LEN {
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

    /// 已知 PBKDF2-HMAC-SHA256 向量：password="password", salt="salt",
    /// iterations=1, dkLen=32 → 120fb6cf...
    ///
    /// 这里直接调用单次派生做固定向量校验；生产参数常量单独断言，
    /// 防止有人误改迭代次数而不自知。
    #[test]
    fn test_pbkdf2_known_vector() {
        assert_eq!(PBKDF2_ITERATIONS, 210_000);
        assert_eq!(VERIFIER_LEN, 32);
        assert_eq!(SALT_LEN, 16);

        let mut output = [0u8; VERIFIER_LEN];
        pbkdf2::pbkdf2_hmac::<sha2::Sha256>(b"password", b"salt", 1, &mut output);
        assert_eq!(
            hex(&output),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
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
        // 合法 Base64 但 verifier 长度不是 32 字节
        let short = base64::engine::general_purpose::STANDARD.encode([0u8; 16]);
        assert!(!verify_password("p", &salt, &short));
        // salt 长度不固定也能正常派生；错误 salt 必然校验失败
        let (_, verifier) = hash_password("p");
        let other_salt = base64::engine::general_purpose::STANDARD.encode([9u8; 16]);
        assert!(!verify_password("p", &other_salt, &verifier));
    }

    /// constant_time_eq 语义：等长逐字节比较、长度不等 false
    #[test]
    fn test_constant_time_eq() {
        assert!(constant_time_eq(&[1, 2, 3], &[1, 2, 3]));
        assert!(!constant_time_eq(&[1, 2, 3], &[1, 2, 4]));
        assert!(!constant_time_eq(&[1, 2], &[1, 2, 3]));
    }
}
