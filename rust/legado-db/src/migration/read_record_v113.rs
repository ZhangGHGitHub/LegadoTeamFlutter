//! Migration112To113 — readRecord 主键重建 + 章节快照/显示元数据 + book_memos
//!
//! 对齐原版 Room schema 113.json 与 `DatabaseMigrations.kt:30-57,78-107`：
//! - `readRecord` 主键 `(deviceId, bookName)` → `(deviceId, bookName, author)`，
//!   补 8 列：`lastChapterTitle` / `lastChapterIndex`（DEFAULT -1）/
//!   `lastChapterPos`（DEFAULT 0）/ `coverUrl` / `resolvedAuthor` /
//!   `displayBookName`（NOT NULL DEFAULT ''）/ `displayAuthor`（NOT NULL DEFAULT ''）/
//!   `metadataEditedAt`（NOT NULL DEFAULT 0）；
//! - 索引 `index_readRecord_snapshot`（displayBookName, displayAuthor,
//!   lastRead DESC, deviceId, bookName, author）与 `index_readRecord_bookName_author`；
//! - 新表 `book_memos`（`bookUrl` 主键，无级联外键）。
//!
//! 迁移语义（对齐原版 106→107 的重建表口径）：
//! - **原样搬运，不拆旧合并作者**：旧 `\u{1E}authors:` 集合串是「同书不同作者
//!   共用一条记录」的历史产物，其阅读时长无法按作者如实拆分，故 author 列原样
//!   保留（上游注释：`Keep legacy blank and combined authors intact: their time
//!   cannot be split truthfully`）；
//! - 113 的 `displayBookName/displayAuthor` 对存量行按
//!   `displayBookName = bookName`、`displayAuthor = CASE WHEN author = '' THEN
//!   coalesce(resolvedAuthor, '') ELSE author END` 回填（对齐上游 112→113）；
//! - **幂等**：上游 3.26102103 曾在版本号仍为 112 时先行发布 display 三列，
//!   故重建/补列前先探测 `displayBookName` 列；`Migration112To113::up` 与
//!   开库自愈（[`ensure_read_record_v113`]）可重复执行。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{
    add_column_if_not_exists, column_exists, primary_key_columns, table_exists, Migration,
};
use crate::schema::{CREATE_BOOK_MEMOS, CREATE_READ_RECORD};

/// v113 readRecord 的完整列集（顺序与建表语句一致）
const READ_RECORD_COLUMNS: [&str; 13] = [
    "deviceId",
    "bookName",
    "author",
    "readTime",
    "lastRead",
    "lastChapterTitle",
    "lastChapterIndex",
    "lastChapterPos",
    "coverUrl",
    "resolvedAuthor",
    "displayBookName",
    "displayAuthor",
    "metadataEditedAt",
];

/// v113 readRecord 主键列（顺序敏感）
const READ_RECORD_PK: [&str; 3] = ["deviceId", "bookName", "author"];

/// 快照索引列（顺序敏感，含 ASC/DESC 语义）
const SNAPSHOT_INDEX_COLUMNS: [&str; 6] = [
    "displayBookName",
    "displayAuthor",
    "lastRead",
    "deviceId",
    "bookName",
    "author",
];

/// 书名/作者索引列
const BOOK_NAME_INDEX_COLUMNS: [&str; 2] = ["bookName", "author"];

/// 确保 readRecord 为 v113 形态（幂等，供迁移与开库自愈共用）
///
/// 步骤：
/// 1. 表不存在 → 直接按 v113 建表；
/// 2. 主键不是 `(deviceId, bookName, author)` → 重建表并**原样搬运**已存在的列
///    （缺列落建表默认值），随后回填显示元数据；
/// 3. 主键已正确但缺列（历史部分迁移/上游「发列未升版本」）→ 补列并回填；
/// 4. 确保 `book_memos` 表与两个索引存在（旧同名索引列集不符时先 DROP）。
pub fn ensure_read_record_v113(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "readRecord")? {
        conn.execute_batch(CREATE_READ_RECORD)
            .map_err(|e| LegadoError::Database(format!("创建 readRecord 表失败: {e}")))?;
    } else {
        let pk = primary_key_columns(conn, "readRecord")?;
        if pk != READ_RECORD_PK {
            rebuild_read_record(conn)?;
        } else {
            add_missing_columns(conn)?;
        }
    }

    if !table_exists(conn, "book_memos")? {
        conn.execute_batch(CREATE_BOOK_MEMOS)
            .map_err(|e| LegadoError::Database(format!("创建 book_memos 表失败: {e}")))?;
    }

    ensure_index(
        conn,
        "index_readRecord_snapshot",
        &SNAPSHOT_INDEX_COLUMNS,
        "CREATE INDEX IF NOT EXISTS index_readRecord_snapshot ON readRecord \
         (displayBookName ASC, displayAuthor ASC, lastRead DESC, deviceId ASC, bookName ASC, author ASC)",
    )?;
    ensure_index(
        conn,
        "index_readRecord_bookName_author",
        &BOOK_NAME_INDEX_COLUMNS,
        "CREATE INDEX IF NOT EXISTS index_readRecord_bookName_author ON readRecord (bookName, author)",
    )?;
    Ok(())
}

/// 重建 readRecord 表（旧主键 → 新主键，原样搬运已存在列）
fn rebuild_read_record(conn: &Connection) -> LegadoResult<()> {
    let existing = table_columns(conn, "readRecord")?;
    let had_display = existing.iter().any(|c| c == "displayBookName");
    // 只搬运新旧表都存在的列：其余列由建表默认值兜底（DEFAULT -1/0/''）
    let shared: Vec<&str> = READ_RECORD_COLUMNS
        .iter()
        .copied()
        .filter(|column| existing.iter().any(|c| c == column))
        .collect();
    let column_list = shared.join(", ");
    // display 三列由上游 112→113 追加；重建时若原本缺失，搬运后按上游口径回填
    let backfill = if had_display {
        String::new()
    } else {
        "UPDATE readRecord SET displayBookName = bookName, \
         displayAuthor = CASE WHEN author = '' THEN coalesce(resolvedAuthor, '') ELSE author END;"
            .to_string()
    };
    let sql = format!(
        "BEGIN;
         DROP TABLE IF EXISTS readRecord_v113;
         CREATE TABLE readRecord_v113 (
             deviceId TEXT NOT NULL,
             bookName TEXT NOT NULL,
             author TEXT NOT NULL DEFAULT '',
             readTime INTEGER NOT NULL DEFAULT 0,
             lastRead INTEGER NOT NULL DEFAULT 0,
             lastChapterTitle TEXT,
             lastChapterIndex INTEGER NOT NULL DEFAULT -1,
             lastChapterPos INTEGER NOT NULL DEFAULT 0,
             coverUrl TEXT,
             resolvedAuthor TEXT,
             displayBookName TEXT NOT NULL DEFAULT '',
             displayAuthor TEXT NOT NULL DEFAULT '',
             metadataEditedAt INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY(deviceId, bookName, author)
         );
         INSERT OR REPLACE INTO readRecord_v113 ({column_list})
             SELECT {column_list} FROM readRecord;
         DROP TABLE readRecord;
         ALTER TABLE readRecord_v113 RENAME TO readRecord;
         {backfill}
         COMMIT;"
    );
    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("重建 readRecord 表失败: {e}")))?;
    Ok(())
}

/// 主键已正确时补缺列；补入 display 三列时按上游口径回填显示元数据
fn add_missing_columns(conn: &Connection) -> LegadoResult<()> {
    let had_display = column_exists(conn, "readRecord", "displayBookName")?;
    add_column_if_not_exists(conn, "readRecord", "lastChapterTitle", "TEXT")?;
    add_column_if_not_exists(
        conn,
        "readRecord",
        "lastChapterIndex",
        "INTEGER NOT NULL DEFAULT -1",
    )?;
    add_column_if_not_exists(
        conn,
        "readRecord",
        "lastChapterPos",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_column_if_not_exists(conn, "readRecord", "coverUrl", "TEXT")?;
    add_column_if_not_exists(conn, "readRecord", "resolvedAuthor", "TEXT")?;
    add_column_if_not_exists(
        conn,
        "readRecord",
        "displayBookName",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    add_column_if_not_exists(
        conn,
        "readRecord",
        "displayAuthor",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    add_column_if_not_exists(
        conn,
        "readRecord",
        "metadataEditedAt",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    if !had_display {
        conn.execute(
            "UPDATE readRecord SET displayBookName = bookName, \
             displayAuthor = CASE WHEN author = '' THEN coalesce(resolvedAuthor, '') ELSE author END",
            [],
        )
        .map_err(|e| LegadoError::Database(format!("回填 readRecord 显示元数据失败: {e}")))?;
    }
    Ok(())
}

/// 读取表的全部列名（PRAGMA table_info）
fn table_columns(conn: &Connection, table: &str) -> LegadoResult<Vec<String>> {
    let sql = format!("PRAGMA table_info({table})");
    let mut stmt = conn
        .prepare(&sql)
        .map_err(|e| LegadoError::Database(format!("查询表结构失败: {e}")))?;
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| LegadoError::Database(format!("遍历表结构失败: {e}")))?
        .filter_map(|r| r.ok())
        .collect();
    Ok(columns)
}

/// 读取索引的列名（`PRAGMA index_info`；索引不存在时返回 `None`）
fn index_columns(conn: &Connection, index: &str) -> LegadoResult<Option<Vec<String>>> {
    let sql = format!("PRAGMA index_info('{index}')");
    let mut stmt = match conn.prepare(&sql) {
        Ok(stmt) => stmt,
        Err(_) => return Ok(None),
    };
    let columns: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(2))
        .map_err(|e| LegadoError::Database(format!("遍历索引结构失败: {e}")))?
        .filter_map(|r| r.ok())
        .collect();
    if columns.is_empty() {
        Ok(None)
    } else {
        Ok(Some(columns))
    }
}

/// 确保索引存在且列集正确：同名旧索引列集不符时先 DROP（上游 109→110
/// 的旧快照索引只含 4 列，`CREATE INDEX IF NOT EXISTS` 会保留错误定义）
fn ensure_index(
    conn: &Connection,
    name: &str,
    expected: &[&str],
    create_sql: &str,
) -> LegadoResult<()> {
    if let Some(columns) = index_columns(conn, name)? {
        if columns.len() != expected.len()
            || columns
                .iter()
                .zip(expected)
                .any(|(actual, want)| actual != want)
        {
            conn.execute(&format!("DROP INDEX IF EXISTS {name}"), [])
                .map_err(|e| LegadoError::Database(format!("删除旧索引 {name} 失败: {e}")))?;
        }
    }
    conn.execute_batch(create_sql)
        .map_err(|e| LegadoError::Database(format!("创建索引 {name} 失败: {e}")))?;
    Ok(())
}

/// 从 v112 升级到 v113
///
/// 变更内容：重建 `readRecord`（新主键 + 8 列）、创建 `book_memos` 与两个索引。
/// 幂等：`user_version` 门禁 + [`ensure_read_record_v113`] 的探测逻辑
/// （displayBookName 列/主键/索引列集），重复执行或上游「发列未升版本」均安全。
pub struct Migration112To113;

impl Migration for Migration112To113 {
    fn from_version(&self) -> u32 {
        112
    }

    fn to_version(&self) -> u32 {
        113
    }

    fn description(&self) -> &str {
        "readRecord 主键加 author + 章节快照/显示元数据 8 列 + 快照索引；新增 book_memos 表"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        ensure_read_record_v113(conn)
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration112To113: DROP TABLE/COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    /// 构造 v112 形态的 readRecord（5 列，主键 (deviceId, bookName)）
    fn create_v112_database(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE readRecord (
                 deviceId TEXT NOT NULL DEFAULT '',
                 bookName TEXT NOT NULL,
                 author TEXT NOT NULL DEFAULT '',
                 readTime INTEGER NOT NULL DEFAULT 0,
                 lastRead INTEGER NOT NULL DEFAULT 0,
                 PRIMARY KEY(deviceId, bookName)
             );
             INSERT INTO readRecord (deviceId, bookName, author, readTime, lastRead)
                 VALUES ('', '书名A', '作者A', 100, 10);
             INSERT INTO readRecord (deviceId, bookName, author, readTime, lastRead)
                 VALUES ('', '合并书', '\u{1E}authors:[\"作者B\",\"作者C\"]', 200, 20);
             INSERT INTO readRecord (deviceId, bookName, author, readTime, lastRead)
                 VALUES ('device-X', '书名B', '', 300, 30);",
        )
        .unwrap();
    }

    fn column_exists(conn: &Connection, column: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('readRecord') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    fn index_exists(conn: &Connection, name: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name = ?1",
            [name],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// v112→v113：旧行原样搬运（含合并作者串不拆）、主键变化、新列默认值/回填
    #[test]
    fn test_migration_112_to_113_rebuilds_and_keeps_rows() {
        let conn = Connection::open_in_memory().unwrap();
        create_v112_database(&conn);

        Migration112To113.up(&conn).unwrap();

        for column in READ_RECORD_COLUMNS {
            assert!(column_exists(&conn, column), "readRecord 应含 {column} 列");
        }
        assert_eq!(
            primary_key_columns(&conn, "readRecord").unwrap(),
            READ_RECORD_PK
        );
        assert!(index_exists(&conn, "index_readRecord_snapshot"));
        assert!(index_exists(&conn, "index_readRecord_bookName_author"));
        assert!(table_exists(&conn, "book_memos").unwrap());

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM readRecord", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 3, "旧行应原样保留");

        // 合并作者串原样保留（不拆不合并）
        let combined: (String, i32, String) = conn
            .query_row(
                "SELECT author, readTime, displayAuthor FROM readRecord
                 WHERE bookName = '合并书' AND author LIKE '\u{1E}authors:%'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert!(combined.0.starts_with("\u{1E}authors:"));
        assert_eq!(combined.1, 200);
        assert_eq!(
            combined.2, combined.0,
            "displayAuthor 按上游口径回填为 author 原值（不拆合并串）"
        );

        // 新列默认值：lastChapterIndex=-1 / lastChapterPos=0 / metadataEditedAt=0
        let (idx, pos, edited, display_name, resolved): (i32, i32, i64, String, Option<String>) =
            conn.query_row(
                "SELECT lastChapterIndex, lastChapterPos, metadataEditedAt,
                        displayBookName, resolvedAuthor
                 FROM readRecord WHERE bookName = '书名B'",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(idx, -1);
        assert_eq!(pos, 0);
        assert_eq!(edited, 0);
        assert_eq!(display_name, "书名B");
        assert_eq!(resolved, None);

        // 空作者存量行的 displayAuthor 回退 resolvedAuthor（此处为空串）
        let empty_display: String = conn
            .query_row(
                "SELECT displayAuthor FROM readRecord WHERE bookName = '书名B'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(empty_display, "");
    }

    /// 幂等：重复执行不清数据、不重复建列
    #[test]
    fn test_migration_112_to_113_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        create_v112_database(&conn);
        Migration112To113.up(&conn).unwrap();
        Migration112To113.up(&conn).unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM readRecord", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 3);
    }

    /// 上游「发列未升版本」：display 三列已存在时只补索引/表，不回填覆盖已有显示值
    #[test]
    fn test_migration_112_to_113_display_columns_preexisting() {
        let conn = Connection::open_in_memory().unwrap();
        create_v112_database(&conn);
        conn.execute_batch(
            "ALTER TABLE readRecord ADD COLUMN displayBookName TEXT NOT NULL DEFAULT '';
             ALTER TABLE readRecord ADD COLUMN displayAuthor TEXT NOT NULL DEFAULT '';
             ALTER TABLE readRecord ADD COLUMN metadataEditedAt INTEGER NOT NULL DEFAULT 0;
             UPDATE readRecord SET displayBookName = '已编辑书名', displayAuthor = '已编辑作者',
                 metadataEditedAt = 123 WHERE bookName = '书名A' AND author = '作者A';",
        )
        .unwrap();

        Migration112To113.up(&conn).unwrap();

        let (name, author, edited): (String, String, i64) = conn
            .query_row(
                "SELECT displayBookName, displayAuthor, metadataEditedAt FROM readRecord
                 WHERE bookName = '书名A' AND author = '作者A'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(name, "已编辑书名");
        assert_eq!(author, "已编辑作者");
        assert_eq!(edited, 123);
    }

    /// 旧同名快照索引（上游 109→110 的 4 列版本）应被替换为新 6 列定义
    #[test]
    fn test_migration_112_to_113_replaces_old_snapshot_index() {
        let conn = Connection::open_in_memory().unwrap();
        create_v112_database(&conn);
        conn.execute_batch(
            "CREATE INDEX index_readRecord_snapshot
             ON readRecord(bookName, author, lastRead DESC, deviceId);",
        )
        .unwrap();

        Migration112To113.up(&conn).unwrap();

        let columns = index_columns(&conn, "index_readRecord_snapshot")
            .unwrap()
            .unwrap();
        assert_eq!(columns, SNAPSHOT_INDEX_COLUMNS);
    }

    /// 经注册表从 v112 升级到最新版本：版本推进且结构到位
    #[test]
    fn test_migration_112_to_113_via_registry() {
        let conn = Connection::open_in_memory().unwrap();
        create_v112_database(&conn);
        conn.pragma_update(None, "user_version", 112).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();

        // 批28 起居最新版本已推进到 v114（113→114 为独立迁移），此处按
        // SCHEMA_VERSION 断言（本用例只验证 112→113 结构随链式迁移到位）
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
        assert!(column_exists(&conn, "metadataEditedAt"));
        assert!(table_exists(&conn, "book_memos").unwrap());
    }

    /// 全新库 init_schema 已建 v113 结构，up 应为空操作
    #[test]
    fn test_migration_112_to_113_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        Migration112To113.up(&conn).unwrap();
        assert!(column_exists(&conn, "displayBookName"));
        assert!(table_exists(&conn, "book_memos").unwrap());
    }

    /// 回归：开库自愈把旧库提前升到 v113 后，v103→v104 迁移不得把 readRecord
    /// 重建回两列主键（否则丢作者维度）
    #[test]
    fn test_v104_rebuild_skips_already_v113_read_record() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.execute(
            "INSERT INTO readRecord (deviceId, bookName, author, readTime, lastRead)
             VALUES ('', '保作者书', '作者A', 100, 10)",
            [],
        )
        .unwrap();

        crate::migration::schema_align_v104::Migration103To104
            .up(&conn)
            .unwrap();

        assert_eq!(
            primary_key_columns(&conn, "readRecord").unwrap(),
            READ_RECORD_PK,
            "v104 迁移不得降级 v113 主键"
        );
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM readRecord WHERE bookName = '保作者书' AND author = '作者A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "已有行应保留");
    }
}
