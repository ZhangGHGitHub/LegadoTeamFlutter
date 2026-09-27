//! BackstageWebView DOM 执行通道 FFI（SOURCE_DIFF P1）
//!
//! 对 `legado_core::webview_channel` 的纯 FFI 包装：
//! - 事件流：[`run_webview_request_stream`]
//! - 回传：[`submit_webview_result`] / [`submit_webview_result_with_cookies`]（项 B/B1）
//! - 取消：[`cancel_webview_request`]

use std::time::Duration;

use legado_core::webview_channel::{self, WebViewRequest};

const STREAM_POLL_INTERVAL: Duration = Duration::from_secs(1);

pub fn serialize_event(request: &WebViewRequest) -> String {
    serde_json::to_string(request).unwrap_or_default()
}

/// WebView 请求事件流（长期存活）
pub async fn run_webview_request_stream<F>(mut on_event: F)
where
    F: FnMut(String) -> Result<(), String>,
{
    use std::sync::mpsc::RecvTimeoutError;

    let mut rx = webview_channel::webview_manager().subscribe();
    loop {
        let recv = tokio::task::spawn_blocking(move || {
            let item = rx.recv_timeout(STREAM_POLL_INTERVAL);
            (rx, item)
        })
        .await;
        let (next_rx, item) = match recv {
            Ok(v) => v,
            Err(_) => break,
        };
        rx = next_rx;
        match item {
            Ok(request) => {
                if on_event(serialize_event(&request)).is_err() {
                    break;
                }
            }
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

pub fn submit_webview_result(key: &str, result: &str) -> bool {
    webview_channel::submit_webview_result(key, result)
}

/// 提交 WebView 执行结果 + WebView 侧域 cookie 回流（项 B/B1，加法式条目）
///
/// 设计/取证：`.tmp/engine_forensic_d/design_upstream_aligned.md` §3 项 B1
/// 与 §2.2 G1——WebView 路径（原生 backstageEval）完成的 WAF 状态机 cookie
/// 此前仅驻留 Android `CookieManager`，从不回流 Rust/DB cookie 存储，后续
/// JS 桥请求缺会话态（冷启动被重新挑战，如 x81zws 403 场景）。
///
/// **执行顺序（数据依赖）**：
/// 1. 解析 `cookies_json`（JSON 对象：域键或 http(s) URL →
///    `k1=v1; k2=v2` cookie 串），域键一律 ETLD+1 归一
///    （`cookie_store::normalized_cookie_key` 口径；P2-19：不相关域名的
///    cookie 绝不落行）；
/// 2. 逐域键 [`crate::http_state::persist_cookie_row_merged`] merged
///    upsert（与既有两个写方同键集并集、同名键新值胜语义；DB 失败仅记
///    日志，不阻塞唤醒）；
/// 3. 有非空条目落库时（quickjs 档）：
///    [`legado_js::host_api::network::reset_shared_client_pools`] 同步 JS
///    桥共享客户端池内存 CookieStore——复用项 A 的 reset/槽位语义（池由
///    下次 JS 请求惰性重建，构建含持久化后端 DB `load_all` 在槽位写锁
///    **之外**完成，临界区内无 DB/sink 调用；槽位锁临界区仅置 None）；
///    空 / 全空条目跳过 reset（避免无谓拆除热池）；
/// 4. 最后 [`webview_channel::submit_webview_result`] 唤醒等待方
///    （先持久化后唤醒——等待方恢复执行后 DB 行已就位，后续 JS 请求
///    即携带合并后 cookie）。
///
/// 旧 [`submit_webview_result`] 冻结不动（旧端忽略未知字段 / 不做 cookie
/// 回流，本方法纯加法式）。返回是否命中进行中的请求（同旧方法语义）。
pub fn submit_webview_result_with_cookies(key: &str, result: &str, cookies_json: &str) -> bool {
    let mut persisted_any = false;
    let trimmed = cookies_json.trim();
    if !trimmed.is_empty() && trimmed != "{}" {
        match serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(trimmed) {
            Ok(entries) => {
                for (raw_key, value) in entries {
                    let cookie_str = match value.as_str() {
                        Some(s) if !s.trim().is_empty() => s.to_string(),
                        _ => continue,
                    };
                    // P2-19：域键一律 ETLD+1 归一（quickjs 档 http(s) URL →
                    // 域名键；默认档 → trim 原串，与 JS 侧写侧口径恒等）
                    let domain_key =
                        legado_js::host_api::cookie_store::normalized_cookie_key(&raw_key);
                    if domain_key.is_empty() {
                        continue;
                    }
                    crate::http_state::persist_cookie_row_merged(&domain_key, &cookie_str);
                    persisted_any = true;
                }
            }
            Err(e) => {
                log::warn!("WebView cookie 回流：cookies_json 解析失败（跳过持久化）: {e}");
            }
        }
    }
    // 同步 JS 桥共享客户端池内存 CookieStore（仅 quickjs 档有 JS 池；
    // 默认档条件恒读、块体 cfg 排除——避免 `persisted_any` 写而不读告警）
    if persisted_any {
        // 锁序不变式（项 A / http_state.rs:300-304 照抄）：池重建由下次 JS
        // 请求惰性触发，构建（含持久化后端 DB `load_all`）在持有客户端槽位
        // 写锁**之前**完成——槽位锁临界区内不做 DB/sink 调用；reset 本身
        // 仅在槽位写锁下把四个池槽位置 None。
        #[cfg(feature = "quickjs")]
        {
            legado_js::host_api::network::reset_shared_client_pools();
        }
    }
    webview_channel::submit_webview_result(key, result)
}

pub fn cancel_webview_request(key: &str) -> bool {
    webview_channel::cancel_webview_request(key)
}

pub fn pending_requests_json() -> String {
    let pending = webview_channel::webview_manager().pending();
    serde_json::to_string(&pending).unwrap_or_else(|_| "[]".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    /// cookie 串按键集合比较辅助（HashMap 迭代序不保证，按键集合相等断言；
    /// 与 http_state 测试同名辅助同语义）
    fn cookie_parts(s: &str) -> Vec<String> {
        let mut parts: Vec<String> = s
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        parts.sort();
        parts
    }

    fn db_cookie_row(dk: &str) -> Option<String> {
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(dk)
        })
        .expect("DB 必须已初始化（ensure_test_db）")
    }

    /// B1：cookiesJson 域键 ETLD+1 归一 → merged upsert 落库（同名键新值
    /// 胜、异名键并集），且等待方被唤醒（先持久化后唤醒）
    #[test]
    fn test_submit_with_cookies_merged_upsert() {
        // 全局锁序不变式：（模块锁）→ store 锁 → 池锁 → DB 守卫
        // （见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://a.wv-b1-merge.test/";
        let dk = cookie_store::normalized_cookie_key(URL);
        // 幂等清理残留行（DB 守卫已持有，失败即环境异常）
        crate::http_state::delete_cookie_rows(&[dk.as_str()])
            .expect("清理残留行必须成功（DB 已初始化）");
        // 预置行（模拟 jar / JS 侧已落库键 a=1）
        crate::http_state::persist_cookie_row_merged(&dk, "a=1");

        // 等待方线程挂起（模拟 JS 执行线程），主线程回流 + 唤醒
        let req = WebViewRequest {
            key: String::new(),
            action: "webView".into(),
            html: String::new(),
            url: URL.into(),
            js: String::new(),
            source_regex: String::new(),
            override_url_regex: String::new(),
            cache_first: false,
            delay_time: 0,
            is_rule: false,
            result: String::new(),
            source_key: String::new(),
            cookie: String::new(),
            created_at_ms: 0,
        };
        let mgr = webview_channel::webview_manager();
        let handle = mgr.request(req);
        let key = handle.key().to_string();
        let waiter = thread::spawn(move || handle.wait(std::time::Duration::from_secs(5)));

        // a=2 覆盖 a=1（写方胜）、b=3 并集追加
        let hit = submit_webview_result_with_cookies(
            &key,
            "done",
            &format!("{{\"{}\": \"a=2; b=3\"}}", URL),
        );
        assert!(hit, "必须命中进行中的请求");
        assert_eq!(waiter.join().unwrap().unwrap(), "done", "等待方必须收到结果");

        let row = db_cookie_row(&dk).expect("落库后 DB 行必须存在");
        assert_eq!(
            cookie_parts(&row),
            cookie_parts("a=2; b=3"),
            "merged upsert 必须为键集并集 + 同名新值胜: {row}"
        );
        // 收尾清理
        crate::http_state::delete_cookie_rows(&[dk.as_str()])
            .expect("收尾清理必须成功（DB 已初始化）");
    }

    /// P2-19 反例：不相关域名的 cookie 绝不落行（归一到 ETLD+1 域键，
    /// 子域 URL 不得新建子域行；其他域已有行不被触碰）
    #[test]
    fn test_submit_with_cookies_unrelated_domain_not_touched() {
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        // 两域 ETLD+1 必须不同（keep → wv-b1.test；other → wv-b2.test），
        // 且 other 为子域形态（验证归一后不落子域原始行）
        const KEEP_URL: &str = "https://keep.wv-b1.test/";
        const OTHER_URL: &str = "https://sub.unrelated.wv-b2.test/";
        let keep_dk = cookie_store::normalized_cookie_key(KEEP_URL);
        let other_dk = cookie_store::normalized_cookie_key(OTHER_URL);
        assert_ne!(keep_dk, other_dk, "两个域键必须不同");
        let tags: Vec<&str> = vec![keep_dk.as_str(), other_dk.as_str()];
        crate::http_state::delete_cookie_rows(&tags)
            .expect("清理残留行必须成功（DB 已初始化）");

        // 无关域已有行
        crate::http_state::persist_cookie_row_merged(&keep_dk, "keep=1");

        // 回流另一域（子域 URL 形态）cookie
        let hit = submit_webview_result_with_cookies(
            "wv-b1-nokey", // 无进行中的请求 → 返回 false，持久化仍生效
            "ignored",
            &format!("{{\"{}\": \"waf=42\"}}", OTHER_URL),
        );
        assert!(!hit, "无进行中请求时 submit 必须返回 false");

        // 不相关域行不被触碰
        assert_eq!(
            cookie_parts(&db_cookie_row(&keep_dk).unwrap_or_default()),
            cookie_parts("keep=1"),
            "回流另一域不得触碰 keep 域行"
        );
        #[cfg(feature = "quickjs")]
        {
            // ETLD+1 归一：子域 URL 落到 `wv-b2.test` 行
            assert_eq!(other_dk, "wv-b2.test", "quickjs 档必须归一到 ETLD+1");
            assert_eq!(
                cookie_parts(&db_cookie_row(&other_dk).unwrap_or_default()),
                cookie_parts("waf=42"),
                "归一域行必须存在"
            );
            // 反例核心：不得新建子域原始行
            assert!(
                db_cookie_row("sub.unrelated.wv-b2.test").is_none(),
                "P2-19：子域原始键不得落行（必须归一到 ETLD+1）"
            );
        }
        // 收尾清理
        let tags: Vec<&str> = vec![keep_dk.as_str(), other_dk.as_str()];
        crate::http_state::delete_cookie_rows(&tags)
            .expect("收尾清理必须成功（DB 已初始化）");
    }

    /// 空 / 非法 cookiesJson：不 panic、不落库、唤醒语义与旧方法一致
    #[test]
    fn test_submit_with_cookies_empty_or_invalid_json() {
        let _gs = crate::test_support::lock_global_store();
        let _p = crate::test_support::lock_pool_tests();
        let _db_guard = crate::db_state::ensure_test_db();

        let req = WebViewRequest {
            key: String::new(),
            action: "webView".into(),
            html: String::new(),
            url: "https://invalid.wv-b1.test/".into(),
            js: String::new(),
            source_regex: String::new(),
            override_url_regex: String::new(),
            cache_first: false,
            delay_time: 0,
            is_rule: false,
            result: String::new(),
            source_key: String::new(),
            cookie: String::new(),
            created_at_ms: 0,
        };
        let mgr = webview_channel::webview_manager();
        let handle = mgr.request(req);
        let key = handle.key().to_string();
        let waiter = thread::spawn(move || handle.wait(std::time::Duration::from_secs(5)));

        for bad in ["", "{}", "   ", "not-a-json", "\"just a string\"", "[1, 2]"] {
            let hit = submit_webview_result_with_cookies(&key, "noop", bad);
            // 首次命中唤醒后请求已出队，后续提交返回 false（同旧方法语义）
            assert_eq!(
                hit,
                bad == "",
                "首次提交必须命中，重复提交返回 false（{bad}）"
            );
        }
        assert_eq!(waiter.join().unwrap().unwrap(), "noop");

        // 空值条目不落行：再发一个全空值对象
        let _ = submit_webview_result_with_cookies(
            "wv-b1-emptyvals",
            "noop",
            r#"{ "https://emptyvals.wv-b1.test/": "  ", "https://emptyvals2.wv-b1.test/": "" }"#,
        );
        assert!(
            db_cookie_row("emptyvals.wv-b1.test").is_none(),
            "全空值条目不得落行"
        );
    }
}
