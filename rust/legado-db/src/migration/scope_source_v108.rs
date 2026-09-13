//! Migration107To108 — replace_rules 补 scopeSource 列（替换规则书源作用域开关）

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v107 升级到 v108
///
/// 变更内容：`replace_rules` 表补 `scopeSource` 列（INTEGER NOT NULL DEFAULT 0），
/// 对齐原版 `ReplaceRule.scopeSource` 独立列（`@ColumnInfo(defaultValue = "0")`）：
/// 书源作用域替换规则开关，书源导入时按源名/源 URL 匹配 scope 后应用整源 JSON 替换。
///
/// 幂等：`user_version` 门禁（仅升级到 v108 时执行一次）+ `add_column_if_not_exists`
/// 列存在性检测双保险（防「版本已到 108 但缺列」历史坑）；`replace_rules` 属懒建表，
/// 表不存在时跳过。
pub struct Migration107To108;

impl Migration for Migration107To108 {
    fn from_version(&self) -> u32 {
        107
    }

    fn to_version(&self) -> u32 {
        108
    }

    fn description(&self) -> &str {
        "replace_rules 补 scopeSource 列（替换规则书源作用域开关）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "replace_rules")? {
            add_column_if_not_exists(
                conn,
                "replace_rules",
                "scopeSource",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration107To108: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    /// 既有 replace_rules 表（v107 状态，缺 scopeSource 列）经 up 补列；
    /// 重复执行幂等不报错
    #[test]
    fn test_migration_107_to_108_adds_scope_source_column() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE replace_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL DEFAULT '',
                pattern TEXT NOT NULL DEFAULT '',
                replacement TEXT NOT NULL DEFAULT '',
                scopeTitle INTEGER NOT NULL DEFAULT 0,
                scopeContent INTEGER NOT NULL DEFAULT 1
            );
            INSERT INTO replace_rules (name, pattern, replacement) VALUES ('legacy', 'a', 'b');",
        )
        .unwrap();

        // 直接调用 up：补列且存量行取默认值 0
        Migration107To108.up(&conn).unwrap();
        assert_eq!(scope_column_count(&conn), 1, "scopeSource 列应存在");
        let value: i64 = conn
            .query_row(
                "SELECT scopeSource FROM replace_rules WHERE id = 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(value, 0, "存量行 scopeSource 应取默认值 0");

        // 幂等：重复执行不报错、不重复补列
        Migration107To108.up(&conn).unwrap();
        assert_eq!(scope_column_count(&conn), 1, "重复 up 不应重复补列");
    }

    /// 经注册表从 v107 升级：user_version 门禁只补列一次，版本推进到 108
    #[test]
    fn test_migration_107_to_108_via_registry() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE replace_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL DEFAULT '',
                pattern TEXT NOT NULL DEFAULT '',
                replacement TEXT NOT NULL DEFAULT ''
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 107).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            108,
            "注册表路径应推进版本到 108"
        );
        assert_eq!(scope_column_count(&conn), 1, "注册表路径只补列一次");
    }

    /// 全新库经 init_schema 已含 scopeSource 列，迁移应幂等跳过
    #[test]
    fn test_migration_107_to_108_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        assert_eq!(
            scope_column_count(&conn),
            1,
            "全新 schema 建表语句应已含 scopeSource 列"
        );
        Migration107To108.up(&conn).unwrap();
        assert_eq!(scope_column_count(&conn), 1, "up 对已含列的表应为空操作");
    }

    /// 懒建表尚未创建时迁移应跳过而不报错
    #[test]
    fn test_migration_107_to_108_skips_missing_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 107).unwrap();
        Migration107To108.up(&conn).unwrap();
    }

    fn scope_column_count(conn: &Connection) -> i64 {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('replace_rules') WHERE name = 'scopeSource'",
            [],
            |row| row.get(0),
        )
        .unwrap()
    }
}
