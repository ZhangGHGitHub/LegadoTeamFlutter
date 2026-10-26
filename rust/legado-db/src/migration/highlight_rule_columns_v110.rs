//! Migration109To110 — highlightRules 补 `uuid`/`applyToBody` 两列（审查批3 P2-11）
//!
//! 缺陷根因（对照原版 `HighlightRule.kt:21,27,40`）：
//! 1. `uuid` 为规则身份列（唯一索引），导入按其去重；缺列导致导入无法按身份去重；
//! 2. `applyToBody` 控制正文侧匹配、与 `applyToTitle`（已移植）组成双开关；
//!    缺列导致「标题高亮规则被错误应用到正文」。
//!
//! 迁移策略同构对齐原版 `DatabaseMigrations.kt:46-68`（Room v100→101）：
//! - `ALTER TABLE highlightRules ADD COLUMN uuid TEXT NOT NULL DEFAULT ''`
//! - 遍历存量行逐行 `UUID.randomUUID().toString()` 回填
//! - `CREATE UNIQUE INDEX index_highlightRules_uuid ON highlightRules(uuid)`
//!
//! `applyToBody` 在原版 v98 建表时即存在（Room 98.json），我方 v98 建表语句
//! 漏列，此处以 `NOT NULL DEFAULT 1` 补齐（对齐原版实体默认 `= true` 与
//! `@ColumnInfo(defaultValue = "1")`）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 从 v109 升级到 v110
///
/// 变更内容：`highlightRules` 表补 `uuid`（TEXT NOT NULL DEFAULT ''，存量行
/// 随机回填 + 唯一索引）与 `applyToBody`（INTEGER NOT NULL DEFAULT 1）两列。
///
/// 幂等：`user_version` 门禁（仅升级到 v110 时执行一次）+ `add_column_if_not_exists`
/// 列存在性检测 + 回填仅处理 `uuid = ''` 行的三重保险；`highlightRules` 表
/// 不存在时跳过（防御性，与 v109 同口径）。
pub struct Migration109To110;

impl Migration for Migration109To110 {
    fn from_version(&self) -> u32 {
        109
    }

    fn to_version(&self) -> u32 {
        110
    }

    fn description(&self) -> &str {
        "highlightRules 补 uuid/applyToBody 两列（uuid 随机回填 + 唯一索引，导入按身份去重；applyToBody 与 applyToTitle 组成标题/正文双开关）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "highlightRules")? {
            return Ok(());
        }
        // 1. 补列（列存在性检测幂等）
        add_column_if_not_exists(conn, "highlightRules", "uuid", "TEXT NOT NULL DEFAULT ''")?;
        add_column_if_not_exists(
            conn,
            "highlightRules",
            "applyToBody",
            "INTEGER NOT NULL DEFAULT 1",
        )?;
        // 2. 存量行 uuid 随机回填（对齐原版 DatabaseMigrations.kt:51-61：
        //    逐行 UPDATE uuid = UUID.randomUUID()），仅处理仍为空的行保证幂等
        let mut backfill = conn
            .prepare("UPDATE highlightRules SET uuid = ?1 WHERE id = ?2 AND uuid = ''")
            .map_err(|e| LegadoError::Database(format!("准备 uuid 回填语句失败: {e}")))?;
        let ids: Vec<i64> = {
            let mut stmt = conn
                .prepare("SELECT id FROM highlightRules WHERE uuid = ''")
                .map_err(|e| LegadoError::Database(format!("查询待回填行失败: {e}")))?;
            let rows = stmt
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(|e| LegadoError::Database(format!("遍历待回填行失败: {e}")))?;
            rows.filter_map(|r| r.ok()).collect()
        };
        for id in ids {
            backfill
                .execute(rusqlite::params![uuid::Uuid::new_v4().to_string(), id])
                .map_err(|e| LegadoError::Database(format!("回填 uuid 失败: {e}")))?;
        }
        // 3. uuid 唯一索引（对齐原版 DatabaseMigrations.kt:63-66）
        conn.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_highlightRules_uuid
             ON highlightRules(uuid);",
        )
        .map_err(|e| LegadoError::Database(format!("创建 uuid 唯一索引失败: {e}")))?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration109To110: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    /// v109 形态的 highlightRules（缺 uuid/applyToBody 两列）
    fn create_v109_highlight_rules(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE highlightRules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL,
                pattern TEXT NOT NULL,
                isRegex INTEGER NOT NULL,
                scope TEXT,
                isEnabled INTEGER NOT NULL,
                style TEXT NOT NULL,
                sortOrder INTEGER NOT NULL,
                timeoutMillisecond INTEGER NOT NULL,
                applyToTitle INTEGER NOT NULL DEFAULT 0
            );",
        )
        .unwrap();
    }

    fn column_exists(conn: &Connection, column: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('highlightRules') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    fn uuid_of(conn: &Connection, id: i64) -> String {
        conn.query_row(
            "SELECT uuid FROM highlightRules WHERE id = ?1",
            [id],
            |row| row.get(0),
        )
        .unwrap()
    }

    /// 补列 + 存量行 uuid 随机回填非空且为合法 UUID、applyToBody 默认 1
    #[test]
    fn test_migration_109_to_110_backfills_uuid() {
        let conn = Connection::open_in_memory().unwrap();
        create_v109_highlight_rules(&conn);
        conn.execute_batch(
            "INSERT INTO highlightRules (name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES
                ('规则A', 'a', 0, 1, '{}', 0, 3000),
                ('规则B', 'b', 1, 1, '{}', 1, 3000);",
        )
        .unwrap();

        Migration109To110.up(&conn).unwrap();

        assert!(column_exists(&conn, "uuid"), "uuid 列应存在");
        assert!(column_exists(&conn, "applyToBody"), "applyToBody 列应存在");
        let (uuid_a, uuid_b) = (uuid_of(&conn, 1), uuid_of(&conn, 2));
        assert!(
            !uuid_a.is_empty() && !uuid_b.is_empty(),
            "存量行 uuid 应回填非空"
        );
        assert_ne!(uuid_a, uuid_b, "回填 uuid 应互不相同");
        assert!(
            uuid::Uuid::parse_str(&uuid_a).is_ok() && uuid::Uuid::parse_str(&uuid_b).is_ok(),
            "回填 uuid 应为合法 UUID"
        );
        let apply_to_body: i64 = conn
            .query_row(
                "SELECT applyToBody FROM highlightRules WHERE id = 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            apply_to_body, 1,
            "存量行 applyToBody 应取默认 1（对齐原版实体默认 true）"
        );
    }

    /// 重复执行幂等：不报错、不重复补列、已回填的 uuid 不被改写
    #[test]
    fn test_migration_109_to_110_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        create_v109_highlight_rules(&conn);
        conn.execute(
            "INSERT INTO highlightRules (name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES ('规则A', 'a', 0, 1, '{}', 0, 3000)",
            [],
        )
        .unwrap();

        Migration109To110.up(&conn).unwrap();
        let first_uuid = uuid_of(&conn, 1);
        Migration109To110.up(&conn).unwrap();
        assert_eq!(
            uuid_of(&conn, 1),
            first_uuid,
            "重复 up 不应改写已回填的 uuid"
        );
    }

    /// uuid 唯一索引生效：重复 uuid 插入被拒绝
    #[test]
    fn test_migration_109_to_110_uuid_unique_index() {
        let conn = Connection::open_in_memory().unwrap();
        create_v109_highlight_rules(&conn);
        Migration109To110.up(&conn).unwrap();

        conn.execute(
            "INSERT INTO highlightRules (uuid, name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES ('u1', 'r1', 'a', 0, 1, '{}', 0, 3000)",
            [],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO highlightRules (uuid, name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES ('u1', 'r2', 'b', 0, 1, '{}', 1, 3000)",
            [],
        );
        assert!(dup.is_err(), "uuid 唯一索引应拒绝重复 uuid 插入");
    }

    /// 经注册表从 v109 升级到最新版本（111）：版本推进、幂等、重复打开不变
    #[test]
    fn test_migration_109_to_110_via_registry_and_reopen() {
        let conn = Connection::open_in_memory().unwrap();
        create_v109_highlight_rules(&conn);
        conn.execute(
            "INSERT INTO highlightRules (name, pattern, isRegex, isEnabled, style,
                sortOrder, timeoutMillisecond) VALUES ('规则A', 'a', 0, 1, '{}', 0, 3000)",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 109).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(&conn).unwrap(), 111);
        let first_uuid = uuid_of(&conn, 1);

        // 模拟重复打开数据库（再触发 migrate_to_latest）：版本不回退、uuid 不改写
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(&conn).unwrap(), 111);
        assert_eq!(uuid_of(&conn, 1), first_uuid);
    }

    /// 全新库 init_schema 建表已含两列与唯一索引，up 应为空操作
    #[test]
    fn test_migration_109_to_110_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        assert!(column_exists(&conn, "uuid"));
        assert!(column_exists(&conn, "applyToBody"));
        Migration109To110.up(&conn).unwrap();
        // 表无数据，应无任何报错且列仍在
        assert!(column_exists(&conn, "uuid"));
    }

    /// highlightRules 表不存在时迁移跳过不报错
    #[test]
    fn test_migration_109_to_110_skips_missing_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 109).unwrap();
        Migration109To110.up(&conn).unwrap();
    }
}
