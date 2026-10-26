//! HTTP 请求日志开关（对齐原版 `AppConfig.recordHttpLog` /
//! `HttpLogController.setRecording`，契约 §2.10）
//!
//! ## 语义
//!
//! 原版 `setRecording(enabled)` 两件事：持久化 `PreferKey.recordHttpLog` +
//! 更新运行期 `AppConfig.recordHttpLog`；`HttpLogInterceptor` 每次请求按运行期
//! 开关门控。我方对应：
//!
//! - 持久化 → caches 表 `config:recordHttpLog`（与 `config_api` 同前缀，跨进程
//!   可读，服务启动经 [`legado_server::legacy::http_log::apply_recording_config`]
//!   回填）；
//! - 运行期 → [`legado_net::http_log::set_recording_enabled`]（`LegadoClient`
//!   统一请求出口的采集门控）。
//!
//! 先落库后切开关：落库失败时返回错误且**不改变**运行期状态，避免「UI 显示已
//! 开启但重启后丢失」的分叉。
//!
//! ## 启动恢复
//!
//! [`restore_http_log_recording`] 在 FFI `db_open` 内调用（尽力而为）：
//! 注册采集实现（`legado-server` 的 ring 存储；与服务启动共享 first-wins 单槽）
//! 并从 caches 回填开关——App 侧 HTTP 请求因此与 Web 端日志写入**同一存储**
//!（对齐原版 App 与 Web 共享 `HttpLogStore` 单例）。

use legado_core::LegadoResult;

use crate::api::config_api;

/// 配置短键（`config_api` 自动补 `config:` 前缀）
pub const RECORD_HTTP_LOG_KEY: &str = "recordHttpLog";

/// 设置 HTTP 日志采集开关（落库 + 运行期切换）
pub fn set_http_log_recording(enabled: bool) -> LegadoResult<bool> {
    config_api::set_config(RECORD_HTTP_LOG_KEY, if enabled { "true" } else { "false" })?;
    legado_net::http_log::set_recording_enabled(enabled);
    Ok(enabled)
}

/// 启动恢复：注册采集实现 + 从 caches 回填运行期开关（尽力而为，不阻断启动）
pub fn restore_http_log_recording() {
    legado_server::legacy::http_log::install_http_log_recorder();
    match config_api::get_config(RECORD_HTTP_LOG_KEY) {
        Ok(raw) => {
            let enabled = legado_server::legacy::http_log::apply_recording_config(Some(&raw));
            log::info!("HTTP 日志采集开关（config:recordHttpLog）: {enabled}");
        }
        Err(e) => {
            // DB 未就绪/读失败：保持缺省关闭（对应 AppConfig 缺省 false）
            log::warn!("读取 config:recordHttpLog 失败，HTTP 日志采集保持关闭: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 串行锁：运行期开关为进程级状态，用例间不得并发切换
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn test_set_http_log_recording_persists_and_toggles() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        // 开启：落库为 "true" 且运行期开关立即生效
        assert!(set_http_log_recording(true).unwrap());
        assert_eq!(config_api::get_config(RECORD_HTTP_LOG_KEY).unwrap(), "true");
        assert!(legado_net::http_log::is_recording_enabled());

        // 关闭：落库为 "false" 且运行期开关立即关闭
        assert!(!set_http_log_recording(false).unwrap());
        assert_eq!(
            config_api::get_config(RECORD_HTTP_LOG_KEY).unwrap(),
            "false"
        );
        assert!(!legado_net::http_log::is_recording_enabled());
    }

    #[test]
    fn test_restore_reads_persisted_value() {
        let _g = TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        config_api::set_config(RECORD_HTTP_LOG_KEY, "true").unwrap();
        restore_http_log_recording();
        assert!(
            legado_net::http_log::is_recording_enabled(),
            "启动恢复应按 caches 值回填运行期开关"
        );
        // 复位（缺省关闭），避免影响同进程其他用例
        config_api::set_config(RECORD_HTTP_LOG_KEY, "false").unwrap();
        restore_http_log_recording();
        assert!(!legado_net::http_log::is_recording_enabled());
    }
}
