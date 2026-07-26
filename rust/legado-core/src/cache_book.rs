//! 离线缓存管理

use serde::{Deserialize, Serialize};

/// 已缓存的章节
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedChapter {
    pub id: i64,
    pub book_url: String,
    pub chapter_index: i32,
    pub chapter_title: String,
    pub chapter_url: String,
    pub content: String,
    pub cached_at: i64, // Unix 时间戳（毫秒）
    pub size_bytes: i64,
}

/// 缓存统计信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheStats {
    pub total_chapters: i32,
    pub total_size_bytes: i64,
    pub books_cached: i32,
}

/// 缓存管理器
pub struct CacheBookManager;

impl CacheBookManager {
    /// 检查章节是否已缓存
    pub fn is_cached(chapters: &[CachedChapter], chapter_url: &str) -> bool {
        chapters.iter().any(|c| c.chapter_url == chapter_url)
    }

    /// 获取缓存统计
    pub fn stats(chapters: &[CachedChapter]) -> CacheStats {
        let total_chapters = chapters.len() as i32;
        let total_size_bytes: i64 = chapters.iter().map(|c| c.size_bytes).sum();

        // 统计不重复的书籍数量
        let mut book_urls: Vec<&str> = chapters.iter().map(|c| c.book_url.as_str()).collect();
        book_urls.sort();
        book_urls.dedup();
        let books_cached = book_urls.len() as i32;

        CacheStats {
            total_chapters,
            total_size_bytes,
            books_cached,
        }
    }

    /// 清理过期缓存：返回超过 max_age_days 天的缓存章节 ID 列表
    ///
    /// `now_ms` 为当前时间戳（毫秒），`max_age_days` 为最大保留天数。
    pub fn should_cleanup(chapters: &[CachedChapter], max_age_days: i64, now_ms: i64) -> Vec<i64> {
        let max_age_ms = max_age_days * 24 * 60 * 60 * 1000;
        let cutoff = now_ms - max_age_ms;
        chapters
            .iter()
            .filter(|c| c.cached_at < cutoff)
            .map(|c| c.id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_cached(id: i64, book_url: &str, chapter_url: &str, cached_at: i64) -> CachedChapter {
        CachedChapter {
            id,
            book_url: book_url.to_string(),
            chapter_index: 0,
            chapter_title: format!("Chapter {id}"),
            chapter_url: chapter_url.to_string(),
            content: "some content".to_string(),
            cached_at,
            size_bytes: 1024,
        }
    }

    #[test]
    fn test_is_cached_true() {
        let chapters = vec![
            make_cached(1, "book1", "http://example.com/ch1", 1000),
            make_cached(2, "book1", "http://example.com/ch2", 2000),
        ];
        assert!(CacheBookManager::is_cached(&chapters, "http://example.com/ch1"));
        assert!(CacheBookManager::is_cached(&chapters, "http://example.com/ch2"));
    }

    #[test]
    fn test_is_cached_false() {
        let chapters = vec![make_cached(1, "book1", "http://example.com/ch1", 1000)];
        assert!(!CacheBookManager::is_cached(&chapters, "http://example.com/ch99"));
    }

    #[test]
    fn test_is_cached_empty() {
        assert!(!CacheBookManager::is_cached(&[], "http://example.com/ch1"));
    }

    #[test]
    fn test_stats_basic() {
        let chapters = vec![
            make_cached(1, "book1", "http://example.com/ch1", 1000),
            make_cached(2, "book1", "http://example.com/ch2", 2000),
            make_cached(3, "book2", "http://example.com/ch3", 3000),
        ];
        let stats = CacheBookManager::stats(&chapters);
        assert_eq!(stats.total_chapters, 3);
        assert_eq!(stats.total_size_bytes, 3072); // 3 * 1024
        assert_eq!(stats.books_cached, 2);
    }

    #[test]
    fn test_stats_empty() {
        let stats = CacheBookManager::stats(&[]);
        assert_eq!(stats.total_chapters, 0);
        assert_eq!(stats.total_size_bytes, 0);
        assert_eq!(stats.books_cached, 0);
    }

    #[test]
    fn test_should_cleanup_returns_expired() {
        let now = 10_000_000_000; // 当前时间
        let day_ms = 24 * 60 * 60 * 1000;
        let chapters = vec![
            make_cached(1, "book1", "ch1", now - 2 * day_ms), // 2天前
            make_cached(2, "book1", "ch2", now - 10 * day_ms), // 10天前
            make_cached(3, "book2", "ch3", now - 1 * day_ms), // 1天前
        ];
        // 清理超过 5 天的
        let expired = CacheBookManager::should_cleanup(&chapters, 5, now);
        assert_eq!(expired, vec![2]); // 只有 id=2 超过 5 天
    }

    #[test]
    fn test_should_cleanup_none_expired() {
        let now = 10_000_000_000;
        let chapters = vec![
            make_cached(1, "book1", "ch1", now - 1000),
            make_cached(2, "book1", "ch2", now - 2000),
        ];
        let expired = CacheBookManager::should_cleanup(&chapters, 30, now);
        assert!(expired.is_empty());
    }
}
