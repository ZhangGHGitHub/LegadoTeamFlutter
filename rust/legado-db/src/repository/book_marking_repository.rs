//! BookMarkingRepository — book_marks 表数据访问层（schema v118，书签标记）
//!
//! 逐条对齐参考版 `data/dao/BookMarkingDao.kt:13-87`：
//! - `flowByBook` → [`BookMarkingRepository::list_by_book`]（按书名+作者跨源，
//!   `chapterIndex` 升序、`createdAt` 升序）；
//! - `getForChapterSync` → [`BookMarkingRepository::list_for_chapter`]（按
//!   `bookUrl` 查；`chapterIndex` 为 Some 时同时返回 `chapterIndex IS NULL`
//!   的全局标记，`createdAt` 升序）；
//! - `getById` / `upsert`（INSERT OR REPLACE）/ `setEnabled` / `delete`；
//! - `all`（参考版 `BookMarkingDao.all`）→ [`BookMarkingRepository::find_all`]。
//!
//! 书签标记与 `bookmarks`（页面导航）和 `highlights`（正文高亮记录）独立。
//! 备份口径：参考版 `Backup.kt:71,158` / `Restore.kt:163-165` **包含**
//! `bookMarking.json`，我方备份格式 v6 起同样纳入——`backup_create` 经
//! [`BookMarkingRepository::find_all`] 收集，恢复经 `upsert` 落库。
//!
//! 查询口径（批7b-1 审查 P3-1）：列表查询统一走
//! [`super::collect_rows_logged`]——坏行（列类型漂移/损坏）跳过但记 stderr
//! 日志（含前 3 条错误与总条数），不再用 `filter_map(|r| r.ok())` 静默吞错，
//! 避免标记「凭空消失」无从定位（同 `book_source_repository.rs` 批30b 先例）。

use rusqlite::{params, Connection, OptionalExtension};

use legado_core::models::BookMarking;
use legado_core::{LegadoError, LegadoResult};

/// 查询列（与 [`row_to_marking`] 的索引一一对应）
const SELECT_COLUMNS: &str = "SELECT id, bookUrl, bookName, bookAuthor, chapterIndex,
    anchorJson, styleJson, note, chapterName, enabled, createdAt, updatedAt FROM book_marks";

/// 书签标记数据访问层
pub struct BookMarkingRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookMarkingRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 取全表（对齐参考版 `BookMarkingDao.all`，供备份导出）
    ///
    /// `createdAt` 升序、`id` 兜底，保证同一库两次备份产出的数组顺序稳定
    /// （为备份往返的逐字段比对提供可复现基线）。
    pub fn find_all(&self) -> LegadoResult<Vec<BookMarking>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} ORDER BY createdAt ASC, id ASC"))
            .map_err(|e| LegadoError::Database(format!("准备书签标记全量查询失败: {e}")))?;
        let rows = super::collect_rows_logged(
            stmt.query_map([], row_to_marking)
                .map_err(|e| LegadoError::Database(format!("查询书签标记失败: {e}")))?,
            "book_marks find_all",
        );
        Ok(rows)
    }

    /// 按「书名 + 作者」取全部章节/全部源的标记
    ///
    /// 对齐参考版 `flowByBook`：`order by chapterIndex, createdAt`；
    /// 追加 `id` 作为稳定次序兜底（同毫秒多条时结果可复现）。
    pub fn list_by_book(
        &self,
        book_name: &str,
        book_author: &str,
    ) -> LegadoResult<Vec<BookMarking>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE bookName = ?1 AND bookAuthor = ?2
                 ORDER BY chapterIndex ASC, createdAt ASC, id ASC"
            ))
            .map_err(|e| LegadoError::Database(format!("准备书签标记查询失败: {e}")))?;
        let rows = super::collect_rows_logged(
            stmt.query_map(params![book_name, book_author], row_to_marking)
                .map_err(|e| LegadoError::Database(format!("查询书签标记失败: {e}")))?,
            "book_marks list_by_book",
        );
        Ok(rows)
    }

    /// 按源地址取标记
    ///
    /// `chapter_index` 为 Some 时对齐参考版 `getForChapterSync` 的
    /// `(:chapterIndex is null or chapterIndex is null or chapterIndex = :chapterIndex)`；
    /// None 时取该书全部章节。排序 `createdAt` 升序（`id` 兜底）。
    pub fn list_for_chapter(
        &self,
        book_url: &str,
        chapter_index: Option<i32>,
    ) -> LegadoResult<Vec<BookMarking>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE bookUrl = ?1
                   AND (?2 IS NULL OR chapterIndex IS NULL OR chapterIndex = ?2)
                 ORDER BY createdAt ASC, id ASC"
            ))
            .map_err(|e| LegadoError::Database(format!("准备书签标记章节查询失败: {e}")))?;
        let rows = super::collect_rows_logged(
            stmt.query_map(params![book_url, chapter_index], row_to_marking)
                .map_err(|e| LegadoError::Database(format!("查询书签标记失败: {e}")))?,
            "book_marks list_for_chapter",
        );
        Ok(rows)
    }

    /// 按主键读取（不存在返回 None）
    pub fn get_by_id(&self, id: &str) -> LegadoResult<Option<BookMarking>> {
        self.conn
            .query_row(
                &format!("{SELECT_COLUMNS} WHERE id = ?1"),
                params![id],
                row_to_marking,
            )
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询书签标记失败: {e}")))
    }

    /// 整条写入/覆盖（`INSERT OR REPLACE`，对齐 DAO `@Insert(onConflict = REPLACE)`）
    pub fn upsert(&self, marking: &BookMarking) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO book_marks
                 (id, bookUrl, bookName, bookAuthor, chapterIndex, anchorJson,
                  styleJson, note, chapterName, enabled, createdAt, updatedAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![
                    marking.id,
                    marking.book_url,
                    marking.book_name,
                    marking.book_author,
                    marking.chapter_index,
                    marking.anchor_json,
                    marking.style_json,
                    marking.note,
                    marking.chapter_name,
                    if marking.enabled { 1i64 } else { 0i64 },
                    marking.created_at,
                    marking.updated_at,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写入书签标记失败: {e}")))?;
        Ok(())
    }

    /// 更新启用状态与更新时间，返回是否存在该行（不存在为 no-op）
    pub fn set_enabled(&self, id: &str, enabled: bool, updated_at: i64) -> LegadoResult<bool> {
        let rows = self
            .conn
            .execute(
                "UPDATE book_marks SET enabled = ?1, updatedAt = ?2 WHERE id = ?3",
                params![if enabled { 1i64 } else { 0i64 }, updated_at, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新书签标记启用状态失败: {e}")))?;
        Ok(rows > 0)
    }

    /// 按主键删除，返回是否实际删除（不存在为 no-op）
    pub fn delete(&self, id: &str) -> LegadoResult<bool> {
        let rows = self
            .conn
            .execute("DELETE FROM book_marks WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除书签标记失败: {e}")))?;
        Ok(rows > 0)
    }
}

fn row_to_marking(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookMarking> {
    Ok(BookMarking {
        id: row.get(0)?,
        book_url: row.get(1)?,
        book_name: row.get(2)?,
        book_author: row.get(3)?,
        chapter_index: row.get(4)?,
        anchor_json: row.get(5)?,
        style_json: row.get(6)?,
        note: row.get(7)?,
        chapter_name: row.get(8)?,
        enabled: row.get::<_, i64>(9)? != 0,
        created_at: row.get(10)?,
        updated_at: row.get(11)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init_in_memory_database;

    fn make_marking(
        id: &str,
        book_url: &str,
        book_name: &str,
        book_author: &str,
        chapter_index: Option<i32>,
        created_at: i64,
    ) -> BookMarking {
        BookMarking {
            id: id.to_string(),
            book_url: book_url.to_string(),
            book_name: book_name.to_string(),
            book_author: book_author.to_string(),
            chapter_index,
            anchor_json: "{\"start\":0}".to_string(),
            style_json: Some("{\"textColor\":-1}".to_string()),
            note: format!("备注-{id}"),
            chapter_name: format!("第{chapter_index:?}章"),
            enabled: true,
            created_at,
            updated_at: created_at,
        }
    }

    #[test]
    fn test_crud_roundtrip() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());

        assert!(repo.get_by_id("m1").unwrap().is_none());
        assert!(!repo.delete("m1").unwrap(), "不存在时 delete 为 no-op");

        let marking = make_marking("m1", "https://a/1", "书", "作者", Some(0), 100);
        repo.upsert(&marking).unwrap();

        let loaded = repo.get_by_id("m1").unwrap().unwrap();
        assert_eq!(loaded, marking);
        assert!(loaded.enabled, "布尔应落 1 并读回 true");

        // 覆盖同 id（INSERT OR REPLACE）
        let mut updated = marking.clone();
        updated.note = "新备注".into();
        updated.enabled = false;
        updated.updated_at = 200;
        repo.upsert(&updated).unwrap();
        let loaded = repo.get_by_id("m1").unwrap().unwrap();
        assert_eq!(loaded.note, "新备注");
        assert!(!loaded.enabled);

        assert!(repo.delete("m1").unwrap(), "存在时 delete 返回 true");
        assert!(repo.get_by_id("m1").unwrap().is_none());
    }

    /// 全表查询：跨书跨源全部返回，`createdAt` 升序、`id` 兜底（备份导出用）
    #[test]
    fn test_find_all_ordering() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());

        repo.upsert(&make_marking(
            "b2",
            "https://b/2",
            "书乙",
            "作者乙",
            Some(1),
            200,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "a2",
            "https://a/1",
            "书甲",
            "作者甲",
            Some(0),
            100,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "a1",
            "https://a/1",
            "书甲",
            "作者甲",
            None,
            100,
        ))
        .unwrap();

        let all = repo.find_all().unwrap();
        let ids: Vec<_> = all.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["a1", "a2", "b2"],
            "createdAt 升序、同毫秒 id 兜底"
        );
    }

    /// 按书名+作者排序：chapterIndex 升序（NULL 在前，SQLite 默认），再 createdAt
    #[test]
    fn test_list_by_book_ordering() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());

        repo.upsert(&make_marking(
            "m3",
            "https://a/1",
            "书",
            "作者",
            Some(2),
            100,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "m1",
            "https://a/1",
            "书",
            "作者",
            Some(0),
            300,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "m2",
            "https://a/1",
            "书",
            "作者",
            Some(0),
            200,
        ))
        .unwrap();
        repo.upsert(&make_marking("m0", "https://a/1", "书", "作者", None, 400))
            .unwrap();
        // 同名不同作者不混入
        repo.upsert(&make_marking(
            "x1",
            "https://a/1",
            "书",
            "另一作者",
            Some(1),
            100,
        ))
        .unwrap();

        let list = repo.list_by_book("书", "作者").unwrap();
        let ids: Vec<_> = list.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["m0", "m2", "m1", "m3"]);

        assert!(repo.list_by_book("书", "不存在").unwrap().is_empty());
    }

    /// 跨源：同名+作者的不同 bookUrl 全部返回（换源后仍可见）
    #[test]
    fn test_list_by_book_cross_source() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());

        repo.upsert(&make_marking(
            "a1",
            "https://a/1",
            "书",
            "作者",
            Some(1),
            100,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "b1",
            "https://b/2",
            "书",
            "作者",
            Some(1),
            200,
        ))
        .unwrap();

        let list = repo.list_by_book("书", "作者").unwrap();
        assert_eq!(list.len(), 2);
        let urls: Vec<_> = list.iter().map(|m| m.book_url.as_str()).collect();
        assert_eq!(urls, vec!["https://a/1", "https://b/2"]);

        // 按源查只返回当前源
        let for_a = repo.list_for_chapter("https://a/1", None).unwrap();
        assert_eq!(for_a.len(), 1);
        assert_eq!(for_a[0].id, "a1");
    }

    /// 章节过滤：Some 时包含该章与 chapterIndex IS NULL；None 时全书
    #[test]
    fn test_list_for_chapter_filter() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());

        repo.upsert(&make_marking(
            "c1",
            "https://a/1",
            "书",
            "作者",
            Some(1),
            100,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "c2",
            "https://a/1",
            "书",
            "作者",
            Some(2),
            200,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "null",
            "https://a/1",
            "书",
            "作者",
            None,
            300,
        ))
        .unwrap();
        repo.upsert(&make_marking(
            "other",
            "https://a/1",
            "书",
            "作者",
            Some(1),
            50,
        ))
        .unwrap();

        let chapter1 = repo.list_for_chapter("https://a/1", Some(1)).unwrap();
        let ids: Vec<_> = chapter1.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["other", "c1", "null"],
            "createdAt 升序且含 NULL 行"
        );

        let all = repo.list_for_chapter("https://a/1", None).unwrap();
        assert_eq!(all.len(), 4);

        let empty = repo.list_for_chapter("https://a/1", Some(9)).unwrap();
        assert_eq!(empty.len(), 1, "只剩 chapterIndex IS NULL 的全局标记");
        assert_eq!(empty[0].id, "null");
    }

    #[test]
    fn test_set_enabled_and_noop() {
        let db = init_in_memory_database().unwrap();
        let repo = BookMarkingRepository::new(db.connection());
        repo.upsert(&make_marking(
            "m1",
            "https://a/1",
            "书",
            "作者",
            Some(0),
            100,
        ))
        .unwrap();

        assert!(repo.set_enabled("m1", false, 500).unwrap());
        let loaded = repo.get_by_id("m1").unwrap().unwrap();
        assert!(!loaded.enabled);
        assert_eq!(loaded.updated_at, 500);
        assert_eq!(loaded.created_at, 100, "启停不得改写 createdAt");

        assert!(
            !repo.set_enabled("missing", true, 600).unwrap(),
            "不存在 id 为 no-op"
        );
        assert!(!repo.delete("missing").unwrap());
    }

    /// P3-1：损坏行（列类型漂移）不得导致整查 panic；坏行跳过、好行保留，
    /// 且走 `collect_rows_logged` 的日志路径（stderr 可见，测试不便捕获时
    /// 以「不 panic + 只返回好行」验证可达性）。
    #[test]
    fn test_damaged_row_is_skipped_without_panic() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let repo = BookMarkingRepository::new(conn);

        repo.upsert(&make_marking(
            "good",
            "https://a/1",
            "坏行书",
            "作者",
            Some(1),
            100,
        ))
        .unwrap();
        // `enabled` 声明为 INTEGER，但 SQLite 动态类型允许写入非数字文本；
        // 读回 `row.get::<i64>` 将失败，触发 collect_rows_logged 的坏行分支。
        conn.execute(
            "INSERT INTO book_marks (id, bookUrl, bookName, bookAuthor, anchorJson, enabled)
             VALUES ('bad', 'https://a/1', '坏行书', '作者', '{}', 'not-a-number')",
            [],
        )
        .unwrap();

        let by_book = repo.list_by_book("坏行书", "作者").unwrap();
        assert_eq!(by_book.len(), 1, "坏行应跳过，不得整查失败");
        assert_eq!(by_book[0].id, "good");

        let by_chapter = repo.list_for_chapter("https://a/1", None).unwrap();
        assert_eq!(by_chapter.len(), 1, "章节查询同样跳过坏行");
        assert_eq!(by_chapter[0].id, "good");

        // 坏行仍在库内（只跳过不回写/删除），确认不是误删数据
        let total: i64 = conn
            .query_row("SELECT COUNT(*) FROM book_marks", [], |row| row.get(0))
            .unwrap();
        assert_eq!(total, 2);
    }
}
