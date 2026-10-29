//! Migration116To117 — 书籍级阅读记录开关 `disableReadRecord`（批35）
//!
//! 对齐参考版 `Book.disableReadRecord`（`Book.kt:120-122`）与
//! `BookDao.setReadRecordDisabled`：单独为某一本书关闭阅读记录，写入侧
//! （Rust `upsert_read_record`）在落库前判断，不删除既有历史记录。
//!
//! DDL：`ALTER TABLE books ADD COLUMN disableReadRecord INTEGER NOT NULL DEFAULT 0`。
//! 旧库升级后全部存量书读为 `false`（照常记录），行为与升级前一致；
//! 旧 JSON / 旧备份缺该键时 serde 默认同样为 `false`。
//!
//! 幂等：`add_column_if_not_exists`（PRAGMA table_info 缺列检测），
//! 配合 `user_version` 门禁；开库自愈 `repair_legacy_columns` 另行兜住
//! 「版本号已到 117 但缺列」场景。

use rusqlite::Connection;

use legado_core::LegadoResult;

use crate::migration::add_column_if_not_exists;
use crate::migration::table_exists;
use crate::migration::Migration;

/// 从 v116 升级到 v117：books 增 `disableReadRecord` 列
pub struct Migration116To117;

impl Migration for Migration116To117 {
    fn from_version(&self) -> u32 {
        116
    }

    fn to_version(&self) -> u32 {
        117
    }

    fn description(&self) -> &str {
        "books 增 disableReadRecord 列（书籍级阅读记录开关，默认 0）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        // `books` 属核心表：表不存在时跳过（对齐 v109 originBookUrl 的防御性
        // 写法——迁移单测常用只建局部表的内存库，不得因缺表整体失败）
        if table_exists(conn, "books")? {
            add_column_if_not_exists(
                conn,
                "books",
                "disableReadRecord",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        // SQLite 不支持 DROP COLUMN 的旧版本兼容语义；列保留不影响旧逻辑
        // （旧代码只读取其关心的列）。回退只需降低 user_version（由注册表负责）。
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    #[test]
    fn test_migration_116_to_117_adds_column_default_false() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        // 模拟旧库：删掉新列（重建表成本高，直接在内存库上验证缺列场景）
        conn.execute_batch(
            "CREATE TABLE books_old AS SELECT bookUrl, tocUrl, origin, originName, name, author,
                kind, customTag, coverUrl, customCoverUrl, intro, customIntro, charset, type,
                \"group\", latestChapterTitle, latestChapterTime, lastCheckTime, lastCheckCount,
                totalChapterNum, durChapterTitle, durChapterIndex, durVolumeIndex,
                chapterInVolumeIndex, durChapterPos, durChapterTime, wordCount, canUpdate,
                \"order\", originOrder, variable, readConfig, syncTime, infoHtml, tocHtml,
                downloadUrls, coverOrigin, originBookUrl FROM books;
             DROP TABLE books;
             ALTER TABLE books_old RENAME TO books;",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO books (bookUrl, name) VALUES (?1, ?2)",
            rusqlite::params!["https://a.com/1", "存量书"],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 116).unwrap();

        Migration116To117.up(&conn).unwrap();

        let disabled: i64 = conn
            .query_row(
                "SELECT disableReadRecord FROM books WHERE bookUrl = 'https://a.com/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(disabled, 0, "存量书默认关闭态=false（照常记录）");

        // 幂等：重复执行不报错
        Migration116To117.up(&conn).unwrap();
    }

    #[test]
    fn test_migration_116_to_117_via_registry_advances_version() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.pragma_update(None, "user_version", 116).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );

        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }
}
