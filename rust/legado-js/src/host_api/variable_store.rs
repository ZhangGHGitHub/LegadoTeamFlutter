//! 变量存储 API
//!
//! 提供全局变量存取功能，对应 Kotlin 端 `JsExtensions` 中
//! AnalyzeRule 变量表的功能：
//! - getVariable(key) — 获取变量
//! - setVariable(key, value) — 设置变量
//! - removeVariable(key) — 删除变量
//! - clearVariables() — 清空所有变量

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

/// 全局变量存储（线程安全单例）
///
/// 对应 Kotlin 端 AnalyzeRule 变量映射。
/// 使用 `Arc<Mutex<HashMap>>` 保证线程安全。
static GLOBAL_VARIABLES: LazyLock<Arc<Mutex<HashMap<String, String>>>> =
    LazyLock::new(|| Arc::new(Mutex::new(HashMap::new())));

/// 获取全局变量映射的句柄（用于注入到 QuickJS 上下文）
pub fn get_variable_store() -> Arc<Mutex<HashMap<String, String>>> {
    Arc::clone(&GLOBAL_VARIABLES)
}

/// 获取变量值
///
/// 对应 Kotlin: `getVariable(key)`
pub fn get_variable(key: &str) -> Result<Option<String>, String> {
    let store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.get(key).cloned())
}

/// 设置变量值
///
/// 对应 Kotlin: `setVariable(key, value)`
pub fn set_variable(key: &str, value: &str) -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.insert(key.to_string(), value.to_string());
    Ok(())
}

/// 删除变量
pub fn remove_variable(key: &str) -> Result<Option<String>, String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.remove(key))
}

/// 清空所有变量
pub fn clear_variables() -> Result<(), String> {
    let mut store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    store.clear();
    Ok(())
}

/// 获取所有变量名
pub fn list_variable_keys() -> Result<Vec<String>, String> {
    let store = GLOBAL_VARIABLES
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(store.keys().cloned().collect())
}

// ============================================================
// 单元测试
// ============================================================
#[cfg(test)]
mod tests {
    use super::*;

    fn reset_store() {
        clear_variables().unwrap();
    }

    #[test]
    fn test_set_and_get_variable() {
        reset_store();
        set_variable("foo", "bar").unwrap();
        assert_eq!(get_variable("foo").unwrap(), Some("bar".to_string()));
    }

    #[test]
    fn test_get_nonexistent_variable() {
        reset_store();
        assert_eq!(get_variable("nonexistent").unwrap(), None);
    }

    #[test]
    fn test_overwrite_variable() {
        reset_store();
        set_variable("key", "v1").unwrap();
        set_variable("key", "v2").unwrap();
        assert_eq!(get_variable("key").unwrap(), Some("v2".to_string()));
    }

    #[test]
    fn test_remove_variable() {
        reset_store();
        set_variable("to_remove", "value").unwrap();
        let removed = remove_variable("to_remove").unwrap();
        assert_eq!(removed, Some("value".to_string()));
        assert_eq!(get_variable("to_remove").unwrap(), None);
    }

    #[test]
    fn test_clear_variables() {
        reset_store();
        set_variable("a", "1").unwrap();
        set_variable("b", "2").unwrap();
        clear_variables().unwrap();
        assert_eq!(get_variable("a").unwrap(), None);
        assert_eq!(get_variable("b").unwrap(), None);
    }

    #[test]
    fn test_list_variable_keys() {
        reset_store();
        set_variable("x", "1").unwrap();
        set_variable("y", "2").unwrap();
        let keys = list_variable_keys().unwrap();
        // Due to parallel tests sharing global state, just check our keys are present
        assert!(keys.contains(&"x".to_string()));
        assert!(keys.contains(&"y".to_string()));
    }

    #[test]
    fn test_get_variable_store_handle() {
        let store = get_variable_store();
        let mut guard = store.lock().unwrap();
        guard.insert("handle_test".to_string(), "ok".to_string());
        drop(guard);
        assert_eq!(get_variable("handle_test").unwrap(), Some("ok".to_string()));
    }
}
