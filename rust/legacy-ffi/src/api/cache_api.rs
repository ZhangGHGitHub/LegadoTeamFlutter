//! 缓存管理 API
//!
//! 提供缓存大小查询、清理、章节缓存读取操作。

use legado_core::LegadoResult;
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
            .map_err(|e| legado_core::LegadoError::Database(format!("清空缓存失败：{e}")))?;
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
        crate::db_state::ensure_test_db();

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

    #[test]
    fn test_cache_counts() {
        crate::db_state::ensure_test_db();

        // 清空后计数为 0
        clear_cache().unwrap();
        assert_eq!(get_cache_book_count().unwrap(), 0);
        assert_eq!(get_cache_chapter_count().unwrap(), 0);

        // 清空过期缓存应该正常执行
        let deleted = clear_cache_before(1000).unwrap();
        assert_eq!(deleted, 0);
    }
}
