//! Bookmark Repository - bookmarks 表 CRUD

use rusqlite::{params, Connection};

use legado_core::models::Bookmark;
use legado_core::{LegadoError, LegadoResult};

/// 书签数据访问层
pub struct BookmarkRepository<'a> {
    conn: &'a Connection,
}

impl<'a> BookmarkRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入书签，返回新插入行的 id
    pub fn insert(&self, bm: &Bookmark) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO bookmarks (bookName, bookAuthor, chapterIndex, chapterPos,
                 chapterName, bookText, content, time)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    bm.book_name,
                    bm.book_author,
                    bm.chapter_index,
                    bm.chapter_pos,
                    bm.chapter_name,
                    bm.book_text,
                    bm.content,
                    bm.time,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入书签失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 更新书签
    pub fn update(&self, bm: &Bookmark) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE bookmarks SET bookName=?1, bookAuthor=?2, chapterIndex=?3,
                 chapterPos=?4, chapterName=?5, bookText=?6, content=?7, time=?8
                 WHERE id=?9",
                params![
                    bm.book_name,
                    bm.book_author,
                    bm.chapter_index,
                    bm.chapter_pos,
                    bm.chapter_name,
                    bm.book_text,
                    bm.content,
                    bm.time,
                    bm.id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新书签失败: {e}")))?;
        Ok(())
    }

    /// 按 id 删除书签
    pub fn delete(&self, id: i64) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM bookmarks WHERE id=?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除书签失败: {e}")))?;
        Ok(())
    }

    /// 按书名查询所有书签
    pub fn get_by_book(&self, book_name: &str) -> LegadoResult<Vec<Bookmark>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, bookName, bookAuthor, chapterIndex, chapterPos,
                        chapterName, bookText, content, time
                 FROM bookmarks WHERE bookName = ?1
                 ORDER BY time DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_name], row_to_bookmark)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按章节查询书签
    pub fn get_by_chapter(&self, book_name: &str, chapter_index: i32) -> LegadoResult<Vec<Bookmark>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, bookName, bookAuthor, chapterIndex, chapterPos,
                        chapterName, bookText, content, time
                 FROM bookmarks WHERE bookName = ?1 AND chapterIndex = ?2
                 ORDER BY chapterPos ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_name, chapter_index], row_to_bookmark)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 搜索书签（按文本内容或备注模糊查询）
    pub fn search(&self, keyword: &str) -> LegadoResult<Vec<Bookmark>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, bookName, bookAuthor, chapterIndex, chapterPos,
                        chapterName, bookText, content, time
                 FROM bookmarks
                 WHERE bookText LIKE ?1 OR content LIKE ?1 OR chapterName LIKE ?1
                 ORDER BY time DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let pattern = format!("%{}%", keyword);
        let rows = stmt
            .query_map(params![pattern], row_to_bookmark)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取所有书签
    pub fn find_all(&self) -> LegadoResult<Vec<Bookmark>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, bookName, bookAuthor, chapterIndex, chapterPos,
                        chapterName, bookText, content, time
                 FROM bookmarks ORDER BY time DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_bookmark)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取书签总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM bookmarks", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_bookmark(row: &rusqlite::Row<'_>) -> rusqlite::Result<Bookmark> {
    Ok(Bookmark {
        id: row.get(0)?,
        book_name: row.get(1)?,
        book_author: row.get(2)?,
        chapter_index: row.get(3)?,
        chapter_pos: row.get(4)?,
        chapter_name: row.get(5)?,
        book_text: row.get(6)?,
        content: row.get(7)?,
        time: row.get(8)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_bookmark(book: &str, chapter: i32, text: &str) -> Bookmark {
        Bookmark {
            book_name: book.to_string(),
            book_author: "author".to_string(),
            chapter_index: chapter,
            chapter_pos: 0,
            chapter_name: format!("Chapter {}", chapter),
            book_text: text.to_string(),
            content: String::new(),
            time: 1000,
            ..Bookmark::default()
        }
    }

    #[test]
    fn test_insert_and_find() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        let bm = make_bookmark("book1", 0, "some text");
        let id = repo.insert(&bm).unwrap();
        assert!(id > 0);

        let found = repo.get_by_book("book1").unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].book_name, "book1");
        assert_eq!(found[0].id, id);
    }

    #[test]
    fn test_get_by_chapter() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        repo.insert(&make_bookmark("book1", 0, "ch0 text")).unwrap();
        repo.insert(&make_bookmark("book1", 1, "ch1 text")).unwrap();
        repo.insert(&make_bookmark("book1", 0, "ch0 text2")).unwrap();

        let ch0 = repo.get_by_chapter("book1", 0).unwrap();
        assert_eq!(ch0.len(), 2);
        let ch1 = repo.get_by_chapter("book1", 1).unwrap();
        assert_eq!(ch1.len(), 1);
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        let id = repo.insert(&make_bookmark("book1", 0, "text")).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        repo.delete(id).unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_search() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        repo.insert(&make_bookmark("book1", 0, "hello world")).unwrap();
        repo.insert(&make_bookmark("book1", 1, "goodbye")).unwrap();

        let results = repo.search("hello").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_text, "hello world");
    }

    #[test]
    fn test_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        repo.insert(&make_bookmark("book1", 0, "t1")).unwrap();
        repo.insert(&make_bookmark("book2", 0, "t2")).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = BookmarkRepository::new(db.connection());
        let mut bm = make_bookmark("book1", 0, "original");
        let id = repo.insert(&bm).unwrap();
        bm.id = id;
        bm.book_text = "updated".to_string();
        repo.update(&bm).unwrap();

        let found = repo.get_by_book("book1").unwrap();
        assert_eq!(found[0].book_text, "updated");
    }
}
