//! 字体 API
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 queryTTF / replaceFont / queryBase64TTF 方法。
//!
//! # 实现说明
//!
//! Kotlin 端使用 `QueryTTF` 类解析 TTF 字体文件，通过 cmap 表建立
//! 错误字符 → 正确字符的映射关系，用于修复防爬字体反爬。
//!
//! Rust 端当前无纯 Rust TTF cmap 解析能力（`ttf-parser` 不包含 cmap 映射），
//! 因此实现策略如下：
//! - `query_ttf` / `query_base64_ttf`：返回结构化 JSON 字体句柄（含类型标识），
//!   供 `replace_font` 消费；实际 cmap 解析由 Flutter 侧完成。
//! - `replace_font`：若句柄有效则原样返回文本（占位），等待 Flutter 侧注入真实映射。

use std::collections::HashMap;
use std::sync::Mutex;

/// 全局字体句柄缓存（font_id → 字体元数据 JSON）
static FONT_CACHE: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

/// 获取或初始化字体缓存
fn get_cache() -> std::sync::MutexGuard<'static, Option<HashMap<String, String>>> {
    let mut guard = FONT_CACHE.lock().unwrap();
    if guard.is_none() {
        *guard = Some(HashMap::new());
    }
    guard
}

/// queryTTF(data, useCache?) → 字体查询句柄 JSON
///
/// 对应 Kotlin: `queryTTF(data: Any?, useCache: Boolean): QueryTTF?`
///
/// `data` 支持 URL / 本地文件路径 / Base64 字符串（自动判断）。
/// 返回 JSON 句柄，供 `replaceFont` 使用；若 data 为空则返回 "null"。
///
/// 返回格式：
/// ```json
/// {"fontId":"...","type":"url|file|base64","data":"...","valid":true}
/// ```
pub fn query_ttf(data: &str, use_cache: bool) -> String {
    if data.is_empty() {
        return "null".to_string();
    }

    // 生成缓存 key（使用简单 hash 避免依赖额外 crate）
    let cache_key = format!("{:x}", simple_hash(data));

    // 检查缓存
    if use_cache {
        let guard = get_cache();
        if let Some(cache) = guard.as_ref() {
            if let Some(cached) = cache.get(&cache_key) {
                return cached.clone();
            }
        }
    }

    // 判断数据类型
    let font_type = if data.starts_with("http://") || data.starts_with("https://") {
        "url"
    } else if data.starts_with('/')
        || data.starts_with("file://")
        || (data.len() > 2 && data[1..].starts_with(":\\"))
    {
        "file"
    } else {
        "base64"
    };

    let handle = serde_json::json!({
        "fontId": cache_key,
        "type": font_type,
        "data": data,
        "valid": true,
        "note": "Rust 桩化实现：cmap 映射需由 Flutter 侧 ttf-parser 提供"
    })
    .to_string();

    // 写入缓存
    if use_cache {
        let mut guard = get_cache();
        if let Some(cache) = guard.as_mut() {
            cache.insert(cache_key, handle.clone());
        }
    }

    handle
}

/// queryBase64TTF(data) → 字体查询句柄 JSON（已废弃，等价于 queryTTF）
///
/// 对应 Kotlin: `@Deprecated queryBase64TTF(data: String?): QueryTTF?`
/// Kotlin 端已标注废弃，建议改用 `queryTTF`；此处保留兼容性。
pub fn query_base64_ttf(data: &str) -> String {
    query_ttf(data, true)
}

/// replaceFont(text, errorFontData, correctFontData, filter?) → 替换后文本
///
/// 对应 Kotlin: `replaceFont(text, errorQueryTTF, correctQueryTTF, filter): String`
///
/// Kotlin 端通过解析两个 TTF 字体的 cmap 表，将错误字符映射为正确字符。
/// Rust 端当前为桩化实现：验证句柄有效性后原样返回文本。
/// 完整实现需引入 TTF cmap 解析能力（建议由 Flutter 侧注入映射表）。
pub fn replace_font(
    text: &str,
    error_font_data: &str,
    correct_font_data: &str,
    filter: bool,
) -> String {
    // 任一句柄为空或 null 时直接返回原文
    if error_font_data.is_empty()
        || error_font_data == "null"
        || correct_font_data.is_empty()
        || correct_font_data == "null"
    {
        return text.to_string();
    }

    // 尝试解析句柄 JSON，验证有效性
    let error_valid = serde_json::from_str::<serde_json::Value>(error_font_data)
        .map(|v| v.get("valid").and_then(|b| b.as_bool()).unwrap_or(false))
        .unwrap_or(false);

    let correct_valid = serde_json::from_str::<serde_json::Value>(correct_font_data)
        .map(|v| v.get("valid").and_then(|b| b.as_bool()).unwrap_or(false))
        .unwrap_or(false);

    if !error_valid || !correct_valid {
        return text.to_string();
    }

    // 桩化实现：无 cmap 映射表，原样返回
    // TODO: 接入 Flutter 侧 TTF cmap 解析，实现真实字符替换
    let _ = filter; // filter 参数在真实实现中用于删除 errorFont 中不存在的字符
    text.to_string()
}

/// 简单字符串 hash（FNV-1a 64 位变体，用于生成字体缓存 key）
fn simple_hash(s: &str) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in s.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_ttf_empty() {
        assert_eq!(query_ttf("", true), "null");
    }

    #[test]
    fn test_query_ttf_url() {
        let result = query_ttf("https://example.com/font.ttf", false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "url");
        assert_eq!(parsed["valid"], true);
        assert!(parsed["fontId"].is_string());
    }

    #[test]
    fn test_query_ttf_file() {
        let result = query_ttf("/fonts/custom.ttf", false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "file");
    }

    #[test]
    fn test_query_ttf_base64() {
        let result = query_ttf("AAECAwQF", false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "base64");
    }

    #[test]
    fn test_query_ttf_cache() {
        // 相同 data 使用缓存应返回相同结果
        let r1 = query_ttf("https://cache-test.com/font.ttf", true);
        let r2 = query_ttf("https://cache-test.com/font.ttf", true);
        assert_eq!(r1, r2);
    }

    #[test]
    fn test_query_base64_ttf() {
        let result = query_base64_ttf("AAECAwQF");
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_replace_font_null_handles() {
        assert_eq!(replace_font("hello", "null", "null", false), "hello");
        assert_eq!(replace_font("hello", "", "", false), "hello");
    }

    #[test]
    fn test_replace_font_stub_returns_original() {
        let err_font = query_ttf("https://example.com/error.ttf", false);
        let ok_font = query_ttf("https://example.com/correct.ttf", false);
        // 桩化实现：原样返回
        assert_eq!(replace_font("测试文本", &err_font, &ok_font, false), "测试文本");
    }

    #[test]
    fn test_simple_hash_deterministic() {
        assert_eq!(simple_hash("hello"), simple_hash("hello"));
        assert_ne!(simple_hash("hello"), simple_hash("world"));
    }
}
