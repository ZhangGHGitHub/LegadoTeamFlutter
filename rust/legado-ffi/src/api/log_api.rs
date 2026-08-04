//! 应用日志 FFI API（Task #79）
//!
//! 基于 [`legado_core::app_log`] 环形缓冲，向 Dart 侧暴露日志
//! 写入 / 查询 / 清空 / 导出能力，供日志页面（UI 轨）消费。
//!
//! 对齐 Kotlin `AppLog.kt` / `AppLogDialog.kt`（上游 #512/#524/#543）：
//! - 级别字符串：`"message"` / `"crash"` / `"http"`（大小写不敏感）
//! - 列表返回最新在前（对齐 `AppLog.logs`）
//! - 导出为格式化文本并按 64_000 字符截断（对齐 #543 `MAX_SHARE_TEXT`）
//!
//! 纯内存缓冲，无数据库依赖，任意时机可调用。

use legado_core::app_log::{LogEntry, LogLevel};
use legado_core::LegadoError;

/// 解析级别字符串，非法值返回错误
fn parse_level(level: &str) -> Result<LogLevel, LegadoError> {
    LogLevel::parse(level).ok_or_else(|| {
        LegadoError::Ffi(format!(
            "无效的日志级别: '{level}'（可选 message / crash / http）"
        ))
    })
}

/// 写入一条日志
///
/// `level` — 级别字符串（message / crash / http，大小写不敏感）
/// `message` — 日志消息（空消息忽略，对齐 Kotlin `put` 的 `message ?: return`）
pub fn push_log(level: &str, message: &str) -> Result<(), LegadoError> {
    let level = parse_level(level)?;
    if message.is_empty() {
        return Ok(());
    }
    legado_core::app_log::push_log(level, message);
    Ok(())
}

/// 获取指定级别的日志列表（最新在前）
pub fn list_logs(level: &str) -> Result<Vec<LogEntry>, LegadoError> {
    let level = parse_level(level)?;
    Ok(legado_core::app_log::get_logs(level))
}

/// 清空指定级别的日志
pub fn clear_logs(level: &str) -> Result<(), LegadoError> {
    let level = parse_level(level)?;
    legado_core::app_log::clear_logs(level);
    Ok(())
}

/// 清空全部级别日志（对齐 #543 清空确认后的 `AppLog.clear() + HttpLogStore.clear()`）
pub fn clear_all_logs() -> Result<(), LegadoError> {
    legado_core::app_log::app_log_store().clear_all();
    Ok(())
}

/// 导出全部日志为格式化文本（时间升序，64_000 字符截断，对齐 #543）
pub fn export_logs() -> Result<String, LegadoError> {
    Ok(legado_core::app_log::export_logs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::app_log::AppLogStore;

    /// 串行保护：以下测试读写全局日志单例，需串行执行避免相互干扰
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn test_push_and_list() {
        let _g = TEST_LOCK.lock().unwrap();
        legado_core::app_log::app_log_store().clear_all();

        push_log("message", "FFI 写入测试").unwrap();
        push_log("MESSAGE", "大小写不敏感").unwrap();
        let logs = list_logs("message").unwrap();
        assert_eq!(logs.len(), 2);
        assert_eq!(logs[0].message, "大小写不敏感", "最新在前");

        // 空消息忽略（对齐 Kotlin put 的 null 短路）
        push_log("message", "").unwrap();
        assert_eq!(list_logs("message").unwrap().len(), 2);
    }

    #[test]
    fn test_invalid_level() {
        let _g = TEST_LOCK.lock().unwrap();
        assert!(push_log("verbose", "x").is_err());
        assert!(list_logs("debug").is_err());
        assert!(clear_logs("warn").is_err());
    }

    #[test]
    fn test_clear_and_export() {
        let _g = TEST_LOCK.lock().unwrap();
        legado_core::app_log::app_log_store().clear_all();

        push_log("message", "消息条目").unwrap();
        push_log("crash", "崩溃条目").unwrap();
        push_log("http", "GET / 200 5ms").unwrap();

        let text = export_logs().unwrap();
        assert!(text.contains("[MESSAGE] 消息条目"));
        assert!(text.contains("[CRASH] 崩溃条目"));
        assert!(text.contains("[HTTP] GET / 200 5ms"));

        // 分级清空
        clear_logs("crash").unwrap();
        assert!(list_logs("crash").unwrap().is_empty());
        assert_eq!(list_logs("message").unwrap().len(), 1);

        // 全量清空
        clear_all_logs().unwrap();
        for level in ["message", "crash", "http"] {
            assert!(list_logs(level).unwrap().is_empty());
        }
    }

    #[test]
    fn test_log_entry_serialization_for_dart() {
        let _g = TEST_LOCK.lock().unwrap();
        legado_core::app_log::app_log_store().clear_all();

        push_log("http", "序列化校验").unwrap();
        let logs = list_logs("http").unwrap();
        let json = serde_json::to_string(&logs).unwrap();
        // Dart 侧按 camelCase 字段解析：timestamp / level / message
        assert!(json.contains(r#""timestamp":"#));
        assert!(json.contains(r#""level":"http""#));
        assert!(json.contains(r#""message":"序列化校验""#));
    }

    /// 直接驱动 AppLogStore 验证环形淘汰经由 FFI 层可见
    #[test]
    fn test_capacity_visible_via_api() {
        let _g = TEST_LOCK.lock().unwrap();
        legado_core::app_log::app_log_store().clear_all();

        for i in 0..(legado_core::app_log::MAX_LOGS_PER_LEVEL + 5) {
            push_log("message", &format!("第 {i} 条")).unwrap();
        }
        let logs = list_logs("message").unwrap();
        assert_eq!(logs.len(), legado_core::app_log::MAX_LOGS_PER_LEVEL);
    }

    /// 确认 [`AppLogStore`] 公共 API 表面（防止意外破坏 FFI 依赖面）
    #[test]
    fn test_store_api_surface() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::default();
        store.push(LogLevel::Message, "x");
        assert!(!store.is_empty(LogLevel::Message));
        assert_eq!(store.len(LogLevel::Message), 1);
        store.clear_all();
        assert!(store.is_empty(LogLevel::Message));
    }
}
