//! 进程级缓存存储（内存 LRU + 本地磁盘文件）
//!
//! P2-9 ①：对齐上游 `help/CacheManager.kt`（put/get/putMemory/getFromMemory/
//! deleteMemory/delete，L60-98）与 WebCacheManager 的 JS 面
//! （`put/putMemory/getFromMemory/deleteMemory/get(onlyDisk)/putFile/getFile/delete`）。
//!
//! 语义对齐：
//! - `put(key, value, saveTime)` — saveTime 单位**秒**；0（或缺省）= 永久
//!   （deadline = 0）并同步写内存层；非零 → `deadline = now + saveTime*1000`
//!   且清除该 key 的内存层（对齐上游 put 后 deleteMemory）。
//! - `get(key, onlyDisk)` — 内存层优先（onlyDisk 跳过）；磁盘层按
//!   deadline 校验：0 = 永久（回写内存层），过期 → 删文件并返回 None。
//! - `putMemory/getFromMemory/deleteMemory` — 内存 LRU（容量 1024）。
//! - `putFile/getFile` — 纯磁盘（独立子目录 `file/`，不进内存层、不过期）。
//! - `delete(key)` — 磁盘 + 内存。
//!
//! QuickJS 引擎按 source_tag LRU 缓存、跨书源复用（engine_cache），
//! 故缓存实现为 **Rust 进程级存储**而非 JS 对象——同一进程内多书源共享
//! 同一份缓存，对齐上游单例 CacheManager 语义（JS 侧每次 eval 都能命中）。
//!
//! 磁盘目录取环境变量 [`CACHE_DIR_ENV`]，缺省 `<temp_dir>/legado-js-cache`
//! （测试通过环境变量隔离）。

use std::fs;
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use lru::LruCache;
use sha2::{Digest, Sha256};

/// 内存层 LRU 容量
const MEMORY_CACHE_CAPACITY: usize = 1024;

/// 磁盘缓存目录环境变量名
pub const CACHE_DIR_ENV: &str = "LEGADO_JS_CACHE_DIR";

/// 磁盘条目：`{"v": 值, "d": deadline(ms, 0=永久)}`
#[derive(serde::Serialize, serde::Deserialize)]
struct DiskCacheEntry {
    v: String,
    d: i64,
}

fn memory_cache() -> &'static Mutex<LruCache<String, String>> {
    static CACHE: OnceLock<Mutex<LruCache<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| {
        let cap =
            NonZeroUsize::new(MEMORY_CACHE_CAPACITY).unwrap_or(NonZeroUsize::new(16).unwrap());
        Mutex::new(LruCache::new(cap))
    })
}

/// 磁盘缓存根目录（env 覆盖，测试隔离用）
pub fn disk_dir() -> PathBuf {
    match std::env::var(CACHE_DIR_ENV) {
        Ok(dir) if !dir.trim().is_empty() => PathBuf::from(dir),
        _ => std::env::temp_dir().join("legado-js-cache"),
    }
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let bytes = hasher.finalize();
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn disk_path(key: &str) -> PathBuf {
    disk_dir().join(format!("{}.json", sha256_hex(key)))
}

fn file_path(key: &str) -> PathBuf {
    disk_dir().join("file").join(sha256_hex(key))
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 内存层写入（`putMemory`）
pub fn put_memory(key: &str, value: &str) {
    if let Ok(mut cache) = memory_cache().lock() {
        cache.put(key.to_string(), value.to_string());
    }
}

/// 内存层读取（`getFromMemory`）
pub fn get_from_memory(key: &str) -> Option<String> {
    memory_cache().lock().ok()?.get(key).cloned()
}

/// 内存层删除（`deleteMemory`）
pub fn delete_memory(key: &str) {
    if let Ok(mut cache) = memory_cache().lock() {
        cache.pop(key);
    }
}

/// 磁盘写入（`put`）：saveTime 秒，0=永久（同步内存层），非零 → 清内存层
pub fn put(key: &str, value: &str, save_time_secs: i64) -> bool {
    let deadline = if save_time_secs <= 0 {
        0
    } else {
        now_millis() + save_time_secs * 1000
    };
    let path = disk_path(key);
    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            eprintln!("[cache_store] 创建缓存目录失败 {:?}: {e}", parent);
            return false;
        }
    }
    let json = match serde_json::to_string(&DiskCacheEntry {
        v: value.to_string(),
        d: deadline,
    }) {
        Ok(j) => j,
        Err(e) => {
            eprintln!("[cache_store] 序列化失败 {key}: {e}");
            return false;
        }
    };
    if fs::write(&path, json).is_err() {
        return false;
    }
    if deadline == 0 {
        put_memory(key, value);
    } else {
        delete_memory(key);
    }
    true
}

/// 磁盘读取（`get`）：内存优先（only_disk 跳过），磁盘按 deadline 校验
pub fn get(key: &str, only_disk: bool) -> Option<String> {
    if !only_disk {
        if let Some(v) = get_from_memory(key) {
            return Some(v);
        }
    }
    let raw = fs::read_to_string(disk_path(key)).ok()?;
    let entry: DiskCacheEntry = serde_json::from_str(&raw).ok()?;
    if entry.d == 0 || now_millis() <= entry.d {
        if entry.d == 0 {
            put_memory(key, &entry.v);
        }
        Some(entry.v)
    } else {
        let _ = fs::remove_file(disk_path(key));
        None
    }
}

/// 纯磁盘写入（`putFile`，无内存层、不过期）
pub fn put_file(key: &str, value: &str) -> bool {
    let path = file_path(key);
    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            eprintln!("[cache_store] 创建缓存目录失败 {:?}: {e}", parent);
            return false;
        }
    }
    fs::write(&path, value).is_ok()
}

/// 纯磁盘读取（`getFile`，不做 deadline 校验）
pub fn get_file(key: &str) -> Option<String> {
    fs::read_to_string(file_path(key)).ok()
}

/// 删除（磁盘 + 内存）
pub fn delete(key: &str) {
    let _ = fs::remove_file(disk_path(key));
    let _ = fs::remove_file(file_path(key));
    delete_memory(key);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn unique_key(tag: &str) -> String {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("{}-{}-{}", std::process::id(), n, tag)
    }

    #[test]
    fn test_memory_roundtrip() {
        let k = unique_key("mem");
        assert!(get_from_memory(&k).is_none());
        put_memory(&k, "v1");
        assert_eq!(get_from_memory(&k).as_deref(), Some("v1"));
        // 数字值（语料 cache.putMemory(k, Date.now())）以字符串存储
        put_memory(&k, "1726540800000");
        assert_eq!(get_from_memory(&k).as_deref(), Some("1726540800000"));
        delete_memory(&k);
        assert!(get_from_memory(&k).is_none());
    }

    #[test]
    fn test_put_get_permanent() {
        let k = unique_key("perm");
        assert!(put(&k, "perm-value", 0));
        assert_eq!(get(&k, false).as_deref(), Some("perm-value"));
        // 永久缓存命中后回写内存层
        assert_eq!(get_from_memory(&k).as_deref(), Some("perm-value"));
        // onlyDisk 跳过内存层，直接读磁盘
        assert_eq!(get(&k, true).as_deref(), Some("perm-value"));
        delete(&k);
        assert!(get(&k, false).is_none());
        assert!(get(&k, true).is_none());
        assert!(get_from_memory(&k).is_none());
    }

    #[test]
    fn test_put_get_expired() {
        let k = unique_key("expired");
        // saveTime=1 秒；等待过期后磁盘读取应 None 且文件被清理
        assert!(put(&k, "short", 1));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert!(get(&k, true).is_none());
    }

    #[test]
    fn test_put_nonsync_clears_memory() {
        let k = unique_key("memclear");
        put_memory(&k, "old");
        put(&k, "new", 3600);
        // 非永久 put 清除内存层（对齐上游 put 后 deleteMemory）
        assert!(get_from_memory(&k).is_none());
        // 磁盘层仍可读
        assert_eq!(get(&k, true).as_deref(), Some("new"));
        delete(&k);
    }

    #[test]
    fn test_file_roundtrip() {
        let k = unique_key("file");
        assert!(put_file(&k, "file-value"));
        assert_eq!(get_file(&k).as_deref(), Some("file-value"));
        // putFile/getFile 不进内存层
        assert!(get_from_memory(&k).is_none());
        delete(&k);
        assert!(get_file(&k).is_none());
    }

    #[test]
    fn test_missing_key_returns_none() {
        let k = unique_key("missing");
        assert!(get(&k, false).is_none());
        assert!(get(&k, true).is_none());
        assert!(get_file(&k).is_none());
        assert!(get_from_memory(&k).is_none());
    }
}
