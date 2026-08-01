//! 数据库连接管理（基于 r2d2 连接池实现读写分离）
//!
//! 核心设计：
//! - `Database` 持有 `r2d2::Pool` + 一个 `PooledConnection`（per-call 包装器）
//! - `connection()` 返回 `&Connection`（通过 Deref），所有调用点零修改
//! - 每个池连接自动设置 PRAGMA（journal_mode=WAL, busy_timeout=5000 等）
//! - `auto_migrate` 仅在建池前执行一次，不在每个连接上重复执行
//! - 多线程并发：每次 `with_database` 调用创建独立 `Database`，各持一个池连接

use std::time::Duration;

use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{self, MigrationRegistry};
use crate::schema;

/// 默认连接池大小
const DEFAULT_POOL_SIZE: u32 = 16;

/// 连接池 PRAGMA 自定义器：在每个池连接创建时自动执行
///
/// 设置的 PRAGMA：
/// - `journal_mode = WAL`：允许并发读写
/// - `foreign_keys = ON`：启用外键约束
/// - `synchronous = NORMAL`：平衡性能与安全
/// - `busy_timeout = 5000`：等待锁释放最多 5 秒，防止 SQLITE_BUSY
#[derive(Debug)]
struct PragmaCustomizer;

impl r2d2::CustomizeConnection<Connection, rusqlite::Error> for PragmaCustomizer {
    fn on_acquire(&self, conn: &mut Connection) -> Result<(), rusqlite::Error> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "busy_timeout", 5000)?;
        Ok(())
    }
}

/// 数据库包装器，持有 r2d2 连接池 + 一个池连接
///
/// 每次通过 `with_database` 访问时，从池中获取一个独立连接包装为 `Database`。
/// 当 `Database` 被 drop 时，连接自动归还到池中。
///
/// `connection()` 返回 `&Connection`（通过 `PooledConnection` 的 Deref），
/// 所有 Repository 调用点无需任何修改。
pub struct Database {
    /// 连接池（Arc 内部共享，clone 开销极低）
    pool: Pool<SqliteConnectionManager>,
    /// 当前持有的池连接（drop 时自动归还到 pool）
    conn: r2d2::PooledConnection<SqliteConnectionManager>,
}

impl Database {
    /// 打开或创建指定路径的数据库文件，自动执行增量迁移
    ///
    /// 流程：临时连接执行迁移 → 创建连接池 → 获取一个池连接
    pub fn open(path: &str) -> LegadoResult<Self> {
        // 阶段1：在临时连接上执行一次性迁移（文件数据库，数据持久化到磁盘）
        let temp_conn = Connection::open(path)
            .map_err(|e| LegadoError::Database(format!("打开数据库失败: {e}")))?;
        Self::init_pragmas(&temp_conn)?;
        Self::auto_migrate(&temp_conn)?;
        drop(temp_conn);

        // 阶段2：创建连接池（每个连接由 PragmaCustomizer 自动设置 PRAGMA）
        let manager = SqliteConnectionManager::file(path);
        let pool = Self::build_pool(manager, DEFAULT_POOL_SIZE)?;
        let conn = pool
            .get()
            .map_err(|e| LegadoError::Database(format!("获取池连接失败: {e}")))?;
        Ok(Self { pool, conn })
    }

    /// 打开内存数据库（用于测试），自动执行迁移
    ///
    /// 内存数据库池大小固定为 1（每个 `:memory:` 连接是独立数据库，无法共享）
    pub fn open_in_memory() -> LegadoResult<Self> {
        let manager = SqliteConnectionManager::memory();
        let pool = Self::build_pool(manager, 1)?;
        let conn = pool
            .get()
            .map_err(|e| LegadoError::Database(format!("获取池连接失败: {e}")))?;

        // 在持有的连接上执行迁移（pool size=1，始终复用同一连接，数据保留）
        Self::auto_migrate(&conn)?;

        Ok(Self { pool, conn })
    }

    /// 打开数据库但不执行迁移（用于测试迁移流程）
    pub fn open_raw(path: &str) -> LegadoResult<Self> {
        let temp_conn = Connection::open(path)
            .map_err(|e| LegadoError::Database(format!("打开数据库失败: {e}")))?;
        Self::init_pragmas(&temp_conn)?;
        drop(temp_conn);

        let manager = SqliteConnectionManager::file(path);
        let pool = Self::build_pool(manager, DEFAULT_POOL_SIZE)?;
        let conn = pool
            .get()
            .map_err(|e| LegadoError::Database(format!("获取池连接失败: {e}")))?;
        Ok(Self { pool, conn })
    }

    /// 打开内存数据库但不执行迁移（用于测试）
    pub fn open_in_memory_raw() -> LegadoResult<Self> {
        let manager = SqliteConnectionManager::memory();
        let pool = Self::build_pool(manager, 1)?;
        let conn = pool
            .get()
            .map_err(|e| LegadoError::Database(format!("获取池连接失败: {e}")))?;
        Ok(Self { pool, conn })
    }

    /// 从已有连接池创建 Database（获取一个池连接）
    ///
    /// 用于 `with_database` 等需要从全局池获取连接的场景。
    pub fn from_pool(pool: &Pool<SqliteConnectionManager>) -> LegadoResult<Self> {
        let conn = pool
            .get()
            .map_err(|e| LegadoError::Database(format!("获取池连接失败: {e}")))?;
        Ok(Self {
            pool: pool.clone(),
            conn,
        })
    }

    /// 获取底层连接池引用
    pub fn pool(&self) -> &Pool<SqliteConnectionManager> {
        &self.pool
    }

    /// 构建连接池（统一入口）
    ///
    /// 对于内存数据库（max_size=1），禁用 idle_timeout 和 max_lifetime，
    /// 防止 r2d2 reaper 关闭唯一连接后下次 pool.get() 创建新的空 :memory: 数据库。
    fn build_pool(
        manager: SqliteConnectionManager,
        max_size: u32,
    ) -> LegadoResult<Pool<SqliteConnectionManager>> {
        let is_in_memory = max_size == 1;
        let mut builder = Pool::builder()
            .max_size(max_size)
            .connection_timeout(Duration::from_secs(10))
            .connection_customizer(Box::new(PragmaCustomizer));
        if is_in_memory {
            // 内存数据库池大小固定为 1，禁止 reaper 回收唯一连接
            builder = builder.idle_timeout(None).max_lifetime(None);
        }
        let pool = builder
            .build(manager)
            .map_err(|e| LegadoError::Database(format!("创建连接池失败: {e}")))?;
        Ok(pool)
    }

    /// 自动迁移：检查版本并执行必要的迁移（仅调用一次）
    fn auto_migrate(conn: &Connection) -> LegadoResult<()> {
        let version = MigrationRegistry::current_version(conn)?;
        if version == 0 {
            // 全新数据库，创建最新 schema
            schema::init_schema(conn)?;
            conn.pragma_update(None, "user_version", schema::SCHEMA_VERSION)
                .map_err(|e| LegadoError::Database(format!("设置版本失败: {e}")))?;
        } else if version < schema::SCHEMA_VERSION {
            // 执行增量迁移
            let registry = MigrationRegistry::new();
            registry.migrate_to_latest(conn)?;
        }
        // 无论版本号如何，始终校验列完整性（修复版本号与实际 schema 不一致的情况）
        Self::ensure_schema_integrity(conn)?;
        Ok(())
    }

    /// 校验并修复 schema 完整性：确保所有必要列存在
    ///
    /// 解决数据库 user_version 已标记为最新版本但实际缺少列的问题
    /// （可能由早期代码直接设置版本号但未执行完整迁移导致）
    fn ensure_schema_integrity(conn: &Connection) -> LegadoResult<()> {
        use migration::{add_column_if_not_exists, table_exists};

        if table_exists(conn, "rssSources")? {
            add_column_if_not_exists(conn, "rssSources", "contentWhitelist", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "contentBlacklist", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "shouldOverrideUrlLoading", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "injectJs", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "preloadJs", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "startHtml", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "startStyle", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "startJs", "TEXT")?;
            add_column_if_not_exists(conn, "rssSources", "showWebLog", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssSources", "type", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssSources", "preload", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssSources", "cacheFirst", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssSources", "searchUrl", "TEXT")?;
        }

        if table_exists(conn, "books")? {
            add_column_if_not_exists(conn, "books", "infoHtml", "TEXT DEFAULT ''")?;
            add_column_if_not_exists(conn, "books", "tocHtml", "TEXT DEFAULT ''")?;
            add_column_if_not_exists(conn, "books", "downloadUrls", "TEXT DEFAULT ''")?;
            add_column_if_not_exists(conn, "books", "coverOrigin", "TEXT DEFAULT ''")?;
        }

        Ok(())
    }

    /// 获取底层 rusqlite 连接引用
    ///
    /// 通过 `PooledConnection` 的 `Deref<Target=Connection>` 返回 `&Connection`。
    /// 所有 Repository 调用 `db.connection()` 的代码无需任何修改。
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// 设置常用 PRAGMA 优化参数（用于临时连接的一次性初始化）
    ///
    /// 池连接的 PRAGMA 由 `PragmaCustomizer` 自动设置，此方法仅用于迁移前的临时连接。
    fn init_pragmas(conn: &Connection) -> LegadoResult<()> {
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| LegadoError::Database(format!("设置 journal_mode 失败: {e}")))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| LegadoError::Database(format!("设置 foreign_keys 失败: {e}")))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| LegadoError::Database(format!("设置 synchronous 失败: {e}")))?;
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(|e| LegadoError::Database(format!("设置 busy_timeout 失败: {e}")))?;
        Ok(())
    }

    /// 获取当前数据库版本（user_version）
    pub fn get_version(&self) -> LegadoResult<u32> {
        let version: u32 = self
            .conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("查询版本失败: {e}")))?;
        Ok(version)
    }

    /// 设置数据库版本（user_version）
    pub fn set_version(&self, version: u32) -> LegadoResult<()> {
        self.conn
            .pragma_update(None, "user_version", version)
            .map_err(|e| LegadoError::Database(format!("设置版本失败: {e}")))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_open_in_memory() {
        let db = Database::open_in_memory().unwrap();
        // Should be able to get connection
        let _conn = db.connection();
    }

    #[test]
    fn test_pragmas_set() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        let fk: i32 = conn
            .pragma_query_value(None, "foreign_keys", |row| row.get(0))
            .unwrap();
        assert_eq!(fk, 1);
        let sync: i32 = conn
            .pragma_query_value(None, "synchronous", |row| row.get(0))
            .unwrap();
        assert_eq!(sync, 1); // NORMAL = 1
    }

    #[test]
    fn test_busy_timeout_set() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        let bt: i32 = conn
            .pragma_query_value(None, "busy_timeout", |row| row.get(0))
            .unwrap();
        assert_eq!(bt, 5000);
    }

    #[test]
    fn test_version_get_set() {
        let db = Database::open_in_memory_raw().unwrap();
        let v = db.get_version().unwrap();
        assert_eq!(v, 0); // fresh db
        db.set_version(42).unwrap();
        assert_eq!(db.get_version().unwrap(), 42);
    }

    #[test]
    fn test_auto_migrate_fresh() {
        // open_in_memory 自动迁移到最新版本
        let db = Database::open_in_memory().unwrap();
        let v = db.get_version().unwrap();
        assert_eq!(v, schema::SCHEMA_VERSION);
    }

    #[test]
    fn test_auto_migrate_tables_exist() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        // 验证核心表存在
        let tables = ["books", "book_sources", "chapters", "auto_task_rules"];
        for table in &tables {
            let count: i32 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "Table {} should exist", table);
        }
    }

    #[test]
    fn test_pool_concurrent_file_db() {
        // 验证连接池支持多线程并发访问（使用文件数据库）
        use std::sync::{Arc, Barrier};
        use std::thread;

        let dir = std::env::temp_dir().join("legado_db_test_concurrent");
        let _ = std::fs::create_dir_all(&dir);
        let db_path = dir.join("test_concurrent.db");
        let db_path_str = db_path.to_str().unwrap();

        // 清理旧文件
        let _ = std::fs::remove_file(&db_path);

        let db = Database::open(db_path_str).unwrap();
        let pool = db.pool().clone();
        drop(db); // 释放初始连接

        let barrier = Arc::new(Barrier::new(8));
        let mut handles = Vec::new();

        for i in 0..8 {
            let pool = pool.clone();
            let barrier = Arc::clone(&barrier);
            handles.push(thread::spawn(move || {
                barrier.wait();
                let db = Database::from_pool(&pool).unwrap();
                let conn = db.connection();
                // 写入
                conn.execute(
                    "INSERT INTO books (bookUrl, tocUrl, origin, originName, name, author) VALUES (?1, '', 'test', 'test', ?2, 'test')",
                    rusqlite::params![format!("url_{i}"), format!("book_{i}")],
                )
                .unwrap();
                // 读取
                let count: i32 = conn
                    .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
                    .unwrap();
                assert!(count >= 1);
            }));
        }

        for h in handles {
            h.join().expect("线程不应 panic");
        }

        // 验证所有写入成功
        let db = Database::from_pool(&pool).unwrap();
        let conn = db.connection();
        let total: i32 = conn
            .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
            .unwrap();
        assert_eq!(total, 8);

        // 清理
        drop(db);
        let _ = std::fs::remove_file(&db_path);
        let _ = std::fs::remove_dir(&dir);
    }
}
