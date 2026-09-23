//! Cookie 存储 API
//!
//! 对应 Kotlin JsExtensions.kt 中的 getCookie(url) / getCookie(url, key)
//! 与 `CookieStore.setCookie(url, cookie)`。
//!
//! # 上游同步（2026-09-23 用户裁决）：cookie 属于域名，不属于书源
//!
//! - **写侧归一**：`set_cookie(url, …)` 的键按上游 `NetworkUtils.getSubDomain(url)`
//!   等价规则归一为 ETLD+1 域名键（http(s) URL → 域名键；非 http(s) 串 / 解析
//!   失败 → 保留原串，对齐上游 `getSubDomain` 回退）；
//! - **读侧按请求 URL 取**：[`cookies_for_url`] 以请求 URL 的域名键取 cookie
//!   （对齐上游 `CookieManager.loadRequest` 的 `getSubDomain(request.url)` 口径），
//!   **去掉书源 tag 维度**——同域 cookie 跨书源共享；不相关域名的 cookie
//!   绝不携带（P2-19 不变式保留）。取代 P2-19 的 `cookies_for_source_tag`
//!   （含「未归属不携带」收紧——本批取消：未归属上下文也携带请求域 cookie）。
//!
//! 键规则单一真源：[`legado_net::cookie_store::cookie_domain_key`] /
//! [`legado_net::cookie_store::domain_key_from_host`]（与 HTTP 层 Cookie 存储、
//! FFI `get_sub_domain` / `clear_cookie` 同一套 ETLD+1 规则，不另写第二套）。

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// 全局 Cookie 存储（按域名键 / 原始串键隔离；值为 name → value 映射）
static GLOBAL_COOKIES: LazyLock<Mutex<HashMap<String, HashMap<String, String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 测试专用（双档）：进程级 cookie 存储串行锁（跨测试模块共享——回环
/// 域名键 `127.0.0.1` 与常见域名键（`book.com.cn` 等）被 cookie_store.rs / network.rs /
/// source_engine.rs 等多处用例共用；
/// 中毒恢复语义同 `legado-ffi::test_support::GLOBAL_STORE_TEST_LOCK`）
#[cfg(test)]
pub(crate) static COOKIE_STORE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 测试专用（双档）：取 [`COOKIE_STORE_TEST_LOCK`] 的 guard（中毒即恢复复用）
#[cfg(test)]
pub(crate) fn lock_cookie_store_test() -> std::sync::MutexGuard<'static, ()> {
    COOKIE_STORE_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

/// 取全局 cookie store 锁（毒化即 `into_inner` 恢复复用——持锁侧 panic
/// 不应令存储永久不可用；与测试锁 `lock_cookie_store_test` 同一恢复语义）
fn lock_store() -> std::sync::MutexGuard<'static, HashMap<String, HashMap<String, String>>> {
    GLOBAL_COOKIES.lock().unwrap_or_else(|e| e.into_inner())
}

/// Cookie 键归一（上游 `NetworkUtils.getSubDomain` 等价规则）
///
/// - http(s) URL（大小写不敏感，对齐上游 `getBaseUrl` 的 `startsWith("http://", true)`）
///   → ETLD+1 域名键，复用 [`legado_net::cookie_store::cookie_domain_key`] 单一真源
///   （URL 解析取 host → `domain_key_from_host`：IP 字面量自键、多段 TLD 末三段、
///   其余末两段、单段兜底自身）；解析失败 → 保留原串（对齐上游异常回退 `baseUrl`
///   的「失败即退回原输入」方向，本实现退回未 trim 前的 trim 串）；
/// - 非 http(s) 串（裸 host / 裸域名 / 任意非 URL 形态）→ 保留原串
///   （对齐上游 `getSubDomain`：`getBaseUrl` 返回 null → 原样返回 url）。
#[cfg(feature = "quickjs")]
fn normalize_cookie_key(input: &str) -> String {
    use legado_net::cookie_store::cookie_domain_key;
    let input = input.trim();
    let lower = input.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return cookie_domain_key(input).unwrap_or_else(|| input.to_string());
    }
    input.to_string()
}

/// 默认档（未启用 quickjs，无 `legado-net` 依赖）降级：不推导域名键，
/// 键为 trim 后的原串（与 P2-19 前「精确键」行为一致，域名键形态仅
/// quickjs 档的 FFI `clear_cookie` / 读侧路径使用）。
#[cfg(not(feature = "quickjs"))]
fn normalize_cookie_key(input: &str) -> String {
    input.trim().to_string()
}

/// 读侧键候选合并：域名键条目先入（继承/域级写入），原始串条目覆盖
///（更具体 / 历史原始串键胜出——延续 P2-19「精确键胜出」方向；归一后
/// 新写入必落域名键，原始串候选仅覆盖历史遗留的原始键与「归一结果
/// 恰为原串」的非 URL 输入）
fn merge_cookie_entries(
    store: &HashMap<String, HashMap<String, String>>,
    input: &str,
) -> HashMap<String, String> {
    let raw = input.trim().to_string();
    let norm = normalize_cookie_key(input);
    let mut merged: HashMap<String, String> = HashMap::new();
    if norm != raw {
        if let Some(map) = store.get(&norm) {
            for (name, value) in map {
                merged.insert(name.clone(), value.clone());
            }
        }
    }
    if let Some(map) = store.get(&raw) {
        for (name, value) in map {
            merged.insert(name.clone(), value.clone());
        }
    }
    merged
}

fn format_cookies(cookies: &HashMap<String, String>) -> String {
    cookies
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// getCookie(url) — 获取 URL 所属域（getSubDomain 等价域名键）的全部 Cookie
///（格式: "key1=value1; key2=value2"；历史原始串键同名时胜出）
pub fn get_cookie(url: &str) -> String {
    let store = lock_store();
    format_cookies(&merge_cookie_entries(&store, url))
}

/// getCookie(url, key) — 获取 URL 所属域下指定 key 的 Cookie 值
pub fn get_cookie_by_key(url: &str, key: &str) -> String {
    let store = lock_store();
    merge_cookie_entries(&store, url)
        .get(key)
        .cloned()
        .unwrap_or_default()
}

/// setCookie(url, key, value) — 设置 Cookie（写侧归一：http(s) URL 键归一为
/// ETLD+1 域名键，对齐上游 `CookieStore.setCookie(url, cookie)` 的
/// `domain = getSubDomain(url)` 落库口径）
pub fn set_cookie(url: &str, key: &str, value: &str) {
    let domain_key = normalize_cookie_key(url);
    let mut store = lock_store();
    store
        .entry(domain_key)
        .or_default()
        .insert(key.to_string(), value.to_string());
}

/// clearCookies(url) — 清除该 URL 归一域名键的 Cookie，并连带清除
///（不同的）原始串键——覆盖历史遗留的原始 URL 形态键（兼容：存储为
/// 内存态、无迁移负担，读侧同时尝试两候选，清理侧同样两键齐清）
pub fn clear_cookies(url: &str) {
    let raw = url.trim().to_string();
    let norm = normalize_cookie_key(url);
    let mut store = lock_store();
    store.remove(&raw);
    if norm != raw {
        store.remove(&norm);
    }
}

/// 上游同步（2026-09-23）：序列化请求应携带的 JS 宿主存储 Cookie——
/// 按**请求 URL** 取（对齐上游 `CookieManager.loadRequest` 的
/// `getSubDomain(request.url)` 口径），**无书源 tag 维度**：
///
/// - 请求 URL 的 ETLD+1 域名键条目 +（不同的）请求 URL 原始串条目
///   （历史兼容，原始串胜出）合并为 `name1=value1; name2=value2`（无则空串）；
/// - 同域不同书源共享（cookie 属于域名）；**不相关域名的 cookie 绝不
///   携带**（P2-19 不变式保留）；
/// - 取代 P2-19 `cookies_for_source_tag` 的「未归属不携带」收紧
///   （本批取消，用户裁决）：未归属上下文（字典规则 / 自动任务等）
///   也按请求 URL 所属域携带。
pub fn cookies_for_url(url: &str) -> String {
    let url = url.trim();
    if url.is_empty() {
        return String::new();
    }
    let store = lock_store();
    format_cookies(&merge_cookie_entries(&store, url))
}

/// clearAllCookies() — 清除所有 Cookie
pub fn clear_all_cookies() {
    let mut store = lock_store();
    store.clear();
}

/// 将 JS 宿主 cookie 按**键**合并进请求头（对齐上游 `AnalyzeUrl.setCookie`
/// → `CookieManager.mergeCookies` 的按键合并语义：已有同名键胜、非冲突
/// JS 键追加——上游反例：静态 `Cookie: a=1` + JS 写 `b=2` → 发
/// `a=1; b=2`，而非整条丢弃 JS cookie）：
///
/// - 取请求 URL 属域的 JS cookie 串（[`cookies_for_url`]；空 → no-op）；
/// - 已有 Cookie 头（**大小写不敏感**键匹配，覆盖 Cookie/cookie/COOKIE
///   等变体）：按 `;` 拆出已有 cookie 名集，非冲突 JS 键按序追加；
///   结果写回**原键**（保留原键大小写），不新插第二键；
/// - 无已有 Cookie 键 → 直接插 `"Cookie"` 键。
pub fn merge_js_cookies(headers: &mut HashMap<String, String>, url: &str) {
    let js_cookie = cookies_for_url(url);
    if js_cookie.is_empty() {
        return;
    }
    let existing_key = headers
        .keys()
        .find(|k| k.eq_ignore_ascii_case("cookie"))
        .cloned();
    match existing_key {
        Some(key) => {
            let existing = headers.get(&key).map(String::as_str).unwrap_or("");
            // 已有 cookie 名集（cookie 名大小写敏感：按 `;` 拆段取 `=` 前）
            let mut existing_names: std::collections::HashSet<String> = existing
                .split(';')
                .filter_map(|part| {
                    let part = part.trim();
                    if part.is_empty() {
                        return None;
                    }
                    Some(part.split('=').next()?.to_string())
                })
                .collect();
            // 非冲突 JS 键按序追加（同名跳过——已有键胜）
            let mut extra = String::new();
            for pair in js_cookie.split("; ") {
                let name = match pair.split_once('=') {
                    Some((n, _)) => n,
                    None => continue,
                };
                if existing_names.insert(name.to_string()) {
                    if !extra.is_empty() {
                        extra.push_str("; ");
                    }
                    extra.push_str(pair);
                }
            }
            if !extra.is_empty() {
                let combined = if existing.trim().is_empty() {
                    extra
                } else {
                    format!("{existing}; {extra}")
                };
                headers.insert(key, combined);
            }
        }
        None => {
            headers.insert("Cookie".to_string(), js_cookie);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_and_get_cookie() {
        let _lock = lock_cookie_store_test();
        let tag = "cookie_set_get";
        set_cookie(tag, "session", "abc123");
        assert_eq!(get_cookie_by_key(tag, "session"), "abc123");
        assert!(get_cookie(tag).contains("session=abc123"));
    }

    #[test]
    fn test_multiple_cookies() {
        let _lock = lock_cookie_store_test();
        let tag = "cookie_multi";
        set_cookie(tag, "session", "abc");
        set_cookie(tag, "token", "xyz");
        let all = get_cookie(tag);
        assert!(all.contains("session=abc"));
        assert!(all.contains("token=xyz"));
    }

    #[test]
    fn test_tag_isolation() {
        let _lock = lock_cookie_store_test();
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
        let _lock = lock_cookie_store_test();
        let tag = "cookie_clear_target";
        set_cookie(tag, "key", "val");
        clear_cookies(tag);
        assert_eq!(get_cookie(tag), "");
    }

    /// 上游同步：空 / 空白 URL 取不到任何 cookie（无请求即无域名键）
    #[test]
    fn test_cookies_for_url_empty_returns_empty() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_none_url", "k", "v");
        assert_eq!(cookies_for_url(""), "");
        assert_eq!(cookies_for_url("   "), "");
        clear_cookies("p219_none_url");
    }

    /// 非 URL 形态的原始串键（两档行为一致：归一为 trim 原串，自键命中）
    #[test]
    fn test_raw_string_key_hit() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_exact", "tk", "v1");
        let out = cookies_for_url("p219_exact");
        assert!(out.contains("tk=v1"), "原始串键 cookie 必须携带: {out}");
        clear_cookies("p219_exact");
    }

    /// 多段 TLD（com.cn）——域名键取末三段（ETLD+1 = book.com.cn，
    /// 前缀 a/b 是子域不属于注册域），不得回落末两段（com.cn）——与 HTTP 层
    /// MULTI_LABEL_TLDS 口径一致
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_multi_label_tld_domain_key() {
        // host a.b.book.com.cn：com.cn 为多段公共后缀 → 键取末三段
        let _lock = lock_cookie_store_test();
        const URL: &str = "https://a.b.book.com.cn/search";
        set_cookie("book.com.cn", "p219_dk", "dk-val");
        // 末两段裸后缀键不得参与（多段 TLD 必须取末三段的证据）
        set_cookie("com.cn", "p219_suffix", "suffix-val");
        let out = cookies_for_url(URL);
        assert!(
            out.contains("p219_dk=dk-val"),
            "ETLD+1（book.com.cn）cookie 必须携带: {out}"
        );
        assert!(
            !out.contains("p219_suffix"),
            "两段 TLD（com.cn）键不得参与: {out}"
        );
        clear_cookies(URL);
        clear_cookies("com.cn");
    }

    /// IP 字面量 host（含 :port）——域名键为 IP 自身（对齐 HTTP 层）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_ip_literal_domain_key() {
        let _lock = lock_cookie_store_test();
        set_cookie("192.168.1.10", "p219_ip", "ip-val");
        let out = cookies_for_url("http://192.168.1.10:8080/api");
        assert!(
            out.contains("p219_ip=ip-val"),
            "IP 字面量键 cookie 必须携带: {out}"
        );
        clear_cookies("192.168.1.10");
    }

    /// 上游同步：裸 host 串（无 scheme，可带 :port）按上游 `getSubDomain`
    /// 回退规则**自键**（`getBaseUrl` 返回 null → 原样返回输入）——不再
    /// 推导 ETLD+1（P2-19 旧口径已废）：写「a.example.com:8080」命中读
    /// 「a.example.com:8080」，而 URL 形态读归一到 example.com，两者不串。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_bare_host_string_is_self_keyed() {
        let _lock = lock_cookie_store_test();
        const BARE: &str = "a.example.com:8080";
        const URL_FORM: &str = "https://a.example.com:8080/";
        set_cookie(BARE, "p219_bare", "bare-val");
        set_cookie("example.com", "p219_url_dk", "url-val");
        let out_bare = cookies_for_url(BARE);
        assert!(
            out_bare.contains("p219_bare=bare-val"),
            "裸 host 串自键命中: {out_bare}"
        );
        assert!(
            !out_bare.contains("p219_url_dk"),
            "裸 host 串自键，不得串到 ETLD+1 域名键: {out_bare}"
        );
        let out_url = cookies_for_url(URL_FORM);
        assert!(
            out_url.contains("p219_url_dk=url-val"),
            "URL 形态读归一 ETLD+1（example.com）命中: {out_url}"
        );
        assert!(
            !out_url.contains("p219_bare"),
            "URL 形态读不得串到裸 host 串键: {out_url}"
        );
        clear_cookies(BARE);
        clear_cookies("example.com");
    }

    /// 上游同步：同域同名 cookie 后写覆盖先写（归一后两次写入落同一域名键，
    /// 对齐上游 `CookieStore` REPLACE 语义；按 name 合并时后写胜出）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_same_domain_same_name_last_write_wins() {
        // host c.d.shop.co.uk：co.uk 为多段公共后缀 → 域名键取末三段 shop.co.uk
        let _lock = lock_cookie_store_test();
        const URL: &str = "https://c.d.shop.co.uk/";
        set_cookie("shop.co.uk", "dup", "domain-v");
        set_cookie(URL, "dup", "exact-v");
        let out = cookies_for_url(URL);
        assert!(out.contains("dup=exact-v"), "后写必须覆盖: {out}");
        assert!(!out.contains("domain-v"), "先写同名值必须被覆盖: {out}");
        clear_cookies(URL);
        clear_cookies("shop.co.uk");
    }

    // ─── 上游同步（2026-09-23 用户裁决）：cookie 属于域名，不属于书源 ─────────────
    //
    // 以下用例按上游语义（写侧归一 `getSubDomain(url)` 域名键、读侧按请求 URL 取、
    // 去掉书源 tag 维度）断言。场景①/②/⑤ 改前按旧 `cookies_for_source_tag`
    // （tag 维度）行为为红（红输出见批次报告），改造后转绿。

    /// 上游同步场景①：同域跨书源共享——源 A 写 cookie，同注册域的源 B 请求
    /// 该域 URL 必须携带（cookie 属于域名，跨书源共享）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_same_domain_cross_source_sharing() {
        // host www.usa-shop-a.com.cn / api.usa-shop-a.com.cn：com.cn 多段 TLD
        // → 域名键取末三段 usa-shop-a.com.cn（同一注册域，两个不同书源 URL）
        let _lock = lock_cookie_store_test();
        const SRC_A: &str = "https://www.usa-shop-a.com.cn/";
        const SRC_B: &str = "https://api.usa-shop-a.com.cn/login";
        const DK: &str = "usa-shop-a.com.cn";
        clear_cookies(SRC_A);
        clear_cookies(DK);
        set_cookie(SRC_A, "p219_sync", "sync-val-8d21");
        // 源 B 上下文请求同域 URL（读侧按请求 URL 归一域名键，与书写者无关）
        let out = cookies_for_url(SRC_B);
        assert!(
            out.contains("p219_sync=sync-val-8d21"),
            "同域跨书源必须共享 cookie（上游语义：cookie 属于域名）: {out}"
        );
        clear_cookies(SRC_A);
        clear_cookies(DK);
    }

    /// 上游同步场景②：非本源 URL 写的 cookie（`java.setCookie('https://api.…', …)`
    /// 第三方域写入缺口）——后续请求该域必须携带（改前缺口：写落原始串键，
    /// 读按 tag / 未归属取 → 落空）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_thirdparty_url_cookie_carried() {
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "https://api.usa-thirdparty.com/";
        const REQ_URL: &str = "https://api.usa-thirdparty.com/v2/items";
        const DK: &str = "usa-thirdparty.com";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_tp", "tp-val-4b7c");
        // 请求该域的其他 URL（不同路径）：写读两侧归一到同一域名键
        let out = cookies_for_url(REQ_URL);
        assert!(
            out.contains("p219_tp=tp-val-4b7c"),
            "按请求 URL 属域取 cookie 时，第三方域写入的 cookie 必须携带: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }

    /// 上游同步场景⑤：无书源上下文的 JS 执行路径（字典规则/自动任务）向某域
    /// 发请求时携带该域 cookie——P2-19 的「未归属不携带」收紧本批取消
    ///（用户裁决同步上游：上游 `CookieManager.loadRequest` 按请求 URL 取 cookie，
    /// 与书源上下文无关）。
    /// 纯单测（无网络）：127.0.0.3 的域名键为 IP 自身。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_upstream_sync_unowned_context_carries_request_domain_cookie() {
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "http://127.0.0.3:8080/";
        const REQ_URL: &str = "http://127.0.0.3:8080/echo";
        const DK: &str = "127.0.0.3";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_un", "un-val-3f7d");
        // 未归属上下文（无书源绑定）：读侧只看请求 URL 属域
        let out = cookies_for_url(REQ_URL);
        assert!(
            out.contains("p219_un=un-val-3f7d"),
            "未归属上下文请求 127.0.0.3 域时必须携带该域 cookie: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }

    // ─── 按键合并（对齐上游 AnalyzeUrl.setCookie → CookieManager.mergeCookies）──
    //
    // 以下用例用非 URL 裸串键（双档归一均为 trim 原串自键，行为一致，
    // 不设 feature 门控），钉住「已有键胜、非冲突追加、大小写不敏感
    // 键查找、无已有键插 Cookie」四条语义。

    /// 无已有 Cookie 键 → 直接插 `"Cookie"` 键
    #[test]
    fn test_merge_js_cookies_no_existing_inserts_cookie_key() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_new", "a", "1");
        let mut headers: HashMap<String, String> = HashMap::new();
        merge_js_cookies(&mut headers, "p219_merge_new");
        assert_eq!(headers.get("Cookie").map(String::as_str), Some("a=1"));
        clear_cookies("p219_merge_new");
    }

    /// 非冲突键追加（上游反例：静态 `Cookie: x=0` + JS `a=1; b=2` →
    /// 发 `x=0; a=1; b=2`，而非仅 `x=0`）
    #[test]
    fn test_merge_js_cookies_appends_nonconflicting_keys() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_append", "a", "1");
        set_cookie("p219_merge_append", "b", "2");
        let mut headers = HashMap::from([("Cookie".to_string(), "x=0".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_append");
        let cookie = headers.get("Cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.starts_with("x=0; "), "已有值必须保留在前: {cookie}");
        assert!(cookie.contains("a=1"), "非冲突键 a 必须追加: {cookie}");
        assert!(cookie.contains("b=2"), "非冲突键 b 必须追加: {cookie}");
        clear_cookies("p219_merge_append");
    }

    /// 同名键：已有 header 值胜（JS 不覆盖），非冲突键仍追加
    #[test]
    fn test_merge_js_cookies_existing_key_wins() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_win", "a", "9");
        set_cookie("p219_merge_win", "b", "2");
        let mut headers = HashMap::from([("Cookie".to_string(), "a=1".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_win");
        let cookie = headers.get("Cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.contains("a=1"), "已有键 a 必须保留既有值: {cookie}");
        assert!(!cookie.contains("a=9"), "JS 不得覆盖已有同名键: {cookie}");
        assert!(cookie.contains("b=2"), "非冲突键 b 必须追加: {cookie}");
        clear_cookies("p219_merge_win");
    }

    /// 已有键大小写变体（小写 `cookie`）：原键保留、不新插 `Cookie` 键
    #[test]
    fn test_merge_js_cookies_preserves_existing_key_case() {
        let _lock = lock_cookie_store_test();
        set_cookie("p219_merge_case", "b", "2");
        let mut headers = HashMap::from([("cookie".to_string(), "a=1".to_string())]);
        merge_js_cookies(&mut headers, "p219_merge_case");
        assert!(headers.contains_key("cookie"), "已有小写键必须保留");
        assert!(!headers.contains_key("Cookie"), "不得新插大写 Cookie 键");
        let cookie = headers.get("cookie").map(String::as_str).unwrap_or("");
        assert!(cookie.contains("b=2"), "非冲突键必须追加到原键: {cookie}");
        clear_cookies("p219_merge_case");
    }

    /// P2-19 不变式（本批保留，改前改后均绿）：不相关域名的 cookie 绝不携带。
    #[test]
    fn test_p219_unrelated_domain_cookie_never_carried() {
        // iso-a.com.cn 域写入；iso-b.com.cn 域请求 → 必须落空
        let _lock = lock_cookie_store_test();
        const WRITE_URL: &str = "https://www.iso-a.com.cn/";
        const READ_URL: &str = "https://www.iso-b.com.cn/x";
        const DK: &str = "iso-a.com.cn";
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
        set_cookie(WRITE_URL, "p219_iso", "iso-val-9a4e");
        // 异域请求：iso-b.com.cn 域名键 / 原始串候选均取不到 iso-a.com.cn 的 cookie
        let out = cookies_for_url(READ_URL);
        assert!(
            !out.contains("p219_iso=iso-val-9a4e"),
            "不相关域名的 cookie 绝不携带（P2-19 不变式）: {out}"
        );
        clear_cookies(WRITE_URL);
        clear_cookies(DK);
    }
}
