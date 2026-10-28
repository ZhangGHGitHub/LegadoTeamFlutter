//! Migration113To114 — 规则字段往返保真（批28）
//!
//! 缺陷根因（对照原版 Room schema `113.json` 与实体定义）：
//! 1. `highlightRules.group`（`HighlightRule.kt:30-32`，`@ColumnInfo(defaultValue = "")`
//!    即 DDL `TEXT DEFAULT ''`，原版 `DatabaseMigrations.kt:65` 的
//!    `migration_108_109` 补列）：规则分组，缺列导致导入/导出/备份往返丢分组；
//! 2. `rssSources.enableReadRecord`（`RssSource.kt:28-30`，
//!    `@ColumnInfo(defaultValue = "1")` 即 DDL `INTEGER NOT NULL DEFAULT 1`）：
//!    是否记录该源阅读历史（上游运行期已回退为全局开关，本批只做字段/DB 往返保真，
//!    不做按源开关行为），缺列导致原版备份恢复与源导出往返丢字段。
//!
//! 迁移策略：两列均为 `add_column_if_not_exists`：
//! - `ALTER TABLE highlightRules ADD COLUMN "group" TEXT DEFAULT ''`
//!   （原版列可空且默认空串，存量行落 ''）；
//! - `ALTER TABLE rssSources ADD COLUMN enableReadRecord INTEGER NOT NULL DEFAULT 1`
//!   （原版 NOT NULL DEFAULT 1，存量行落 1，对齐 Kotlin `= true`）。
//!
//! 幂等：`user_version` 门禁（仅升级到 v114 时执行一次）+ 列存在性检测双保险；
//! 表不存在时跳过（防御性，与 v109/v110/v111 同口径）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v113 升级到 v114
///
/// 变更内容：`highlightRules` 补 `group`（TEXT DEFAULT ''）、
/// `rssSources` 补 `enableReadRecord`（INTEGER NOT NULL DEFAULT 1）。
pub struct Migration113To114;

impl Migration for Migration113To114 {
    fn from_version(&self) -> u32 {
        113
    }

    fn to_version(&self) -> u32 {
        114
    }

    fn description(&self) -> &str {
        "highlightRules 补 group（规则分组）、rssSources 补 enableReadRecord（阅读历史开关），对齐原版 RssSource/HighlightRule 实体"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "highlightRules")? {
            // `group` 是 SQLite 关键字，列名加引号；检测时 helper 会去引号比对
            add_column_if_not_exists(conn, "highlightRules", "\"group\"", "TEXT DEFAULT ''")?;
        }
        if table_exists(conn, "rssSources")? {
            add_column_if_not_exists(
                conn,
                "rssSources",
                "enableReadRecord",
                "INTEGER NOT NULL DEFAULT 1",
            )?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration113To114: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    /// v113 形态的两张表（缺 group / enableReadRecord）
    fn create_v113_tables(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE highlightRules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                uuid TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                pattern TEXT NOT NULL,
                isRegex INTEGER NOT NULL,
                scope TEXT,
                isEnabled INTEGER NOT NULL,
                style TEXT NOT NULL,
                sortOrder INTEGER NOT NULL,
                timeoutMillisecond INTEGER NOT NULL,
                applyToTitle INTEGER NOT NULL DEFAULT 0,
                applyToBody INTEGER NOT NULL DEFAULT 1
            );
            CREATE TABLE rssSources (
                sourceUrl TEXT NOT NULL,
                sourceName TEXT NOT NULL,
                sourceIcon TEXT NOT NULL DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1,
                ruleContent TEXT,
                PRIMARY KEY(sourceUrl)
            );",
        )
        .unwrap();
    }

    fn column_exists(conn: &Connection, table: &str, column: &str) -> bool {
        conn.query_row(
            &format!("SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = ?1"),
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// 补列 + 存量行保留，新列取原版默认值（'' / 1）
    #[test]
    fn test_migration_113_to_114_adds_columns_and_keeps_rows() {
        let conn = Connection::open_in_memory().unwrap();
        create_v113_tables(&conn);
        conn.execute_batch(
            "INSERT INTO highlightRules (uuid, name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES
                ('11111111-1111-4111-8111-111111111111', '规则A', 'a', 0, 1, '{}', 0, 3000);
             INSERT INTO rssSources (sourceUrl, sourceName, ruleContent)
                VALUES ('https://rss.example.com', '订阅', 'div.content');",
        )
        .unwrap();

        Migration113To114.up(&conn).unwrap();

        assert!(
            column_exists(&conn, "highlightRules", "group"),
            "highlightRules.group 列应存在"
        );
        assert!(
            column_exists(&conn, "rssSources", "enableReadRecord"),
            "rssSources.enableReadRecord 列应存在"
        );

        let (name, group): (String, Option<String>) = conn
            .query_row(
                "SELECT name, \"group\" FROM highlightRules WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(name, "规则A", "存量行不应丢失");
        assert_eq!(
            group.as_deref(),
            Some(""),
            "存量行 group 应取原版默认空串（对齐 Kotlin defaultValue = \"\"）"
        );

        let (rss_name, enable_read_record): (String, i64) = conn
            .query_row(
                "SELECT sourceName, enableReadRecord FROM rssSources
                 WHERE sourceUrl = 'https://rss.example.com'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(rss_name, "订阅", "存量行不应丢失");
        assert_eq!(
            enable_read_record, 1,
            "存量行 enableReadRecord 应取原版默认 1（对齐 Kotlin = true）"
        );
    }

    /// 重复执行幂等：不报错、列仍唯一存在、既有值不被改写
    #[test]
    fn test_migration_113_to_114_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        create_v113_tables(&conn);
        Migration113To114.up(&conn).unwrap();
        conn.execute_batch(
            "INSERT INTO highlightRules (uuid, name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond, \"group\")
                VALUES ('22222222-2222-4222-8222-222222222222', '规则B', 'b', 0, 1, '{}',
                        0, 3000, '自定义分组');",
        )
        .unwrap();
        Migration113To114.up(&conn).unwrap();
        assert!(column_exists(&conn, "highlightRules", "group"));
        assert!(column_exists(&conn, "rssSources", "enableReadRecord"));
        let group: Option<String> = conn
            .query_row(
                "SELECT \"group\" FROM highlightRules WHERE id = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            group.as_deref(),
            Some("自定义分组"),
            "重复 up 不应改写既有分组"
        );
    }

    /// 经注册表从 v113 升级到最新版本：版本推进 + 重复打开不变
    #[test]
    fn test_migration_113_to_114_via_registry_and_reopen() {
        let conn = Connection::open_in_memory().unwrap();
        create_v113_tables(&conn);
        conn.pragma_update(None, "user_version", 113).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION,
            "注册表路径应推进版本到最新"
        );
        assert!(column_exists(&conn, "highlightRules", "group"));
        assert!(column_exists(&conn, "rssSources", "enableReadRecord"));

        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }

    /// 全新库 init_schema 建表已含两列，up 应为空操作
    #[test]
    fn test_migration_113_to_114_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        assert!(column_exists(&conn, "highlightRules", "group"));
        assert!(column_exists(&conn, "rssSources", "enableReadRecord"));
        Migration113To114.up(&conn).unwrap();
        assert!(column_exists(&conn, "highlightRules", "group"));
        assert!(column_exists(&conn, "rssSources", "enableReadRecord"));
    }

    /// 两张表都不存在时迁移跳过不报错
    #[test]
    fn test_migration_113_to_114_skips_missing_tables() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 113).unwrap();
        Migration113To114.up(&conn).unwrap();
    }
}
