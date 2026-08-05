//! 各版本迁移实现
//!
//! 基于 Room schema 差异分析（版本号对齐上游 AppDatabase 语义）：
//! - v90 → v91: book_sources 新增 `mainJs` 列
//! - v91 → v92: 无结构变化（Room identityHash 变更）
//! - v92 → v93: 无结构变化
//! - v93 → v94: 新增 `auto_task_rules` 表
//! - v94 → v95: 无结构变化
//! - v95 → v96: 新建 `highlights` 表（上游语义，Room 96.json）
//! - v96 → v97: `highlights` 表新增 bookUrl/chapterUrl 列并回填（Migration_96_97）
//! - v97 → v98: 新建 `highlightRules` 表（上游 v98 引入）
//! - v98 → v99: `readRecord` 表新增 `author` 列并用 books 表回填（Migration_98_99）
//! - v99 → v100: `rule_subs` 表补全 Kotlin RuleSub 字段（customOrder/autoUpdate/
//!   updateInterval/silentUpdate/js/showRule/sourceUrl，Rust 轨自有扩展）
//! - v100 → v101: 偏离表修复（rssArticles/rssStars/readRecord/txtTocRules
//!   补齐 Room 99.json 缺列，对齐 Android 遗留库互读/迁移）
//!
//! 历史说明：原 Rust 自有 `Migration95To96`（books/rssSources 补列）与上游 v96
//! 语义撞车，已改造为不占版本号的幂等修复函数 [`repair_legacy_columns`]，
//! 由 `auto_migrate` 在迁移执行前统一调用。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};
use crate::schema::{CREATE_AUTO_TASK_RULES, CREATE_HIGHLIGHT_RULES};

/// BookType.notShelf（对齐 Kotlin `BookType.notShelf = 0b100_0000_0000`）
///
/// 未正式加入书架的临时阅读书籍标志位，Migration_98_99 回填时排除此类书籍。
const BOOK_TYPE_NOT_SHELF: i64 = 0b100_0000_0000;

// ---------------------------------------------------------------------------
// 幂等修复步骤（不占版本号）
// ---------------------------------------------------------------------------

/// 幂等修复历史遗留缺列问题（原 Rust 自有 Migration95To96 的内容）
///
/// 早期 Rust 轨曾以自有 v96 语义为 books/rssSources 补列，与上游 v96
/// （建 highlights 表）撞车。现改造为不占版本号的幂等修复步骤：
/// 用 PRAGMA table_info 检测缺列才补，可在任意版本安全重复执行。
///
/// 变更内容：
/// - books 表补齐: infoHtml, tocHtml, downloadUrls, coverOrigin
/// - rssSources 表补齐: jsLib, enabledCookieJar, contentWhitelist, contentBlacklist,
///   shouldOverrideUrlLoading, injectJs, preloadJs, startHtml, startStyle, startJs,
///   showWebLog, type, preload, cacheFirst, searchUrl
pub fn repair_legacy_columns(conn: &Connection) -> LegadoResult<()> {
    // books 表补列（仅当表存在时）
    if table_exists(conn, "books")? {
        add_column_if_not_exists(conn, "books", "infoHtml", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "tocHtml", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "downloadUrls", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "coverOrigin", "TEXT DEFAULT ''")?;
    }

    // rssSources 表补列（仅当表存在时）
    if table_exists(conn, "rssSources")? {
        add_column_if_not_exists(conn, "rssSources", "jsLib", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "enabledCookieJar", "INTEGER DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "contentWhitelist", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "contentBlacklist", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "shouldOverrideUrlLoading", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "injectJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "preloadJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startHtml", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startStyle", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "showWebLog", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "type", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "preload", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "cacheFirst", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "searchUrl", "TEXT")?;
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// v90 → v91: book_sources 新增 mainJs 列
// ---------------------------------------------------------------------------

/// 从 v90 升级到 v91
///
/// 变更内容：book_sources 表新增 `mainJs` TEXT 列
pub struct Migration90To91;

impl Migration for Migration90To91 {
    fn from_version(&self) -> u32 {
        90
    }
    fn to_version(&self) -> u32 {
        91
    }
    fn description(&self) -> &str {
        "book_sources 新增 mainJs 列"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        add_column_if_not_exists(conn, "book_sources", "mainJs", "TEXT")?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        // SQLite 不支持 DROP COLUMN（旧版本），需重建表
        Err(LegadoError::Database(
            "Cannot safely rollback Migration90To91: DROP COLUMN not supported".into(),
        ))
    }
}

// ---------------------------------------------------------------------------
// v91 → v92: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v91 升级到 v92
///
/// 变更内容：无表结构变化（Room 内部 identityHash 变更）
pub struct Migration91To92;

impl Migration for Migration91To92 {
    fn from_version(&self) -> u32 {
        91
    }
    fn to_version(&self) -> u32 {
        92
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        // 无结构变化，仅更新版本号
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v92 → v93: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v92 升级到 v93
///
/// 变更内容：无表结构变化
pub struct Migration92To93;

impl Migration for Migration92To93 {
    fn from_version(&self) -> u32 {
        92
    }
    fn to_version(&self) -> u32 {
        93
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v93 → v94: 新增 auto_task_rules 表
// ---------------------------------------------------------------------------

/// 从 v93 升级到 v94
///
/// 变更内容：新增 `auto_task_rules` 表
pub struct Migration93To94;

impl Migration for Migration93To94 {
    fn from_version(&self) -> u32 {
        93
    }
    fn to_version(&self) -> u32 {
        94
    }
    fn description(&self) -> &str {
        "新增 auto_task_rules 表"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "auto_task_rules")? {
            conn.execute_batch(CREATE_AUTO_TASK_RULES)
                .map_err(|e| LegadoError::Database(format!("创建 auto_task_rules 表失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, conn: &Connection) -> LegadoResult<()> {
        conn.execute_batch("DROP TABLE IF EXISTS auto_task_rules;")
            .map_err(|e| LegadoError::Database(format!("删除 auto_task_rules 表失败: {e}")))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v94 → v95: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v94 升级到 v95
///
/// 变更内容：无表结构变化
pub struct Migration94To95;

impl Migration for Migration94To95 {
    fn from_version(&self) -> u32 {
        94
    }
    fn to_version(&self) -> u32 {
        95
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v95 → v96: 新建 highlights 表（上游语义，Room 96.json）
// ---------------------------------------------------------------------------

/// 从 v95 升级到 v96（上游语义）
///
/// 变更内容：新建 `highlights` 表（v96 形态：不含 bookUrl/chapterUrl，
/// 该两列由上游 v96→v97 迁移追加）。
///
/// 注意：原 Rust 自有 v96 补列迁移已改造为 [`repair_legacy_columns`]，
/// 不再占用版本号。
pub struct Migration95To96;

impl Migration for Migration95To96 {
    fn from_version(&self) -> u32 {
        95
    }
    fn to_version(&self) -> u32 {
        96
    }
    fn description(&self) -> &str {
        "新建 highlights 表（上游 v96 语义）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "highlights")? {
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS highlights (
                    time INTEGER NOT NULL,
                    bookName TEXT NOT NULL,
                    bookAuthor TEXT NOT NULL,
                    chapterIndex INTEGER NOT NULL,
                    chapterPos INTEGER NOT NULL,
                    chapterPosEnd INTEGER NOT NULL,
                    layoutTitleLength INTEGER NOT NULL DEFAULT -1,
                    chapterName TEXT NOT NULL,
                    bookText TEXT NOT NULL,
                    style TEXT NOT NULL,
                    note TEXT NOT NULL,
                    PRIMARY KEY(time)
                );",
            )
            .map_err(|e| LegadoError::Database(format!("创建 highlights 表失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, conn: &Connection) -> LegadoResult<()> {
        conn.execute_batch("DROP TABLE IF EXISTS highlights;")
            .map_err(|e| LegadoError::Database(format!("删除 highlights 表失败: {e}")))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v96 → v97: highlights 新增 bookUrl/chapterUrl 列并回填（Migration_96_97）
// ---------------------------------------------------------------------------

/// 从 v96 升级到 v97
///
/// 变更内容（对应上游 `Migration_96_97`）：
/// 1. highlights 表新增 bookUrl/chapterUrl 列（TEXT NOT NULL DEFAULT ''）
/// 2. 按 bookName+bookAuthor 从 books 表回填 bookUrl
/// 3. 按 bookUrl+chapterIndex+chapterName 从 chapters 表回填 chapterUrl
pub struct Migration96To97;

impl Migration for Migration96To97 {
    fn from_version(&self) -> u32 {
        96
    }
    fn to_version(&self) -> u32 {
        97
    }
    fn description(&self) -> &str {
        "highlights 新增 bookUrl/chapterUrl 列并回填（Migration_96_97）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "highlights")? {
            // 防御：跳过 v96 直接升级的极端场景，先建 v96 形态表
            Migration95To96.up(conn)?;
        }
        add_column_if_not_exists(conn, "highlights", "bookUrl", "TEXT NOT NULL DEFAULT ''")?;
        add_column_if_not_exists(conn, "highlights", "chapterUrl", "TEXT NOT NULL DEFAULT ''")?;

        // 补建 bookUrl 索引（Room 97.json：index_highlights_bookUrl）
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS index_highlights_bookUrl ON highlights (bookUrl);",
        )
        .map_err(|e| LegadoError::Database(format!("创建 highlights 索引失败: {e}")))?;

        // 回填 bookUrl（上游 Migration_96_97 第一段 SQL）
        conn.execute_batch(
            "UPDATE highlights SET bookUrl = coalesce((
                SELECT books.bookUrl FROM books
                WHERE books.name = highlights.bookName
                AND books.author = highlights.bookAuthor
                LIMIT 1
            ), '') WHERE bookUrl = '';",
        )
        .map_err(|e| LegadoError::Database(format!("回填 highlights.bookUrl 失败: {e}")))?;

        // 回填 chapterUrl（上游 Migration_96_97 第二段 SQL）
        if table_exists(conn, "chapters")? {
            conn.execute_batch(
                "UPDATE highlights SET chapterUrl = coalesce((
                    SELECT chapters.url FROM chapters
                    WHERE chapters.bookUrl = highlights.bookUrl
                    AND chapters.\"index\" = highlights.chapterIndex
                    AND chapters.title = highlights.chapterName
                    LIMIT 1
                ), '') WHERE chapterUrl = '';",
            )
            .map_err(|e| LegadoError::Database(format!("回填 highlights.chapterUrl 失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration96To97: DROP COLUMN not supported".into(),
        ))
    }
}

// ---------------------------------------------------------------------------
// v97 → v98: 新建 highlightRules 表（上游 v98 引入）
// ---------------------------------------------------------------------------

/// 从 v97 升级到 v98
///
/// 变更内容：新建 `highlightRules` 表（自动高亮规则，Room 98.json 定义）。
pub struct Migration97To98;

impl Migration for Migration97To98 {
    fn from_version(&self) -> u32 {
        97
    }
    fn to_version(&self) -> u32 {
        98
    }
    fn description(&self) -> &str {
        "新建 highlightRules 表（上游 v98 引入）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "highlightRules")? {
            conn.execute_batch(CREATE_HIGHLIGHT_RULES)
                .map_err(|e| LegadoError::Database(format!("创建 highlightRules 表失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, conn: &Connection) -> LegadoResult<()> {
        conn.execute_batch("DROP TABLE IF EXISTS highlightRules;")
            .map_err(|e| LegadoError::Database(format!("删除 highlightRules 表失败: {e}")))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v98 → v99: readRecord 新增 author 列并回填（Migration_98_99）
// ---------------------------------------------------------------------------

/// 从 v98 升级到 v99
///
/// 变更内容（对应上游 v98→v99 的 `Migration_98_99`）：
/// 1. readRecord 表新增 `author` 列（TEXT NOT NULL DEFAULT ''）
/// 2. 书名唯一对应一个作者时，用书架数据（books 表）补全阅读记录的作者；
///    有歧义（多个不同作者）的保持为空；排除未正式上架的临时书籍
///    （type & BookType.notShelf != 0）
pub struct Migration98To99;

impl Migration for Migration98To99 {
    fn from_version(&self) -> u32 {
        98
    }
    fn to_version(&self) -> u32 {
        99
    }
    fn description(&self) -> &str {
        "readRecord 新增 author 列并用 books 回填（Migration_98_99）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "readRecord")? {
            add_column_if_not_exists(conn, "readRecord", "author", "TEXT NOT NULL DEFAULT ''")?;

            // 回填 author（上游 Migration_98_99 SQL，notShelf = 1024）
            let sql = format!(
                "UPDATE readRecord SET author = (
                    SELECT max(books.author) FROM books
                    WHERE books.name = readRecord.bookName
                    AND (books.type & {not_shelf}) = 0
                ) WHERE author = '' AND (
                    SELECT count(DISTINCT books.author) FROM books
                    WHERE books.name = readRecord.bookName
                    AND (books.type & {not_shelf}) = 0
                ) = 1;",
                not_shelf = BOOK_TYPE_NOT_SHELF
            );
            conn.execute_batch(&sql)
                .map_err(|e| LegadoError::Database(format!("回填 readRecord.author 失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration98To99: DROP COLUMN not supported".into(),
        ))
    }
}

// ---------------------------------------------------------------------------
// v99 → v100: rule_subs 补全 Kotlin RuleSub 字段（Rust 轨自有扩展）
// ---------------------------------------------------------------------------

/// 从 v99 升级到 v100
///
/// 变更内容（对齐 Kotlin `RuleSub` 实体字段清单）：
/// rule_subs 表新增 7 列：
/// - `custom_order` INTEGER（自定义排序，拖拽排序依据）
/// - `auto_update` INTEGER/BOOLEAN（是否自动更新）
/// - `update_interval` INTEGER（更新间隔，小时）
/// - `silent_update` INTEGER/BOOLEAN（是否静默更新）
/// - `js` TEXT（访问链接前执行的 js 规则）
/// - `show_rule` TEXT（显示规则）
/// - `source_url` TEXT（绑定的源链接）
///
/// 幂等检测缺列才补，重复执行安全。
pub struct Migration99To100;

impl Migration for Migration99To100 {
    fn from_version(&self) -> u32 {
        99
    }
    fn to_version(&self) -> u32 {
        100
    }
    fn description(&self) -> &str {
        "rule_subs 补全 Kotlin RuleSub 字段（customOrder/autoUpdate/updateInterval/silentUpdate/js/showRule/sourceUrl）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "rule_subs")? {
            add_column_if_not_exists(
                conn,
                "rule_subs",
                "custom_order",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
            add_column_if_not_exists(
                conn,
                "rule_subs",
                "auto_update",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
            add_column_if_not_exists(
                conn,
                "rule_subs",
                "update_interval",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
            add_column_if_not_exists(
                conn,
                "rule_subs",
                "silent_update",
                "INTEGER NOT NULL DEFAULT 0",
            )?;
            add_column_if_not_exists(conn, "rule_subs", "js", "TEXT")?;
            add_column_if_not_exists(conn, "rule_subs", "show_rule", "TEXT")?;
            add_column_if_not_exists(conn, "rule_subs", "source_url", "TEXT")?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration99To100: DROP COLUMN not supported".into(),
        ))
    }
}

// ---------------------------------------------------------------------------
// v100 → v101: 偏离表修复（对齐 Room 99.json 列集）
// ---------------------------------------------------------------------------

/// 从 v100 升级到 v101
///
/// 变更内容（列定义来源：Room 基线
/// `app/schemas/io.legado.app.data.AppDatabase/99.json` + Kotlin 实体）：
/// - rssArticles 补 4 列：
///   - `group` TEXT NOT NULL DEFAULT '默认分组'（RssArticle.kt @ColumnInfo）
///   - `read` INTEGER NOT NULL DEFAULT 0（Kotlin 默认 false，Room JSON 未带默认值，
///     SQLite 补列要求 NOT NULL 必须带默认值）
///   - `type` INTEGER NOT NULL DEFAULT 0（0网页，1图片，2视频）
///   - `durPos` INTEGER NOT NULL DEFAULT 0（阅读进度）
/// - rssStars 补 3 列：group/type/durPos（定义同上，RssStar.kt）
/// - readRecord 补 2 列：`deviceId` TEXT NOT NULL DEFAULT ''、
///   `lastRead` INTEGER NOT NULL DEFAULT 0（ReadRecord.kt）
/// - txtTocRules 补 1 列：`replacement` TEXT NOT NULL DEFAULT ''（TxtTocRule.kt）
///
/// 幂等检测缺列才补，重复执行安全。
pub struct Migration100To101;

impl Migration for Migration100To101 {
    fn from_version(&self) -> u32 {
        100
    }
    fn to_version(&self) -> u32 {
        101
    }
    fn description(&self) -> &str {
        "偏离表修复：rssArticles/rssStars/readRecord/txtTocRules 补齐 Room 99.json 缺列"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        // rssArticles 补列（Room 99.json：group/read/type/durPos）
        // group/read 为 SQLite 关键字，列名需带双引号
        if table_exists(conn, "rssArticles")? {
            add_column_if_not_exists(
                conn,
                "rssArticles",
                "\"group\"",
                "TEXT NOT NULL DEFAULT '默认分组'",
            )?;
            add_column_if_not_exists(conn, "rssArticles", "\"read\"", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssArticles", "type", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssArticles", "durPos", "INTEGER NOT NULL DEFAULT 0")?;
        }

        // rssStars 补列（Room 99.json：group/type/durPos）
        if table_exists(conn, "rssStars")? {
            add_column_if_not_exists(
                conn,
                "rssStars",
                "\"group\"",
                "TEXT NOT NULL DEFAULT '默认分组'",
            )?;
            add_column_if_not_exists(conn, "rssStars", "type", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_not_exists(conn, "rssStars", "durPos", "INTEGER NOT NULL DEFAULT 0")?;
        }

        // readRecord 补列（Room 99.json：deviceId/lastRead）
        if table_exists(conn, "readRecord")? {
            add_column_if_not_exists(conn, "readRecord", "deviceId", "TEXT NOT NULL DEFAULT ''")?;
            add_column_if_not_exists(conn, "readRecord", "lastRead", "INTEGER NOT NULL DEFAULT 0")?;
        }

        // txtTocRules 补列（Room 99.json：replacement）
        if table_exists(conn, "txtTocRules")? {
            add_column_if_not_exists(
                conn,
                "txtTocRules",
                "replacement",
                "TEXT NOT NULL DEFAULT ''",
            )?;
        }

        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration100To101: DROP COLUMN not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::Database;
    use crate::migration::MigrationRegistry;

    /// 构造 v95 形态的升级测试数据库（含 books/chapters/readRecord）
    fn create_v95_db() -> Database {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE books (
                bookUrl TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                author TEXT NOT NULL DEFAULT '',
                type INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(bookUrl)
            );
            CREATE TABLE chapters (
                url TEXT NOT NULL,
                title TEXT NOT NULL,
                bookUrl TEXT NOT NULL,
                \"index\" INTEGER NOT NULL,
                PRIMARY KEY(url, bookUrl)
            );
            CREATE TABLE readRecord (
                bookName TEXT NOT NULL,
                readTime INTEGER NOT NULL,
                PRIMARY KEY(bookName)
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 95).unwrap();
        db
    }

    fn column_exists(conn: &Connection, table: &str, column: &str) -> bool {
        let sql = format!("PRAGMA table_info({table})");
        let mut stmt = conn.prepare(&sql).unwrap();
        let result = stmt
            .query_map([], |row| {
                let name: String = row.get(1)?;
                Ok(name == column)
            })
            .unwrap()
            .filter_map(|r| r.ok())
            .any(|b| b);
        result
    }

    #[test]
    fn test_full_chain_v95_to_v99() {
        let db = create_v95_db();
        let conn = db.connection();

        // 准备回填数据：书籍 + 章节 + 高亮 + 阅读记录
        conn.execute(
            "INSERT INTO books (bookUrl, name, author, type) VALUES ('bk://1', '书名A', '作者A', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO chapters (url, title, bookUrl, \"index\") VALUES ('ch://1', '第一章', 'bk://1', 0)",
            [],
        )
        .unwrap();

        // 执行 v95 → v96（建表）后插入高亮数据，再继续升级
        let registry = MigrationRegistry::new();
        registry.migrate_to(conn, 96, 95).unwrap();
        conn.execute(
            "INSERT INTO highlights (time, bookName, bookAuthor, chapterIndex, chapterPos, chapterPosEnd, layoutTitleLength, chapterName, bookText, style, note)
             VALUES (1001, '书名A', '作者A', 0, 10, 20, -1, '第一章', '高亮文本', '{}', '备注')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO readRecord (bookName, readTime) VALUES ('书名A', 100)",
            [],
        )
        .unwrap();

        // 继续 v96 → v99
        registry.migrate_to(conn, 99, 96).unwrap();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 99);

        // 验证 bookUrl/chapterUrl 回填成功
        let (book_url, chapter_url): (String, String) = conn
            .query_row(
                "SELECT bookUrl, chapterUrl FROM highlights WHERE time = 1001",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(book_url, "bk://1");
        assert_eq!(chapter_url, "ch://1");

        // 验证 readRecord.author 回填成功
        let author: String = conn
            .query_row(
                "SELECT author FROM readRecord WHERE bookName = '书名A'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(author, "作者A");

        // 验证 highlightRules 表已创建
        assert!(table_exists(conn, "highlightRules").unwrap());
    }

    #[test]
    fn test_migration_idempotent_twice() {
        let db = create_v95_db();
        let conn = db.connection();
        let registry = MigrationRegistry::new();

        // 第一次迁移
        registry.migrate_to_latest(conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 101);

        // 第二次迁移（已是最新版本，应为 no-op 不报错）
        registry.migrate_to_latest(conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 101);

        // 幂等修复函数重复执行也不报错
        repair_legacy_columns(conn).unwrap();
        repair_legacy_columns(conn).unwrap();
    }

    #[test]
    fn test_migration_98_99_ambiguous_author_keeps_empty() {
        let db = create_v95_db();
        let conn = db.connection();
        // 同名书籍两个不同作者 → 回填应保持为空
        conn.execute(
            "INSERT INTO books (bookUrl, name, author, type) VALUES ('bk://1', '歧义书', '作者甲', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO books (bookUrl, name, author, type) VALUES ('bk://2', '歧义书', '作者乙', 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO readRecord (bookName, readTime) VALUES ('歧义书', 50)",
            [],
        )
        .unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(conn).unwrap();

        let author: String = conn
            .query_row(
                "SELECT author FROM readRecord WHERE bookName = '歧义书'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(author, "");
    }

    #[test]
    fn test_migration_98_99_excludes_not_shelf_books() {
        let db = create_v95_db();
        let conn = db.connection();
        // 仅存在 notShelf（1024）标志位的临时书籍 → 不参与回填
        conn.execute(
            "INSERT INTO books (bookUrl, name, author, type) VALUES ('bk://1', '临时书', '临时作者', 1024)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO readRecord (bookName, readTime) VALUES ('临时书', 50)",
            [],
        )
        .unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(conn).unwrap();

        let author: String = conn
            .query_row(
                "SELECT author FROM readRecord WHERE bookName = '临时书'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(author, "");
    }

    #[test]
    fn test_repair_legacy_columns_idempotent() {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE books (bookUrl TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '');
             CREATE TABLE rssSources (sourceUrl TEXT PRIMARY KEY, sourceName TEXT NOT NULL);",
        )
        .unwrap();

        // 重复执行两次均应成功
        repair_legacy_columns(conn).unwrap();
        repair_legacy_columns(conn).unwrap();

        assert!(column_exists(conn, "books", "infoHtml"));
        assert!(column_exists(conn, "books", "coverOrigin"));
        assert!(column_exists(conn, "rssSources", "searchUrl"));
        assert!(column_exists(conn, "rssSources", "cacheFirst"));
    }

    #[test]
    fn test_migration_99_to_100_rule_subs_columns() {
        // 构造 v99 形态的 rule_subs 表（缺少新增 7 列）
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE rule_subs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL DEFAULT '',
                sub_type TEXT NOT NULL DEFAULT 'bookSource',
                last_update INTEGER NOT NULL DEFAULT 0,
                version TEXT DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO rule_subs (url, name, created_at) VALUES ('https://example.com/s.json', '存量订阅', 1700000000000)",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 99).unwrap();

        // 执行 v99 → v100
        let m = Migration99To100;
        m.up(conn).unwrap();
        // 幂等：重复执行不报错
        m.up(conn).unwrap();

        assert!(column_exists(conn, "rule_subs", "custom_order"));
        assert!(column_exists(conn, "rule_subs", "auto_update"));
        assert!(column_exists(conn, "rule_subs", "update_interval"));
        assert!(column_exists(conn, "rule_subs", "silent_update"));
        assert!(column_exists(conn, "rule_subs", "js"));
        assert!(column_exists(conn, "rule_subs", "show_rule"));
        assert!(column_exists(conn, "rule_subs", "source_url"));

        // 存量数据新列取默认值
        let (custom_order, auto_update, js): (i32, i32, Option<String>) = conn
            .query_row(
                "SELECT custom_order, auto_update, js FROM rule_subs WHERE url = 'https://example.com/s.json'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(custom_order, 0);
        assert_eq!(auto_update, 0);
        assert!(js.is_none());

        // down 应报错（不支持 DROP COLUMN）
        assert!(m.down(conn).is_err());
    }

    #[test]
    fn test_fresh_db_reaches_v101_with_deviation_columns() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 101);
        assert!(table_exists(conn, "highlights").unwrap());
        assert!(table_exists(conn, "highlightRules").unwrap());
        assert!(column_exists(conn, "highlights", "bookUrl"));
        assert!(column_exists(conn, "highlights", "chapterUrl"));
        assert!(column_exists(conn, "readRecord", "author"));
        // v100: rule_subs 补全 Kotlin RuleSub 字段
        assert!(column_exists(conn, "rule_subs", "custom_order"));
        assert!(column_exists(conn, "rule_subs", "auto_update"));
        assert!(column_exists(conn, "rule_subs", "update_interval"));
        assert!(column_exists(conn, "rule_subs", "silent_update"));
        assert!(column_exists(conn, "rule_subs", "js"));
        assert!(column_exists(conn, "rule_subs", "show_rule"));
        assert!(column_exists(conn, "rule_subs", "source_url"));
        // v101: 偏离表补列（新建库 CREATE 语句已含全部列）
        assert!(column_exists(conn, "rssArticles", "group"));
        assert!(column_exists(conn, "rssArticles", "read"));
        assert!(column_exists(conn, "rssArticles", "type"));
        assert!(column_exists(conn, "rssArticles", "durPos"));
        assert!(column_exists(conn, "rssStars", "group"));
        assert!(column_exists(conn, "rssStars", "type"));
        assert!(column_exists(conn, "rssStars", "durPos"));
        assert!(column_exists(conn, "readRecord", "deviceId"));
        assert!(column_exists(conn, "readRecord", "lastRead"));
        assert!(column_exists(conn, "txtTocRules", "replacement"));
    }

    #[test]
    fn test_migration_100_to_101_deviation_columns() {
        // 构造 v100 形态的偏离表（缺少新增列）
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE rssArticles (
                origin TEXT NOT NULL,
                sort TEXT NOT NULL,
                title TEXT NOT NULL,
                \"order\" INTEGER NOT NULL,
                link TEXT,
                pubDate TEXT,
                description TEXT,
                content TEXT,
                image TEXT,
                variable TEXT,
                PRIMARY KEY(origin, title)
            );
            CREATE TABLE rssStars (
                origin TEXT NOT NULL,
                sort TEXT NOT NULL,
                title TEXT NOT NULL,
                starTime INTEGER NOT NULL,
                link TEXT,
                pubDate TEXT,
                description TEXT,
                content TEXT,
                image TEXT,
                variable TEXT,
                PRIMARY KEY(origin, title)
            );
            CREATE TABLE readRecord (
                bookName TEXT NOT NULL,
                author TEXT NOT NULL DEFAULT '',
                readTime INTEGER NOT NULL,
                PRIMARY KEY(bookName)
            );
            CREATE TABLE txtTocRules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL,
                rule TEXT NOT NULL,
                serialNumber INTEGER NOT NULL DEFAULT 0,
                enable INTEGER NOT NULL DEFAULT 1,
                example TEXT
            );",
        )
        .unwrap();
        // 存量数据（升级后新列应取默认值）
        conn.execute(
            "INSERT INTO rssArticles (origin, sort, title, \"order\", link) VALUES ('https://rss.com', 's1', '存量文章', 1, 'https://rss.com/a1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO rssStars (origin, sort, title, starTime, link) VALUES ('https://rss.com', 's1', '存量收藏', 100, 'https://rss.com/s1')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO readRecord (bookName, readTime) VALUES ('存量书', 500)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO txtTocRules (name, rule) VALUES ('存量规则', '^第.+章')",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 100).unwrap();

        // 执行 v100 → v101
        let m = Migration100To101;
        m.up(conn).unwrap();
        // 幂等：重复执行不报错
        m.up(conn).unwrap();

        // 新列全部存在
        assert!(column_exists(conn, "rssArticles", "group"));
        assert!(column_exists(conn, "rssArticles", "read"));
        assert!(column_exists(conn, "rssArticles", "type"));
        assert!(column_exists(conn, "rssArticles", "durPos"));
        assert!(column_exists(conn, "rssStars", "group"));
        assert!(column_exists(conn, "rssStars", "type"));
        assert!(column_exists(conn, "rssStars", "durPos"));
        assert!(column_exists(conn, "readRecord", "deviceId"));
        assert!(column_exists(conn, "readRecord", "lastRead"));
        assert!(column_exists(conn, "txtTocRules", "replacement"));

        // 存量数据新列取默认值
        let (group, read, article_type, dur_pos): (String, i32, i32, i32) = conn
            .query_row(
                "SELECT \"group\", \"read\", type, durPos FROM rssArticles WHERE title = '存量文章'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .unwrap();
        assert_eq!(group, "默认分组");
        assert_eq!(read, 0);
        assert_eq!(article_type, 0);
        assert_eq!(dur_pos, 0);

        let (star_group, star_type): (String, i32) = conn
            .query_row(
                "SELECT \"group\", type FROM rssStars WHERE title = '存量收藏'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(star_group, "默认分组");
        assert_eq!(star_type, 0);

        let (device_id, last_read): (String, i64) = conn
            .query_row(
                "SELECT deviceId, lastRead FROM readRecord WHERE bookName = '存量书'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(device_id, "");
        assert_eq!(last_read, 0);

        let replacement: String = conn
            .query_row(
                "SELECT replacement FROM txtTocRules WHERE name = '存量规则'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(replacement, "");

        // down 应报错（不支持 DROP COLUMN）
        assert!(m.down(conn).is_err());
    }

    #[test]
    fn test_migration_100_to_101_via_registry() {
        // 经注册表从 v100 升级到最新（v101）
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE rssArticles (
                origin TEXT NOT NULL,
                title TEXT NOT NULL,
                PRIMARY KEY(origin, title)
            );
            CREATE TABLE readRecord (
                bookName TEXT NOT NULL,
                readTime INTEGER NOT NULL,
                PRIMARY KEY(bookName)
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 100).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 101);
        assert!(column_exists(conn, "rssArticles", "group"));
        assert!(column_exists(conn, "readRecord", "lastRead"));
    }
}
