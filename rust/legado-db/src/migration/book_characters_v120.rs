//! Migration119To120 — 新增 `book_character_profiles` 表（R42 阶段 2A 角色卡）
//!
//! 逐列对齐参考版 `data/entities/BookKnowledge.kt:8-70` 的
//! `BookCharacterProfile` 与 Room schema v97+（17 列），索引对齐
//! `BookKnowledge.kt:10-13`：
//!
//! ```sql
//! CREATE TABLE book_character_profiles (
//!     id TEXT PRIMARY KEY NOT NULL,
//!     bookUrl TEXT NOT NULL,
//!     name TEXT NOT NULL,
//!     aliasesJson TEXT NOT NULL DEFAULT '[]',
//!     avatarUri TEXT,
//!     tagsJson TEXT NOT NULL DEFAULT '[]',
//!     role TEXT NOT NULL DEFAULT '',
//!     voiceGender TEXT NOT NULL DEFAULT 'unknown',
//!     voiceAgeBand TEXT NOT NULL DEFAULT 'unknown',
//!     personality TEXT NOT NULL DEFAULT '',
//!     summary TEXT NOT NULL DEFAULT '',
//!     status INTEGER NOT NULL DEFAULT 1,
//!     source TEXT NOT NULL DEFAULT 'user',
//!     confidence REAL NOT NULL DEFAULT 1.0,
//!     schemaVersion INTEGER NOT NULL DEFAULT 1,
//!     createdAt INTEGER NOT NULL DEFAULT 0,
//!     updatedAt INTEGER NOT NULL DEFAULT 0
//! );
//! CREATE UNIQUE INDEX index_book_character_profiles_bookUrl_name
//!     ON book_character_profiles(bookUrl, name);
//! CREATE INDEX index_book_character_profiles_bookUrl_updatedAt
//!     ON book_character_profiles(bookUrl, updatedAt);
//! ```
//!
//! 角色卡与其余 4 张角色/知识表（events/relations/knowledge_entries/
//! outline_nodes）**无外键**（参考版 `foreignKeys = null`），本批只建
//! profiles 一张表。**不纳入备份**（参考版 `Backup.kt`/`Restore.kt` 均无
//! 这 5 张表）。
//!
//! 幂等：`CREATE TABLE/INDEX IF NOT EXISTS`，配合 `user_version` 门禁；
//! 开库自愈 `repair_legacy_columns` 复用 [`ensure_book_character_profiles_v120`]
//! 兜住「版本号已到 120 但缺表/缺索引」场景。

use rusqlite::Connection;

use legado_core::LegadoResult;

use crate::migration::Migration;
use crate::schema::{CREATE_BOOK_CHARACTER_PROFILES, CREATE_BOOK_CHARACTER_PROFILES_INDEXES};

/// 幂等建表 + 建索引（迁移与开库自愈共用）
///
/// 可在任意版本安全重复执行：表/索引已存在时为空操作。
pub fn ensure_book_character_profiles_v120(conn: &Connection) -> LegadoResult<()> {
    conn.execute_batch(CREATE_BOOK_CHARACTER_PROFILES)
        .map_err(|e| {
            legado_core::LegadoError::Database(format!("创建 book_character_profiles 表失败: {e}"))
        })?;
    conn.execute_batch(CREATE_BOOK_CHARACTER_PROFILES_INDEXES)
        .map_err(|e| {
            legado_core::LegadoError::Database(format!(
                "创建 book_character_profiles 索引失败: {e}"
            ))
        })?;
    Ok(())
}

/// 从 v119 升级到 v120：建 `book_character_profiles` 表与 2 个索引
pub struct Migration119To120;

impl Migration for Migration119To120 {
    fn from_version(&self) -> u32 {
        119
    }

    fn to_version(&self) -> u32 {
        120
    }

    fn description(&self) -> &str {
        "新增 book_character_profiles 表（角色卡：id/bookUrl/name/aliasesJson/avatarUri/tagsJson/role/voiceGender/voiceAgeBand/personality/summary/status/source/confidence/schemaVersion/createdAt/updatedAt）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        ensure_book_character_profiles_v120(conn)
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
            "SELECT COUNT(*) FROM pragma_table_info('book_character_profiles') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// 建表后 17 列齐备，2 索引存在（对齐参考版实体列）
    #[test]
    fn test_migration_119_to_120_creates_table_and_indexes() {
        let conn = Connection::open_in_memory().unwrap();
        Migration119To120.up(&conn).unwrap();

        for column in [
            "id",
            "bookUrl",
            "name",
            "aliasesJson",
            "avatarUri",
            "tagsJson",
            "role",
            "voiceGender",
            "voiceAgeBand",
            "personality",
            "summary",
            "status",
            "source",
            "confidence",
            "schemaVersion",
            "createdAt",
            "updatedAt",
        ] {
            assert!(
                column_exists(&conn, column),
                "book_character_profiles 表应含 {column} 列"
            );
        }
        assert!(
            index_exists(&conn, "index_book_character_profiles_bookUrl_name"),
            "应创建 UNIQUE(bookUrl, name) 索引"
        );
        assert!(
            index_exists(&conn, "index_book_character_profiles_bookUrl_updatedAt"),
            "应创建 (bookUrl, updatedAt) 索引"
        );

        // 主键约束：同 id 重复插入需报错（验证 PRIMARY KEY）
        conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name)
             VALUES ('c1', 'https://a/1', '角色甲')",
            [],
        )
        .unwrap();
        let dup = conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name)
             VALUES ('c1', 'https://a/2', '角色乙')",
            [],
        );
        assert!(dup.is_err(), "id 主键应拒绝重复插入");

        // 唯一约束：同 (bookUrl, name) 不同 id 需报错（一书一名唯一）
        let dup_name = conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name)
             VALUES ('c2', 'https://a/1', '角色甲')",
            [],
        );
        assert!(dup_name.is_err(), "UNIQUE(bookUrl, name) 应拒绝同名角色");

        // 列默认值兜底
        conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name)
             VALUES ('c3', 'https://a/1', '角色丙')",
            [],
        )
        .unwrap();
        let (aliases, tags, role, gender, band, status, source, confidence, sv): (
            String,
            String,
            String,
            String,
            String,
            i64,
            String,
            f64,
            i64,
        ) = conn
            .query_row(
                "SELECT aliasesJson, tagsJson, role, voiceGender, voiceAgeBand,
                        status, source, confidence, schemaVersion
                 FROM book_character_profiles WHERE id = 'c3'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                        row.get(8)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(aliases, "[]");
        assert_eq!(tags, "[]");
        assert_eq!(role, "");
        assert_eq!(gender, "unknown");
        assert_eq!(band, "unknown");
        assert_eq!(status, 1);
        assert_eq!(source, "user");
        assert_eq!(confidence, 1.0);
        assert_eq!(sv, 1);
    }

    /// 幂等：重复执行不报错，数据保留
    #[test]
    fn test_ensure_book_character_profiles_v120_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        ensure_book_character_profiles_v120(&conn).unwrap();
        conn.execute(
            "INSERT INTO book_character_profiles (id, bookUrl, name)
             VALUES ('c1', 'https://a/1', '角色')",
            [],
        )
        .unwrap();

        ensure_book_character_profiles_v120(&conn).unwrap();
        ensure_book_character_profiles_v120(&conn).unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_character_profiles", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(count, 1, "重复建表不得丢数据");
    }

    /// 注册表路径：v119 旧库 → v120 版本推进且表存在，旧数据完好
    #[test]
    fn test_migration_119_to_120_via_registry_advances_version() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute("DROP TABLE book_character_profiles", [])
            .unwrap();
        // v119 形态：既有关键表有数据
        conn.execute(
            "INSERT INTO book_marks (id, bookUrl, anchorJson) VALUES ('m1', 'https://a/1', '{}')",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 119).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
        assert!(table_exists(&conn, "book_character_profiles"));
        assert!(index_exists(
            &conn,
            "index_book_character_profiles_bookUrl_name"
        ));

        // v119 存量数据完好
        let marks: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_marks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(marks, 1, "升级不得丢既有数据");

        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }

    /// 开库自愈路径：user_version 已到 120 但缺表，`repair_legacy_columns` 兜住
    #[test]
    fn test_repair_legacy_columns_heals_missing_book_character_profiles() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute("DROP TABLE book_character_profiles", [])
            .unwrap();
        conn.pragma_update(None, "user_version", 120).unwrap();

        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();

        assert!(
            table_exists(&conn, "book_character_profiles"),
            "自愈应重建缺表"
        );
        assert!(
            index_exists(&conn, "index_book_character_profiles_bookUrl_name"),
            "自愈应重建唯一索引"
        );
        assert!(
            index_exists(&conn, "index_book_character_profiles_bookUrl_updatedAt"),
            "自愈应重建排序索引"
        );
        // 幂等：再次执行不报错
        crate::migration::migrations::repair_legacy_columns(&conn).unwrap();
    }
}
