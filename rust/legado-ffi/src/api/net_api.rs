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

use legado_core::LegadoResult;

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
        crate::api::config_api::set_config("customHosts", "").unwrap();
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
