//! Migration118To119 — `books` / `book_groups` 补 `isPrivate`（批9a）
//!
//! 对齐参考版 `Book.kt:85-89`（`@ColumnInfo(defaultValue = "0") var isPrivate = false`）
//! 与 `BookGroup.kt:23-27`：单本私密标记 + 私密分组标记，二者取并集判定
//! （`isPrivateBook`，判定属 UI/后续批次）。私密标记**纳入备份**：参考版
//! 注释明确它属于书架结构，剔除会导致恢复后私密属性丢失。
//!
//! DDL：
//! ```sql
//! ALTER TABLE books ADD COLUMN isPrivate INTEGER NOT NULL DEFAULT 0;
//! ALTER TABLE book_groups ADD COLUMN isPrivate INTEGER NOT NULL DEFAULT 0;
//! ```
//!
//! 幂等：`add_column_if_not_exists`（PRAGMA table_info 缺列检测），配合
//! `user_version` 门禁；开库自愈 `repair_legacy_columns` 另行兜住
//! 「版本号已到 119 但缺列」场景。表不存在时跳过（防御性，与 v117 同口径）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};

/// 幂等补 `isPrivate` 列（迁移与开库自愈共用）
///
/// 可在任意版本安全重复执行：列已存在时为空操作。
pub fn ensure_privacy_flags_v119(conn: &Connection) -> LegadoResult<()> {
    if table_exists(conn, "books")? {
        add_column_if_not_exists(conn, "books", "isPrivate", "INTEGER NOT NULL DEFAULT 0")?;
    }
    if table_exists(conn, "book_groups")? {
        add_column_if_not_exists(
            conn,
            "book_groups",
            "isPrivate",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
    }
    Ok(())
}

/// 从 v118 升级到 v119：books / book_groups 增 `isPrivate` 列
pub struct Migration118To119;

impl Migration for Migration118To119 {
    fn from_version(&self) -> u32 {
        118
    }

    fn to_version(&self) -> u32 {
        119
    }

    fn description(&self) -> &str {
        "books/book_groups 增 isPrivate 列（私密标记，默认 0）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        ensure_privacy_flags_v119(conn)
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration118To119: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    fn column_exists(conn: &Connection, table: &str, column: &str) -> bool {
        conn.query_row(
            &format!("SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = ?1"),
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// v118 形态的两张表（无 isPrivate 列）
    fn create_v118_tables(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE books (
                bookUrl TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                author TEXT NOT NULL DEFAULT '',
                \"group\" INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(bookUrl)
            );
            CREATE TABLE book_groups (
                groupId INTEGER NOT NULL,
                groupName TEXT NOT NULL,
                \"order\" INTEGER NOT NULL,
                PRIMARY KEY(groupId)
            );",
        )
        .unwrap();
    }

    /// 补列 + 存量行保留，新列默认 0（非私密）
    #[test]
    fn test_migration_118_to_119_adds_columns_and_keeps_rows() {
        let conn = Connection::open_in_memory().unwrap();
        create_v118_tables(&conn);
        conn.execute_batch(
            "INSERT INTO books (bookUrl, name) VALUES ('https://a/1', '存量书');
             INSERT INTO book_groups (groupId, groupName, \"order\")
                VALUES (2, '分组', 0);",
        )
        .unwrap();

        Migration118To119.up(&conn).unwrap();

        assert!(column_exists(&conn, "books", "isPrivate"));
        assert!(column_exists(&conn, "book_groups", "isPrivate"));

        let (name, is_private): (String, i64) = conn
            .query_row(
                "SELECT name, isPrivate FROM books WHERE bookUrl = 'https://a/1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(name, "存量书", "存量行不应丢失");
        assert_eq!(is_private, 0, "存量书默认非私密");

        let (group_name, group_private): (String, i64) = conn
            .query_row(
                "SELECT groupName, isPrivate FROM book_groups WHERE groupId = 2",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(group_name, "分组");
        assert_eq!(group_private, 0, "存量分组默认非私密");

        // 幂等：重复执行不报错
        Migration118To119.up(&conn).unwrap();
    }

    /// 重复 up 不改写既有 isPrivate 值
    #[test]
    fn test_migration_118_to_119_idempotent_keeps_values() {
        let conn = Connection::open_in_memory().unwrap();
        create_v118_tables(&conn);
        Migration118To119.up(&conn).unwrap();
        conn.execute_batch(
            "INSERT INTO books (bookUrl, name, isPrivate) VALUES ('https://a/2', '私密书', 1);
             INSERT INTO book_groups (groupId, groupName, \"order\", isPrivate)
                VALUES (4, '私密组', 1, 1);",
        )
        .unwrap();

        Migration118To119.up(&conn).unwrap();

        let book_private: i64 = conn
            .query_row(
                "SELECT isPrivate FROM books WHERE bookUrl = 'https://a/2'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let group_private: i64 = conn
            .query_row(
                "SELECT isPrivate FROM book_groups WHERE groupId = 4",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(book_private, 1, "重复 up 不得改写书籍私密标记");
        assert_eq!(group_private, 1, "重复 up 不得改写分组私密标记");
    }

    /// 注册表路径：v118 旧库 → v119 版本推进且补列；重复迁移为空操作
    #[test]
    fn test_migration_118_to_119_via_registry_advances_version() {
        let conn = Connection::open_in_memory().unwrap();
        create_v118_tables(&conn);
        conn.execute_batch(
            "INSERT INTO books (bookUrl, name) VALUES ('https://a/3', '旧库书');
             INSERT INTO book_groups (groupId, groupName, \"order\")
                VALUES (2, '旧库组', 0);",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 118).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
        assert!(column_exists(&conn, "books", "isPrivate"));
        assert!(column_exists(&conn, "book_groups", "isPrivate"));

        // 旧数据保留且默认非私密
        let (name, is_private): (String, i64) = conn
            .query_row(
                "SELECT name, isPrivate FROM books WHERE bookUrl = 'https://a/3'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(name, "旧库书");
        assert_eq!(is_private, 0);

        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }

    /// 开库自愈：user_version 已到 119 但缺列，`repair_legacy_columns` 兜住
    #[test]
    fn test_repair_legacy_columns_heals_missing_private_columns() {
        let conn = Connection::open_in_memory().unwrap();
        create_v118_tables(&conn);
        conn.pragma_update(None, "user_version", 119).unwrap();

        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();

        assert!(column_exists(&conn, "books", "isPrivate"));
        assert!(column_exists(&conn, "book_groups", "isPrivate"));
        // 幂等：再次执行不报错
        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();
    }

    /// 两张表都不存在时迁移跳过不报错
    #[test]
    fn test_migration_118_to_119_skips_missing_tables() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 118).unwrap();
        Migration118To119.up(&conn).unwrap();
    }
}
