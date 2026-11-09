//! Migration117To118 — 新增 `book_marks` 表（批7b-1 书签标记数据层）
//!
//! 逐列对齐参考版 `data/entities/BookMarking.kt:21-46` 与
//! `data/dao/BookMarkingDao.kt:13-87`：
//!
//! ```sql
//! CREATE TABLE book_marks (
//!     id TEXT PRIMARY KEY NOT NULL,
//!     bookUrl TEXT NOT NULL,
//!     bookName TEXT NOT NULL DEFAULT '',
//!     bookAuthor TEXT NOT NULL DEFAULT '',
//!     chapterIndex INTEGER,
//!     anchorJson TEXT NOT NULL,
//!     styleJson TEXT,
//!     note TEXT NOT NULL DEFAULT '',
//!     chapterName TEXT NOT NULL DEFAULT '',
//!     enabled INTEGER NOT NULL DEFAULT 1,
//!     createdAt INTEGER NOT NULL DEFAULT 0,
//!     updatedAt INTEGER NOT NULL DEFAULT 0
//! );
//! CREATE INDEX index_book_marks_bookUrl_chapterIndex ON book_marks(bookUrl, chapterIndex);
//! ```
//!
//! 书签标记与既有 `bookmarks`（页面导航书签）、`highlights`（正文高亮记录）
//! 相互独立，**不纳入备份**（与参考版一致）。
//!
//! 幂等：`CREATE TABLE/INDEX IF NOT EXISTS`，配合 `user_version` 门禁；
//! 开库自愈 `repair_legacy_columns` 复用 [`ensure_book_marks_v118`] 兜住
//! 「版本号已到 118 但缺表/缺索引」场景。

use rusqlite::Connection;

use legado_core::LegadoResult;

use crate::migration::Migration;
use crate::schema::{CREATE_BOOK_MARKS, CREATE_BOOK_MARKS_INDEX};

/// 幂等建表 + 建索引（迁移与开库自愈共用）
///
/// 可在任意版本安全重复执行：表/索引已存在时为空操作。
pub fn ensure_book_marks_v118(conn: &Connection) -> LegadoResult<()> {
    conn.execute_batch(CREATE_BOOK_MARKS)
        .map_err(|e| legado_core::LegadoError::Database(format!("创建 book_marks 表失败: {e}")))?;
    conn.execute_batch(CREATE_BOOK_MARKS_INDEX).map_err(|e| {
        legado_core::LegadoError::Database(format!("创建 book_marks 索引失败: {e}"))
    })?;
    Ok(())
}

/// 从 v117 升级到 v118：建 `book_marks` 表与 `(bookUrl, chapterIndex)` 索引
pub struct Migration117To118;

impl Migration for Migration117To118 {
    fn from_version(&self) -> u32 {
        117
    }

    fn to_version(&self) -> u32 {
        118
    }

    fn description(&self) -> &str {
        "新增 book_marks 表（书签标记：id/bookUrl/bookName/bookAuthor/chapterIndex/anchorJson/styleJson/note/chapterName/enabled/createdAt/updatedAt）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        ensure_book_marks_v118(conn)
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        // SQLite 不支持通用的 DROP 回滚语义；表保留不影响旧版本逻辑。
        // 回退只需降低 user_version（由注册表负责）。
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    fn table_exists(conn: &Connection, table: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
            [table],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    fn index_exists(conn: &Connection, index: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name=?1",
            [index],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    fn column_exists(conn: &Connection, column: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('book_marks') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// 建表后 12 列齐备，索引存在（对齐参考版实体列）
    #[test]
    fn test_migration_117_to_118_creates_table_and_index() {
        let conn = Connection::open_in_memory().unwrap();
        Migration117To118.up(&conn).unwrap();

        for column in [
            "id",
            "bookUrl",
            "bookName",
            "bookAuthor",
            "chapterIndex",
            "anchorJson",
            "styleJson",
            "note",
            "chapterName",
            "enabled",
            "createdAt",
            "updatedAt",
        ] {
            assert!(
                column_exists(&conn, column),
                "book_marks 表应含 {column} 列"
            );
        }
        assert!(
            index_exists(&conn, "index_book_marks_bookUrl_chapterIndex"),
            "应创建 (bookUrl, chapterIndex) 索引"
        );

        // 主键约束：同 id 重复插入需报错（验证 PRIMARY KEY）
        conn.execute(
            "INSERT INTO book_marks (id, bookUrl, anchorJson) VALUES ('m1', 'https://a/1', '{}')",
            [],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO book_marks (id, bookUrl, anchorJson) VALUES ('m1', 'https://a/2', '{}')",
            [],
        );
        assert!(dup.is_err(), "id 主键应拒绝重复插入");
    }

    /// 幂等：重复执行不报错，数据保留
    #[test]
    fn test_ensure_book_marks_v118_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        ensure_book_marks_v118(&conn).unwrap();
        conn.execute(
            "INSERT INTO book_marks (id, bookUrl, anchorJson) VALUES ('m1', 'https://a/1', '{}')",
            [],
        )
        .unwrap();

        ensure_book_marks_v118(&conn).unwrap();
        ensure_book_marks_v118(&conn).unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_marks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "重复建表不得丢数据");
    }

    /// 注册表路径：v117 → v118 版本推进且表存在；重复迁移为空操作
    #[test]
    fn test_migration_117_to_118_via_registry_advances_version() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute("DROP TABLE book_marks", []).unwrap();
        conn.pragma_update(None, "user_version", 117).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
        assert!(table_exists(&conn, "book_marks"));

        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }

    /// 开库自愈路径：user_version 已到 118 但缺表，`repair_legacy_columns` 兜住
    #[test]
    fn test_repair_legacy_columns_heals_missing_book_marks() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute("DROP TABLE book_marks", []).unwrap();
        conn.pragma_update(None, "user_version", 118).unwrap();

        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();

        assert!(table_exists(&conn, "book_marks"), "自愈应重建缺表");
        assert!(
            index_exists(&conn, "index_book_marks_bookUrl_chapterIndex"),
            "自愈应重建索引"
        );
        // 幂等：再次执行不报错
        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();
    }
}
