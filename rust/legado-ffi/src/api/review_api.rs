//! 段评/章评 FFI API
//!
//! 暴露 legado-db::ReviewRepository 到 Flutter 端。
//! 支持：获取章节评论、添加评论、删除评论、点赞。

use legado_core::review::ChapterReview;
use legado_core::LegadoResult;
use legado_db::ReviewRepository;

use crate::db_state::with_database;

/// 获取指定章节的所有评论（JSON 数组）
pub fn review_get_by_chapter(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let reviews = repo.get_by_chapter(book_url, chapter_index)?;
        serde_json::to_string(&reviews)
            .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 获取指定书籍的所有评论（JSON 数组）
pub fn review_get_by_book(book_url: &str) -> LegadoResult<String> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let reviews = repo.get_by_book(book_url)?;
        serde_json::to_string(&reviews)
            .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 添加评论，返回评论 ID
pub fn review_add(
    book_url: &str,
    chapter_index: i32,
    paragraph_index: i32,
    content: &str,
    author: &str,
) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let review = ChapterReview {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index,
            paragraph_index,
            content: content.to_string(),
            author: author.to_string(),
            created_at: now,
            like_count: 0,
        };
        repo.insert(&review)
    })
}

/// 删除评论
pub fn review_delete(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let count = repo.delete(id)?;
        Ok(count > 0)
    })
}

/// 点赞评论
pub fn review_like(id: i64) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        repo.add_like(id)
    })
}

/// 删除章节所有评论
pub fn review_delete_chapter(book_url: &str, chapter_index: i32) -> LegadoResult<i32> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let count = repo.delete_by_chapter(book_url, chapter_index)?;
        Ok(count as i32)
    })
}
