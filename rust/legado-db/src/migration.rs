//! 数据库迁移管理
//!
//! 提供基于版本号的增量迁移框架：
//! - `Migration` trait 定义单次迁移的行为（含 up/down）
//! - `MigrationRegistry` 注册表管理所有版本间的迁移
//! - 使用 SQLite `user_version` PRAGMA 追踪当前版本

pub mod migrations;

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::schema;

/// 迁移 trait：定义从版本 from_version 升级到 to_version 的行为
pub trait Migration: Send + Sync {
    /// 起始版本号
    #[allow(clippy::wrong_self_convention)]
    fn from_version(&self) -> u32;
    /// 目标版本号
    fn to_version(&self) -> u32;
    /// 迁移描述
    fn description(&self) -> &str;
    /// 执行升级
    fn up(&self, conn: &Connection) -> LegadoResult<()>;
    /// 执行回退
    fn down(&self, conn: &Connection) -> LegadoResult<()>;
}

/// 迁移注册表 — 管理所有版本间的迁移
pub struct MigrationRegistry {
    migrations: Vec<Box<dyn Migration>>,
}

impl MigrationRegistry {
    pub fn new() -> Self {
        let mut registry = Self {
            migrations: Vec::new(),
        };
        registry.register_defaults();
        registry
    }

    /// 注册所有内置迁移
    fn register_defaults(&mut self) {
        self.register(Box::new(migrations::Migration90To91));
        self.register(Box::new(migrations::Migration91To92));
        self.register(Box::new(migrations::Migration92To93));
        self.register(Box::new(migrations::Migration93To94));
        self.register(Box::new(migrations::Migration94To95));
        self.register(Box::new(migrations::Migration95To96));
        self.register(Box::new(migrations::Migration96To97));
        self.register(Box::new(migrations::Migration97To98));
        self.register(Box::new(migrations::Migration98To99));
        self.register(Box::new(migrations::Migration99To100));
        self.register(Box::new(migrations::Migration100To101));
    }

    /// 注册单个迁移
    pub fn register(&mut self, migration: Box<dyn Migration>) {
        self.migrations.push(migration);
        self.migrations.sort_by_key(|m| m.from_version());
    }

    /// 获取当前数据库版本（user_version）
    pub fn current_version(conn: &Connection) -> LegadoResult<u32> {
        let version: u32 = conn
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("查询版本失败: {e}")))?;
        Ok(version)
    }

    /// 从指定版本迁移到最新版本
    pub fn migrate_to_latest(&self, conn: &Connection) -> LegadoResult<()> {
        let current = Self::current_version(conn)?;
        self.migrate_to(conn, schema::SCHEMA_VERSION, current)
    }

    /// 从当前版本迁移到目标版本
    pub fn migrate_to(&self, conn: &Connection, target: u32, current: u32) -> LegadoResult<()> {
        if current >= target {
            return Ok(());
        }

        // 如果是全新数据库（版本 0），直接初始化 schema
        if current == 0 {
            schema::init_schema(conn)?;
            conn.pragma_update(None, "user_version", target)
                .map_err(|e| LegadoError::Database(format!("设置版本失败: {e}")))?;
            return Ok(());
        }

        let applicable: Vec<_> = self
            .migrations
            .iter()
            .filter(|m| m.from_version() >= current && m.to_version() <= target)
            .collect();

        for migration in applicable {
            eprintln!(
                "执行迁移 v{} -> v{}: {}",
                migration.from_version(),
                migration.to_version(),
                migration.description()
            );
            migration.up(conn)?;
            conn.pragma_update(None, "user_version", migration.to_version())
                .map_err(|e| LegadoError::Database(format!("更新版本失败: {e}")))?;
        }

        Ok(())
    }

    /// 获取所有已注册的迁移列表
    pub fn list_migrations(&self) -> Vec<(u32, u32, &str)> {
        self.migrations
            .iter()
            .map(|m| (m.from_version(), m.to_version(), m.description()))
            .collect()
    }
}

impl Default for MigrationRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// 向后兼容的 MigrationManager 类型别名
pub type MigrationManager = MigrationRegistry;

/// 安全添加列（如果不存在）
///
/// column 允许传入带双引号的列名（如 `"group"`/`"read"` 等 SQLite 关键字列），
/// 存在性检测时会去除引号后再与 PRAGMA table_info 返回的裸列名比较。
pub(crate) fn add_column_if_not_exists(
    conn: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> LegadoResult<()> {
    let bare = column.trim_matches('"');
    let sql = format!("PRAGMA table_info({table})");
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| LegadoError::Database(format!("查询表结构失败: {e}")))?;

    let exists: bool = stmt
        .query_map([], |row| {
            let name: String = row.get(1)?;
            Ok(name == bare)
        })
        .map_err(|e| LegadoError::Database(format!("遍历表结构失败: {e}")))?
        .filter_map(|r| r.ok())
        .any(|b| b);

    if !exists {
        let alter = format!("ALTER TABLE {table} ADD COLUMN {column} {definition}");
        conn.execute_batch(&alter)
            .map_err(|e| LegadoError::Database(format!("ALTER TABLE 失败: {e}")))?;
    }
    Ok(())
}

/// 检查表是否存在
pub(crate) fn table_exists(conn: &Connection, table: &str) -> LegadoResult<bool> {
    let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?";
    let count: i32 = conn
        .query_row(sql, [table], |row| row.get(0))
        .map_err(|e| LegadoError::Database(format!("查询表是否存在失败: {e}")))?;
    Ok(count > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::Database;

    /// 创建指定版本的数据库（不自动迁移）
    fn create_db_at_version(version: u32) -> Database {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        // 创建 v90 基础 schema（不含 mainJs 和 auto_task_rules）
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS book_sources (
                bookSourceUrl TEXT NOT NULL,
                bookSourceName TEXT NOT NULL,
                bookSourceGroup TEXT,
                bookSourceType INTEGER NOT NULL,
                bookUrlPattern TEXT,
                customOrder INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                enabledExplore INTEGER NOT NULL DEFAULT 1,
                jsLib TEXT,
                enabledCookieJar INTEGER DEFAULT 0,
                concurrentRate TEXT,
                header TEXT,
                loginUrl TEXT,
                loginUi TEXT,
                loginCheckJs TEXT,
                coverDecodeJs TEXT,
                bookSourceComment TEXT,
                variableComment TEXT,
                lastUpdateTime INTEGER NOT NULL,
                respondTime INTEGER NOT NULL,
                weight INTEGER NOT NULL,
                exploreUrl TEXT,
                exploreScreen TEXT,
                ruleExplore TEXT,
                searchUrl TEXT,
                ruleSearch TEXT,
                ruleBookInfo TEXT,
                ruleToc TEXT,
                ruleContent TEXT,
                ruleReview TEXT,
                eventListener INTEGER NOT NULL DEFAULT 0,
                customButton INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(bookSourceUrl)
            );",
        )
        .unwrap();
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS books (
                bookUrl TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                author TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(bookUrl)
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", version).unwrap();
        db
    }

    fn column_exists(conn: &Connection, table: &str, column: &str) -> bool {
        let sql = format!("PRAGMA table_info({table})");
        let mut stmt = conn.prepare(&sql).unwrap();
        let result = stmt
            .query_map([], |row| {
                let name: String = row.get(1)?;
                Ok(name == column)
            })
            .unwrap()
            .filter_map(|r| r.ok())
            .any(|b| b);
        result
    }

    #[test]
    fn test_migration_registry_list() {
        let registry = MigrationRegistry::new();
        let list = registry.list_migrations();
        assert_eq!(list.len(), 11);
        assert_eq!(list[0].0, 90);
        assert_eq!(list[0].1, 91);
    }

    #[test]
    fn test_migration_90_to_99_full_chain() {
        let db = create_db_at_version(90);
        let conn = db.connection();

        // v90 没有 mainJs 列
        assert!(!column_exists(conn, "book_sources", "mainJs"));
        // v90 没有 auto_task_rules 表
        assert!(!table_exists(conn, "auto_task_rules").unwrap());

        // 执行迁移到 v99
        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 99, 90).unwrap();

        // 验证版本
        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 99);

        // 验证 mainJs 列存在
        assert!(column_exists(conn, "book_sources", "mainJs"));

        // 验证 auto_task_rules 表存在
        assert!(table_exists(conn, "auto_task_rules").unwrap());

        // 验证高亮相关表存在
        assert!(table_exists(conn, "highlights").unwrap());
        assert!(table_exists(conn, "highlightRules").unwrap());
    }

    #[test]
    fn test_migration_91_to_99() {
        let db = create_db_at_version(91);
        let conn = db.connection();
        // 手动添加 mainJs 列（模拟 v91 状态）
        conn.execute_batch("ALTER TABLE book_sources ADD COLUMN mainJs TEXT")
            .unwrap();

        assert!(column_exists(conn, "book_sources", "mainJs"));
        assert!(!table_exists(conn, "auto_task_rules").unwrap());

        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 99, 91).unwrap();

        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 99);
        assert!(table_exists(conn, "auto_task_rules").unwrap());
    }

    #[test]
    fn test_migration_94_to_99() {
        let db = create_db_at_version(94);
        let conn = db.connection();
        conn.execute_batch("ALTER TABLE book_sources ADD COLUMN mainJs TEXT")
            .unwrap();
        conn.execute_batch(schema::CREATE_AUTO_TASK_RULES).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 99, 94).unwrap();

        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 99);
    }

    #[test]
    fn test_migration_no_op_when_current() {
        let db = create_db_at_version(99);
        let conn = db.connection();

        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 99, 99).unwrap();

        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 99);
    }

    #[test]
    fn test_migration_93_to_94_creates_table() {
        let db = create_db_at_version(93);
        let conn = db.connection();
        conn.execute_batch("ALTER TABLE book_sources ADD COLUMN mainJs TEXT")
            .unwrap();

        assert!(!table_exists(conn, "auto_task_rules").unwrap());

        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 94, 93).unwrap();

        assert!(table_exists(conn, "auto_task_rules").unwrap());
        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 94);
    }

    #[test]
    fn test_migration_93_to_94_down() {
        let db = create_db_at_version(94);
        let conn = db.connection();
        conn.execute_batch("ALTER TABLE book_sources ADD COLUMN mainJs TEXT")
            .unwrap();
        conn.execute_batch(schema::CREATE_AUTO_TASK_RULES).unwrap();

        // down should drop auto_task_rules
        let m = migrations::Migration93To94;
        m.down(conn).unwrap();
        assert!(!table_exists(conn, "auto_task_rules").unwrap());
    }

    #[test]
    fn test_fresh_db_auto_migration() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        let version = MigrationRegistry::current_version(conn).unwrap();
        assert_eq!(version, 101);
        assert!(table_exists(conn, "auto_task_rules").unwrap());
        assert!(column_exists(conn, "book_sources", "mainJs"));
    }

    #[test]
    fn test_table_exists_helper() {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        assert!(!table_exists(conn, "nonexistent").unwrap());
        conn.execute_batch("CREATE TABLE test_table (id INTEGER)")
            .unwrap();
        assert!(table_exists(conn, "test_table").unwrap());
    }
}
