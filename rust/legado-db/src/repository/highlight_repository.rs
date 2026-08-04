//! BookHighlight Repository — highlights 表数据访问层
//!
//! 对齐 Android 原版 `BookHighlightDao` 方法清单：
//! all / getByBook / flowSearch / insert / pinLayoutTitleLength /
//! bindChapterUrl / updateBookMetadata / update / delete，
//! 并扩展 getByChapter / searchByKeyword / deleteByBook 供 FFI 层使用。

use rusqlite::{params, Connection};

use legado_core::models::BookHighlight;
use legado_core::{LegadoError, LegadoResult};

/// 高亮记录查询列（与 row_to_highlight 的索引一一对应）
const SELECT_COLUMNS: &str = "SELECT time, bookUrl, chapterUrl, bookName, bookAuthor,
    chapterIndex, chapterPos, chapterPosEnd, layoutTitleLength,
    chapterName, bookText, style, note FROM highlights";

/// 高亮记录数据访问层
pub struct HighlightRepository<'a> {
    conn: &'a Connection,
}

impl<'a> HighlightRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入高亮记录（INSERT OR REPLACE，对齐 DAO `@Insert(onConflict = REPLACE)`）
    pub fn insert(&self, highlight: &BookHighlight) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO highlights
                 (time, bookUrl, chapterUrl, bookName, bookAuthor, chapterIndex,
                  chapterPos, chapterPosEnd, layoutTitleLength, chapterName,
                  bookText, style, note)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    highlight.time,
                    highlight.bookUrl,
                    highlight.chapterUrl,
                    highlight.bookName,
                    highlight.bookAuthor,
                    highlight.chapterIndex,
                    highlight.chapterPos,
                    highlight.chapterPosEnd,
                    highlight.layoutTitleLength,
                    highlight.chapterName,
                    highlight.bookText,
                    highlight.style,
                    highlight.note,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入高亮记录失败: {e}")))?;
        Ok(())
    }

    /// 更新高亮记录（按主键 time 更新，对齐 DAO `@Update`）
    pub fn update(&self, highlight: &BookHighlight) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE highlights SET bookUrl=?1, chapterUrl=?2, bookName=?3, bookAuthor=?4,
                 chapterIndex=?5, chapterPos=?6, chapterPosEnd=?7, layoutTitleLength=?8,
                 chapterName=?9, bookText=?10, style=?11, note=?12
                 WHERE time=?13",
                params![
                    highlight.bookUrl,
                    highlight.chapterUrl,
                    highlight.bookName,
                    highlight.bookAuthor,
                    highlight.chapterIndex,
                    highlight.chapterPos,
                    highlight.chapterPosEnd,
                    highlight.layoutTitleLength,
                    highlight.chapterName,
                    highlight.bookText,
                    highlight.style,
                    highlight.note,
                    highlight.time,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新高亮记录失败: {e}")))?;
        Ok(())
    }

    /// 按主键 time 删除高亮记录（对齐 DAO `@Delete`）
    pub fn delete(&self, time: i64) -> LegadoResult<bool> {
        let rows = self
            .conn
            .execute("DELETE FROM highlights WHERE time=?1", params![time])
            .map_err(|e| LegadoError::Database(format!("删除高亮记录失败: {e}")))?;
        Ok(rows > 0)
    }

    /// 按书籍删除全部高亮记录
    pub fn delete_by_book(&self, book_url: &str) -> LegadoResult<i64> {
        let rows = self
            .conn
            .execute(
                "DELETE FROM highlights WHERE bookUrl=?1",
                params![book_url],
            )
            .map_err(|e| LegadoError::Database(format!("按书籍删除高亮记录失败: {e}")))?;
        Ok(rows as i64)
    }

    /// 获取所有高亮记录（对齐 DAO `all`：按书名/作者/章节/位置排序）
    pub fn find_all(&self) -> LegadoResult<Vec<BookHighlight>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS}
                 ORDER BY bookName COLLATE NOCASE, bookAuthor COLLATE NOCASE,
                          chapterIndex, chapterPos, time"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map([], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按书籍获取高亮记录（对齐 DAO `getByBook`）
    pub fn get_by_book(&self, book_url: &str) -> LegadoResult<Vec<BookHighlight>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE bookUrl = ?1
                 ORDER BY chapterIndex, chapterPos, time"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![book_url], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按书籍 + 章节索引获取高亮记录
    pub fn get_by_chapter(
        &self,
        book_url: &str,
        chapter_index: i32,
    ) -> LegadoResult<Vec<BookHighlight>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE bookUrl = ?1 AND chapterIndex = ?2
                 ORDER BY chapterPos, time"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![book_url, chapter_index], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 书内关键词搜索（对齐 DAO `flowSearch`：匹配 chapterName/bookText/note）
    pub fn search_in_book(&self, book_url: &str, key: &str) -> LegadoResult<Vec<BookHighlight>> {
        let pattern = format!("%{key}%");
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS}
                 WHERE bookUrl = ?1 AND (
                     chapterName LIKE ?2 OR bookText LIKE ?2 OR note LIKE ?2
                 )
                 ORDER BY chapterIndex, chapterPos, time"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![book_url, pattern], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 全局关键词搜索（跨书籍，匹配 chapterName/bookText/note）
    pub fn search(&self, key: &str) -> LegadoResult<Vec<BookHighlight>> {
        let pattern = format!("%{key}%");
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS}
                 WHERE chapterName LIKE ?1 OR bookText LIKE ?1 OR note LIKE ?1
                 ORDER BY bookName COLLATE NOCASE, bookAuthor COLLATE NOCASE,
                          chapterIndex, chapterPos, time"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![pattern], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按主键 time 查询单条高亮记录
    pub fn find_by_time(&self, time: i64) -> LegadoResult<Option<BookHighlight>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} WHERE time = ?1"))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let mut rows = stmt
            .query_map(params![time], row_to_highlight)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        match rows.next() {
            Some(Ok(h)) => Ok(Some(h)),
            Some(Err(e)) => Err(LegadoError::Database(format!("查询失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 固定标题长度（对齐 DAO `pinLayoutTitleLength`：仅更新 layoutTitleLength < 0 的记录）
    pub fn pin_layout_title_length(
        &self,
        book_url: &str,
        chapter_url: &str,
        layout_title_length: i32,
    ) -> LegadoResult<i64> {
        let rows = self
            .conn
            .execute(
                "UPDATE highlights SET layoutTitleLength = ?1
                 WHERE bookUrl = ?2 AND chapterUrl = ?3 AND layoutTitleLength < 0",
                params![layout_title_length, book_url, chapter_url],
            )
            .map_err(|e| LegadoError::Database(format!("固定标题长度失败: {e}")))?;
        Ok(rows as i64)
    }

    /// 绑定章节 URL（对齐 DAO `bindChapterUrl`：仅更新 chapterUrl 为空的记录）
    pub fn bind_chapter_url(&self, times: &[i64], chapter_url: &str) -> LegadoResult<i64> {
        if times.is_empty() {
            return Ok(0);
        }
        let placeholders: Vec<String> = times.iter().enumerate().map(|(i, _)| format!("?{}", i + 2)).collect();
        let sql = format!(
            "UPDATE highlights SET chapterUrl = ?1
             WHERE time IN ({}) AND chapterUrl = ''",
            placeholders.join(", ")
        );
        let mut stmt = self
            .conn
            .prepare(&sql)
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::with_capacity(times.len() + 1);
        params.push(Box::new(chapter_url.to_string()));
        for t in times {
            params.push(Box::new(*t));
        }
        let refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let rows = stmt
            .execute(refs.as_slice())
            .map_err(|e| LegadoError::Database(format!("绑定章节 URL 失败: {e}")))?;
        Ok(rows as i64)
    }

    /// 更新书籍元数据（对齐 DAO `updateBookMetadata`）
    pub fn update_book_metadata(
        &self,
        book_url: &str,
        book_name: &str,
        book_author: &str,
    ) -> LegadoResult<i64> {
        let rows = self
            .conn
            .execute(
                "UPDATE highlights SET bookName = ?1, bookAuthor = ?2 WHERE bookUrl = ?3",
                params![book_name, book_author, book_url],
            )
            .map_err(|e| LegadoError::Database(format!("更新书籍元数据失败: {e}")))?;
        Ok(rows as i64)
    }

    /// 获取高亮记录总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM highlights", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

/// 行数据映射为 BookHighlight（列顺序与 SELECT_COLUMNS 一致）
fn row_to_highlight(row: &rusqlite::Row<'_>) -> rusqlite::Result<BookHighlight> {
    Ok(BookHighlight {
        time: row.get(0)?,
        bookUrl: row.get(1)?,
        chapterUrl: row.get(2)?,
        bookName: row.get(3)?,
        bookAuthor: row.get(4)?,
        chapterIndex: row.get(5)?,
        chapterPos: row.get(6)?,
        chapterPosEnd: row.get(7)?,
        layoutTitleLength: row.get(8)?,
        chapterName: row.get(9)?,
        bookText: row.get(10)?,
        style: row.get(11)?,
        note: row.get(12)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_highlight(time: i64, book_url: &str, chapter_index: i32, text: &str) -> BookHighlight {
        BookHighlight {
            time,
            bookUrl: book_url.to_string(),
            chapterUrl: format!("ch://{chapter_index}"),
            bookName: "书名A".to_string(),
            bookAuthor: "作者A".to_string(),
            chapterIndex: chapter_index,
            chapterPos: 10,
            chapterPosEnd: 20,
            layoutTitleLength: -1,
            chapterName: format!("第{}章", chapter_index + 1),
            bookText: text.to_string(),
            style: "{}".to_string(),
            note: String::new(),
        }
    }

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "文本一")).unwrap();
        repo.insert(&make_highlight(2, "bk://1", 1, "文本二")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_insert_replace_on_conflict() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "原文本")).unwrap();
        // 相同主键 time 重复插入应替换
        repo.insert(&make_highlight(1, "bk://1", 0, "新文本")).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        let found = repo.find_by_time(1).unwrap().unwrap();
        assert_eq!(found.bookText, "新文本");
    }

    #[test]
    fn test_get_by_book_and_chapter() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "a")).unwrap();
        repo.insert(&make_highlight(2, "bk://1", 1, "b")).unwrap();
        repo.insert(&make_highlight(3, "bk://2", 0, "c")).unwrap();

        let by_book = repo.get_by_book("bk://1").unwrap();
        assert_eq!(by_book.len(), 2);

        let by_chapter = repo.get_by_chapter("bk://1", 1).unwrap();
        assert_eq!(by_chapter.len(), 1);
        assert_eq!(by_chapter[0].time, 2);
    }

    #[test]
    fn test_search_in_book_and_global() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "重要内容")).unwrap();
        repo.insert(&make_highlight(2, "bk://2", 0, "普通内容")).unwrap();

        // 全局搜索
        let results = repo.search("重要").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].time, 1);

        // 书内搜索（无匹配）
        let results = repo.search_in_book("bk://2", "重要").unwrap();
        assert_eq!(results.len(), 0);
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        let mut h = make_highlight(1, "bk://1", 0, "原始");
        repo.insert(&h).unwrap();
        h.note = "补充笔记".to_string();
        repo.update(&h).unwrap();
        let found = repo.find_by_time(1).unwrap().unwrap();
        assert_eq!(found.note, "补充笔记");
    }

    #[test]
    fn test_delete_and_delete_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "a")).unwrap();
        repo.insert(&make_highlight(2, "bk://1", 1, "b")).unwrap();
        repo.insert(&make_highlight(3, "bk://2", 0, "c")).unwrap();

        assert!(repo.delete(1).unwrap());
        assert!(!repo.delete(999).unwrap());
        assert_eq!(repo.count().unwrap(), 2);

        let deleted = repo.delete_by_book("bk://1").unwrap();
        assert_eq!(deleted, 1);
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_pin_layout_title_length() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "a")).unwrap();
        let updated = repo.pin_layout_title_length("bk://1", "ch://0", 5).unwrap();
        assert_eq!(updated, 1);
        // 已固定后不再更新
        let updated = repo.pin_layout_title_length("bk://1", "ch://0", 8).unwrap();
        assert_eq!(updated, 0);
        let found = repo.find_by_time(1).unwrap().unwrap();
        assert_eq!(found.layoutTitleLength, 5);
    }

    #[test]
    fn test_bind_chapter_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        let mut h = make_highlight(1, "bk://1", 0, "a");
        h.chapterUrl = String::new();
        repo.insert(&h).unwrap();
        let updated = repo.bind_chapter_url(&[1], "ch://new").unwrap();
        assert_eq!(updated, 1);
        let found = repo.find_by_time(1).unwrap().unwrap();
        assert_eq!(found.chapterUrl, "ch://new");
        // 空列表安全返回
        assert_eq!(repo.bind_chapter_url(&[], "ch://x").unwrap(), 0);
    }

    #[test]
    fn test_update_book_metadata() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRepository::new(db.connection());
        repo.insert(&make_highlight(1, "bk://1", 0, "a")).unwrap();
        let updated = repo.update_book_metadata("bk://1", "新书名", "新作者").unwrap();
        assert_eq!(updated, 1);
        let found = repo.find_by_time(1).unwrap().unwrap();
        assert_eq!(found.bookName, "新书名");
        assert_eq!(found.bookAuthor, "新作者");
    }
}
