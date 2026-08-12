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

    // 持久化（宽容失败：DB 未初始化/写入失败仅记日志）
    if crate::db_state::is_initialized() {
        if let Err(e) =
            crate::api::config_api::set_config(CUSTOM_HOSTS_CONFIG_KEY, hosts_json)
        {
            log::warn!("持久化 customHosts 配置失败: {e}");
        }
    } else {
        log::debug!("数据库未初始化，customHosts 配置不持久化");
    }
    Ok(())
}

/// 从 URL 或域名提取二级域名（对齐 Kotlin `NetworkUtils.getSubDomain`）
///
/// 与 MCP `clear_cookies` / HTTP Cookie 持久化键一致：取 host 最后两段。
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
    let host = host.split(':').next().unwrap_or("").trim();
    if host.is_empty() {
        return url.trim().to_string();
    }
    let parts: Vec<&str> = host.split('.').filter(|p| !p.is_empty()).collect();
    if parts.len() >= 2 {
        parts[parts.len() - 2..].join(".")
    } else {
        host.to_string()
    }
}

/// 清除指定 URL 所属二级域名的 Cookie（契约 §2.3 `clearCookie`）
///
/// 对齐原版 `CookieStore.removeCookie`：
/// 1. 共享 HTTP 客户端内存 [`CookieStore`](legado_net::CookieStore)
/// 2. cookies 表持久层（DB 已初始化时）
/// 3. JS 宿主 `cookie_store` 内存表
///
/// 差距：原版另清 WebView Cookie / CacheManager 会话；本实现无独立 WebView 层。
pub fn clear_cookie(url: &str) -> LegadoResult<()> {
    let url = url.trim();
    if url.is_empty() {
        return Err(LegadoError::Internal("url 不能为空".into()));
    }
    let domain = get_sub_domain(url);

    // 1. 内存 CookieStore（共享客户端；未初始化时 shared_client 会惰性创建）
    {
        let client = crate::http_state::shared_client();
        let mut store = client.cookie_store().write().unwrap();
        store.remove_domain(&domain);
    }

    // 2. 持久层（DB 未初始化时跳过，与 MCP clear_cookies 行为一致）
    if crate::db_state::is_initialized() {
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.delete_by_tag(&domain)
        })?;
    }

    // 3. JS 宿主 Cookie（java.clearCookies(tag) 同源）
    legado_js::host_api::cookie_store::clear_cookies(&domain);

    Ok(())
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

        // 二级域名键与 HTTP Cookie 持久化一致（host 最后两段）
        let domain = "cookieclear.test";
        crate::db_state::with_database(|db| {
            let repo = legado_db::CookieRepository::new(db.connection());
            repo.upsert(domain, "session=abc; token=xyz")
        })
        .unwrap();
        {
            let client = crate::http_state::shared_client();
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

        let client = crate::http_state::shared_client();
        let store = client.cookie_store().read().unwrap();
        assert!(store.get_cookies(domain).is_empty());
        drop(store);
        assert!(legado_js::host_api::cookie_store::get_cookie(domain).is_empty());

        let err = clear_cookie("  ").unwrap_err();
        assert!(matches!(err, LegadoError::Internal(_)));
    }

    /// 非法 JSON：报 Internal 错误且不落库
    #[test]
    fn test_set_custom_hosts_invalid_json() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();

        assert!(set_custom_hosts("not-json").is_err());
        assert!(set_custom_hosts(r#"["array"]"#).is_err());
    }
}
