//! Cookie 存储 API
//!
//! 对应 Kotlin JsExtensions.kt 中的 getCookie(tag) / getCookie(tag, key)

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// 全局 Cookie 存储（按 tag 隔离）
static GLOBAL_COOKIES: LazyLock<Mutex<HashMap<String, HashMap<String, String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// getCookie(tag) — 获取指定 tag 的所有 Cookie（格式: "key1=value1; key2=value2"）
pub fn get_cookie(tag: &str) -> String {
    let store = GLOBAL_COOKIES.lock().unwrap();
    if let Some(cookies) = store.get(tag) {
        cookies
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join("; ")
    } else {
        String::new()
    }
}

/// getCookie(tag, key) — 获取指定 tag 下指定 key 的 Cookie 值
pub fn get_cookie_by_key(tag: &str, key: &str) -> String {
    let store = GLOBAL_COOKIES.lock().unwrap();
    store
        .get(tag)
        .and_then(|cookies| cookies.get(key))
        .cloned()
        .unwrap_or_default()
}

/// setCookie(tag, key, value) — 设置 Cookie（供内部使用）
pub fn set_cookie(tag: &str, key: &str, value: &str) {
    let mut store = GLOBAL_COOKIES.lock().unwrap();
    store
        .entry(tag.to_string())
        .or_insert_with(HashMap::new)
        .insert(key.to_string(), value.to_string());
}

/// clearCookies(tag) — 清除指定 tag 的 Cookie
pub fn clear_cookies(tag: &str) {
    let mut store = GLOBAL_COOKIES.lock().unwrap();
    store.remove(tag);
}

/// clearAllCookies() — 清除所有 Cookie
pub fn clear_all_cookies() {
    let mut store = GLOBAL_COOKIES.lock().unwrap();
    store.clear();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_cookie() {
        clear_all_cookies();
        set_cookie("source1", "session", "abc123");
        assert_eq!(get_cookie_by_key("source1", "session"), "abc123");
        assert!(get_cookie("source1").contains("session=abc123"));
    }

    #[test]
    fn test_multiple_cookies() {
        clear_all_cookies();
        set_cookie("source1", "session", "abc");
        set_cookie("source1", "token", "xyz");
        let all = get_cookie("source1");
        assert!(all.contains("session=abc"));
        assert!(all.contains("token=xyz"));
    }

    #[test]
    fn test_tag_isolation() {
        clear_all_cookies();
        set_cookie("source1", "key", "val1");
        set_cookie("source2", "key", "val2");
        assert_eq!(get_cookie_by_key("source1", "key"), "val1");
        assert_eq!(get_cookie_by_key("source2", "key"), "val2");
    }

    #[test]
    fn test_missing_cookie() {
        clear_all_cookies();
        assert_eq!(get_cookie_by_key("nonexistent", "key"), "");
        assert_eq!(get_cookie("nonexistent"), "");
    }

    #[test]
    fn test_clear_cookies() {
        clear_all_cookies();
        set_cookie("source1", "key", "val");
        clear_cookies("source1");
        assert_eq!(get_cookie("source1"), "");
    }
}
