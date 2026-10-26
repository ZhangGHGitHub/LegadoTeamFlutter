//! Migration110To111 — rssSources 补 `nextContentUrl` 列（审查批4 P1-2）
//!
//! 缺陷根因（对照原版 Room v104 `io.legado.app.data.AppDatabase/104.json`
//! 与 `RssSource.kt:73`）：原版 `rssSources` 自 v104 起含 `nextContentUrl`
//! （TEXT 可空，无 default，「正文下一页规则」），我方 schema/模型/仓储
//! 全链缺失该列，导致 RSS 源导入导出与读写往返丢失该规则。
//!
//! 迁移策略：`ALTER TABLE rssSources ADD COLUMN nextContentUrl TEXT`
//! （原版列无 default，存量行落 NULL，与 Kotlin `String? = null` 同语义）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v110 升级到 v111
///
/// 变更内容：`rssSources` 表补 `nextContentUrl`（TEXT 可空）列。
///
/// 幂等：`user_version` 门禁（仅升级到 v111 时执行一次）+
/// `add_column_if_not_exists` 列存在性检测双保险；`rssSources` 表不存在时
/// 跳过（防御性，与 v109/v110 同口径）。
pub struct Migration110To111;

impl Migration for Migration110To111 {
    fn from_version(&self) -> u32 {
        110
    }

    fn to_version(&self) -> u32 {
        111
    }

    fn description(&self) -> &str {
        "rssSources 补 nextContentUrl 列（原版 RssSource 正文下一页规则，Room v104 同名列）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "rssSources")? {
            return Ok(());
        }
        add_column_if_not_exists(conn, "rssSources", "nextContentUrl", "TEXT")?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration110To111: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    /// v110 形态的 rssSources（缺 nextContentUrl 列）
    fn create_v110_rss_sources(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE rssSources (
                sourceUrl TEXT NOT NULL,
                sourceName TEXT NOT NULL,
                sourceIcon TEXT NOT NULL DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1,
                ruleContent TEXT,
                contentWhitelist TEXT,
                customOrder INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(sourceUrl)
            );",
        )
        .unwrap();
    }

    fn column_exists(conn: &Connection, column: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('rssSources') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// 补列 + 存量行保留且新列默认 NULL（对齐原版 `String? = null`）
    #[test]
    fn test_migration_110_to_111_adds_column_and_keeps_rows() {
        let conn = Connection::open_in_memory().unwrap();
        create_v110_rss_sources(&conn);
        conn.execute_batch(
            "INSERT INTO rssSources (sourceUrl, sourceName, ruleContent, customOrder)
             VALUES ('https://rss.example.com', '订阅', 'div.content', 3);",
        )
        .unwrap();

        Migration110To111.up(&conn).unwrap();

        assert!(
            column_exists(&conn, "nextContentUrl"),
            "nextContentUrl 列应存在"
        );
        let (name, rule, next): (String, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT sourceName, ruleContent, nextContentUrl FROM rssSources
                 WHERE sourceUrl = 'https://rss.example.com'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(name, "订阅", "存量行不应丢失");
        assert_eq!(rule.as_deref(), Some("div.content"), "既有规则列应保留");
        assert_eq!(next, None, "存量行 nextContentUrl 应为 NULL");
    }

    /// 重复执行幂等：不报错、列仍唯一存在
    #[test]
    fn test_migration_110_to_111_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        create_v110_rss_sources(&conn);
        Migration110To111.up(&conn).unwrap();
        Migration110To111.up(&conn).unwrap();
        assert!(column_exists(&conn, "nextContentUrl"));
    }

    /// 经注册表从 v110 升级到最新版本：版本推进 + 重复打开不变
    #[test]
    fn test_migration_110_to_111_via_registry_and_reopen() {
        let conn = Connection::open_in_memory().unwrap();
        create_v110_rss_sources(&conn);
        conn.pragma_update(None, "user_version", 110).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            112,
            "注册表路径应推进版本到 112"
        );
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(&conn).unwrap(), 112);
    }

    /// 全新库 init_schema 建表已含该列，up 应为空操作
    #[test]
    fn test_migration_110_to_111_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        assert!(column_exists(&conn, "nextContentUrl"));
        Migration110To111.up(&conn).unwrap();
        assert!(column_exists(&conn, "nextContentUrl"));
    }

    /// rssSources 表不存在时迁移跳过不报错
    #[test]
    fn test_migration_110_to_111_skips_missing_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 110).unwrap();
        Migration110To111.up(&conn).unwrap();
    }
}
