//! 编解码 API 实现
//!
//! 提供纯 Rust 实现的编解码函数，对应 Kotlin 端 `JsEncodeUtils` 和
//! `JsExtensions` 中的编解码方法：
//! - MD5（32 位 / 16 位）
//! - Base64 编解码
//! - Hex 编解码
//! - URI 编码
//! - SHA-256
//! - HMAC-MD5

// ============================================================
// 启用 quickjs feature 时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_encoding {
    use base64::Engine;
    use hmac::{Hmac, Mac};
    use md5::{Digest as Md5Digest, Md5};
    use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
    use sha1::Sha1;
    use sha2::{Sha256, Sha384, Sha512};

    /// MD5 编码 — 返回 32 位十六进制小写字符串
    ///
    /// 对应 Kotlin: `MD5Utils.md5Encode(str)`
    pub fn md5_encode(input: &str) -> String {
        let mut hasher = Md5::new();
        hasher.update(input.as_bytes());
        let result = hasher.finalize();
        hex::encode(result)
    }

    /// MD5 编码 — 返回 16 位十六进制小写字符串（取中间 16 字符）
    ///
    /// 对应 Kotlin: `MD5Utils.md5Encode16(str)`
    pub fn md5_encode_16(input: &str) -> String {
        let full = md5_encode(input);
        full[8..24].to_string()
    }

    /// MD5 编码字节数组
    pub fn md5_encode_bytes(input: &[u8]) -> String {
        let mut hasher = Md5::new();
        hasher.update(input);
        let result = hasher.finalize();
        hex::encode(result)
    }

    /// Base64 编码
    ///
    /// 对应 Kotlin: `base64Encode(str)`
    pub fn base64_encode(input: &str) -> String {
        base64::engine::general_purpose::STANDARD.encode(input.as_bytes())
    }

    /// Base64 编码（字节数组输入）
    pub fn base64_encode_bytes(input: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(input)
    }

    /// Base64 解码
    ///
    /// 对应 Kotlin: `base64Decode(str)`
    pub fn base64_decode(input: &str) -> Result<String, String> {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(input)
            .map_err(|e| format!("Base64 decode error: {}", e))?;
        String::from_utf8(bytes).map_err(|e| format!("UTF-8 decode error: {}", e))
    }

    /// Base64 解码为字节数组
    pub fn base64_decode_bytes(input: &str) -> Result<Vec<u8>, String> {
        base64::engine::general_purpose::STANDARD
            .decode(input)
            .map_err(|e| format!("Base64 decode error: {}", e))
    }

    /// Base64 解码为字节数组（带 Android Base64 flags）
    ///
    /// 对应 Kotlin: `base64DecodeToByteArray(str, flags)`
    /// 兼容 Android `Base64.URL_SAFE`(8)；NO_WRAP 等标志不影响解码行为
    pub fn base64_decode_bytes_with_flags(input: &str, flags: i32) -> Result<Vec<u8>, String> {
        // Android Base64.URL_SAFE == 8（'-' 与 '_' 替代 '+' 与 '/'）
        let url_safe = flags & 8 != 0;
        let engine = if url_safe {
            base64::engine::general_purpose::URL_SAFE
        } else {
            base64::engine::general_purpose::STANDARD
        };
        engine
            .decode(input)
            .map_err(|e| format!("Base64 decode error: {}", e))
    }

    /// Hex 编码 — UTF-8 字符串转十六进制字符串
    ///
    /// 对应 Kotlin: `hexEncodeToString(utf8)`
    pub fn hex_encode(input: &str) -> String {
        hex::encode(input.as_bytes())
    }

    /// Hex 编码（字节数组输入）
    pub fn hex_encode_bytes(input: &[u8]) -> String {
        hex::encode(input)
    }

    /// Hex 解码 — 十六进制字符串转 UTF-8 字符串
    ///
    /// 对应 Kotlin: `hexDecodeToString(hex)`
    pub fn hex_decode(input: &str) -> Result<String, String> {
        let bytes = hex::decode(input).map_err(|e| format!("Hex decode error: {}", e))?;
        String::from_utf8(bytes).map_err(|e| format!("UTF-8 decode error: {}", e))
    }

    /// Hex 解码为字节数组
    pub fn hex_decode_bytes(input: &str) -> Result<Vec<u8>, String> {
        hex::decode(input).map_err(|e| format!("Hex decode error: {}", e))
    }

    /// URI 编码（percent-encode）
    ///
    /// 对应 Kotlin: `encodeURI(str)`
    /// 注意: JS 的 `encodeURIComponent` 保留 `-_.!~*'()` 不编码，
    /// 这里使用 NON_ALPHANUMERIC 集合作为保守实现。
    pub fn encode_uri(input: &str) -> String {
        utf8_percent_encode(input, NON_ALPHANUMERIC).to_string()
    }

    /// 按指定字符集 URI 编码（对齐 Kotlin encodeURI(str, enc)）
    ///
    /// 燃文等源 `java.encodeURI(String(key), "UTF8")` 双参调用依赖；
    /// 非 UTF-8 字符集（GBK 等）先经 encoding_rs 转码再百分号编码。
    /// — 2026-08-17
    pub fn encode_uri_charset(input: &str, charset: &str) -> String {
        let lower = charset.to_ascii_lowercase().replace('-', "").replace('_', "");
        if lower == "utf8" || lower == "utf" {
            return encode_uri(input);
        }
        if lower == "gbk" || lower == "gb2312" || lower == "gb18030" {
            let (bytes, _, _) = encoding_rs::GBK.encode(input);
            return bytes
                .iter()
                .map(|b| format!("%{:02X}", b))
                .collect::<String>();
        }
        // 未知字符集：回退 UTF-8
        encode_uri(input)
    }

    /// encodeURIComponent 语义编码（对齐 JS 标准 / Kotlin encodeURIComponent）
    ///
    /// [UI-fix 2026-08-10 | Reasonix] 新增：percent-encode 除 `A-Za-z0-9-_.!~*'()`
    /// 外的全部字符（含 `;/?:@&=+$,#` 等 encodeURI 不编码的保留字符）。
    /// 背景：yckceo 书源（思兔阅读 sto66 等）searchUrl 用 `{{encodeURIComponent(key)}}`，
    /// 此前 quickjs 宿主未注册该函数 → 表达式求值失败 → URL 中模板被替换为空串
    /// → 搜索 URL 残缺 →「原版能搜到、重构版搜不到」。
    pub fn encode_uri_component(input: &str) -> String {
        // 保留集：JS encodeURIComponent 不编码 A-Za-z0-9 与 -_.!~*'()
        const ENCODE_URI_COMPONENT_KEEP: &AsciiSet = &NON_ALPHANUMERIC
            .remove(b'-')
            .remove(b'_')
            .remove(b'.')
            .remove(b'!')
            .remove(b'~')
            .remove(b'*')
            .remove(b'\'')
            .remove(b'(')
            .remove(b')');
        utf8_percent_encode(input, ENCODE_URI_COMPONENT_KEEP).to_string()
    }

    /// SHA-256 摘要 — 返回 64 位十六进制小写字符串
    pub fn sha256(input: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(input.as_bytes());
        let result = hasher.finalize();
        hex::encode(result)
    }

    /// SHA-256 摘要（字节数组输入）
    pub fn sha256_bytes(input: &[u8]) -> String {
        let mut hasher = Sha256::new();
        hasher.update(input);
        let result = hasher.finalize();
        hex::encode(result)
    }

    /// HMAC-MD5 — 返回十六进制小写字符串
    pub fn hmac_md5(data: &str, key: &str) -> Result<String, String> {
        type HmacMd5 = Hmac<Md5>;
        let mut mac = HmacMd5::new_from_slice(key.as_bytes())
            .map_err(|e| format!("HMAC key error: {}", e))?;
        mac.update(data.as_bytes());
        let result = mac.finalize();
        Ok(hex::encode(result.into_bytes()))
    }

    /// HMAC-SHA256 — 返回十六进制小写字符串
    pub fn hmac_sha256(data: &str, key: &str) -> Result<String, String> {
        type HmacSha256 = Hmac<Sha256>;
        let mut mac = HmacSha256::new_from_slice(key.as_bytes())
            .map_err(|e| format!("HMAC key error: {}", e))?;
        mac.update(data.as_bytes());
        let result = mac.finalize();
        Ok(hex::encode(result.into_bytes()))
    }

    // ============================================================
    // 通用摘要 + 编解码扩展
    // ============================================================

    /// 通用消息摘要 — digestHex(data, algorithm)
    /// 支持: MD5, SHA-1, SHA-256, SHA-384, SHA-512
    ///
    /// 对应 Kotlin: `digestHex(data, algorithm)`
    pub fn digest_hex(data: &str, algorithm: &str) -> Result<String, String> {
        match algorithm.to_uppercase().replace('-', "").as_str() {
            "MD5" => Ok(md5_encode(data)),
            "SHA1" => {
                use sha1::Digest;
                let mut hasher = Sha1::new();
                hasher.update(data.as_bytes());
                Ok(hex::encode(hasher.finalize()))
            }
            "SHA256" => Ok(sha256(data)),
            "SHA384" => {
                let mut hasher = Sha384::new();
                hasher.update(data.as_bytes());
                Ok(hex::encode(hasher.finalize()))
            }
            "SHA512" => {
                let mut hasher = Sha512::new();
                hasher.update(data.as_bytes());
                Ok(hex::encode(hasher.finalize()))
            }
            _ => Err(format!("Unsupported algorithm: {}", algorithm)),
        }
    }

    /// 通用消息摘要 Base64 — digestBase64Str(data, algorithm)
    /// 支持: MD5, SHA-1, SHA-256, SHA-384, SHA-512
    ///
    /// 对应 Kotlin: `digestBase64Str(data, algorithm)`
    pub fn digest_base64_str(data: &str, algorithm: &str) -> Result<String, String> {
        let bytes: Vec<u8> = match algorithm.to_uppercase().replace('-', "").as_str() {
            "MD5" => {
                let mut hasher = Md5::new();
                hasher.update(data.as_bytes());
                hasher.finalize().to_vec()
            }
            "SHA1" => {
                use sha1::Digest;
                let mut hasher = Sha1::new();
                hasher.update(data.as_bytes());
                hasher.finalize().to_vec()
            }
            "SHA256" => {
                let mut hasher = Sha256::new();
                hasher.update(data.as_bytes());
                hasher.finalize().to_vec()
            }
            "SHA384" => {
                let mut hasher = Sha384::new();
                hasher.update(data.as_bytes());
                hasher.finalize().to_vec()
            }
            "SHA512" => {
                let mut hasher = Sha512::new();
                hasher.update(data.as_bytes());
                hasher.finalize().to_vec()
            }
            _ => return Err(format!("Unsupported algorithm: {}", algorithm)),
        };
        Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
    }

    /// 通用 HMAC — hmacHex(data, algorithm, key)
    /// 支持: MD5, SHA-1, SHA-256, SHA-512
    ///
    /// 对应 Kotlin: `HMacHex(data, algorithm, key)`
    pub fn hmac_hex(data: &str, algorithm: &str, key: &str) -> Result<String, String> {
        match algorithm.to_uppercase().replace('-', "").as_str() {
            "MD5" => hmac_md5(data, key),
            "SHA1" => {
                type HmacSha1 = Hmac<Sha1>;
                let mut mac = HmacSha1::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                Ok(hex::encode(mac.finalize().into_bytes()))
            }
            "SHA256" => hmac_sha256(data, key),
            "SHA512" => {
                type HmacSha512 = Hmac<Sha512>;
                let mut mac = HmacSha512::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                Ok(hex::encode(mac.finalize().into_bytes()))
            }
            _ => Err(format!("Unsupported HMAC algorithm: {}", algorithm)),
        }
    }

    /// HMAC Base64 — hmacBase64(data, algorithm, key)
    /// 支持: MD5, SHA-1, SHA-256, SHA-512
    ///
    /// 对应 Kotlin: `HMacBase64(data, algorithm, key)`
    pub fn hmac_base64(data: &str, algorithm: &str, key: &str) -> Result<String, String> {
        let bytes: Vec<u8> = match algorithm.to_uppercase().replace('-', "").as_str() {
            "MD5" => {
                type HmacMd5T = Hmac<Md5>;
                let mut mac = HmacMd5T::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                mac.finalize().into_bytes().to_vec()
            }
            "SHA1" => {
                type HmacSha1 = Hmac<Sha1>;
                let mut mac = HmacSha1::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                mac.finalize().into_bytes().to_vec()
            }
            "SHA256" => {
                type HmacSha256T = Hmac<Sha256>;
                let mut mac = HmacSha256T::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                mac.finalize().into_bytes().to_vec()
            }
            "SHA512" => {
                type HmacSha512 = Hmac<Sha512>;
                let mut mac = HmacSha512::new_from_slice(key.as_bytes())
                    .map_err(|e| format!("HMAC key error: {}", e))?;
                mac.update(data.as_bytes());
                mac.finalize().into_bytes().to_vec()
            }
            _ => return Err(format!("Unsupported HMAC algorithm: {}", algorithm)),
        };
        Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
    }

    /// strToBytes(str, charset) — 字符串转字节数组（JSON 数组格式）
    ///
    /// 对应 Kotlin: `strToBytes(str, charset)`
    /// 返回 JSON 数组格式，如 "[72,101,108,108,111]"
    pub fn str_to_bytes(s: &str, charset: Option<&str>) -> Result<String, String> {
        let encoding_name = charset.unwrap_or("UTF-8");
        let encoding = encoding_rs::Encoding::for_label(encoding_name.as_bytes())
            .ok_or_else(|| format!("Unsupported charset: {}", encoding_name))?;
        let (bytes, _enc, _had_errors) = encoding.encode(s);
        let arr: Vec<serde_json::Value> =
            bytes.iter().map(|&b| serde_json::Value::from(b)).collect();
        serde_json::to_string(&arr).map_err(|e| format!("JSON serialize error: {}", e))
    }

    /// bytesToStr(bytes, charset) — 字节数组转字符串
    ///
    /// 对应 Kotlin: `bytesToStr(bytes, charset)`
    /// 输入为 JSON 数组格式，如 "[72,101,108,108,111]"
    pub fn bytes_to_str(bytes_json: &str, charset: Option<&str>) -> Result<String, String> {
        let arr: Vec<i64> =
            serde_json::from_str(bytes_json).map_err(|e| format!("JSON parse error: {}", e))?;
        let bytes: Vec<u8> = arr.iter().map(|&v| v as u8).collect();
        let encoding_name = charset.unwrap_or("UTF-8");
        let encoding = encoding_rs::Encoding::for_label(encoding_name.as_bytes())
            .ok_or_else(|| format!("Unsupported charset: {}", encoding_name))?;
        let (result, _enc, _had_errors) = encoding.decode(&bytes);
        Ok(result.into_owned())
    }
}

#[cfg(feature = "quickjs")]
pub use impl_encoding::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_encoding {
    fn not_available() -> String {
        "encoding not available: build with --features quickjs".to_string()
    }

    /// MD5 编码（占位）
    pub fn md5_encode(_input: &str) -> String {
        not_available()
    }

    /// MD5 编码 16 位（占位）
    pub fn md5_encode_16(_input: &str) -> String {
        not_available()
    }

    /// MD5 编码字节数组（占位）
    pub fn md5_encode_bytes(_input: &[u8]) -> String {
        not_available()
    }

    /// Base64 编码（占位）
    pub fn base64_encode(_input: &str) -> String {
        not_available()
    }

    /// Base64 编码字节数组（占位）
    pub fn base64_encode_bytes(_input: &[u8]) -> String {
        not_available()
    }

    /// Base64 解码（占位）
    pub fn base64_decode(_input: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// Base64 解码为字节数组（占位）
    pub fn base64_decode_bytes(_input: &str) -> Result<Vec<u8>, String> {
        Err(not_available())
    }

    /// Base64 解码为字节数组（带 flags，占位）
    pub fn base64_decode_bytes_with_flags(_input: &str, _flags: i32) -> Result<Vec<u8>, String> {
        Err(not_available())
    }

    /// Hex 编码（占位）
    pub fn hex_encode(_input: &str) -> String {
        not_available()
    }

    /// Hex 编码字节数组（占位）
    pub fn hex_encode_bytes(_input: &[u8]) -> String {
        not_available()
    }

    /// Hex 解码（占位）
    pub fn hex_decode(_input: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// Hex 解码为字节数组（占位）
    pub fn hex_decode_bytes(_input: &str) -> Result<Vec<u8>, String> {
        Err(not_available())
    }

    /// URI 编码（占位）
    pub fn encode_uri(_input: &str) -> String {
        not_available()
    }

    /// SHA-256（占位）
    pub fn sha256(_input: &str) -> String {
        not_available()
    }

    /// SHA-256 字节数组（占位）
    pub fn sha256_bytes(_input: &[u8]) -> String {
        not_available()
    }

    /// HMAC-MD5（占位）
    pub fn hmac_md5(_data: &str, _key: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// HMAC-SHA256（占位）
    pub fn hmac_sha256(_data: &str, _key: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// 通用消息摘要（占位）
    pub fn digest_hex(_data: &str, _algorithm: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// 通用消息摘要 Base64（占位）
    pub fn digest_base64_str(_data: &str, _algorithm: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// 通用 HMAC（占位）
    pub fn hmac_hex(_data: &str, _algorithm: &str, _key: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// HMAC Base64（占位）
    pub fn hmac_base64(_data: &str, _algorithm: &str, _key: &str) -> Result<String, String> {
        Err(not_available())
    }

    /// strToBytes（占位）
    pub fn str_to_bytes(_s: &str, _charset: Option<&str>) -> Result<String, String> {
        Err(not_available())
    }

    /// bytesToStr（占位）
    pub fn bytes_to_str(_bytes_json: &str, _charset: Option<&str>) -> Result<String, String> {
        Err(not_available())
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_encoding::*;

// ============================================================
// 测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    #[test]
    fn test_digest_hex_md5() {
        let result = digest_hex("hello", "MD5").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_encode_uri_component_keeps_unreserved() {
        // JS encodeURIComponent 保留 A-Za-z0-9-_.!~*'()
        assert_eq!(encode_uri_component("abcXYZ012-_.!~*'()"), "abcXYZ012-_.!~*'()");
    }

    #[test]
    fn test_encode_uri_component_percent_encodes() {
        // 中文 UTF-8 百分号编码
        assert_eq!(
            encode_uri_component("重生"),
            "%E9%87%8D%E7%94%9F"
        );
        // 空格与 +（encodeURI 不编码 +，encodeURIComponent 编码）
        assert_eq!(encode_uri_component("a b+c"), "a%20b%2Bc");
        // 保留字符 / ? & = 等全部编码（区别于 encodeURI）
        assert_eq!(encode_uri_component("/?&="), "%2F%3F%26%3D");
    }

    #[test]
    fn test_digest_hex_sha1() {
        let result = digest_hex("hello", "SHA-1").unwrap();
        assert_eq!(result, "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    }

    #[test]
    fn test_digest_hex_sha256() {
        let result = digest_hex("hello", "SHA-256").unwrap();
        assert_eq!(
            result,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_digest_hex_sha384() {
        let result = digest_hex("hello", "SHA-384").unwrap();
        assert_eq!(
            result,
            "59e1748777448c69de6b800d7a33bbfb9ff1b463e44354c3553bcdb9c666fa90125a3c79f90397bdf5f6a13de828684f"
        );
    }

    #[test]
    fn test_digest_hex_sha512() {
        let result = digest_hex("hello", "SHA-512").unwrap();
        assert_eq!(
            result,
            "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043"
        );
    }

    #[test]
    fn test_digest_hex_unsupported() {
        let result = digest_hex("hello", "SHA3-256");
        assert!(result.is_err());
    }

    #[test]
    fn test_digest_base64_str_sha256() {
        let result = digest_base64_str("hello", "SHA-256").unwrap();
        // Base64 of SHA-256("hello")
        assert_eq!(result, "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=");
    }

    #[test]
    fn test_hmac_hex_md5() {
        let result = hmac_hex("hello", "MD5", "key").unwrap();
        assert_eq!(result, "04130747afca4d79e32e87cf2104f087");
    }

    #[test]
    fn test_hmac_hex_sha1() {
        let result = hmac_hex("hello", "SHA-1", "key").unwrap();
        assert_eq!(result, "b34ceac4516ff23a143e61d79d0fa7a4fbe5f266");
    }

    #[test]
    fn test_hmac_hex_sha256() {
        let result = hmac_hex("hello", "SHA-256", "key").unwrap();
        assert_eq!(
            result,
            "9307b3b915efb5171ff14d8cb55fbcc798c6c0ef1456d66ded1a6aa723a58b7b"
        );
    }

    #[test]
    fn test_hmac_hex_sha512() {
        let result = hmac_hex("hello", "SHA-512", "key").unwrap();
        assert_eq!(
            result,
            "ff06ab36757777815c008d32c8e14a705b4e7bf310351a06a23b612dc4c7433e7757d20525a5593b71020ea2ee162d2311b247e9855862b270122419652c0c92"
        );
        // Verify it returns 128 hex chars (64 bytes)
        assert_eq!(result.len(), 128);
    }

    #[test]
    fn test_hmac_base64_sha256() {
        let result = hmac_base64("hello", "SHA-256", "key").unwrap();
        // Should be valid base64
        assert!(!result.is_empty());
        // Verify it's valid base64 by decoding
        use base64::Engine;
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&result)
            .unwrap();
        assert_eq!(decoded.len(), 32); // SHA-256 output is 32 bytes
    }

    #[test]
    fn test_str_to_bytes_utf8() {
        let result = str_to_bytes("Hello", None).unwrap();
        assert_eq!(result, "[72,101,108,108,111]");
    }

    #[test]
    fn test_str_to_bytes_gbk() {
        let result = str_to_bytes("中", Some("GBK")).unwrap();
        // "中" in GBK is [0xD6, 0xD0] = [214, 208]
        assert_eq!(result, "[214,208]");
    }

    #[test]
    fn test_bytes_to_str_utf8() {
        let result = bytes_to_str("[72,101,108,108,111]", None).unwrap();
        assert_eq!(result, "Hello");
    }

    #[test]
    fn test_bytes_to_str_gbk() {
        let result = bytes_to_str("[214,208]", Some("GBK")).unwrap();
        assert_eq!(result, "中");
    }

    #[test]
    fn test_str_to_bytes_roundtrip() {
        let original = "Hello, 世界!";
        let bytes_json = str_to_bytes(original, Some("UTF-8")).unwrap();
        let recovered = bytes_to_str(&bytes_json, Some("UTF-8")).unwrap();
        assert_eq!(recovered, original);
    }
}
