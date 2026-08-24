//! Migration105To106 — searchBooks 补 bookScore 列（换源页 👍/👎 用户评分持久化）

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v105 升级到 v106
///
/// 变更内容：`searchBooks` 表补 `bookScore` 列（INTEGER NOT NULL DEFAULT 0），
/// 对齐换源页用户评分 -1/0/1 持久化（对标原版 `SourceConfig` 按书维度评分，
/// 本轨落库于 searchBooks 主键 bookUrl）。
pub struct Migration105To106;

impl Migration for Migration105To106 {
    fn from_version(&self) -> u32 {
        105
    }

    fn to_version(&self) -> u32 {
        106
    }

    fn description(&self) -> &str {
        "searchBooks 补 bookScore 列（换源用户评分）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "searchBooks")? {
            add_column_if_not_exists(
                conn,
                "searchBooks",
                "bookScore",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration105To106: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    #[test]
    fn test_migration_105_to_106_adds_book_score() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(&conn).unwrap(), 106);
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('searchBooks') WHERE name = 'bookScore'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }
}
