//! 数据库连接管理

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{self, MigrationRegistry};
use crate::schema;

/// 数据库包装器，持有 SQLite 连接
pub struct Database {
    conn: Connection,
}

impl Database {
    /// 打开或创建指定路径的数据库文件，自动执行增量迁移
    pub fn open(path: &str) -> LegadoResult<Self> {
        let conn = Connection::open(path)
            .map_err(|e| LegadoError::Database(format!("打开数据库失败: {e}")))?;
        Self::init_pragmas(&conn)?;
        Self::auto_migrate(&conn)?;
        Ok(Self { conn })
    }

    /// 打开内存数据库（用于测试），自动执行迁移
    pub fn open_in_memory() -> LegadoResult<Self> {
        let conn = Connection::open_in_memory()
            .map_err(|e| LegadoError::Database(format!("打开内存数据库失败: {e}")))?;
        Self::init_pragmas(&conn)?;
        Self::auto_migrate(&conn)?;
        Ok(Self { conn })
    }

    /// 打开数据库但不执行迁移（用于测试迁移流程）
    pub fn open_raw(path: &str) -> LegadoResult<Self> {
        let conn = Connection::open(path)
            .map_err(|e| LegadoError::Database(format!("打开数据库失败: {e}")))?;
        Self::init_pragmas(&conn)?;
        Ok(Self { conn })
    }

    /// 打开内存数据库但不执行迁移（用于测试）
    pub fn open_in_memory_raw() -> LegadoResult<Self> {
        let conn = Connection::open_in_memory()
            .map_err(|e| LegadoError::Database(format!("打开内存数据库失败: {e}")))?;
        Self::init_pragmas(&conn)?;
        Ok(Self { conn })
    }

    /// 自动迁移：检查版本并执行必要的迁移
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
    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    /// 设置常用 PRAGMA 优化参数
    fn init_pragmas(conn: &Connection) -> LegadoResult<()> {
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| LegadoError::Database(format!("设置 journal_mode 失败: {e}")))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| LegadoError::Database(format!("设置 foreign_keys 失败: {e}")))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| LegadoError::Database(format!("设置 synchronous 失败: {e}")))?;
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
}
