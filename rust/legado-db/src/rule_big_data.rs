//! 规则大数据管理
//! 移植自 Kotlin RuleBigDataHelp.kt (258行)
//! 管理书源规则中的大量文本数据（如 mainJs、自定义配置等）
//!
//! 存储结构：
//!   storage_dir/
//!     book/
//!       <md5(bookUrl)>/
//!         bookUrl.txt          ← 标记文件（反查用）
//!         <md5(key)>.txt       ← 书籍变量
//!         <md5(chapterUrl)>/
//!           <md5(key)>.txt     ← 章节变量
//!     rss/
//!       <md5(origin)>/
//!         origin.txt           ← 标记文件
//!         <md5(link)>/
//!           origin.txt
//!           <md5(key)>.txt     ← RSS 变量

use std::path::{Path, PathBuf};

/// 批量查询默认批次大小（对应 Kotlin RULE_DATA_QUERY_BATCH_SIZE）
pub const RULE_DATA_QUERY_BATCH_SIZE: usize = 900;

/// 将 keys 按批次分组（对应 Kotlin ruleDataKeyBatches）
pub fn rule_data_key_batches(keys: &[String], batch_size: usize) -> Vec<Vec<String>> {
    assert!(batch_size > 0, "batch_size must be > 0");
    let mut unique: Vec<String> = keys.to_vec();
    unique.sort();
    unique.dedup();
    unique.chunks(batch_size).map(|c| c.to_vec()).collect()
}

/// 大数据存储管理器
pub struct RuleBigDataManager {
    book_data_dir: PathBuf,
    rss_data_dir: PathBuf,
}

impl RuleBigDataManager {
    /// 创建管理器，storage_dir 为 ruleData 根目录
    pub fn new(storage_dir: &Path) -> Self {
        let book_data_dir = storage_dir.join("book");
        let rss_data_dir = storage_dir.join("rss");
        std::fs::create_dir_all(&book_data_dir).ok();
        std::fs::create_dir_all(&rss_data_dir).ok();
        Self {
            book_data_dir,
            rss_data_dir,
        }
    }

    // ─── Book Variables ───────────────────────────────────────────────

    /// 存储书籍变量（对应 Kotlin putBookVariable）
    pub fn put_book_variable(
        &self,
        book_url: &str,
        key: &str,
        value: Option<&str>,
    ) -> Result<(), String> {
        let md5_book_url = Self::md5(book_url);
        let md5_key = Self::md5(key);
        let dir = self.book_data_dir.join(&md5_book_url);

        match value {
            None => {
                let file = dir.join(format!("{md5_key}.txt"));
                if file.exists() {
                    std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                }
            }
            Some(v) => {
                std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                std::fs::write(dir.join(format!("{md5_key}.txt")), v).map_err(|e| e.to_string())?;
                // 写入标记文件
                let marker = dir.join("bookUrl.txt");
                if !marker.exists() {
                    std::fs::write(&marker, book_url).map_err(|e| e.to_string())?;
                }
            }
        }
        Ok(())
    }

    /// 读取书籍变量（对应 Kotlin getBookVariable）
    pub fn get_book_variable(&self, book_url: &str, key: &str) -> Result<Option<String>, String> {
        let md5_book_url = Self::md5(book_url);
        let md5_key = Self::md5(key);
        let file = self
            .book_data_dir
            .join(&md5_book_url)
            .join(format!("{md5_key}.txt"));
        if file.exists() {
            Ok(Some(
                std::fs::read_to_string(&file).map_err(|e| e.to_string())?,
            ))
        } else {
            Ok(None)
        }
    }

    /// 检查书籍变量是否存在（对应 Kotlin hasBookVariable）
    pub fn has_book_variable(&self, book_url: &str, key: &str) -> bool {
        let md5_book_url = Self::md5(book_url);
        let md5_key = Self::md5(key);
        self.book_data_dir
            .join(&md5_book_url)
            .join(format!("{md5_key}.txt"))
            .exists()
    }

    // ─── Chapter Variables ────────────────────────────────────────────

    /// 存储章节变量（对应 Kotlin putChapterVariable）
    pub fn put_chapter_variable(
        &self,
        book_url: &str,
        chapter_url: &str,
        key: &str,
        value: Option<&str>,
    ) -> Result<(), String> {
        let md5_book_url = Self::md5(book_url);
        let md5_chapter_url = Self::md5(chapter_url);
        let md5_key = Self::md5(key);
        let dir = self
            .book_data_dir
            .join(&md5_book_url)
            .join(&md5_chapter_url);

        match value {
            None => {
                let file = dir.join(format!("{md5_key}.txt"));
                if file.exists() {
                    std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                }
            }
            Some(v) => {
                std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                std::fs::write(dir.join(format!("{md5_key}.txt")), v).map_err(|e| e.to_string())?;
                let marker = self.book_data_dir.join(&md5_book_url).join("bookUrl.txt");
                if !marker.exists() {
                    std::fs::write(&marker, book_url).map_err(|e| e.to_string())?;
                }
            }
        }
        Ok(())
    }

    /// 读取章节变量（对应 Kotlin getChapterVariable）
    pub fn get_chapter_variable(
        &self,
        book_url: &str,
        chapter_url: &str,
        key: &str,
    ) -> Result<Option<String>, String> {
        let md5_book_url = Self::md5(book_url);
        let md5_chapter_url = Self::md5(chapter_url);
        let md5_key = Self::md5(key);
        let file = self
            .book_data_dir
            .join(&md5_book_url)
            .join(&md5_chapter_url)
            .join(format!("{md5_key}.txt"));
        if file.exists() {
            Ok(Some(
                std::fs::read_to_string(&file).map_err(|e| e.to_string())?,
            ))
        } else {
            Ok(None)
        }
    }

    // ─── RSS Variables ────────────────────────────────────────────────

    /// 存储 RSS 变量（对应 Kotlin putRssVariable）
    pub fn put_rss_variable(
        &self,
        origin: &str,
        link: &str,
        key: &str,
        value: Option<&str>,
    ) -> Result<(), String> {
        let md5_origin = Self::md5(origin);
        let md5_link = Self::md5(link);
        let md5_key = Self::md5(key);
        let dir = self.rss_data_dir.join(&md5_origin).join(&md5_link);

        match value {
            None => {
                let file = dir.join(format!("{md5_key}.txt"));
                if file.exists() {
                    std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                }
            }
            Some(v) => {
                std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
                std::fs::write(dir.join(format!("{md5_key}.txt")), v).map_err(|e| e.to_string())?;
                // origin 标记
                let origin_marker = self.rss_data_dir.join(&md5_origin).join("origin.txt");
                if !origin_marker.exists() {
                    std::fs::write(&origin_marker, origin).map_err(|e| e.to_string())?;
                }
                // link 标记
                let link_marker = dir.join("origin.txt");
                if !link_marker.exists() {
                    std::fs::write(&link_marker, link).map_err(|e| e.to_string())?;
                }
            }
        }
        Ok(())
    }

    /// 读取 RSS 变量（对应 Kotlin getRssVariable）
    pub fn get_rss_variable(
        &self,
        origin: &str,
        link: &str,
        key: &str,
    ) -> Result<Option<String>, String> {
        let md5_origin = Self::md5(origin);
        let md5_link = Self::md5(link);
        let md5_key = Self::md5(key);
        let file = self
            .rss_data_dir
            .join(&md5_origin)
            .join(&md5_link)
            .join(format!("{md5_key}.txt"));
        if file.exists() {
            Ok(Some(
                std::fs::read_to_string(&file).map_err(|e| e.to_string())?,
            ))
        } else {
            Ok(None)
        }
    }

    // ─── Cleanup ──────────────────────────────────────────────────────

    /// 清理无效书籍数据（对应 Kotlin clearInvalid 中 book 部分）
    pub fn clear_invalid_book_data(&self, valid_book_urls: &[String]) -> Result<usize, String> {
        self.clear_invalid_data(&self.book_data_dir, "bookUrl.txt", valid_book_urls)
    }

    /// 清理无效 RSS 数据（对应 Kotlin clearInvalid 中 rss 部分）
    pub fn clear_invalid_rss_data(&self, valid_origins: &[String]) -> Result<usize, String> {
        self.clear_invalid_data(&self.rss_data_dir, "origin.txt", valid_origins)
    }

    fn clear_invalid_data(
        &self,
        data_dir: &Path,
        marker_file_name: &str,
        valid_keys: &[String],
    ) -> Result<usize, String> {
        let mut removed = 0;
        if let Ok(entries) = std::fs::read_dir(data_dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if !path.is_dir() {
                    // 非目录文件直接删除
                    std::fs::remove_file(&path).ok();
                    continue;
                }
                let marker = path.join(marker_file_name);
                let should_remove = if marker.exists() {
                    match std::fs::read_to_string(&marker) {
                        Ok(key) => !valid_keys.contains(&key),
                        Err(_) => true,
                    }
                } else {
                    true
                };
                if should_remove && std::fs::remove_dir_all(&path).is_ok() {
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// 获取存储统计
    pub fn stats(&self) -> BigDataStats {
        let mut total_dirs = 0;
        let mut total_files = 0;
        let mut total_size: u64 = 0;

        for base in [&self.book_data_dir, &self.rss_data_dir] {
            if let Ok(dirs) = std::fs::read_dir(base) {
                for dir_entry in dirs.flatten() {
                    if dir_entry.path().is_dir() {
                        total_dirs += 1;
                        Self::count_recursive(&dir_entry.path(), &mut total_files, &mut total_size);
                    }
                }
            }
        }

        BigDataStats {
            total_sources: total_dirs,
            total_files,
            total_size_bytes: total_size,
        }
    }

    fn count_recursive(dir: &Path, files: &mut usize, size: &mut u64) {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    Self::count_recursive(&path, files, size);
                } else {
                    *files += 1;
                    *size += entry.metadata().map(|m| m.len()).unwrap_or(0);
                }
            }
        }
    }

    fn md5(input: &str) -> String {
        format!("{:x}", md5::compute(input.as_bytes()))
    }
}

/// 大数据存储统计
#[derive(Debug, Clone)]
pub struct BigDataStats {
    pub total_sources: usize,
    pub total_files: usize,
    pub total_size_bytes: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use std::sync::atomic::{AtomicUsize, Ordering};
    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_manager() -> (RuleBigDataManager, PathBuf) {
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("legado_test_rbd_{}_{}", std::process::id(), id));
        let _ = fs::remove_dir_all(&dir);
        let mgr = RuleBigDataManager::new(&dir);
        (mgr, dir)
    }

    #[test]
    fn test_put_and_get_book_variable() {
        let (mgr, dir) = temp_manager();
        mgr.put_book_variable("http://book1.com", "js", Some("console.log(1)"))
            .unwrap();
        let val = mgr.get_book_variable("http://book1.com", "js").unwrap();
        assert_eq!(val, Some("console.log(1)".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_get_nonexistent_book_variable() {
        let (mgr, dir) = temp_manager();
        let val = mgr.get_book_variable("http://none.com", "key").unwrap();
        assert_eq!(val, None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_delete_book_variable() {
        let (mgr, dir) = temp_manager();
        mgr.put_book_variable("http://b.com", "k", Some("v"))
            .unwrap();
        assert!(mgr.has_book_variable("http://b.com", "k"));
        mgr.put_book_variable("http://b.com", "k", None).unwrap();
        assert!(!mgr.has_book_variable("http://b.com", "k"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_chapter_variable() {
        let (mgr, dir) = temp_manager();
        mgr.put_chapter_variable("http://b.com", "http://c1", "content", Some("chapter text"))
            .unwrap();
        let val = mgr
            .get_chapter_variable("http://b.com", "http://c1", "content")
            .unwrap();
        assert_eq!(val, Some("chapter text".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_rss_variable() {
        let (mgr, dir) = temp_manager();
        mgr.put_rss_variable("http://rss.com", "http://link1", "title", Some("News"))
            .unwrap();
        let val = mgr
            .get_rss_variable("http://rss.com", "http://link1", "title")
            .unwrap();
        assert_eq!(val, Some("News".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_clear_invalid_book_data() {
        let (mgr, dir) = temp_manager();
        mgr.put_book_variable("http://valid.com", "k", Some("v"))
            .unwrap();
        mgr.put_book_variable("http://invalid.com", "k", Some("v"))
            .unwrap();
        let valid = vec!["http://valid.com".to_string()];
        let removed = mgr.clear_invalid_book_data(&valid).unwrap();
        assert_eq!(removed, 1);
        // valid still exists
        assert!(mgr.has_book_variable("http://valid.com", "k"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_stats() {
        let (mgr, dir) = temp_manager();
        mgr.put_book_variable("http://s1.com", "a", Some("data1"))
            .unwrap();
        mgr.put_book_variable("http://s2.com", "b", Some("data2"))
            .unwrap();
        let stats = mgr.stats();
        assert_eq!(stats.total_sources, 2);
        assert!(stats.total_files >= 2);
        assert!(stats.total_size_bytes > 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_rule_data_key_batches() {
        let keys: Vec<String> = (0..10).map(|i| format!("key{i}")).collect();
        let batches = rule_data_key_batches(&keys, 3);
        assert_eq!(batches.len(), 4); // 3+3+3+1
        assert_eq!(batches[0].len(), 3);
        assert_eq!(batches[3].len(), 1);
    }

    #[test]
    fn test_overwrite_book_variable() {
        let (mgr, dir) = temp_manager();
        mgr.put_book_variable("http://ow.com", "k", Some("v1"))
            .unwrap();
        mgr.put_book_variable("http://ow.com", "k", Some("v2"))
            .unwrap();
        let val = mgr.get_book_variable("http://ow.com", "k").unwrap();
        assert_eq!(val, Some("v2".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }
}
