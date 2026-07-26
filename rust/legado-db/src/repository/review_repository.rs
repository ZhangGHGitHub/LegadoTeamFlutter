//! ChapterReview Repository - chapter_reviews 表 CRUD

use rusqlite::{params, Connection};

use legado_core::review::ChapterReview;
use legado_core::{LegadoError, LegadoResult};

/// 段评/本章热评数据访问层
pub struct ReviewRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReviewRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条评论，返回新插入行的 rowid
    pub fn insert(&self, review: &ChapterReview) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO chapter_reviews
                 (book_url, chapter_index, paragraph_index, content, author, created_at, like_count)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    review.book_url,
                    review.chapter_index,
                    review.paragraph_index,
                    review.content,
                    review.author,
                    review.created_at,
                    review.like_count,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入评论失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 按书籍 URL 和章节索引查询评论
    pub fn get_by_chapter(
        &self,
        book_url: &str,
        chapter_index: i32,
    ) -> LegadoResult<Vec<ChapterReview>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, paragraph_index, content, author, created_at, like_count
                 FROM chapter_reviews
                 WHERE book_url = ?1 AND chapter_index = ?2
                 ORDER BY like_count DESC, created_at ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_url, chapter_index], row_to_review)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按书籍 URL 查询所有评论
    pub fn get_by_book(&self, book_url: &str) -> LegadoResult<Vec<ChapterReview>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, paragraph_index, content, author, created_at, like_count
                 FROM chapter_reviews
                 WHERE book_url = ?1
                 ORDER BY chapter_index ASC, like_count DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_url], row_to_review)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 删除评论
    pub fn delete(&self, id: i64) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute("DELETE FROM chapter_reviews WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除评论失败: {e}")))?;
        Ok(count)
    }

    /// 删除某本书某章节的所有评论
    pub fn delete_by_chapter(
        &self,
        book_url: &str,
        chapter_index: i32,
    ) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute(
                "DELETE FROM chapter_reviews WHERE book_url = ?1 AND chapter_index = ?2",
                params![book_url, chapter_index],
            )
            .map_err(|e| LegadoError::Database(format!("删除章节评论失败: {e}")))?;
        Ok(count)
    }

    /// 点赞：增加 like_count
    pub fn add_like(&self, id: i64) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE chapter_reviews SET like_count = like_count + 1 WHERE id = ?1",
                params![id],
            )
            .map_err(|e| LegadoError::Database(format!("点赞失败: {e}")))?;
        Ok(())
    }
}

fn row_to_review(row: &rusqlite::Row<'_>) -> rusqlite::Result<ChapterReview> {
    Ok(ChapterReview {
        id: row.get(0)?,
        book_url: row.get(1)?,
        chapter_index: row.get(2)?,
        paragraph_index: row.get(3)?,
        content: row.get(4)?,
        author: row.get(5)?,
        created_at: row.get(6)?,
        like_count: row.get(7)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_review(
        book_url: &str,
        chapter_index: i32,
        paragraph_index: i32,
        content: &str,
        like_count: i32,
    ) -> ChapterReview {
        ChapterReview {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index,
            paragraph_index,
            content: content.to_string(),
            author: "test_user".to_string(),
            created_at: 1000,
            like_count,
        }
    }

    #[test]
    fn test_insert_and_get_by_chapter() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        let review = make_review("book1", 0, -1, "Great chapter!", 5);
        let id = repo.insert(&review).unwrap();
        assert!(id > 0);

        let results = repo.get_by_chapter("book1", 0).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].content, "Great chapter!");
        assert_eq!(results[0].paragraph_index, -1);
    }

    #[test]
    fn test_get_by_chapter_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        let results = repo.get_by_chapter("nonexistent", 0).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_get_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        repo.insert(&make_review("book1", 0, -1, "Hot review", 10))
            .unwrap();
        repo.insert(&make_review("book1", 1, 3, "Para review", 2))
            .unwrap();
        repo.insert(&make_review("book2", 0, -1, "Other book", 5))
            .unwrap();

        let results = repo.get_by_book("book1").unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        let id = repo
            .insert(&make_review("book1", 0, -1, "To delete", 0))
            .unwrap();

        let deleted = repo.delete(id).unwrap();
        assert_eq!(deleted, 1);

        let results = repo.get_by_chapter("book1", 0).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_delete_by_chapter() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        repo.insert(&make_review("book1", 0, -1, "Review 1", 5))
            .unwrap();
        repo.insert(&make_review("book1", 0, 2, "Review 2", 3))
            .unwrap();
        repo.insert(&make_review("book1", 1, -1, "Review 3", 1))
            .unwrap();

        let deleted = repo.delete_by_chapter("book1", 0).unwrap();
        assert_eq!(deleted, 2);

        let remaining = repo.get_by_book("book1").unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].chapter_index, 1);
    }

    #[test]
    fn test_add_like() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        let id = repo
            .insert(&make_review("book1", 0, -1, "Likeable", 5))
            .unwrap();

        repo.add_like(id).unwrap();

        let results = repo.get_by_chapter("book1", 0).unwrap();
        assert_eq!(results[0].like_count, 6);
    }

    #[test]
    fn test_order_by_likes() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReviewRepository::new(db.connection());

        repo.insert(&make_review("book1", 0, -1, "Low likes", 1))
            .unwrap();
        repo.insert(&make_review("book1", 0, -1, "High likes", 100))
            .unwrap();
        repo.insert(&make_review("book1", 0, -1, "Mid likes", 50))
            .unwrap();

        let results = repo.get_by_chapter("book1", 0).unwrap();
        assert_eq!(results[0].like_count, 100);
        assert_eq!(results[1].like_count, 50);
        assert_eq!(results[2].like_count, 1);
    }
}
