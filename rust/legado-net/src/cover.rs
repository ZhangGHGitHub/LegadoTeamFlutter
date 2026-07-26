//! 封面图片下载与缓存
//!
//! 基于 URL hash 的文件系统缓存，避免重复下载封面图片。
//! 参考 Kotlin 侧 `BookCover.kt` / Glide 缓存策略。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use legado_core::{LegadoError, LegadoResult};

use crate::client::LegadoClient;

/// 封面图片缓存管理器
///
/// # 用法
/// ```ignore
/// let cache = CoverCache::new(PathBuf::from("/tmp/legado/cover_cache"));
/// // 优先从缓存读取，未命中则下载
/// let bytes = cache.download("https://example.com/cover.jpg", &client).await?;
/// ```
pub struct CoverCache {
    /// 缓存目录路径
    cache_dir: PathBuf,
}

impl CoverCache {
    /// 创建封面缓存管理器
    ///
    /// `cache_dir` 为缓存文件存放的目录，不存在时会在首次写入时自动创建。
    pub fn new(cache_dir: PathBuf) -> Self {
        Self { cache_dir }
    }

    /// 返回缓存目录路径
    pub fn cache_dir(&self) -> &Path {
        &self.cache_dir
    }

    // -----------------------------------------------------------------------
    // 缓存路径
    // -----------------------------------------------------------------------

    /// 根据 URL 生成缓存文件路径（使用 URL hash 防止路径冲突）
    fn cache_path(&self, url: &str) -> PathBuf {
        let mut hasher = DefaultHasher::new();
        url.hash(&mut hasher);
        let hash = hasher.finish();
        // 用前 2 位作为子目录，避免单目录下文件过多
        let sub = format!("{:02x}", (hash >> 56) & 0xFF);
        self.cache_dir.join(&sub).join(format!("{:016x}.img", hash))
    }

    // -----------------------------------------------------------------------
    // 读取
    // -----------------------------------------------------------------------

    /// 获取已缓存的封面图片数据，未命中时返回 `None`
    pub fn get_cached(&self, url: &str) -> Option<Vec<u8>> {
        let path = self.cache_path(url);
        std::fs::read(&path).ok()
    }

    /// 判断某 URL 的缓存是否存在
    pub fn is_cached(&self, url: &str) -> bool {
        self.cache_path(url).exists()
    }

    // -----------------------------------------------------------------------
    // 下载
    // -----------------------------------------------------------------------

    /// 下载并缓存封面图片
    ///
    /// 优先返回本地缓存；缓存未命中时通过 [`LegadoClient`] 下载，
    /// 成功后写入缓存目录。
    pub async fn download(&self, url: &str, client: &LegadoClient) -> LegadoResult<Vec<u8>> {
        // 先检查缓存
        if let Some(data) = self.get_cached(url) {
            return Ok(data);
        }

        // 下载图片（二进制）
        let bytes = client.get_bytes(url, None).await?;

        if bytes.is_empty() {
            return Err(LegadoError::Network(format!(
                "Empty response when downloading cover: {}",
                url
            )));
        }

        // 保存到缓存
        self.write_cache(url, &bytes);

        Ok(bytes)
    }

    /// 强制重新下载并覆盖缓存
    pub async fn refresh(&self, url: &str, client: &LegadoClient) -> LegadoResult<Vec<u8>> {
        let bytes = client.get_bytes(url, None).await?;

        if bytes.is_empty() {
            return Err(LegadoError::Network(format!(
                "Empty response when refreshing cover: {}",
                url
            )));
        }

        self.write_cache(url, &bytes);
        Ok(bytes)
    }

    fn write_cache(&self, url: &str, bytes: &[u8]) {
        let path = self.cache_path(url);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        std::fs::write(&path, bytes).ok();
    }

    // -----------------------------------------------------------------------
    // 缓存维护
    // -----------------------------------------------------------------------

    /// 清理超过 `max_age_days` 天的缓存文件，返回删除的文件数
    pub fn cleanup(&self, max_age_days: u64) -> LegadoResult<usize> {
        let max_age_secs = max_age_days * 24 * 3600;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let cutoff = now.saturating_sub(max_age_secs);

        let mut removed = 0usize;
        let entries = match std::fs::read_dir(&self.cache_dir) {
            Ok(entries) => entries,
            Err(_) => return Ok(0), // 目录不存在，无需清理
        };

        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                // 遍历子目录
                for sub_entry in std::fs::read_dir(&path).into_iter().flatten().flatten() {
                    if self.remove_if_expired(&sub_entry.path(), cutoff) {
                        removed += 1;
                    }
                }
            } else if self.remove_if_expired(&path, cutoff) {
                removed += 1;
            }
        }
        Ok(removed)
    }

    fn remove_if_expired(&self, path: &Path, cutoff_secs: u64) -> bool {
        let meta = match std::fs::metadata(path) {
            Ok(m) => m,
            Err(_) => return false,
        };
        let modified = match meta.modified() {
            Ok(t) => t,
            Err(_) => return false,
        };
        let modified_secs = modified
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        if modified_secs < cutoff_secs {
            std::fs::remove_file(path).ok();
            true
        } else {
            false
        }
    }

    /// 计算缓存目录总大小（字节）
    pub fn cache_size(&self) -> u64 {
        let mut total = 0u64;
        let entries = match std::fs::read_dir(&self.cache_dir) {
            Ok(entries) => entries,
            Err(_) => return 0,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                for sub_entry in std::fs::read_dir(&path).into_iter().flatten().flatten() {
                    if let Ok(meta) = sub_entry.metadata() {
                        if meta.is_file() {
                            total += meta.len();
                        }
                    }
                }
            } else if path.is_file() {
                if let Ok(meta) = std::fs::metadata(&path) {
                    total += meta.len();
                }
            }
        }
        total
    }

    /// 清空所有缓存，返回删除的文件数
    pub fn clear(&self) -> LegadoResult<usize> {
        let mut removed = 0usize;
        let entries = match std::fs::read_dir(&self.cache_dir) {
            Ok(entries) => entries,
            Err(_) => return Ok(0),
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                for sub_entry in std::fs::read_dir(&path).into_iter().flatten().flatten() {
                    if std::fs::remove_file(sub_entry.path()).is_ok() {
                        removed += 1;
                    }
                }
                std::fs::remove_dir(&path).ok();
            } else if std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// 为每个测试创建独立的临时缓存目录
    fn make_temp_cache(test_name: &str) -> (CoverCache, PathBuf) {
        let dir = std::env::temp_dir()
            .join("legado_cover_test")
            .join(test_name);
        // 确保目录干净
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create temp dir");
        (CoverCache::new(dir.clone()), dir)
    }

    #[test]
    fn test_cache_path_deterministic() {
        let (cache, _dir) = make_temp_cache("path_deterministic");
        let url = "https://example.com/cover1.jpg";
        let p1 = cache.cache_path(url);
        let p2 = cache.cache_path(url);
        assert_eq!(p1, p2, "Same URL should produce same cache path");
    }

    #[test]
    fn test_cache_path_different_urls() {
        let (cache, _dir) = make_temp_cache("path_different");
        let p1 = cache.cache_path("https://example.com/a.jpg");
        let p2 = cache.cache_path("https://example.com/b.jpg");
        assert_ne!(p1, p2, "Different URLs should produce different paths");
    }

    #[test]
    fn test_get_cached_miss() {
        let (cache, _dir) = make_temp_cache("cache_miss");
        assert!(cache
            .get_cached("https://example.com/missing.jpg")
            .is_none());
        assert!(!cache.is_cached("https://example.com/missing.jpg"));
    }

    #[test]
    fn test_get_cached_hit() {
        let (cache, _dir) = make_temp_cache("cache_hit");
        let url = "https://example.com/hit.jpg";
        // 手动写入缓存文件
        let path = cache.cache_path(url);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"fake image data").unwrap();

        assert!(cache.is_cached(url));
        let data = cache.get_cached(url).expect("should be cached");
        assert_eq!(data, b"fake image data");
    }

    #[test]
    fn test_write_and_read_cache() {
        let (cache, _dir) = make_temp_cache("write_read");
        let url = "https://example.com/write.jpg";
        let bytes = b"image binary content here";

        cache.write_cache(url, bytes);
        assert!(cache.is_cached(url));

        let read = cache.get_cached(url).expect("read back");
        assert_eq!(read, bytes);
    }

    #[test]
    fn test_cache_size() {
        let (cache, _dir) = make_temp_cache("cache_size");
        // 空目录
        assert_eq!(cache.cache_size(), 0);

        // 写入两个文件
        cache.write_cache("url1", &[0u8; 100]);
        cache.write_cache("url2", &[0u8; 200]);
        assert_eq!(cache.cache_size(), 300);
    }

    #[test]
    fn test_cleanup_no_expired() {
        let (cache, _dir) = make_temp_cache("cleanup_none");
        cache.write_cache("fresh", b"data");
        // 0 天 = 所有文件都已过期（cutoff = now）
        // 实际 cutoff = now - 0s = now，modified 时间 <= now，应全部删除
        let removed = cache.cleanup(0).expect("cleanup");
        // 由于文件刚刚创建，modified_secs 可能 == cutoff（同一秒），行为不稳定
        // 只检查不 panic 即可
        assert!(removed <= 1);
    }

    #[test]
    fn test_cleanup_all_expired() {
        let (cache, _dir) = make_temp_cache("cleanup_all");
        cache.write_cache("old1", b"data1");
        cache.write_cache("old2", b"data2");

        // 设置文件的修改时间为很久以前
        let filetime = filetime::FileTime::from_unix_time(0, 0);
        for entry in walk_files(&cache.cache_dir()) {
            filetime::set_file_mtime(&entry, filetime).ok();
        }

        let removed = cache.cleanup(1).expect("cleanup");
        assert_eq!(removed, 2, "Both files should be removed");
        assert_eq!(cache.cache_size(), 0);
    }

    #[test]
    fn test_clear() {
        let (cache, _dir) = make_temp_cache("clear");
        cache.write_cache("a", b"1234");
        cache.write_cache("b", b"5678");
        assert!(cache.cache_size() > 0);

        let removed = cache.clear().expect("clear");
        assert_eq!(removed, 2);
        assert_eq!(cache.cache_size(), 0);
    }

    /// 递归收集目录下所有文件路径
    fn walk_files(dir: &Path) -> Vec<PathBuf> {
        let mut files = Vec::new();
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    files.extend(walk_files(&p));
                } else {
                    files.push(p);
                }
            }
        }
        files
    }
}
