//! 音频离线缓存管理
//!
//! 移植自 Kotlin AudioCacheManager + AudioCachePolicy + AudioCacheService

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 缓存条目
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AudioCacheEntry {
    pub chapter_url: String,
    pub book_url: String,
    pub chapter_index: i32,
    pub file_path: PathBuf,
    pub file_size: u64,
    pub cached_at: i64,
    pub last_accessed: i64,
    pub is_complete: bool,
}

/// 缓存策略配置
#[derive(Debug, Clone)]
pub struct AudioCachePolicy {
    /// 最大缓存大小（默认 500MB）
    pub max_cache_size_bytes: u64,
    /// 最大缓存天数（默认 30）
    pub max_age_days: i64,
    /// 最大缓存条目数（默认 1000）
    pub max_entries: usize,
    /// 触发清理的容量比例（默认 0.9）
    pub cleanup_threshold: f64,
}

impl Default for AudioCachePolicy {
    fn default() -> Self {
        Self {
            max_cache_size_bytes: 500 * 1024 * 1024,
            max_age_days: 30,
            max_entries: 1000,
            cleanup_threshold: 0.9,
        }
    }
}

/// 缓存状态
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AudioCacheStatus {
    pub total_entries: usize,
    pub total_size_bytes: u64,
    pub book_count: usize,
    pub oldest_entry: Option<i64>,
    pub newest_entry: Option<i64>,
}

/// 下载队列项
#[derive(Debug, Clone)]
pub struct CacheDownloadItem {
    pub chapter_url: String,
    pub book_url: String,
    pub chapter_index: i32,
    pub audio_url: String,
    pub status: DownloadStatus,
}

/// 下载状态
#[derive(Debug, Clone, PartialEq)]
pub enum DownloadStatus {
    Pending,
    Downloading,
    Completed,
    Failed(String),
}

/// 音频缓存管理器
pub struct AudioCacheManager {
    cache_dir: PathBuf,
    policy: AudioCachePolicy,
    entries: Arc<Mutex<HashMap<String, AudioCacheEntry>>>,
    download_queue: Arc<Mutex<Vec<CacheDownloadItem>>>,
}

impl AudioCacheManager {
    pub fn new(cache_dir: PathBuf, policy: AudioCachePolicy) -> Self {
        if !cache_dir.exists() {
            std::fs::create_dir_all(&cache_dir).ok();
        }
        Self {
            cache_dir,
            policy,
            entries: Arc::new(Mutex::new(HashMap::new())),
            download_queue: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// 检查章节是否已缓存
    pub fn is_cached(&self, chapter_url: &str) -> bool {
        let entries = self.entries.lock().unwrap();
        entries.get(chapter_url).is_some_and(|e| e.is_complete)
    }

    /// 获取缓存文件路径
    pub fn get_cache_path(&self, chapter_url: &str) -> Option<PathBuf> {
        let entries = self.entries.lock().unwrap();
        entries.get(chapter_url).map(|e| e.file_path.clone())
    }

    /// 添加缓存条目
    pub fn add_entry(&self, entry: AudioCacheEntry) {
        let mut entries = self.entries.lock().unwrap();
        entries.insert(entry.chapter_url.clone(), entry);
    }

    /// 移除缓存条目
    pub fn remove_entry(&self, chapter_url: &str) -> Result<(), String> {
        let mut entries = self.entries.lock().unwrap();
        if let Some(entry) = entries.remove(chapter_url) {
            if entry.file_path.exists() {
                std::fs::remove_file(&entry.file_path).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }

    /// 获取缓存状态
    pub fn status(&self) -> AudioCacheStatus {
        let entries = self.entries.lock().unwrap();
        let total_entries = entries.len();
        let total_size: u64 = entries.values().map(|e| e.file_size).sum();
        let books: std::collections::HashSet<&str> =
            entries.values().map(|e| e.book_url.as_str()).collect();
        let oldest = entries.values().map(|e| e.cached_at).min();
        let newest = entries.values().map(|e| e.cached_at).max();

        AudioCacheStatus {
            total_entries,
            total_size_bytes: total_size,
            book_count: books.len(),
            oldest_entry: oldest,
            newest_entry: newest,
        }
    }

    /// 清理过期缓存
    pub fn cleanup_expired(&self) -> usize {
        let now = now_millis();
        let max_age_ms = self.policy.max_age_days * 24 * 3600 * 1000;
        let mut entries = self.entries.lock().unwrap();
        let expired: Vec<String> = entries
            .iter()
            .filter(|(_, e)| now - e.cached_at > max_age_ms)
            .map(|(k, _)| k.clone())
            .collect();

        let count = expired.len();
        for key in expired {
            if let Some(entry) = entries.remove(&key) {
                if entry.file_path.exists() {
                    std::fs::remove_file(&entry.file_path).ok();
                }
            }
        }
        count
    }

    /// LRU 清理（按最后访问时间）
    pub fn cleanup_lru(&self, target_count: usize) -> usize {
        let mut entries = self.entries.lock().unwrap();
        if entries.len() <= target_count {
            return 0;
        }

        let mut sorted: Vec<(String, i64)> = entries
            .iter()
            .map(|(k, v)| (k.clone(), v.last_accessed))
            .collect();
        sorted.sort_by_key(|(_, t)| *t);

        let to_remove = entries.len() - target_count;
        let mut removed = 0;
        for (key, _) in sorted.into_iter().take(to_remove) {
            if let Some(entry) = entries.remove(&key) {
                if entry.file_path.exists() {
                    std::fs::remove_file(&entry.file_path).ok();
                }
                removed += 1;
            }
        }
        removed
    }

    /// 添加下载任务到队列
    pub fn enqueue_download(&self, item: CacheDownloadItem) {
        self.download_queue.lock().unwrap().push(item);
    }

    /// 获取待下载数量
    pub fn pending_count(&self) -> usize {
        self.download_queue
            .lock()
            .unwrap()
            .iter()
            .filter(|i| i.status == DownloadStatus::Pending)
            .count()
    }

    /// 获取缓存目录
    pub fn cache_dir(&self) -> &PathBuf {
        &self.cache_dir
    }

    /// 获取策略配置
    pub fn policy(&self) -> &AudioCachePolicy {
        &self.policy
    }

    /// 计算文件存储路径
    pub fn cache_file_path(&self, chapter_url: &str) -> PathBuf {
        let hash = format!("{:x}", md5::compute(chapter_url.as_bytes()));
        self.cache_dir.join(format!("{}.audio", hash))
    }

    /// 按书籍获取缓存条目数
    pub fn entries_for_book(&self, book_url: &str) -> usize {
        let entries = self.entries.lock().unwrap();
        entries.values().filter(|e| e.book_url == book_url).count()
    }

    /// 清除指定书籍的所有缓存
    pub fn clear_book_cache(&self, book_url: &str) -> usize {
        let mut entries = self.entries.lock().unwrap();
        let keys: Vec<String> = entries
            .iter()
            .filter(|(_, e)| e.book_url == book_url)
            .map(|(k, _)| k.clone())
            .collect();
        let count = keys.len();
        for key in keys {
            if let Some(entry) = entries.remove(&key) {
                if entry.file_path.exists() {
                    std::fs::remove_file(&entry.file_path).ok();
                }
            }
        }
        count
    }

    /// 更新最后访问时间
    pub fn touch(&self, chapter_url: &str) {
        let mut entries = self.entries.lock().unwrap();
        if let Some(entry) = entries.get_mut(chapter_url) {
            entry.last_accessed = now_millis();
        }
    }

    /// 检查是否需要触发清理
    pub fn needs_cleanup(&self) -> bool {
        let entries = self.entries.lock().unwrap();
        let total_size: u64 = entries.values().map(|e| e.file_size).sum();
        let threshold =
            (self.policy.max_cache_size_bytes as f64 * self.policy.cleanup_threshold) as u64;
        total_size >= threshold || entries.len() >= self.policy.max_entries
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir() -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("legado_audio_cache_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok();
        dir
    }

    fn make_entry(url: &str, book: &str, index: i32, size: u64, cached_at: i64) -> AudioCacheEntry {
        AudioCacheEntry {
            chapter_url: url.to_string(),
            book_url: book.to_string(),
            chapter_index: index,
            file_path: PathBuf::from(format!("/tmp/nonexist_{}.audio", index)),
            file_size: size,
            cached_at,
            last_accessed: cached_at,
            is_complete: true,
        }
    }

    #[test]
    fn test_new_creates_directory() {
        let dir = test_dir().join("new_dir_test");
        let _mgr = AudioCacheManager::new(dir.clone(), AudioCachePolicy::default());
        assert!(dir.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_add_and_is_cached() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        assert!(!mgr.is_cached("ch1"));
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        assert!(mgr.is_cached("ch1"));
    }

    #[test]
    fn test_incomplete_entry_not_cached() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        let mut entry = make_entry("ch2", "book1", 1, 512, 1000);
        entry.is_complete = false;
        mgr.add_entry(entry);
        assert!(!mgr.is_cached("ch2"));
    }

    #[test]
    fn test_get_cache_path() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        assert!(mgr.get_cache_path("ch1").is_none());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        let path = mgr.get_cache_path("ch1");
        assert!(path.is_some());
        assert!(path.unwrap().to_str().unwrap().contains("nonexist_0"));
    }

    #[test]
    fn test_remove_entry() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        assert!(mgr.is_cached("ch1"));
        mgr.remove_entry("ch1").unwrap();
        assert!(!mgr.is_cached("ch1"));
    }

    #[test]
    fn test_status_empty() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        let status = mgr.status();
        assert_eq!(status.total_entries, 0);
        assert_eq!(status.total_size_bytes, 0);
        assert_eq!(status.book_count, 0);
        assert!(status.oldest_entry.is_none());
        assert!(status.newest_entry.is_none());
    }

    #[test]
    fn test_status_with_entries() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        mgr.add_entry(make_entry("ch2", "book1", 1, 2048, 2000));
        mgr.add_entry(make_entry("ch3", "book2", 0, 4096, 3000));
        let status = mgr.status();
        assert_eq!(status.total_entries, 3);
        assert_eq!(status.total_size_bytes, 7168);
        assert_eq!(status.book_count, 2);
        assert_eq!(status.oldest_entry, Some(1000));
        assert_eq!(status.newest_entry, Some(3000));
    }

    #[test]
    fn test_cleanup_expired() {
        let policy = AudioCachePolicy {
            max_age_days: 1,
            ..Default::default()
        };
        let mgr = AudioCacheManager::new(test_dir(), policy);
        let now = now_millis();
        let old = now - 2 * 24 * 3600 * 1000; // 2 days ago
        mgr.add_entry(make_entry("old", "book1", 0, 1024, old));
        mgr.add_entry(make_entry("new", "book1", 1, 1024, now));
        let removed = mgr.cleanup_expired();
        assert_eq!(removed, 1);
        assert!(!mgr.is_cached("old"));
        assert!(mgr.is_cached("new"));
    }

    #[test]
    fn test_cleanup_lru() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        mgr.add_entry(make_entry("ch2", "book1", 1, 1024, 2000));
        mgr.add_entry(make_entry("ch3", "book1", 2, 1024, 3000));
        let removed = mgr.cleanup_lru(2);
        assert_eq!(removed, 1);
        assert!(!mgr.is_cached("ch1")); // oldest access removed
        assert!(mgr.is_cached("ch2"));
        assert!(mgr.is_cached("ch3"));
    }

    #[test]
    fn test_cleanup_lru_no_op() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        let removed = mgr.cleanup_lru(5);
        assert_eq!(removed, 0);
        assert!(mgr.is_cached("ch1"));
    }

    #[test]
    fn test_download_queue() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        assert_eq!(mgr.pending_count(), 0);
        mgr.enqueue_download(CacheDownloadItem {
            chapter_url: "ch1".to_string(),
            book_url: "book1".to_string(),
            chapter_index: 0,
            audio_url: "http://example.com/a.mp3".to_string(),
            status: DownloadStatus::Pending,
        });
        mgr.enqueue_download(CacheDownloadItem {
            chapter_url: "ch2".to_string(),
            book_url: "book1".to_string(),
            chapter_index: 1,
            audio_url: "http://example.com/b.mp3".to_string(),
            status: DownloadStatus::Completed,
        });
        assert_eq!(mgr.pending_count(), 1);
    }

    #[test]
    fn test_cache_file_path_deterministic() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        let p1 = mgr.cache_file_path("http://example.com/ch1");
        let p2 = mgr.cache_file_path("http://example.com/ch1");
        assert_eq!(p1, p2);
        assert!(p1.to_str().unwrap().ends_with(".audio"));
    }

    #[test]
    fn test_cache_file_path_unique() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        let p1 = mgr.cache_file_path("http://example.com/ch1");
        let p2 = mgr.cache_file_path("http://example.com/ch2");
        assert_ne!(p1, p2);
    }

    #[test]
    fn test_entries_for_book() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        mgr.add_entry(make_entry("ch2", "book1", 1, 1024, 2000));
        mgr.add_entry(make_entry("ch3", "book2", 0, 1024, 3000));
        assert_eq!(mgr.entries_for_book("book1"), 2);
        assert_eq!(mgr.entries_for_book("book2"), 1);
        assert_eq!(mgr.entries_for_book("book3"), 0);
    }

    #[test]
    fn test_clear_book_cache() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        mgr.add_entry(make_entry("ch2", "book1", 1, 1024, 2000));
        mgr.add_entry(make_entry("ch3", "book2", 0, 1024, 3000));
        let removed = mgr.clear_book_cache("book1");
        assert_eq!(removed, 2);
        assert!(!mgr.is_cached("ch1"));
        assert!(!mgr.is_cached("ch2"));
        assert!(mgr.is_cached("ch3"));
    }

    #[test]
    fn test_touch_updates_access_time() {
        let mgr = AudioCacheManager::new(test_dir(), AudioCachePolicy::default());
        mgr.add_entry(make_entry("ch1", "book1", 0, 1024, 1000));
        mgr.touch("ch1");
        let entries = mgr.entries.lock().unwrap();
        let entry = entries.get("ch1").unwrap();
        assert!(entry.last_accessed > 1000);
    }

    #[test]
    fn test_needs_cleanup_by_size() {
        let policy = AudioCachePolicy {
            max_cache_size_bytes: 1000,
            cleanup_threshold: 0.9,
            ..Default::default()
        };
        let mgr = AudioCacheManager::new(test_dir(), policy);
        assert!(!mgr.needs_cleanup());
        mgr.add_entry(make_entry("ch1", "book1", 0, 950, 1000));
        assert!(mgr.needs_cleanup());
    }

    #[test]
    fn test_needs_cleanup_by_count() {
        let policy = AudioCachePolicy {
            max_entries: 2,
            ..Default::default()
        };
        let mgr = AudioCacheManager::new(test_dir(), policy);
        mgr.add_entry(make_entry("ch1", "book1", 0, 10, 1000));
        assert!(!mgr.needs_cleanup());
        mgr.add_entry(make_entry("ch2", "book1", 1, 10, 2000));
        assert!(mgr.needs_cleanup());
    }

    #[test]
    fn test_default_policy_values() {
        let policy = AudioCachePolicy::default();
        assert_eq!(policy.max_cache_size_bytes, 500 * 1024 * 1024);
        assert_eq!(policy.max_age_days, 30);
        assert_eq!(policy.max_entries, 1000);
        assert!((policy.cleanup_threshold - 0.9).abs() < f64::EPSILON);
    }

    #[test]
    fn test_cache_dir_accessor() {
        let dir = test_dir().join("accessor_test");
        let mgr = AudioCacheManager::new(dir.clone(), AudioCachePolicy::default());
        assert_eq!(mgr.cache_dir(), &dir);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_download_status_equality() {
        assert_eq!(DownloadStatus::Pending, DownloadStatus::Pending);
        assert_eq!(DownloadStatus::Completed, DownloadStatus::Completed);
        assert_ne!(DownloadStatus::Pending, DownloadStatus::Downloading);
        assert_eq!(
            DownloadStatus::Failed("err".to_string()),
            DownloadStatus::Failed("err".to_string())
        );
        assert_ne!(
            DownloadStatus::Failed("a".to_string()),
            DownloadStatus::Failed("b".to_string())
        );
    }
}
