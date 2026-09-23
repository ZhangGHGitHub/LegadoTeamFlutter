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
        .or_default()
        .insert(key.to_string(), value.to_string());
}

/// clearCookies(tag) — 清除指定 tag 的 Cookie
pub fn clear_cookies(tag: &str) {
    let mut store = GLOBAL_COOKIES.lock().unwrap();
    store.remove(tag);
}

/// P2-19：序列化「当前书源」的 JS ajax 请求应携带的 Cookie
///
/// 取代旧版 `all_cookies()` 全量合并（把**所有书源**的 Cookie 拼进每个请求，
/// 导致源 A 的脚本携带源 B 的会话 cookie —— 跨源泄漏）。新口径：
///
/// - `tag = None`（**未归属上下文**：payAction / 登录 / 回调 / 独立 eval 等
///   非书源驱动路径，线程局部无当前书源）→ 返回空串，即**不携带任何
///   JS 宿主存储 cookie**。安全默认：无法归属时宁可不带、不得错带——
///   全量合并正是泄漏源；HTTP 层按域 Cookie（`legado-net` 的
///   `CookieStore`，ETLD+1 键）不受本存储影响，照常随请求 URL 附带。
/// - `tag = Some(tag)` → 合并两个来源，**同名键精确键胜出**：
///   1. 精确 tag 本身（book_source_url 精确键——FFI 读取路径
///      `get_cookie(source.book_source_url)` 的约定，也是 JS 规则
///      `java.setCookie(url, ...)` 的主写入形态）；
///   2. tag 对应的 ETLD+1 域名键（FFI `clear_cookie` 以
///      `domain_key_from_host` 清理 JS 存储的约定；复用 `legado-net`
///      键函数同一真源，避免宿主层与 HTTP 层口径漂移）。
///
/// 返回 `name1=value1; name2=value2`（无则为空串）。
pub fn cookies_for_source_tag(tag: Option<&str>) -> String {
    let Some(tag) = tag else {
        return String::new();
    };
    let tag = tag.trim();
    if tag.is_empty() {
        return String::new();
    }
    let store = GLOBAL_COOKIES.lock().unwrap();
    // 先合并域名键（继承条目），再以精确键覆盖（源自身显式写入更具体）
    let mut merged: HashMap<String, String> = HashMap::new();
    if let Some(key) = domain_key_for_tag(tag).filter(|k| k.as_str() != tag) {
        if let Some(map) = store.get(&key) {
            for (name, value) in map {
                merged.insert(name.clone(), value.clone());
            }
        }
    }
    if let Some(map) = store.get(tag) {
        for (name, value) in map {
            merged.insert(name.clone(), value.clone());
        }
    }
    merged
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// 由 tag 推导 ETLD+1 域名键（复用 HTTP 层单一真源，避免两处口径漂移）
///
/// quickjs 档启用 `legado-net` 可选依赖：URL 形态经
/// [`legado_net::cookie_store::cookie_domain_key`]（URL 解析取 host），
/// 裸 host 形态（无 scheme，可带 `:port` / IPv6 `[...]` 括号）剥掉端口与
/// 括号后经 [`legado_net::cookie_store::domain_key_from_host`]——与 HTTP 层
/// Cookie 存储、FFI `get_sub_domain` / `clear_cookie` 完全同一套键规则
/// （IP 字面量自键、多段 TLD 取末三段、其余取末两段、单段兜底自身）。
#[cfg(feature = "quickjs")]
fn domain_key_for_tag(tag: &str) -> Option<String> {
    use legado_net::cookie_store::{cookie_domain_key, domain_key_from_host};
    // URL 形态（带 scheme）：URL 解析器取 host
    if let Some(key) = cookie_domain_key(tag) {
        return Some(key);
    }
    // 裸 host / 裸域名形态（如 `a.example.com`、`a.example.com:8080`、`[::1]`）
    let host = if tag.starts_with('[') {
        // IPv6 括号形式：取 `[` 与 `]` 之间（整体含冒号，不能按 ':' 切）
        tag.find(']')
            .map(|end| &tag[..end])
            .unwrap_or(tag)
            .to_string()
    } else {
        // 剥掉 `:port`
        tag.split(':').next().unwrap_or(tag).to_string()
    };
    Some(domain_key_from_host(&host))
}

/// 默认档（未启用 quickjs，无 `legado-net` 依赖）降级：不推导域名键，
/// 仅按精确 tag 匹配。可接受——JS 宿主存储的主写入/读取路径均以
/// book_source_url 精确键为主；域名键形态仅 FFI `clear_cookie` 会用到，
/// 而该路径只在 quickjs 档编译。
#[cfg(not(feature = "quickjs"))]
fn domain_key_for_tag(_tag: &str) -> Option<String> {
    None
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
        let tag = "cookie_set_get";
        set_cookie(tag, "session", "abc123");
        assert_eq!(get_cookie_by_key(tag, "session"), "abc123");
        assert!(get_cookie(tag).contains("session=abc123"));
    }

    #[test]
    fn test_multiple_cookies() {
        let tag = "cookie_multi";
        set_cookie(tag, "session", "abc");
        set_cookie(tag, "token", "xyz");
        let all = get_cookie(tag);
        assert!(all.contains("session=abc"));
        assert!(all.contains("token=xyz"));
    }

    #[test]
    fn test_tag_isolation() {
        let tag1 = "cookie_iso_1";
        let tag2 = "cookie_iso_2";
        set_cookie(tag1, "key", "val1");
        set_cookie(tag2, "key", "val2");
        assert_eq!(get_cookie_by_key(tag1, "key"), "val1");
        assert_eq!(get_cookie_by_key(tag2, "key"), "val2");
    }

    #[test]
    fn test_missing_cookie() {
        assert_eq!(get_cookie_by_key("cookie_never_set", "key"), "");
        assert_eq!(get_cookie("cookie_never_set"), "");
    }

    #[test]
    fn test_clear_cookies() {
        let tag = "cookie_clear_target";
        set_cookie(tag, "key", "val");
        clear_cookies(tag);
        assert_eq!(get_cookie(tag), "");
    }

    /// P2-19：未归属上下文（None / 空 tag）不携带任何 JS 宿主存储 cookie（安全默认）
    #[test]
    fn test_p219_unowned_tag_returns_empty() {
        set_cookie("p219_none_tag", "k", "v");
        assert_eq!(cookies_for_source_tag(None), "");
        assert_eq!(cookies_for_source_tag(Some("")), "");
        clear_cookies("p219_none_tag");
    }

    /// P2-19：精确 tag 命中（单段裸 tag 自键，两档行为一致）
    #[test]
    fn test_p219_exact_tag_hit() {
        set_cookie("p219_exact", "tk", "v1");
        let out = cookies_for_source_tag(Some("p219_exact"));
        assert!(out.contains("tk=v1"), "精确键 cookie 必须携带: {out}");
        clear_cookies("p219_exact");
    }

    /// P2-19：多段 TLD（com.cn）——域名键取末三段（ETLD+1 = book.com.cn，
    /// 前缀 a/b 是子域不属于注册域），不得回落末两段（com.cn）——与 HTTP 层
    /// MULTI_LABEL_TLDS 口径一致
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_multi_label_tld_domain_key() {
        // host a.b.book.com.cn：com.cn 为多段公共后缀 → 键取末三段
        const TAG: &str = "https://a.b.book.com.cn/search";
        set_cookie("book.com.cn", "p219_dk", "dk-val");
        // 末两段裸后缀键不得参与（多段 TLD 必须取末三段的证据）
        set_cookie("com.cn", "p219_suffix", "suffix-val");
        let out = cookies_for_source_tag(Some(TAG));
        assert!(
            out.contains("p219_dk=dk-val"),
            "ETLD+1（book.com.cn）cookie 必须携带: {out}"
        );
        assert!(
            !out.contains("p219_suffix"),
            "两段 TLD（com.cn）键不得参与: {out}"
        );
        clear_cookies("book.com.cn");
        clear_cookies("com.cn");
    }

    /// P2-19：IP 字面量 host（含 :port）——域名键为 IP 自身（对齐 HTTP 层）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ip_literal_domain_key() {
        set_cookie("192.168.1.10", "p219_ip", "ip-val");
        let out = cookies_for_source_tag(Some("http://192.168.1.10:8080/api"));
        assert!(
            out.contains("p219_ip=ip-val"),
            "IP 字面量键 cookie 必须携带: {out}"
        );
        clear_cookies("192.168.1.10");
    }

    /// P2-19：裸域名 tag（无 scheme，带 :port）也按同一键规则解析到 ETLD+1
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_bare_domain_tag() {
        set_cookie("example.com", "p219_bare", "bare-val");
        let out = cookies_for_source_tag(Some("a.example.com:8080"));
        assert!(
            out.contains("p219_bare=bare-val"),
            "裸域名 tag 的 ETLD+1（example.com）cookie 必须携带: {out}"
        );
        clear_cookies("example.com");
    }

    /// P2-19：精确键与域名键同名冲突时精确键（源自身显式写入）胜出
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_exact_key_wins_over_domain_key() {
        // host c.d.shop.co.uk：co.uk 为多段公共后缀 → 域名键取末三段 shop.co.uk
        const TAG: &str = "https://c.d.shop.co.uk/";
        set_cookie("shop.co.uk", "dup", "domain-v");
        set_cookie(TAG, "dup", "exact-v");
        let out = cookies_for_source_tag(Some(TAG));
        assert!(out.contains("dup=exact-v"), "精确键必须胜出: {out}");
        assert!(
            !out.contains("domain-v"),
            "域名键同名值必须被精确键覆盖: {out}"
        );
        clear_cookies(TAG);
        clear_cookies("shop.co.uk");
    }
}
