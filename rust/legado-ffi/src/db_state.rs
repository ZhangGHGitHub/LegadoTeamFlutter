//! 全局数据库状态管理
//!
//! FFI 层持有一个全局 `Database` 实例，通过 `Mutex` + `OnceLock` 管理。
//! 由 `ffi_db_open` 初始化，各 API 模块通过 `with_database` / `with_database_mut` 访问。

use std::sync::{Mutex, OnceLock};

use legado_core::{LegadoError, LegadoResult};
use legado_db::Database;

/// 全局数据库实例
static DB_INSTANCE: OnceLock<Mutex<Option<Database>>> = OnceLock::new();

/// 获取全局 Mutex 引用
fn get_db_slot() -> &'static Mutex<Option<Database>> {
    DB_INSTANCE.get_or_init(|| Mutex::new(None))
}

/// 初始化全局数据库（由 `ffi_db_open` 调用）
pub fn init_database(db: Database) {
    let slot = get_db_slot();
    let mut guard = slot.lock().expect("Database mutex poisoned");
    *guard = Some(db);
}

/// 以不可变方式访问数据库，执行闭包
pub fn with_database<F, R>(f: F) -> LegadoResult<R>
where
    F: FnOnce(&Database) -> LegadoResult<R>,
{
    let slot = get_db_slot();
    let guard = slot
        .lock()
        .map_err(|_| LegadoError::Internal("数据库互斥锁被毒化".into()))?;
    let db = guard
        .as_ref()
        .ok_or_else(|| LegadoError::Database("数据库尚未初始化，请先调用 db_open".into()))?;
    f(db)
}

/// 测试专用：确保全局数据库已初始化（仅执行一次，并行安全）
#[cfg(test)]
pub fn ensure_test_db() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let db = legado_db::init_in_memory_database().expect("Failed to init test database");
        init_database(db);
    });
}
