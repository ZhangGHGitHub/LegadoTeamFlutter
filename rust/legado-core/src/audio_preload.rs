//! AudioPlay 预加载优化
//!
//! 升级 AudioPlayUrlPreloadStore 为有界 LRU，
//! 支持流式播放和磁盘缓存。

use std::collections::HashMap;
use std::path::PathBuf;

/// 预加载条目
#[derive(Debug, Clone)]
pub struct PreloadEntry {
    pub chapter_index: i32,
    pub audio_url: String,
    pub generation: u64, // 代数（用于失效判断）
}

/// 有界 LRU 预加载存储（2-3 条）
pub struct AudioPreloadStore {
    entries: Vec<PreloadEntry>,
    max_size: usize,
    generation: u64,
}

impl AudioPreloadStore {
    pub fn new(max_size: usize) -> Self {
        Self {
            entries: Vec::new(),
            max_size,
            generation: 0,
        }
    }

    /// 存入预加载结果
    pub fn put(&mut self, chapter_index: i32, audio_url: String) {
        self.generation += 1;
        // 移除已存在的同章节条目
        self.entries.retain(|e| e.chapter_index != chapter_index);
        // LRU 淘汰
        while self.entries.len() >= self.max_size {
            self.entries.remove(0); // 移除最老的
        }
        self.entries.push(PreloadEntry {
            chapter_index,
            audio_url,
            generation: self.generation,
        });
    }

    /// 获取预加载结果
    pub fn get(&self, chapter_index: i32) -> Option<&PreloadEntry> {
        self.entries.iter().find(|e| e.chapter_index == chapter_index)
    }

    /// 清空
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// 当前条目数
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 当前代数
    pub fn generation(&self) -> u64 {
        self.generation
    }
}

/// 磁盘缓存管理器
pub struct AudioDiskCache {
    cache_dir: PathBuf,
    max_size_bytes: u64,
    /// 缓存索引：url_key → file_path
    index: HashMap<String, PathBuf>,
}

impl AudioDiskCache {
    pub fn new(cache_dir: PathBuf, max_size_bytes: u64) -> Self {
        Self {
            cache_dir,
            max_size_bytes,
            index: HashMap::new(),
        }
    }

    /// 检查缓存是否存在
    pub fn has(&self, url: &str) -> bool {
        let key = Self::url_to_key(url);
        self.index.contains_key(&key)
    }

    /// 获取缓存文件路径
    pub fn get_path(&self, url: &str) -> Option<&PathBuf> {
        let key = Self::url_to_key(url);
        self.index.get(&key)
    }

    /// 存入缓存
    pub fn put(&mut self, url: &str, data: &[u8]) -> Result<PathBuf, String> {
        let key = Self::url_to_key(url);
        if !self.cache_dir.exists() {
            std::fs::create_dir_all(&self.cache_dir).map_err(|e| e.to_string())?;
        }
        let path = self.cache_dir.join(&key);
        std::fs::write(&path, data).map_err(|e| e.to_string())?;
        self.index.insert(key, path.clone());
        Ok(path)
    }

    /// 清理过期缓存
    pub fn cleanup(&mut self) -> Result<usize, String> {
        // 简单策略：当缓存超过 max_size 时，删除最早的文件
        let mut removed = 0;
        if let Ok(entries) = std::fs::read_dir(&self.cache_dir) {
            let mut files: Vec<_> = entries
                .flatten()
                .filter(|e| e.path().is_file())
                .collect();
            files.sort_by_key(|e| e.metadata().and_then(|m| m.modified()).ok());

            let mut total_size: u64 = files
                .iter()
                .filter_map(|e| e.metadata().ok())
                .map(|m| m.len())
                .sum();

            while total_size > self.max_size_bytes {
                if let Some(oldest) = files.first() {
                    let size = oldest.metadata().map(|m| m.len()).unwrap_or(0);
                    let path = oldest.path();
                    let key = path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("")
                        .to_string();
                    if std::fs::remove_file(&path).is_ok() {
                        self.index.remove(&key);
                        total_size -= size;
                        removed += 1;
                    }
                }
                files.remove(0);
                if files.is_empty() {
                    break;
                }
            }
        }
        Ok(removed)
    }

    /// 缓存目录
    pub fn cache_dir(&self) -> &PathBuf {
        &self.cache_dir
    }

    /// 索引条目数
    pub fn index_len(&self) -> usize {
        self.index.len()
    }

    fn url_to_key(url: &str) -> String {
        // 使用 URL hash 作为文件名
        format!("{:x}", md5::compute(url.as_bytes()))
    }
}

/// 音频章节信息（预加载用）
#[derive(Debug, Clone)]
pub struct AudioChapterInfo {
    pub index: i32,
    pub title: String,
    pub audio_url: Option<String>,
    pub duration_ms: Option<i64>,
}

/// 播放列表管理器
pub struct PlaylistManager {
    chapters: Vec<AudioChapterInfo>,
    current_index: usize,
}

impl PlaylistManager {
    pub fn new(chapters: Vec<AudioChapterInfo>) -> Self {
        Self {
            chapters,
            current_index: 0,
        }
    }

    pub fn current(&self) -> Option<&AudioChapterInfo> {
        self.chapters.get(self.current_index)
    }

    pub fn next(&mut self) -> Option<&AudioChapterInfo> {
        if self.current_index + 1 < self.chapters.len() {
            self.current_index += 1;
            self.current()
        } else {
            None
        }
    }

    pub fn prev(&mut self) -> Option<&AudioChapterInfo> {
        if self.current_index > 0 {
            self.current_index -= 1;
            self.current()
        } else {
            None
        }
    }

    pub fn jump_to(&mut self, index: usize) -> Option<&AudioChapterInfo> {
        if index < self.chapters.len() {
            self.current_index = index;
            self.current()
        } else {
            None
        }
    }

    pub fn current_index(&self) -> usize {
        self.current_index
    }

    pub fn total(&self) -> usize {
        self.chapters.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── AudioPreloadStore tests ───

    #[test]
    fn test_store_new_is_empty() {
        let store = AudioPreloadStore::new(3);
        assert!(store.is_empty());
        assert_eq!(store.len(), 0);
        assert_eq!(store.generation(), 0);
    }

    #[test]
    fn test_store_put_and_get() {
        let mut store = AudioPreloadStore::new(3);
        store.put(1, "http://audio/1.mp3".to_string());
        let entry = store.get(1).unwrap();
        assert_eq!(entry.chapter_index, 1);
        assert_eq!(entry.audio_url, "http://audio/1.mp3");
        assert_eq!(entry.generation, 1);
    }

    #[test]
    fn test_store_get_missing_returns_none() {
        let store = AudioPreloadStore::new(3);
        assert!(store.get(99).is_none());
    }

    #[test]
    fn test_store_lru_eviction() {
        let mut store = AudioPreloadStore::new(2);
        store.put(0, "url0".to_string());
        store.put(1, "url1".to_string());
        store.put(2, "url2".to_string()); // should evict chapter 0
        assert!(store.get(0).is_none());
        assert!(store.get(1).is_some());
        assert!(store.get(2).is_some());
        assert_eq!(store.len(), 2);
    }

    #[test]
    fn test_store_put_same_chapter_replaces() {
        let mut store = AudioPreloadStore::new(3);
        store.put(1, "old_url".to_string());
        store.put(1, "new_url".to_string());
        assert_eq!(store.len(), 1);
        assert_eq!(store.get(1).unwrap().audio_url, "new_url");
    }

    #[test]
    fn test_store_clear() {
        let mut store = AudioPreloadStore::new(3);
        store.put(0, "a".to_string());
        store.put(1, "b".to_string());
        store.clear();
        assert!(store.is_empty());
        assert!(store.get(0).is_none());
    }

    #[test]
    fn test_store_generation_increments() {
        let mut store = AudioPreloadStore::new(3);
        store.put(0, "a".to_string());
        store.put(1, "b".to_string());
        assert_eq!(store.generation(), 2);
        assert_eq!(store.get(0).unwrap().generation, 1);
        assert_eq!(store.get(1).unwrap().generation, 2);
    }

    // ─── AudioDiskCache tests ───

    #[test]
    fn test_disk_cache_url_to_key_deterministic() {
        let k1 = AudioDiskCache::url_to_key("http://example.com/a.mp3");
        let k2 = AudioDiskCache::url_to_key("http://example.com/a.mp3");
        assert_eq!(k1, k2);
        let k3 = AudioDiskCache::url_to_key("http://example.com/b.mp3");
        assert_ne!(k1, k3);
    }

    #[test]
    fn test_disk_cache_put_and_has() {
        let dir = std::env::temp_dir().join("legado_test_cache_put_has");
        let _ = std::fs::remove_dir_all(&dir);
        let mut cache = AudioDiskCache::new(dir.clone(), 1024 * 1024);
        assert!(!cache.has("http://x.com/1.mp3"));
        let path = cache.put("http://x.com/1.mp3", b"audio-data").unwrap();
        assert!(path.exists());
        assert!(cache.has("http://x.com/1.mp3"));
        assert_eq!(cache.index_len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_disk_cache_get_path() {
        let dir = std::env::temp_dir().join("legado_test_cache_get_path");
        let _ = std::fs::remove_dir_all(&dir);
        let mut cache = AudioDiskCache::new(dir.clone(), 1024 * 1024);
        assert!(cache.get_path("http://x.com/2.mp3").is_none());
        cache.put("http://x.com/2.mp3", b"data").unwrap();
        let p = cache.get_path("http://x.com/2.mp3").unwrap();
        assert!(p.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_disk_cache_cleanup() {
        let dir = std::env::temp_dir().join("legado_test_cache_cleanup");
        let _ = std::fs::remove_dir_all(&dir);
        // max 10 bytes → writing 20-byte entries should trigger cleanup
        let mut cache = AudioDiskCache::new(dir.clone(), 10);
        cache.put("http://x.com/a", &[0u8; 20]).unwrap();
        cache.put("http://x.com/b", &[0u8; 20]).unwrap();
        let removed = cache.cleanup().unwrap();
        assert!(removed >= 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ─── PlaylistManager tests ───

    fn make_chapters(n: i32) -> Vec<AudioChapterInfo> {
        (0..n)
            .map(|i| AudioChapterInfo {
                index: i,
                title: format!("Ch {}", i),
                audio_url: Some(format!("http://audio/{}.mp3", i)),
                duration_ms: Some(i as i64 * 60_000),
            })
            .collect()
    }

    #[test]
    fn test_playlist_new_and_current() {
        let pm = PlaylistManager::new(make_chapters(5));
        assert_eq!(pm.total(), 5);
        assert_eq!(pm.current_index(), 0);
        assert_eq!(pm.current().unwrap().title, "Ch 0");
    }

    #[test]
    fn test_playlist_next_prev() {
        let mut pm = PlaylistManager::new(make_chapters(3));
        assert!(pm.next().is_some());
        assert_eq!(pm.current_index(), 1);
        assert!(pm.next().is_some());
        assert_eq!(pm.current_index(), 2);
        // at end
        assert!(pm.next().is_none());
        assert_eq!(pm.current_index(), 2);
        // go back
        assert!(pm.prev().is_some());
        assert_eq!(pm.current_index(), 1);
        assert!(pm.prev().is_some());
        assert_eq!(pm.current_index(), 0);
        // at beginning
        assert!(pm.prev().is_none());
    }

    #[test]
    fn test_playlist_jump_to() {
        let mut pm = PlaylistManager::new(make_chapters(10));
        assert!(pm.jump_to(7).is_some());
        assert_eq!(pm.current().unwrap().index, 7);
        // out of bounds
        assert!(pm.jump_to(10).is_none());
        assert_eq!(pm.current_index(), 7); // unchanged
    }

    #[test]
    fn test_playlist_empty() {
        let mut pm = PlaylistManager::new(vec![]);
        assert_eq!(pm.total(), 0);
        assert!(pm.current().is_none());
        assert!(pm.next().is_none());
        assert!(pm.prev().is_none());
        assert!(pm.jump_to(0).is_none());
    }
}
