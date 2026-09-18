//! Migration108To109 — books 补 originBookUrl 列（当前书源下该书的详情页地址）
//!
//! [P2-8] 换源根因修复：换源后 `bookUrl`（稳定主键，多处持有者依赖其不变）
//! 保持旧源地址，而「抓取书籍页」路径（详情刷新 / tocUrl 推导 / preUpdateJs
//! 钩子）需要当前书源的详情页地址。本列为空时各路径回退 `bookUrl`，
//! 存量书籍行为不变（向后兼容）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v108 升级到 v109
///
/// 变更内容：`books` 表补 `originBookUrl` 列（TEXT NOT NULL DEFAULT ''），
/// 承载当前书源下该书的详情页地址（换源事务写入 `new_book_url`）。
///
/// 幂等：`user_version` 门禁（仅升级到 v109 时执行一次）+ `add_column_if_not_exists`
/// 列存在性检测双保险（防「版本已到 109 但缺列」历史坑）；`books` 属核心表，
/// 表不存在时跳过（防御性）。
pub struct Migration108To109;

impl Migration for Migration108To109 {
    fn from_version(&self) -> u32 {
        108
    }

    fn to_version(&self) -> u32 {
        109
    }

    fn description(&self) -> &str {
        "books 补 originBookUrl 列（换源后当前书源详情页地址，bookUrl 稳定主键不变）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "books")? {
            add_column_if_not_exists(conn, "books", "originBookUrl", "TEXT NOT NULL DEFAULT ''")?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration108To109: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    fn origin_book_url_column_count(conn: &Connection) -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('books') WHERE name = 'originBookUrl'",
            [],
            |row| row.get(0),
        )
        .unwrap()
    }

    /// 既有 books 表（v108 状态，缺 originBookUrl 列）经 up 补列；
    /// 存量行取默认空串；重复执行幂等不报错
    #[test]
    fn test_migration_108_to_109_adds_origin_book_url_column() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE books (
                bookUrl TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(bookUrl)
            );
            INSERT INTO books (bookUrl, name) VALUES ('https://a.com/1', '存量书');",
        )
        .unwrap();

        Migration108To109.up(&conn).unwrap();
        assert_eq!(
            origin_book_url_column_count(&conn),
            1,
            "originBookUrl 列应存在"
        );
        let value: String = conn
            .query_row(
                "SELECT originBookUrl FROM books WHERE bookUrl = 'https://a.com/1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(value, "", "存量行 originBookUrl 应取默认空串");

        // 幂等：重复执行不报错、不重复补列
        Migration108To109.up(&conn).unwrap();
        assert_eq!(
            origin_book_url_column_count(&conn),
            1,
            "重复 up 不应重复补列"
        );
    }

    /// 经注册表从 v108 升级：user_version 门禁只补列一次，版本推进到 109
    #[test]
    fn test_migration_108_to_109_via_registry() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE books (
                bookUrl TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(bookUrl)
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 108).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            109,
            "注册表路径应推进版本到 109"
        );
        assert_eq!(
            origin_book_url_column_count(&conn),
            1,
            "注册表路径只补列一次"
        );
    }

    /// 全新库经 init_schema 已含 originBookUrl 列，迁移应幂等跳过
    #[test]
    fn test_migration_108_to_109_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        assert_eq!(
            origin_book_url_column_count(&conn),
            1,
            "全新 schema 建表语句应已含 originBookUrl 列"
        );
        Migration108To109.up(&conn).unwrap();
        assert_eq!(
            origin_book_url_column_count(&conn),
            1,
            "up 对已含列的表应为空操作"
        );
    }

    /// books 表尚未创建时迁移应跳过而不报错
    #[test]
    fn test_migration_108_to_109_skips_missing_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 108).unwrap();
        Migration108To109.up(&conn).unwrap();
    }
}
