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

    /// 全局态快照-恢复守卫（仅测试用，照抄 config_api.rs StoreGuard 模式）
    ///
    /// 构造时快照 `GLOBAL_VARIABLES` 全量 `HashMap`，`Drop` 时整体恢复原内容
    /// ——panic 路径同样经 `Drop` 恢复。用于消除 cargo 默认多线程并行跑测时，
    /// `test_clear_variables` 的 `clear_variables()`（清空整表）与其他 set/get
    /// 类测试对进程级全局 `GLOBAL_VARIABLES` 的交叉污染：写入类测试结束（含
    /// panic）后自动恢复原值，不向后续/并行测试泄漏清空或残留状态。
    struct StoreGuard {
        previous: HashMap<String, String>,
    }

    impl StoreGuard {
        fn new() -> Self {
            let store = GLOBAL_VARIABLES.lock().unwrap_or_else(|p| p.into_inner());
            Self {
                previous: store.clone(),
            }
        }
    }

    impl Drop for StoreGuard {
        fn drop(&mut self) {
            let mut store = GLOBAL_VARIABLES.lock().unwrap_or_else(|p| p.into_inner());
            *store = self.previous.clone();
        }
    }

    /// 测试间互斥锁：串行化「触碰全局变量表的 7 个测试」，其余测试仍照常
    /// 并行。避免 `clear_variables()`（整表清空）与写入/读取类测试真正并发
    /// 交错（如某测试 set 后、get 前被 clear 插入，导致读到 None）。
    static VARIABLES_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 获取测试互斥锁（panic 时经 Drop 自动释放，不会永久卡死后续测试）
    fn lock_variables() -> std::sync::MutexGuard<'static, ()> {
        VARIABLES_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner())
    }

    #[test]
    fn test_set_and_get_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("var_set_get", "bar").unwrap();
        assert_eq!(
            get_variable("var_set_get").unwrap(),
            Some("bar".to_string())
        );
    }

    #[test]
    fn test_get_nonexistent_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        assert_eq!(get_variable("var_never_exists_xyz").unwrap(), None);
    }

    #[test]
    fn test_overwrite_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let key = "var_overwrite";
        set_variable(key, "v1").unwrap();
        set_variable(key, "v2").unwrap();
        assert_eq!(get_variable(key).unwrap(), Some("v2".to_string()));
    }

    #[test]
    fn test_remove_variable() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let key = "var_remove_target";
        set_variable(key, "value").unwrap();
        let removed = remove_variable(key).unwrap();
        assert_eq!(removed, Some("value".to_string()));
        assert_eq!(get_variable(key).unwrap(), None);
    }

    #[test]
    fn test_clear_variables() {
        let _lock = lock_variables();
        // 守卫快照整表，测试结束（含 panic）恢复，避免 clear 泄漏给并行测试
        let _guard = StoreGuard::new();
        let key_a = "var_clear_a";
        let key_b = "var_clear_b";
        set_variable(key_a, "1").unwrap();
        set_variable(key_b, "2").unwrap();
        clear_variables().unwrap();
        assert_eq!(get_variable(key_a).unwrap(), None);
        assert_eq!(get_variable(key_b).unwrap(), None);
    }

    #[test]
    fn test_list_variable_keys() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        set_variable("var_list_x", "1").unwrap();
        set_variable("var_list_y", "2").unwrap();
        let keys = list_variable_keys().unwrap();
        assert!(keys.contains(&"var_list_x".to_string()));
        assert!(keys.contains(&"var_list_y".to_string()));
    }

    #[test]
    fn test_get_variable_store_handle() {
        let _lock = lock_variables();
        let _guard = StoreGuard::new();
        let store = get_variable_store();
        let mut guard = store.lock().unwrap();
        guard.insert("var_handle_test".to_string(), "ok".to_string());
        drop(guard);
        assert_eq!(
            get_variable("var_handle_test").unwrap(),
            Some("ok".to_string())
        );
    }
}
