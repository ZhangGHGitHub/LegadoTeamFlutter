//! Migration114To115 — 书源检验状态表（批30）
//!
//! 原版依据（upstream）：
//! - `BookSourceCheckState.kt`：实体定义（`bookSourceUrl` 主键 + 外键级联，
//!   revision/sourceRevision/status/checkedAt/detail 全 NOT NULL）；
//! - `DatabaseMigrations.kt:108-121` 的 `migration_105_106`：
//!   1. `CREATE TABLE IF NOT EXISTS book_source_check_states (...)`；
//!   2. 为全部存量书源播种 `NEEDS_CHECK` 占位行
//!      （`lower(hex(randomblob(16)))` 生成两个 revision）；
//!   3. `DROP VIEW IF EXISTS book_sources_part` + 按联查状态重建。
//!
//! 本实现对齐 1/2：建表 + `INSERT OR IGNORE` 播种（幂等；重复 up 不覆盖
//! 已有状态）。第 3 步**不执行**——`book_sources_part` 是 Android 列表联查
//! 视图，Rust 轨无消费方（网页管理端点直接返回完整源 + 状态两组数据），
//! 见 `schema.rs` v115 注释与 `legacy/source_check_api.rs` 模块文档。
//!
//! 幂等：`CREATE TABLE IF NOT EXISTS` + `INSERT OR IGNORE`，配合
//! `user_version` 门禁；开库自愈（`repair_legacy_columns`）亦调用
//! [`ensure_book_source_check_states`] 兜住「版本号已到 115 但缺表」场景。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::table_exists;
use crate::migration::Migration;

/// 建表 DDL（与 `schema::CREATE_BOOK_SOURCE_CHECK_STATES` 同一文本）
const CREATE_TABLE: &str = "
CREATE TABLE IF NOT EXISTS book_source_check_states (
    bookSourceUrl TEXT NOT NULL,
    revision TEXT NOT NULL,
    sourceRevision TEXT NOT NULL,
    status TEXT NOT NULL,
    checkedAt INTEGER NOT NULL,
    detail TEXT NOT NULL,
    PRIMARY KEY(bookSourceUrl),
    FOREIGN KEY(bookSourceUrl) REFERENCES book_sources(bookSourceUrl)
    ON UPDATE NO ACTION ON DELETE CASCADE
);
";

/// 为存量书源补齐缺失的状态行（对齐 `migration_105_106` 的 INSERT SELECT）
///
/// `INSERT OR IGNORE`：已存在的状态（含检验结果）原样保留；仅给「有源无状态」
/// 的行播种，重复执行不产生任何变化。
///
/// 批30b P3-2 门控：开库自愈每库至少调用两次（`repair_legacy_columns` 在
/// `auto_migrate` 首尾各一次），原实现每次都执行 `INSERT ... SELECT` 写扫描
/// （即使零缺行也要拿写锁）。先比较两表计数，**计数齐平即直接返回**，只有
/// 「表缺失或计数不齐」才真正写库。
fn seed_missing_states(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "book_sources")? {
        return Ok(());
    }
    let (source_count, state_count): (i64, i64) = conn
        .query_row(
            "SELECT (SELECT COUNT(*) FROM book_sources),
                    (SELECT COUNT(*) FROM book_source_check_states)",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|e| LegadoError::Database(format!("统计书源检验状态播种规模失败: {e}")))?;
    if state_count >= source_count {
        // 无缺行（含状态多于源的异常残留）：跳过写扫描
        return Ok(());
    }
    conn.execute_batch(
        "INSERT OR IGNORE INTO book_source_check_states
            (bookSourceUrl, revision, sourceRevision, status, checkedAt, detail)
         SELECT bookSourceUrl, lower(hex(randomblob(16))), lower(hex(randomblob(16))),
                'NEEDS_CHECK', 0, ''
         FROM book_sources;",
    )
    .map_err(|e| LegadoError::Database(format!("播种书源检验状态失败: {e}")))?;
    Ok(())
}

/// 幂等确保表存在并补齐播种（迁移与开库自愈共用）
pub fn ensure_book_source_check_states(conn: &Connection) -> LegadoResult<()> {
    conn.execute_batch(CREATE_TABLE)
        .map_err(|e| LegadoError::Database(format!("创建 book_source_check_states 表失败: {e}")))?;
    seed_missing_states(conn)
}

/// 从 v114 升级到 v115
///
/// 变更内容：新增 `book_source_check_states` 表；存量书源播种
/// `NEEDS_CHECK` 状态（随机 revision/sourceRevision）。
pub struct Migration114To115;

impl Migration for Migration114To115 {
    fn from_version(&self) -> u32 {
        114
    }

    fn to_version(&self) -> u32 {
        115
    }

    fn description(&self) -> &str {
        "新增 book_source_check_states 表（对齐原版 migration_105_106），存量书源播种 NEEDS_CHECK"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        ensure_book_source_check_states(conn)
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration114To115: drop table would lose check states".into(),
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

    /// v114 形态：书源表存在、无状态表
    fn create_v114_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE book_sources (
                bookSourceUrl TEXT NOT NULL,
                bookSourceName TEXT NOT NULL,
                PRIMARY KEY(bookSourceUrl)
            );
            INSERT INTO book_sources (bookSourceUrl, bookSourceName) VALUES
                ('https://a.example.com', '源A'),
                ('https://b.example.com', '源B');",
        )
        .unwrap();
        conn
    }

    #[test]
    fn test_migration_114_to_115_creates_table_and_seeds() {
        let conn = create_v114_db();
        Migration114To115.up(&conn).unwrap();

        assert!(table_exists(&conn, "book_source_check_states").unwrap());
        for column in [
            "bookSourceUrl",
            "revision",
            "sourceRevision",
            "status",
            "checkedAt",
            "detail",
        ] {
            assert!(
                column_exists(&conn, "book_source_check_states", column),
                "列 {column} 应存在"
            );
        }

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_source_check_states", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 2, "每个存量书源一条状态");
        let (status, checked_at, detail, revision, source_revision): (
            String,
            i64,
            String,
            String,
            String,
        ) = conn
            .query_row(
                "SELECT status, checkedAt, detail, revision, sourceRevision
                 FROM book_source_check_states WHERE bookSourceUrl = 'https://a.example.com'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .unwrap();
        assert_eq!(status, "NEEDS_CHECK");
        assert_eq!(checked_at, 0);
        assert!(detail.is_empty());
        assert_eq!(revision.len(), 32, "randomblob(16) 的 hex 形态");
        assert_eq!(source_revision.len(), 32);
    }

    #[test]
    fn test_migration_114_to_115_idempotent_and_preserves_states() {
        let conn = create_v114_db();
        Migration114To115.up(&conn).unwrap();
        conn.execute(
            "UPDATE book_source_check_states SET status='PASSED', checkedAt=99, detail='ok',
                revision='fixed-rev', sourceRevision='fixed-source'
             WHERE bookSourceUrl = 'https://a.example.com'",
            [],
        )
        .unwrap();

        // 重复 up：不覆盖已有状态、不重复播种
        Migration114To115.up(&conn).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_source_check_states", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 2);
        let (status, checked_at, revision): (String, i64, String) = conn
            .query_row(
                "SELECT status, checkedAt, revision FROM book_source_check_states
                 WHERE bookSourceUrl = 'https://a.example.com'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(status, "PASSED");
        assert_eq!(checked_at, 99);
        assert_eq!(revision, "fixed-rev");
    }

    #[test]
    fn test_migration_114_to_115_adds_state_for_new_source_on_reup() {
        let conn = create_v114_db();
        Migration114To115.up(&conn).unwrap();
        conn.execute(
            "INSERT INTO book_sources (bookSourceUrl, bookSourceName)
             VALUES ('https://c.example.com', '源C')",
            [],
        )
        .unwrap();
        Migration114To115.up(&conn).unwrap();
        let seeded: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM book_source_check_states WHERE bookSourceUrl = 'https://c.example.com'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(seeded, 1, "开库自愈/重复 up 为新增源补状态");
    }

    /// P3-2：计数齐平时开库自愈不得执行播种写扫描
    ///
    /// 用 AFTER INSERT 触发器观察是否真的发生 INSERT；`INSERT OR IGNORE`
    /// 的冲突行不算 changes，无法用 `total_changes()` 区分，故用触发器计数。
    #[test]
    fn test_ensure_skips_seed_scan_when_counts_match() {
        let conn = create_v114_db();
        Migration114To115.up(&conn).unwrap();
        conn.execute_batch(
            "CREATE TABLE seed_probe (n INTEGER NOT NULL);
             INSERT INTO seed_probe (n) VALUES (0);
             CREATE TRIGGER seed_probe_trigger AFTER INSERT ON book_source_check_states
             BEGIN UPDATE seed_probe SET n = n + 1; END;",
        )
        .unwrap();

        // 开库自愈每库至少两次；计数齐平时都应直接返回
        ensure_book_source_check_states(&conn).unwrap();
        ensure_book_source_check_states(&conn).unwrap();
        let probes: i64 = conn
            .query_row("SELECT n FROM seed_probe", [], |r| r.get(0))
            .unwrap();
        assert_eq!(probes, 0, "计数齐平不得执行播种 INSERT");

        // 新增源 → 计数不齐 → 真正播种一次
        conn.execute(
            "INSERT INTO book_sources (bookSourceUrl, bookSourceName)
             VALUES ('https://d.example.com', '源D')",
            [],
        )
        .unwrap();
        ensure_book_source_check_states(&conn).unwrap();
        let probes: i64 = conn
            .query_row("SELECT n FROM seed_probe", [], |r| r.get(0))
            .unwrap();
        assert_eq!(probes, 1, "计数不齐应播种新增源");
    }

    #[test]
    fn test_migration_114_to_115_via_registry() {
        let conn = create_v114_db();
        conn.pragma_update(None, "user_version", 114).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
        assert!(table_exists(&conn, "book_source_check_states").unwrap());
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }

    #[test]
    fn test_migration_114_to_115_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        assert!(table_exists(&conn, "book_source_check_states").unwrap());
        Migration114To115.up(&conn).unwrap();
    }

    #[test]
    fn test_migration_114_to_115_skips_missing_source_table() {
        let conn = Connection::open_in_memory().unwrap();
        Migration114To115.up(&conn).unwrap();
        assert!(table_exists(&conn, "book_source_check_states").unwrap());
    }
}
