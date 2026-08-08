//! 缓存管理 API
//!
//! 提供缓存大小查询、清理、章节缓存读取操作；
//! Task #136 R5 补齐写侧（[`save_chapter_content`]）。

use legado_core::cache_book::CachedChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::{CacheBookRepository, CacheRepository};

use crate::db_state::with_database;

/// 获取缓存总大小（字节）
pub fn get_cache_size() -> LegadoResult<i64> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.total_size_bytes)
    })
}

/// 清空所有章节缓存
pub fn clear_cache() -> LegadoResult<bool> {
    with_database(|db| {
        let conn = db.connection();
        // 清空 cached_chapters 表
        conn.execute("DELETE FROM cached_chapters", [])
            .map_err(|e| legado_core::LegadoError::Database(format!("清空缓存失败: {e}")))?;
        // 同时清空通用 KV 缓存
        let cache_repo = CacheRepository::new(conn);
        cache_repo.clear()?;
        Ok(true)
    })
}

/// 获取指定章节的缓存内容（无缓存返回空字符串）
pub fn get_chapter_cache(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let chapters = repo.get_by_book(book_url)?;
        let found = chapters
            .into_iter()
            .find(|c| c.chapter_index == chapter_index);
        Ok(found.map(|c| c.content).unwrap_or_default())
    })
}

/// 列出某本书已缓存章节的 chapter_url 集合（Task #22，目录页云图标缓存态）
///
/// 复用 [`CacheBookRepository::get_by_book`]（按 book_url 复合键查询，不串本），
/// 仅提取 chapter_url 供 Flutter 目录页据此为每章标记「已缓存/未缓存」渲染
/// 云图标；返回顺序按 chapter_index 升序（仓储已排序），空 chapter_url 过滤。
pub fn list_cached_chapter_urls(book_url: &str) -> LegadoResult<Vec<String>> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let chapters = repo.get_by_book(book_url)?;
        Ok(chapters
            .into_iter()
            .map(|c| c.chapter_url)
            .filter(|u| !u.trim().is_empty())
            .collect())
    })
}

/// 获取缓存书籍数量
pub fn get_cache_book_count() -> LegadoResult<i32> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.books_cached)
    })
}

/// 获取缓存章节数量
pub fn get_cache_chapter_count() -> LegadoResult<i32> {
    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        let stats = repo.get_stats()?;
        Ok(stats.total_chapters)
    })
}

/// 写入/覆盖单章缓存（Task #136 R5，API_CONTRACT §2.43.1）
///
/// 复用 [`CacheBookRepository::insert`]（INSERT OR REPLACE），供阅读器
/// 「编辑内容/反转」闭环回写章节缓存；正文按原文存储（不做净化，
/// 与正文抓取链路缓存写入一致，读取时再净化）。
///
/// `title` / `chapter_url` 为空串时从 DB 章节表回填（章节也不存在则报错）。
pub fn save_chapter_content(
    book_url: &str,
    chapter_index: i32,
    title: &str,
    content: &str,
    chapter_url: &str,
) -> LegadoResult<bool> {
    // 缺省字段回填：对齐 Kotlin cached_chapters 主键（book_url + chapter_url）
    let (chapter_title, chapter_url) = if title.is_empty() || chapter_url.is_empty() {
        let ch = with_database(|db| {
            let repo = BookChapterRepository::new(db.connection());
            repo.find_by_book_url_and_index(book_url, chapter_index)
        })?
        .ok_or_else(|| {
            LegadoError::Database(format!("章节 {chapter_index} 不存在: {book_url}"))
        })?;
        (
            if title.is_empty() {
                ch.title
            } else {
                title.to_string()
            },
            if chapter_url.is_empty() {
                ch.url
            } else {
                chapter_url.to_string()
            },
        )
    } else {
        (title.to_string(), chapter_url.to_string())
    };

    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title,
        chapter_url,
        content: content.to_string(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };

    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&chapter)?;
        Ok(true)
    })
}

/// 清除指定时间之前的缓存，返回删除的行数
pub fn clear_cache_before(before_timestamp: i64) -> LegadoResult<i64> {
    with_database(|db| {
        use rusqlite::params;
        let conn = db.connection();
        let deleted = conn
            .execute(
                "DELETE FROM cached_chapters WHERE cached_at < ?1",
                params![before_timestamp],
            )
            .map_err(|e| legado_core::LegadoError::Database(format!("清空过期缓存失败：{e}")))?;
        Ok(deleted as i64)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cache_apis() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 先清空缓存确保测试隔离
        clear_cache().unwrap();

        // 清空后缓存大小为 0
        let size = get_cache_size().unwrap();
        assert_eq!(size, 0);

        // 无缓存时返回空
        let content = get_chapter_cache("http://book.com/1", 0).unwrap();
        assert!(content.is_empty());

        // 清空缓存不报错
        assert!(clear_cache().unwrap());
    }

    /// Task #136 R5：写入→cache_get 读回一致
    #[test]
    fn test_save_chapter_content_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_cache().unwrap();

        let book_url = "http://save-chapter.example.com/book1";
        let chapter_url = "http://save-chapter.example.com/ch3";
        let content = "第三章正文：缓存写侧闭环测试。";

        // 写入（显式 title/chapter_url）
        assert!(save_chapter_content(book_url, 3, "第三章", content, chapter_url).unwrap());

        // 读回一致
        let read_back = get_chapter_cache(book_url, 3).unwrap();
        assert_eq!(read_back, content, "写入后读回应一致");

        // 覆盖写入（INSERT OR REPLACE）
        let edited = "第三章正文（用户编辑后）";
        assert!(save_chapter_content(book_url, 3, "第三章", edited, chapter_url).unwrap());
        assert_eq!(get_chapter_cache(book_url, 3).unwrap(), edited);

        // 清理测试数据
        clear_cache().unwrap();
    }
}
