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
use rusqlite::{Connection, Transaction, TransactionBehavior};

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
        // 幂等修复步骤（不占版本号）：原 Rust 自有 v96 补列迁移已改造为此函数，
        // 无论当前版本号如何均先执行，保证 books/rssSources 列完整
        migration::migrations::repair_legacy_columns(conn)?;

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
        // Task #21：幂等清理历史换源 Bug 遗留的空 bookUrl 僵尸书籍（无僵尸时为空操作）
        migration::migrations::cleanup_zombie_books(conn)?;
        Ok(())
    }

    /// 校验并修复 schema 完整性：确保所有必要列存在
    ///
    /// 解决数据库 user_version 已标记为最新版本但实际缺少列的问题
    /// （可能由早期代码直接设置版本号但未执行完整迁移导致）。
    /// 复用幂等修复函数 [`migration::migrations::repair_legacy_columns`]。
    fn ensure_schema_integrity(conn: &Connection) -> LegadoResult<()> {
        migration::migrations::repair_legacy_columns(conn)
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

/// 在单个数据库事务内执行批量写入闭包（批量导入共享事务边界，P1-1）
///
/// 语义：
/// - **autocommit 连接**：`BEGIN IMMEDIATE` → 执行闭包 → 成功 `COMMIT` 后才
///   返回 `Ok`；闭包返回 `Err` 时 `Transaction` 在 drop 中回滚，调用方观察到
///   `Err` 且库内零改动（不会出现前 k-1 条已提交、第 k 条失败的部分成功态）。
/// - **已处于外层显式事务内**（`is_autocommit() == false`）：不再发起
///   `BEGIN`，直接在既有事务内执行闭包，避免 "cannot start a transaction
///   within a transaction" 嵌套错误；提交/回滚由外层事务负责（组合语义）。
///
/// # 为什么是 `TransactionBehavior::Immediate`（P1 并发缺陷修复）
///
/// 本函数的调用方全部是**写事务**（2026-11-17 盘点：16 个生产调用点无一纯读），
/// 且其中多处在闭包内**先读后写**（典型：[`crate::repository::book_source_repository::BookSourceRepository::update_with_check_state`]
/// 先 `find_by_url` 读旧源/旧状态、再 `insert` 写回）。若用 DEFERRED（`BEGIN`
/// 不取锁、首条语句才定读/写角色），事务会先建立**读快照**；一旦另一连接在
/// 「读完成、写开始」窗口内提交了写入，本连接从读快照升级为写会立即失败
/// `SQLITE_BUSY_SNAPSHOT`（报 `database is locked`），而 **`busy_timeout`
/// 对这种快照升级失败完全无效**（SQLite 不会重试）。生产上「书源校验写回 +
/// 用户编辑」「备份恢复（读旧行→写新行）」等并发路径都会命中。
///
/// `BEGIN IMMEDIATE` 在事务起点就取写锁：后续读到的都是最新已提交状态，
/// 不存在快照升级，竞争退化为常规的锁等待并由 `busy_timeout=5000` 兜住。
/// 仓内先例：`legado_ffi::api::privacy_api`（隐私密码写事务）、`reader.rs` 的
/// 本地目录落库、`video_api.rs` 的章节 variable 读-改-写均显式使用 IMMEDIATE。
///
/// 性能影响：调用方本就全部写入，DEFERRED 也会在首条写语句处取同一把写锁，
/// 提前到 `BEGIN` 的额外串行窗口仅为本闭包开头的少量读语句；纯读路径（不走
/// 本函数）在 WAL 下不受写锁阻塞（见 `test_in_transaction_does_not_block_wal_readers`）。
///
/// 背景：rusqlite 0.41.1（当前版本；0.31 起即如此）的
/// `Connection::transaction` 需要 `&mut Connection`，而本项目连接经 r2d2 池
/// 共享为 `&Connection`，故沿用项目既有的 `Transaction::new_unchecked` 模式
/// （见 source_switch / reader / toc_update）。升级后签名未变，结论仍成立。
pub fn in_transaction<T, F>(conn: &Connection, context: &str, f: F) -> LegadoResult<T>
where
    F: FnOnce(&Connection) -> LegadoResult<T>,
{
    if !conn.is_autocommit() {
        // 外层事务已生效（unchecked_transaction 的 BEGIN 已执行）：复用之，
        // 不再嵌套 BEGIN；本层失败不替外层决定提交或回滚
        return f(conn);
    }

    let tx = Transaction::new_unchecked(conn, TransactionBehavior::Immediate).map_err(|e| {
        LegadoError::Database(format!("{context}: 开启事务失败（BEGIN IMMEDIATE）: {e}"))
    })?;
    let result = f(conn)?;
    tx.commit()
        .map_err(|e| LegadoError::Database(format!("{context}: 提交事务失败: {e}")))?;
    Ok(result)
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

    // ─── 共享事务边界 in_transaction（P1-1 批量导入原子性） ───────────────

    /// 闭包返回 Err：已执行的插入必须整体回滚，库内零改动
    #[test]
    fn test_in_transaction_rolls_back_on_error() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        conn.execute_batch("CREATE TEMP TABLE tx_probe (id INTEGER)")
            .unwrap();

        let err = in_transaction(conn, "回滚测试", |conn| -> LegadoResult<()> {
            conn.execute("INSERT INTO tx_probe (id) VALUES (1)", [])
                .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
            Err(LegadoError::Database("模拟第 2 条失败".into()))
        })
        .unwrap_err();
        assert!(matches!(err, LegadoError::Database(_)));

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tx_probe", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 0, "闭包失败须回滚此前已执行的插入");
    }

    /// 闭包成功：整体提交，写入全部可见
    #[test]
    fn test_in_transaction_commits_on_success() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        conn.execute_batch("CREATE TEMP TABLE tx_probe (id INTEGER)")
            .unwrap();

        in_transaction(conn, "提交测试", |conn| {
            for id in 1..=2 {
                conn.execute(
                    "INSERT INTO tx_probe (id) VALUES (?1)",
                    rusqlite::params![id],
                )
                .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
            }
            Ok(())
        })
        .unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tx_probe", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 2);
    }

    /// 已在外层事务内：复用外层事务而非嵌套 BEGIN（否则报
    /// "cannot start a transaction within a transaction"）
    #[test]
    fn test_in_transaction_reuses_outer_transaction() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        conn.execute_batch("CREATE TEMP TABLE tx_probe (id INTEGER)")
            .unwrap();

        let tx = conn.unchecked_transaction().unwrap();
        in_transaction(conn, "内层", |conn| {
            conn.execute("INSERT INTO tx_probe (id) VALUES (7)", [])
                .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
            Ok(())
        })
        .expect("外层事务内调用不得嵌套 BEGIN");
        tx.commit().unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tx_probe", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "内层写入应随外层提交落库");
    }

    // ─── 并发：BEGIN IMMEDIATE 修复「先读后写」快照升级失败 ───────────────

    /// 建一个全新的文件库（WAL），返回连接池与文件路径
    ///
    /// 必须用**文件库**：`:memory:` 每条连接是独立数据库，无法复现两连接竞争。
    fn open_shared_file_db(tag: &str) -> (std::path::PathBuf, Pool<SqliteConnectionManager>) {
        let dir = std::env::temp_dir().join("legado_db_test_tx_behavior");
        std::fs::create_dir_all(&dir).expect("创建临时目录失败");
        let path = dir.join(format!("{tag}_{}.db", std::process::id()));
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
        let pool = {
            let db = Database::open(path.to_str().expect("临时路径须为合法 UTF-8")).unwrap();
            db.pool().clone()
        };
        {
            let seed = Database::from_pool(&pool).unwrap();
            seed.connection()
                .execute_batch(
                    "CREATE TABLE IF NOT EXISTS tx_race (id INTEGER PRIMARY KEY, v TEXT)",
                )
                .unwrap();
        }
        (path, pool)
    }

    fn remove_file_db(path: &std::path::Path) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
    }

    /// 并发回归：A 在事务内「先读后写」，B 在中间提交写入 → A 不得失败
    ///
    /// 缺陷复现（修复前必红）：`in_transaction` 用 DEFERRED（裸 `BEGIN`），
    /// A 的首条 SELECT 建立读快照；B 在 A「读完成、写开始」窗口内提交后，
    /// A 的写语句升级快照立即失败 `database is locked`（SQLITE_BUSY_SNAPSHOT，
    /// **`busy_timeout=5000` 对此完全不重试**）。
    ///
    /// 修复后（BEGIN IMMEDIATE）：A 在事务起点即持写锁，B 的提交被挡在
    /// 锁外排队，A 读到的始终是最新已提交状态，写不会再失败。
    #[test]
    fn test_in_transaction_read_then_write_survives_concurrent_commit() {
        use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
        use std::sync::Arc;
        use std::thread;
        use std::time::{Duration, Instant};

        let (path, pool) = open_shared_file_db("race");

        let stop = Arc::new(AtomicBool::new(false));
        let commits = Arc::new(AtomicI64::new(0));

        // 写线程 B：独立连接上做自动提交写（不显式开事务），持续制造并发提交
        let writer = {
            let pool = pool.clone();
            let stop = Arc::clone(&stop);
            let commits = Arc::clone(&commits);
            thread::spawn(move || {
                let db = Database::from_pool(&pool).unwrap();
                let conn = db.connection();
                while !stop.load(Ordering::SeqCst) {
                    if conn
                        .execute("INSERT OR REPLACE INTO tx_race (id, v) VALUES (1, 'b')", [])
                        .is_ok()
                    {
                        commits.fetch_add(1, Ordering::SeqCst);
                    }
                }
            })
        };

        // 确保 B 已进入写循环（否则 A 的事务期间可能无并发写者）
        let wait_start = Instant::now();
        while commits.load(Ordering::SeqCst) == 0 {
            assert!(
                wait_start.elapsed() < Duration::from_secs(10),
                "写线程未能完成首次提交"
            );
            thread::sleep(Duration::from_millis(5));
        }

        let db_a = Database::from_pool(&pool).unwrap();
        let conn_a = db_a.connection();
        // 探针连接：用极短 busy_timeout 判定「A 是否在事务起点就持写锁」
        let db_probe = Database::from_pool(&pool).unwrap();
        let conn_probe = db_probe.connection();
        conn_probe.pragma_update(None, "busy_timeout", 50).unwrap();

        let mut commits_at_read = 0i64;
        let result = in_transaction(conn_a, "并发读后写", |conn| {
            // 1) 先读：DEFERRED 下这一刻建立读快照
            let _before: i64 = conn
                .query_row("SELECT COUNT(*) FROM tx_race", [], |row| row.get(0))
                .map_err(|e| LegadoError::Database(format!("事务内读失败: {e}")))?;
            commits_at_read = commits.load(Ordering::SeqCst);

            // 2) 留出「读完成、写开始」窗口：DEFERRED 下 B 会在此窗口内提交，
            //    使 A 的快照过期；IMMEDIATE 下 A 已持写锁，B 只能排队
            thread::sleep(Duration::from_millis(300));

            // 3) 再写：DEFERRED 下此处快照升级失败（`database is locked`，
            //    busy_timeout 不生效）——修复前本断言即红
            conn.execute("INSERT OR REPLACE INTO tx_race (id, v) VALUES (2, 'a')", [])
                .map_err(|e| LegadoError::Database(format!("事务内写失败: {e}")))?;

            // 4) 确定性证据：IMMEDIATE 在事务起点即持写锁，探针连接（50ms
            //    busy_timeout）此刻拿不到写锁；DEFERRED 下它能拿到 → 本断言红
            assert!(
                Transaction::new_unchecked(conn_probe, TransactionBehavior::Immediate).is_err(),
                "事务起点应已持写锁；探针连接却拿到了写锁，说明仍是 DEFERRED"
            );
            Ok(())
        });

        stop.store(true, Ordering::SeqCst);
        writer.join().expect("写线程不应 panic");

        result.expect(
            "并发读后写事务不得失败：BEGIN IMMEDIATE 已取写锁，\
             其他连接的提交应在 busy_timeout 内排队而非触发 SQLITE_BUSY_SNAPSHOT",
        );
        assert!(
            commits.load(Ordering::SeqCst) > commits_at_read,
            "写线程应至少成功提交一次，否则未构成并发竞争"
        );

        let written: i64 = db_a
            .connection()
            .query_row("SELECT COUNT(*) FROM tx_race WHERE id = 2", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(written, 1, "A 的写入必须随事务提交落库");

        drop(db_probe);
        drop(db_a);
        drop(pool);
        remove_file_db(&path);
    }

    /// 性能回退核查：写事务期间 WAL 纯读连接不被阻塞
    ///
    /// `BEGIN IMMEDIATE` 只是把写锁提前到事务起点，不影响 WAL 的读写并发：
    /// 读连接读的是最近已提交快照，既不等待写锁，也读不到未提交改动。
    /// 若此处阻塞，读路径会等满 busy_timeout(5s) 再报错——故以 1s 上界断言。
    #[test]
    fn test_in_transaction_does_not_block_wal_readers() {
        use std::time::{Duration, Instant};

        let (path, pool) = open_shared_file_db("reader");

        let db_a = Database::from_pool(&pool).unwrap();
        let conn_a = db_a.connection();
        let db_reader = Database::from_pool(&pool).unwrap();
        let reader = db_reader.connection();

        in_transaction(conn_a, "写事务持有写锁", |conn| {
            conn.execute(
                "INSERT OR REPLACE INTO tx_race (id, v) VALUES (1, 'uncommitted')",
                [],
            )
            .map_err(|e| LegadoError::Database(format!("事务内写失败: {e}")))?;

            let started = Instant::now();
            let visible: i64 = reader
                .query_row("SELECT COUNT(*) FROM tx_race", [], |row| row.get(0))
                .map_err(|e| LegadoError::Database(format!("并发读失败: {e}")))?;
            let elapsed = started.elapsed();

            assert!(
                elapsed < Duration::from_secs(1),
                "WAL 读连接不得被写事务阻塞（实测 {elapsed:?}，busy_timeout 为 5s）"
            );
            assert_eq!(visible, 0, "读连接只应看到已提交快照，不得读到未提交写入");
            Ok(())
        })
        .expect("写事务应成功提交");

        let after: i64 = reader
            .query_row("SELECT COUNT(*) FROM tx_race", [], |row| row.get(0))
            .unwrap();
        assert_eq!(after, 1, "事务提交后读连接应看到新行");

        drop(db_reader);
        drop(db_a);
        drop(pool);
        remove_file_db(&path);
    }
}
