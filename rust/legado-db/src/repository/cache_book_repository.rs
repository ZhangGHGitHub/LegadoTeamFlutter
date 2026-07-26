//! CacheBook Repository - cached_chapters 表 CRUD

use rusqlite::{params, Connection};

use legado_core::cache_book::{CacheStats, CachedChapter};
use legado_core::{LegadoError, LegadoResult};

/// 离线缓存数据访问层
pub struct CacheBookRepository<'a> {
    conn: &'a Connection,
}

impl<'a> CacheBookRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条缓存章节，返回新插入行的 rowid
    pub fn insert(&self, chapter: &CachedChapter) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO cached_chapters
                 (book_url, chapter_index, chapter_title, chapter_url, content, cached_at, size_bytes)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    chapter.book_url,
                    chapter.chapter_index,
                    chapter.chapter_title,
                    chapter.chapter_url,
                    chapter.content,
                    chapter.cached_at,
                    chapter.size_bytes,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入缓存章节失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 更新缓存章节内容
    pub fn update(&self, chapter: &CachedChapter) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE cached_chapters SET
                 book_url = ?1, chapter_index = ?2, chapter_title = ?3,
                 content = ?4, cached_at = ?5, size_bytes = ?6
                 WHERE chapter_url = ?7",
                params![
                    chapter.book_url,
                    chapter.chapter_index,
                    chapter.chapter_title,
                    chapter.content,
                    chapter.cached_at,
                    chapter.size_bytes,
                    chapter.chapter_url,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新缓存章节失败: {e}")))?;
        Ok(())
    }

    /// 按 chapter_url 删除缓存
    pub fn delete_by_chapter_url(&self, chapter_url: &str) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute(
                "DELETE FROM cached_chapters WHERE chapter_url = ?1",
                params![chapter_url],
            )
            .map_err(|e| LegadoError::Database(format!("删除缓存章节失败: {e}")))?;
        Ok(count)
    }

    /// 按书籍 URL 查询所有缓存章节
    pub fn get_by_book(&self, book_url: &str) -> LegadoResult<Vec<CachedChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, chapter_title, chapter_url, content, cached_at, size_bytes
                 FROM cached_chapters
                 WHERE book_url = ?1
                 ORDER BY chapter_index ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_url], row_to_cached_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 chapter_url 查询单条缓存
    pub fn get_by_chapter_url(&self, chapter_url: &str) -> LegadoResult<Option<CachedChapter>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, chapter_title, chapter_url, content, cached_at, size_bytes
                 FROM cached_chapters
                 WHERE chapter_url = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_map(params![chapter_url], row_to_cached_chapter)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .next();
        Ok(result)
    }

    /// 获取缓存统计信息
    pub fn get_stats(&self) -> LegadoResult<CacheStats> {
        let (total_chapters, total_size_bytes): (i32, i64) = self
            .conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(size_bytes), 0) FROM cached_chapters",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .map_err(|e| LegadoError::Database(format!("查询缓存统计失败: {e}")))?;

        let books_cached: i32 = self
            .conn
            .query_row(
                "SELECT COUNT(DISTINCT book_url) FROM cached_chapters",
                [],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询缓存书籍数失败: {e}")))?;

        Ok(CacheStats {
            total_chapters,
            total_size_bytes,
            books_cached,
        })
    }

    /// 删除某本书的所有缓存
    pub fn delete_by_book(&self, book_url: &str) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute(
                "DELETE FROM cached_chapters WHERE book_url = ?1",
                params![book_url],
            )
            .map_err(|e| LegadoError::Database(format!("删除书籍缓存失败: {e}")))?;
        Ok(count)
    }

    /// 删除过期缓存（cached_at < before_timestamp），返回删除行数
    pub fn delete_expired(&self, before_timestamp: i64) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute(
                "DELETE FROM cached_chapters WHERE cached_at < ?1",
                params![before_timestamp],
            )
            .map_err(|e| LegadoError::Database(format!("删除过期缓存失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_cached_chapter(row: &rusqlite::Row<'_>) -> rusqlite::Result<CachedChapter> {
    Ok(CachedChapter {
        id: row.get(0)?,
        book_url: row.get(1)?,
        chapter_index: row.get(2)?,
        chapter_title: row.get(3)?,
        chapter_url: row.get(4)?,
        content: row.get(5)?,
        cached_at: row.get(6)?,
        size_bytes: row.get(7)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cached(book_url: &str, chapter_url: &str, index: i32, cached_at: i64) -> CachedChapter {
        CachedChapter {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: index,
            chapter_title: format!("Chapter {index}"),
            chapter_url: chapter_url.to_string(),
            content: "content here".to_string(),
            cached_at,
            size_bytes: 2048,
        }
    }

    #[test]
    fn test_insert_and_get_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        let ch = make_cached("book1", "http://ex.com/ch1", 0, 1000);
        let id = repo.insert(&ch).unwrap();
        assert!(id > 0);

        let results = repo.get_by_book("book1").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].chapter_url, "http://ex.com/ch1");
        assert_eq!(results[0].content, "content here");
    }

    #[test]
    fn test_get_by_chapter_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        repo.insert(&make_cached("book1", "http://ex.com/ch1", 0, 1000))
            .unwrap();

        let found = repo.get_by_chapter_url("http://ex.com/ch1").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().book_url, "book1");

        let not_found = repo.get_by_chapter_url("http://ex.com/ch99").unwrap();
        assert!(not_found.is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        let ch = make_cached("book1", "http://ex.com/ch1", 0, 1000);
        repo.insert(&ch).unwrap();

        let mut updated = ch.clone();
        updated.content = "updated content".to_string();
        updated.size_bytes = 4096;
        repo.update(&updated).unwrap();

        let result = repo
            .get_by_chapter_url("http://ex.com/ch1")
            .unwrap()
            .unwrap();
        assert_eq!(result.content, "updated content");
        assert_eq!(result.size_bytes, 4096);
    }

    #[test]
    fn test_delete_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        repo.insert(&make_cached("book1", "http://ex.com/ch1", 0, 1000))
            .unwrap();
        repo.insert(&make_cached("book1", "http://ex.com/ch2", 1, 2000))
            .unwrap();
        repo.insert(&make_cached("book2", "http://ex.com/ch3", 0, 3000))
            .unwrap();

        let deleted = repo.delete_by_book("book1").unwrap();
        assert_eq!(deleted, 2);

        let remaining = repo.get_by_book("book2").unwrap();
        assert_eq!(remaining.len(), 1);
    }

    #[test]
    fn test_delete_expired() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        repo.insert(&make_cached("book1", "http://ex.com/ch1", 0, 1000))
            .unwrap();
        repo.insert(&make_cached("book1", "http://ex.com/ch2", 1, 5000))
            .unwrap();

        let deleted = repo.delete_expired(3000).unwrap();
        assert_eq!(deleted, 1);

        let stats = repo.get_stats().unwrap();
        assert_eq!(stats.total_chapters, 1);
    }

    #[test]
    fn test_get_stats() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        repo.insert(&make_cached("book1", "http://ex.com/ch1", 0, 1000))
            .unwrap();
        repo.insert(&make_cached("book1", "http://ex.com/ch2", 1, 2000))
            .unwrap();
        repo.insert(&make_cached("book2", "http://ex.com/ch3", 0, 3000))
            .unwrap();

        let stats = repo.get_stats().unwrap();
        assert_eq!(stats.total_chapters, 3);
        assert_eq!(stats.total_size_bytes, 6144); // 3 * 2048
        assert_eq!(stats.books_cached, 2);
    }

    #[test]
    fn test_delete_by_chapter_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CacheBookRepository::new(db.connection());

        repo.insert(&make_cached("book1", "http://ex.com/ch1", 0, 1000))
            .unwrap();

        let deleted = repo.delete_by_chapter_url("http://ex.com/ch1").unwrap();
        assert_eq!(deleted, 1);

        let result = repo.get_by_chapter_url("http://ex.com/ch1").unwrap();
        assert!(result.is_none());
    }
}
