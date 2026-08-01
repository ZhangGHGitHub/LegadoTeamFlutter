//! 全局数据库状态管理
//!
//! FFI 层持有一个全局 r2d2 连接池，通过 `OnceLock` 管理。
//! 由 `ffi_db_open` 初始化，各 API 模块通过 `with_database` 访问。
//!
//! 连接池保证：
//! - 多线程可并发调用 `with_database`，每次获取独立的池连接
//! - `Pool` 是 `Send + Sync`，无需 `Mutex` 保护
//! - 当 `Database`（per-call 包装器）被 drop 时，连接自动归还到池中

use std::sync::OnceLock;

use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;

use legado_core::{LegadoError, LegadoResult};
use legado_db::Database;

/// 全局连接池（线程安全，内部使用 Arc 共享）
static DB_POOL: OnceLock<Pool<SqliteConnectionManager>> = OnceLock::new();

/// 初始化全局数据库连接池（由 `ffi_db_open` 调用）
///
/// 从 `Database` 实例中提取连接池并存储到全局状态。
/// 仅首次调用生效，后续调用记录警告并返回 Ok（避免冗余的 Database::open 开销）。
pub fn init_database(db: Database) -> LegadoResult<()> {
    // 已初始化时跳过，避免重复构建池的开销
    if DB_POOL.get().is_some() {
        eprintln!("[legado-ffi] 数据库已初始化，忽略重复调用");
        return Ok(());
    }
    let pool = db.pool().clone();
    DB_POOL.set(pool).ok(); // First-wins，上方已记录日志
    Ok(())
}

/// 检查全局数据库是否已初始化
pub fn is_initialized() -> bool {
    DB_POOL.get().is_some()
}

/// 以不可变方式访问数据库，执行闭包
///
/// 每次调用从连接池获取独立连接，包装为 `Database`，支持多线程并发访问。
/// 闭包结束后 `Database` 被 drop，连接自动归还到池中。
pub fn with_database<F, R>(f: F) -> LegadoResult<R>
where
    F: FnOnce(&Database) -> LegadoResult<R>,
{
    let pool = DB_POOL
        .get()
        .ok_or_else(|| LegadoError::Database("数据库尚未初始化，请先调用 db_open".into()))?;
    let db = Database::from_pool(pool)?;
    f(&db)
}

/// 测试专用：确保全局数据库已初始化（仅执行一次，并行安全）
#[cfg(test)]
pub fn ensure_test_db() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let db = legado_db::init_in_memory_database().expect("Failed to init test database");
        init_database(db).expect("Failed to set global database");
    });
}
