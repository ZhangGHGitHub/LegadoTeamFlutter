//! 网络配置 API（契约 §2.20 网络组，Task #73）
//!
//! `setCustomHosts`（§2.20.3）：设置自定义 hosts 映射——
//! 对齐原版 `AppConfig.customHosts` / `hostMap` 语义：
//! - hostsJson 为 JSON 对象 `{"域名":"IP", "域名":["IP1","IP2"]}`
//!   （值支持单 IP 字符串或 IP 数组，解析语义见
//!   [`legado_net::custom_hosts`]）；空串/空对象 = 清除映射、恢复系统 DNS；
//! - 应用后网络层 DNS 解析即时生效（legado-net resolver 实时读全局映射）；
//! - 持久化：caches 表 `config:` 前缀键 `customHosts`（与既有 setConfig 同语义），
//!   启动时由 [`restore_custom_hosts`] 读回应用。
//!
//! `clear_cookie`（契约 §2.3，2026-08-12 P1-2）：对齐原版
//! `CookieStore.removeCookie`，按 URL 二级域名清除持久层 + 内存 Cookie。

use legado_core::{LegadoError, LegadoResult};

/// 配置持久化键（caches 表 `config:` 前缀，与既有 setConfig 同语义）
const CUSTOM_HOSTS_CONFIG_KEY: &str = "customHosts";

/// 设置自定义 hosts 映射（契约 §2.20.3）
///
/// - 先应用到网络层（即时生效），非法 JSON/非对象 → `Internal` 错误；
/// - 再持久化到 `config:customHosts`（DB 未初始化时仅记日志，
///   不影响即时生效主语义）。
pub fn set_custom_hosts(hosts_json: &str) -> LegadoResult<()> {
    // 应用到 legado-net 全局映射（resolver 实时读取，即时生效）
    legado_net::apply_custom_hosts(hosts_json)?;

    // 重建共享客户端：reqwest 连接池按 host 名缓存 keep-alive 空闲连接，hosts 变更后
    // 池中旧连接仍指向旧 IP（直至空闲超时），期间请求会打到错误地址。重建后新连接
    // 一律经更新后的映射重解析；在途请求持有旧客户端 Arc clone，不受影响。
    crate::http_state::reset_shared_client();

    // 持久化（宽容失败：DB 未初始化/写入失败仅记日志）
    if crate::db_state::is_initialized() {
        if let Err(e) = crate::api::config_api::set_config(CUSTOM_HOSTS_CONFIG_KEY, hosts_json) {
            log::warn!("持久化 customHosts 配置失败: {e}");
        }
    } else {
        log::debug!("数据库未初始化，customHosts 配置不持久化");
    }
    Ok(())
}

/// 从 URL 或域名提取 Cookie 域名键（对齐 Kotlin `NetworkUtils.getSubDomain`）
///
/// 单一真源：[`legado_net::cookie_store::domain_key_from_host`]（ETLD+1，IP 字面量
/// 以自身为键），保证清除侧键与 HTTP Cookie 持久化存储侧键永不分叉
///（2026-09-22 P1 回归修复：旧实现取 host 末两段，多段 TLD/IP 下清除空转）。
/// 保留原「host 为空 → 回退原始 URL」分支。
fn get_sub_domain(url: &str) -> String {
    let without_scheme = url
        .split("://")
        .last()
        .unwrap_or(url)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .trim();
    let host = without_scheme.split('@').next_back().unwrap_or("");
    let host = if host.starts_with('[') {
        // IPv6 字面量（如 `[::1]:8080`）：去首 `[` 后截到 `]`（再丢弃端口）
        host.strip_prefix('[')
            .unwrap_or(host)
            .split(']')
            .next()
            .unwrap_or("")
    } else {
        host.split(':').next().unwrap_or("")
    }
    .trim();
    if host.is_empty() {
        return url.trim().to_string();
    }
    legado_net::cookie_store::domain_key_from_host(host)
}

/// 清除指定 URL 所属二级域名的 Cookie（契约 §2.3 `clearCookie`）
///
/// 对齐原版 `CookieStore.removeCookie`：
/// 1. 共享 HTTP 客户端内存 [`CookieStore`](legado_net::CookieStore)
/// 2. cookies 表持久层（DB 已初始化时）
/// 3. JS 宿主 `cookie_store` 内存表
///
/// 差距：原版另清 WebView Cookie / CacheManager 会话；本实现无独立 WebView 层。
///
/// [正确性 2026-09-24] 删除侧纳入与写方同一保护域（否则删行可被夹在写方
/// 「捕获视图 → 落库」的 RMW 中间，随后写方落库旧视图即把已删行「复活」，
/// 红态回归：`test_clear_cookie_concurrent_rmw_no_resurrection`）：
/// - **D（按域写通道，最外层）**：对「存储域键 + JS 归一键 + 域键归一
///   结果」去重排序后逐键取 net 层域锁（quickjs 档 JS 写侧 / jar 写回
///   共用 net 注册表 → 一把锁覆盖；默认档 JS 写侧用本地注册表 → 另经
///   [`legado_js::host_api::cookie_store::lock_local_domain_writes`] 取同
///   键集本地 D，两侧写方都能挡住）；
/// - **C（DB 行 RMW 串行）**：删行走 [`crate::http_state::delete_cookie_rows`]
///   （C 守卫内逐键删行，与写方 `persist_cookie_row_merged` 的 RMW 串行）；
/// - **全局锁序 D→J→C→P**：J（jar）仅在清内存 CookieStore 的短作用域内
///   取放、不跨 DB I/O；C 在 D 内取；P 最内层——链状无环。
/// - **自死锁规避**：`std::sync::Mutex` 不可重入，本入口对每个 D 键
///   至多取一次（键集先去重 + 排序），且其后 JS 侧只调「假设锁已持有」
///   的 [`legado_js::host_api::cookie_store::clear_cookies_locked`]（绝不
///   重取 D）；公共入口 `clear_cookies` 不在本路径上被调用。
/// - **跨进程 caveat**：进程内 D/C 不覆盖另一进程（app ↔ server）的写方；
///   跨进程竞态回落到数据库行级语句原子性。
pub fn clear_cookie(url: &str) -> LegadoResult<()> {
    let url = url.trim();
    if url.is_empty() {
        return Err(LegadoError::Internal("url 不能为空".into()));
    }
    let domain = get_sub_domain(url);
    // 删除侧保护域键候选：存储域键（jar / DB 行键）+ JS 归一键 + 域键
    // 归一结果（双档归一口径的兜底超集）。去重 + 排序保证每个 D 键只取
    // 一次且顺序固定（Mutex 不可重入 + 排序序无环）
    let norm = legado_js::host_api::cookie_store::normalized_cookie_key(url);
    let mut keys = vec![
        domain.clone(),
        norm.clone(),
        legado_js::host_api::cookie_store::normalized_cookie_key(&domain),
    ];
    keys.sort();
    keys.dedup();
    // D（最外层）：与同域写方「捕获 + 落库」互斥
    let _d_guards: Vec<_> = keys
        .iter()
        .map(|k| legado_net::cookie_store::domain_write_lock(k))
        .collect();
    // 默认档：JS 写侧用本地注册表（quickjs 档 JS 侧复用 net 注册表，上方
    // net D 已覆盖，该函数不存在于此档）
    #[cfg(not(feature = "quickjs"))]
    let _local_guards = legado_js::host_api::cookie_store::lock_local_domain_writes(&keys);

    // 1. 内存 CookieStore（共享客户端；J 作用域在 DB I/O 前完成——锁序
    //    D→J，不持 J 跨 DB I/O；未初始化时 shared_client 会惰性创建）
    {
        let client = crate::http_state::shared_client()?;
        let mut store = client
            .cookie_store()
            .write()
            .map_err(|e| LegadoError::Internal(format!("CookieStore 写锁 poisoned: {e}")))?;
        store.remove_domain(&domain);
    }

    // 2. 持久层（C 守卫删行，与写方 RMW 串行；DB 未初始化时跳过，与 MCP
    //    clear_cookies 行为一致）
    if crate::db_state::is_initialized() {
        crate::http_state::delete_cookie_rows(&[&domain])?;
    }

    // 3. JS 宿主 Cookie（java.clearCookies(url) 同源；已持 D 的内层变体）：
    //    清归一域名键（单一真源 `domain_key_from_host`，与写侧归一口径一致），
    //    并追加清原始 URL 形态键——上游同步（2026-09-23 用户裁决）后读侧容忍
    //    「归一键 + 原始串键」双命中，历史数据或 JS 侧可能直接以原始 URL 串
    //    为键写入，须连 raw 键一并清除才不漏。http(s) 可解析 URL 的
    //    norm(url) 即上行的 `domain` 键，两行删除互为幂等超集；非 http(s)
    //    串两键相同，同样幂等。
    legado_js::host_api::cookie_store::clear_cookies_locked(&domain);
    legado_js::host_api::cookie_store::clear_cookies_locked(url);

    Ok(())
}

/// HTTP GET 二进制响应（F3-14，经共享 legado-net 客户端）
///
/// 返回 JSON：`{"status": int, "bodyBase64": string, "url": string}`。
/// `headers_json` 为空串时不附加请求头；否则为 JSON 对象字符串。
pub fn http_get_bytes(url: &str, headers_json: &str) -> LegadoResult<String> {
    use std::collections::HashMap;

    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let url = url.trim();
    if url.is_empty() {
        return Err(LegadoError::Internal("url 不能为空".into()));
    }
    let headers: Option<HashMap<String, String>> = if headers_json.trim().is_empty() {
        None
    } else {
        Some(
            serde_json::from_str(headers_json)
                .map_err(|e| LegadoError::Internal(format!("headersJson 解析失败: {e}")))?,
        )
    };
    let response = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        client.get_raw(url, headers).await
    })?;
    serde_json::to_string(&serde_json::json!({
        "status": response.status,
        "bodyBase64": STANDARD.encode(&response.body),
        "url": response.url,
    }))
    .map_err(LegadoError::Serialization)
}

/// 启动时恢复 hosts 映射（由 db_open 调用，尽力而为）
///
/// 读回 `config:customHosts`：非空时应用到网络层（失败仅记日志）；
/// 空/缺省不应用（保持系统 DNS）。
pub fn restore_custom_hosts() {
    if !crate::db_state::is_initialized() {
        return;
    }
    let value = match crate::api::config_api::get_config(CUSTOM_HOSTS_CONFIG_KEY) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("读取 customHosts 配置失败: {e}");
            return;
        }
    };
    if value.trim().is_empty() {
        return;
    }
    if let Err(e) = legado_net::apply_custom_hosts(&value) {
        log::warn!("启动时恢复 hosts 映射失败: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 串行锁：以下测试读写全局 hosts 映射与共享 DB 配置，需串行执行
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 设置 + 即时生效 + 持久化
    #[test]
    fn test_set_custom_hosts_apply_and_persist() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();

        set_custom_hosts(r#"{"net-api.test": "10.0.0.1"}"#).unwrap();

        // 即时生效：legado-net 全局映射命中
        assert_eq!(
            legado_net::lookup_ips("net-api.test"),
            Some(vec!["10.0.0.1".parse().unwrap()])
        );
        // 持久化：config:customHosts
        let persisted = crate::api::config_api::get_config("customHosts").unwrap();
        assert_eq!(persisted, r#"{"net-api.test": "10.0.0.1"}"#);

        // 清除语义：空串清空映射
        set_custom_hosts("").unwrap();
        assert!(legado_net::lookup_ips("net-api.test").is_none());

        // 恢复链路：写回配置后 restore 应重新应用
        crate::api::config_api::set_config("customHosts", r#"{"net-api.test": "10.0.0.2"}"#)
            .unwrap();
        restore_custom_hosts();
        assert_eq!(
            legado_net::lookup_ips("net-api.test"),
            Some(vec!["10.0.0.2".parse().unwrap()])
        );

        // 收尾：清除映射与配置残留
        set_custom_hosts("").unwrap();
    }

    /// 契约 §2.3：按二级域名清除 DB + 内存 Cookie
    #[test]
    fn test_clear_cookie_by_subdomain() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();

        // 二级域名键与 HTTP Cookie 持久化键一致（ETLD+1；单段 TLD 即末两段）
        let domain = "cookieclear.test";
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert(domain, "session=abc; token=xyz")
        })
        .unwrap();
        {
            let client = crate::http_state::shared_client().unwrap();
            let mut store = client.cookie_store().write().unwrap();
            store.set_cookies_from_string(domain, "session=abc; token=xyz");
        }
        legado_js::host_api::cookie_store::set_cookie(domain, "session", "abc");

        clear_cookie("https://www.cookieclear.test/path").unwrap();

        let remaining = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(domain)
        })
        .unwrap();
        assert!(remaining.is_none());

        let client = crate::http_state::shared_client().unwrap();
        let store = client.cookie_store().read().unwrap();
        assert!(store.get_cookies(domain).is_empty());
        drop(store);
        assert!(legado_js::host_api::cookie_store::get_cookie(domain).is_empty());

        let err = clear_cookie("  ").unwrap_err();
        assert!(matches!(err, LegadoError::Internal(_)));
    }

    /// 契约 §2.3（上游同步 2026-09-23）：clear_cookie 入口覆盖 JS cookie
    /// 持久化行——「DB + net jar + JS store」双侧（归一域名键 + 原始串键）
    /// 齐清且幂等（落库后清除入口仍把内存 + DB 两侧清干净）
    #[test]
    fn test_clear_cookie_covers_db_persistence_rows() {
        let _g = TEST_LOCK.lock().unwrap();
        // 断言含全局 JS cookie store 状态，持全局 store 串行锁排除并发干扰；
        // 全局锁序不变式：先 store 锁、后 DB 锁（见 test_support 模块文档）
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        use legado_js::host_api::cookie_store;

        const URL: &str = "https://www.clearedb.test/path";
        let dk = cookie_store::normalized_cookie_key(URL);
        // 清理残留（幂等；下沉若已被同二进制其他用例注册，此处同时清 DB）
        clear_cookie(URL).unwrap();

        crate::http_state::register_js_cookie_sink();

        // JS 侧写入（sink upsert：归一域名键下必有 DB 行）
        cookie_store::set_cookie(URL, "s", "1");
        let row = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(&dk)
        })
        .unwrap();
        assert!(
            row.is_some(),
            "JS 写入后 DB 必须有「归一域名键 → cookie 串」持久行"
        );

        // FFI 清除入口：DB + 内存两侧齐清
        clear_cookie(URL).unwrap();
        let row_norm = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(&dk)
        })
        .unwrap();
        assert!(
            row_norm.is_none(),
            "clear_cookie 后归一域名键 DB 行必须删除"
        );
        let row_raw = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(URL)
        })
        .unwrap();
        assert!(
            row_raw.is_none(),
            "原始 URL 形态键的 DB 行必须同步删除（两侧齐清）"
        );
        assert!(
            cookie_store::get_cookie(URL).is_empty(),
            "clear_cookie 后 JS 内存态必须为空"
        );

        // 幂等：重复清除不报错、状态保持干净
        clear_cookie(URL).unwrap();
        let row_again = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(&dk)
        })
        .unwrap();
        assert!(row_again.is_none(), "重复清除必须幂等");
    }

    /// P1 回归钉死：清除侧键必须与存储侧键（ETLD+1 / IP 自键）相等
    #[test]
    fn test_get_sub_domain_matches_storage_key() {
        // 多段 TLD：旧实现塌缩为 `com.cn`，现应为 ETLD+1
        assert_eq!(get_sub_domain("https://www.a.com.cn/"), "a.com.cn");
        assert_eq!(get_sub_domain("https://shop.a.co.uk/"), "a.co.uk");
        // IP 字面量：旧实现塌缩为 `1.10`，现应为 IP 自身
        assert_eq!(get_sub_domain("http://192.168.1.10:8080/x"), "192.168.1.10");
        // IPv6 字面量（方括号 host）
        assert_eq!(get_sub_domain("http://[::1]:8080/x"), "::1");
        // 单段 TLD 行为不变
        assert_eq!(
            get_sub_domain("https://www.cookieclear.test/p"),
            "cookieclear.test"
        );
        // 非 URL 输入回退原串（与空 host 兜底分支一致）
        assert_eq!(get_sub_domain("not a url"), "not a url");
        // 空 host（纯 scheme）兜底原 URL
        assert_eq!(get_sub_domain("https://"), "https://");
    }

    /// hosts 变更后共享客户端必须重建（池化连接不得继续指向旧 IP）
    #[test]
    fn test_set_custom_hosts_rebuilds_shared_client() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();

        let before = crate::http_state::shared_client().unwrap();
        set_custom_hosts(r#"{"reset-pool.test": "10.9.9.9"}"#).unwrap();
        let after = crate::http_state::shared_client().unwrap();
        assert!(
            !std::sync::Arc::ptr_eq(before.cookie_store(), after.cookie_store()),
            "hosts 变更后共享客户端应重建（避免池化连接指向旧 IP）"
        );
        // 收尾：清除映射
        set_custom_hosts("").unwrap();
    }

    /// 非法 JSON：报 Internal 错误且不落库
    #[test]
    fn test_set_custom_hosts_invalid_json() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();

        assert!(set_custom_hosts("not-json").is_err());
        assert!(set_custom_hosts(r#"["array"]"#).is_err());
    }

    /// [正确性 2026-09-24] 并发「删行被夹在写方 RMW 中间」→ 旧视图写回复活已删行
    ///
    /// 写方线程模拟生产 jar 写回（save_cookies_from_response）：取 D(domain)
    /// → 捕获 jar 域视图 → 等放行信号（超时 2s）→ 以捕获视图合并落库
    ///（C + 合并 upsert，与生产 persist 路径同源）→ 放 D。
    /// 删除侧线程跑 FFI 入口 [`clear_cookie`]。
    ///
    /// 红态（删除侧未纳入 D/C 保护域）：删除在写方持 D 期间完成删行，
    /// 随后写方落库旧视图 → 行复活（断言失败）。默认档下该窗口真实存在：
    /// jar 写回走 net 注册表的 D，JS 清除走本地注册表的 D，两注册表
    /// 互不串行。
    /// 绿态（删除侧取 D + C 守卫）：删除阻塞在 D 上，写方超时落库
    ///（复活）并放 D 后，删除的 D+C 段执行 → 行被最终删除（断言通过）。
    #[test]
    fn test_clear_cookie_concurrent_rmw_no_resurrection() {
        let _g = TEST_LOCK.lock().unwrap();
        let _gs = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        crate::http_state::register_js_cookie_sink();

        const URL: &str = "https://www.rmwffi.test/x";
        // jar 写回 / 删除侧共用的域名键（ETLD+1，与存储侧键一致）
        let dk = get_sub_domain(URL);

        // 清理残留 + 预置：jar 内存域视图（写方将捕获）+ DB 行
        clear_cookie(URL).unwrap();
        {
            let client = crate::http_state::shared_client().unwrap();
            client
                .cookie_store()
                .write()
                .unwrap()
                .set_cookies_from_string(&dk, "s=1");
        }
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert(&dk, "s=1")
        })
        .unwrap();

        let (captured_tx, captured_rx) = std::sync::mpsc::channel();
        let (go_tx, go_rx) = std::sync::mpsc::channel();
        let dk_writer = dk.clone();
        let writer = std::thread::spawn(move || {
            // 写方保护域（D）：与生产 jar 写回同一把锁
            let _d = legado_net::cookie_store::domain_write_lock(&dk_writer);
            // 捕获 jar 域视图（生产路径在 J 作用域内捕获）
            let captured = crate::http_state::shared_client()
                .unwrap()
                .cookie_store()
                .read()
                .unwrap_or_else(|p| p.into_inner())
                .domain_cookie_string(&dk_writer);
            let _ = captured_tx.send(());
            // 绿态：删除侧阻塞在 D 上 → 此处必然超时；红态：删除已完成
            let _ = go_rx.recv_timeout(std::time::Duration::from_secs(2));
            // 落库捕获视图（C + 合并 upsert，与生产 persist 路径同源）
            if !captured.is_empty() {
                let persistence = crate::http_state::DbCookiePersistence;
                legado_net::CookiePersistence::save(&persistence, &dk_writer, &captured);
            }
            // 放 D（guard drop）
        });

        // 删除侧：独立线程跑 FFI 清除入口
        let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let done_flag = std::sync::Arc::clone(&done);
        let deleter = std::thread::spawn(move || {
            let _ = clear_cookie(URL);
            done_flag.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        // 等写方完成捕获（此刻写方持 D + 旧视图）
        captured_rx.recv().expect("写方应完成视图捕获");
        // 等删除完成（绿态下需等写方 2s 超时放 D；留足上限防误判死锁）
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        while !done.load(std::sync::atomic::Ordering::SeqCst) {
            assert!(
                std::time::Instant::now() < deadline,
                "clear_cookie 不应永久阻塞（锁序 D→C 链状无环）"
            );
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        // 放行写方落库（绿态下写方已超时落库；红态下落库发生于删除完成之后）
        let _ = go_tx.send(());
        writer.join().expect("写方线程不应 panic");
        deleter.join().expect("删除线程不应 panic");

        // 终态：已删行不得被写方旧视图复活
        let row = crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.get_by_tag(&dk)
        })
        .unwrap();
        assert!(row.is_none(), "删行被夹在写方 RMW 中间后不得复活: {row:?}");
        // jar 内存侧同样干净
        let client = crate::http_state::shared_client().unwrap();
        assert!(client
            .cookie_store()
            .read()
            .unwrap()
            .get_cookies(&dk)
            .is_empty());

        // 收尾：清理残留（幂等）
        clear_cookie(URL).unwrap();
    }
}
