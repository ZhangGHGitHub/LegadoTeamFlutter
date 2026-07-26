//! 共享作用域管理
//!
//! 参考 Kotlin 端 `SharedJsScope.kt`：
//! - 使用 LRU 缓存存储已编译的 JS 作用域
//! - 分离普通作用域缓存与 CryptoJS 作用域缓存
//! - 支持并发安全的缓存访问与作用域创建锁
//!
//! 未启用 quickjs feature 时仅提供占位结构。

use std::collections::HashMap;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

use lru::LruCache;

/// 作用域数据 —— 存储已初始化的 JS 作用域信息
#[derive(Debug, Clone)]
pub struct ScopeData {
    /// 作用域标识（通常为 jsLib 的 MD5）
    pub key: String,
    /// 是否已注入 CryptoJS
    pub has_crypto: bool,
    /// 作用域关联的元数据
    pub metadata: HashMap<String, String>,
}

impl ScopeData {
    pub fn new(key: String) -> Self {
        Self {
            key,
            has_crypto: false,
            metadata: HashMap::new(),
        }
    }

    pub fn with_crypto(mut self, has_crypto: bool) -> Self {
        self.has_crypto = has_crypto;
        self
    }
}

/// 共享作用域管理器
///
/// 管理两类缓存：
/// 1. `scope_cache` — 基于 jsLib 内容的普通作用域缓存
/// 2. `crypto_cache` — 注入了 CryptoJS 的加密作用域缓存
///
/// 参考 SharedJsScope.kt 中的 LruCache(16) 配置。
/// 使用 `lru::LruCache` 实现 O(1) 的 get/put/evict 操作。
pub struct SharedScopeManager {
    /// 普通作用域缓存（默认容量 16）
    scope_cache: Arc<Mutex<LruCache<String, ScopeData>>>,
    /// CryptoJS 作用域缓存（默认容量 16）
    crypto_cache: Arc<Mutex<LruCache<String, ScopeData>>>,
    /// 作用域创建锁（防止并发重复创建）
    creation_locks: Arc<Mutex<HashMap<String, Arc<Mutex<()>>>>>,
    /// 最大缓存容量
    max_capacity: usize,
}

impl SharedScopeManager {
    /// 创建新的作用域管理器
    pub fn new() -> Self {
        Self::with_capacity(16)
    }

    /// 创建指定容量的作用域管理器
    pub fn with_capacity(capacity: usize) -> Self {
        let cap = NonZeroUsize::new(capacity).unwrap_or(NonZeroUsize::new(16).unwrap());
        Self {
            scope_cache: Arc::new(Mutex::new(LruCache::new(cap))),
            crypto_cache: Arc::new(Mutex::new(LruCache::new(cap))),
            creation_locks: Arc::new(Mutex::new(HashMap::new())),
            max_capacity: capacity,
        }
    }

    /// 获取或创建普通作用域
    ///
    /// 参考 `SharedJsScope.getScope()`
    pub fn get_scope(&self, key: &str) -> Option<ScopeData> {
        let mut cache = self.scope_cache.lock().ok()?;
        cache.get(key).cloned()
    }

    /// 缓存普通作用域
    pub fn put_scope(&self, key: String, data: ScopeData) {
        if let Ok(mut cache) = self.scope_cache.lock() {
            cache.put(key, data);
        }
    }

    /// 获取或创建 CryptoJS 作用域
    ///
    /// 参考 `SharedJsScope.getCryptoScope()`
    pub fn get_crypto_scope(&self, key: &str) -> Option<ScopeData> {
        let mut cache = self.crypto_cache.lock().ok()?;
        cache.get(key).cloned()
    }

    /// 缓存 CryptoJS 作用域
    pub fn put_crypto_scope(&self, key: String, data: ScopeData) {
        if let Ok(mut cache) = self.crypto_cache.lock() {
            cache.put(key, data);
        }
    }

    /// 移除指定 key 的作用域缓存
    ///
    /// 参考 `SharedJsScope.remove()`
    pub fn remove(&self, key: &str) {
        if let Ok(mut cache) = self.scope_cache.lock() {
            cache.pop(key);
        }
        if let Ok(mut cache) = self.crypto_cache.lock() {
            cache.pop(key);
        }
    }

    /// 获取作用域创建锁（防止并发重复创建同一作用域）
    pub fn acquire_creation_lock(&self, key: &str) -> Arc<Mutex<()>> {
        let mut locks = self.creation_locks.lock().unwrap();
        locks
            .entry(key.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// 释放不再使用的作用域创建锁
    pub fn release_creation_lock(&self, key: &str) {
        let mut locks = self.creation_locks.lock().unwrap();
        // 仅当没有其他使用者时才移除
        if let Some(lock) = locks.get(key) {
            if Arc::strong_count(lock) <= 1 {
                locks.remove(key);
            }
        }
    }

    /// 获取普通作用域缓存大小
    pub fn scope_cache_size(&self) -> usize {
        self.scope_cache.lock().map(|c| c.len()).unwrap_or(0)
    }

    /// 获取 CryptoJS 作用域缓存大小
    pub fn crypto_cache_size(&self) -> usize {
        self.crypto_cache.lock().map(|c| c.len()).unwrap_or(0)
    }

    /// 获取最大容量
    pub fn max_capacity(&self) -> usize {
        self.max_capacity
    }

    /// 清空所有缓存
    pub fn clear(&self) {
        let cap = NonZeroUsize::new(self.max_capacity).unwrap_or(NonZeroUsize::new(16).unwrap());
        if let Ok(mut cache) = self.scope_cache.lock() {
            *cache = LruCache::new(cap);
        }
        if let Ok(mut cache) = self.crypto_cache.lock() {
            *cache = LruCache::new(cap);
        }
    }
}

impl Default for SharedScopeManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scope_data_new() {
        let sd = ScopeData::new("test_key".to_string());
        assert_eq!(sd.key, "test_key");
        assert!(!sd.has_crypto);
        assert!(sd.metadata.is_empty());
    }

    #[test]
    fn test_scope_data_with_crypto() {
        let sd = ScopeData::new("k".to_string()).with_crypto(true);
        assert!(sd.has_crypto);
    }

    #[test]
    fn test_shared_scope_manager_new() {
        let mgr = SharedScopeManager::new();
        assert_eq!(mgr.max_capacity(), 16);
        assert_eq!(mgr.scope_cache_size(), 0);
        assert_eq!(mgr.crypto_cache_size(), 0);
    }

    #[test]
    fn test_scope_put_and_get() {
        let mgr = SharedScopeManager::new();
        let data = ScopeData::new("k1".to_string());
        mgr.put_scope("k1".to_string(), data);
        let got = mgr.get_scope("k1");
        assert!(got.is_some());
        assert_eq!(got.unwrap().key, "k1");
    }

    #[test]
    fn test_scope_get_missing() {
        let mgr = SharedScopeManager::new();
        assert!(mgr.get_scope("missing").is_none());
    }

    #[test]
    fn test_crypto_scope_put_and_get() {
        let mgr = SharedScopeManager::new();
        let data = ScopeData::new("ck1".to_string()).with_crypto(true);
        mgr.put_crypto_scope("ck1".to_string(), data);
        let got = mgr.get_crypto_scope("ck1");
        assert!(got.is_some());
        assert!(got.unwrap().has_crypto);
    }

    #[test]
    fn test_scope_remove() {
        let mgr = SharedScopeManager::new();
        mgr.put_scope("k1".to_string(), ScopeData::new("k1".to_string()));
        mgr.put_crypto_scope("k1".to_string(), ScopeData::new("k1".to_string()));
        mgr.remove("k1");
        assert!(mgr.get_scope("k1").is_none());
        assert!(mgr.get_crypto_scope("k1").is_none());
    }

    #[test]
    fn test_scope_clear() {
        let mgr = SharedScopeManager::new();
        mgr.put_scope("a".to_string(), ScopeData::new("a".to_string()));
        mgr.put_scope("b".to_string(), ScopeData::new("b".to_string()));
        mgr.put_crypto_scope("c".to_string(), ScopeData::new("c".to_string()));
        mgr.clear();
        assert_eq!(mgr.scope_cache_size(), 0);
        assert_eq!(mgr.crypto_cache_size(), 0);
    }

    #[test]
    fn test_lru_eviction() {
        let mgr = SharedScopeManager::with_capacity(2);
        mgr.put_scope("a".to_string(), ScopeData::new("a".to_string()));
        mgr.put_scope("b".to_string(), ScopeData::new("b".to_string()));
        mgr.put_scope("c".to_string(), ScopeData::new("c".to_string()));
        // "a" should be evicted
        assert!(mgr.get_scope("a").is_none());
        assert!(mgr.get_scope("b").is_some());
        assert!(mgr.get_scope("c").is_some());
        assert_eq!(mgr.scope_cache_size(), 2);
    }

    #[test]
    fn test_creation_lock_same_key() {
        let mgr = SharedScopeManager::new();
        let lock1 = mgr.acquire_creation_lock("key1");
        let lock2 = mgr.acquire_creation_lock("key1");
        assert!(Arc::ptr_eq(&lock1, &lock2));
    }

    #[test]
    fn test_creation_lock_different_keys() {
        let mgr = SharedScopeManager::new();
        let lock1 = mgr.acquire_creation_lock("key1");
        let lock2 = mgr.acquire_creation_lock("key2");
        assert!(!Arc::ptr_eq(&lock1, &lock2));
    }

    #[test]
    fn test_release_creation_lock() {
        let mgr = SharedScopeManager::new();
        {
            let _lock = mgr.acquire_creation_lock("key1");
            // lock goes out of scope here, strong_count drops
        }
        mgr.release_creation_lock("key1");
        // After release, acquiring again should create a new lock
        let lock2 = mgr.acquire_creation_lock("key1");
        assert!(Arc::strong_count(&lock2) >= 1);
    }

    #[test]
    fn test_lru_access_refreshes_order() {
        // 访问某个 key 后，它不应被淘汰
        let mgr = SharedScopeManager::with_capacity(2);
        mgr.put_scope("a".to_string(), ScopeData::new("a".to_string()));
        mgr.put_scope("b".to_string(), ScopeData::new("b".to_string()));

        // 访问 "a" 使其变为最近使用
        let _ = mgr.get_scope("a");

        // 插入 "c"，应淘汰最久未使用的 "b"
        mgr.put_scope("c".to_string(), ScopeData::new("c".to_string()));
        assert!(mgr.get_scope("a").is_some()); // "a" 被访问过，未被淘汰
        assert!(mgr.get_scope("b").is_none()); // "b" 被淘汰
        assert!(mgr.get_scope("c").is_some());
    }

    #[test]
    fn test_lru_cache_hit_and_miss() {
        let mgr = SharedScopeManager::with_capacity(4);

        // 未命中
        assert!(mgr.get_scope("x").is_none());
        assert_eq!(mgr.scope_cache_size(), 0);

        // 插入后命中
        mgr.put_scope("x".to_string(), ScopeData::new("x".to_string()));
        let hit = mgr.get_scope("x");
        assert!(hit.is_some());
        assert_eq!(hit.unwrap().key, "x");
        assert_eq!(mgr.scope_cache_size(), 1);
    }

    #[test]
    fn test_lru_capacity_eviction_multiple() {
        let mgr = SharedScopeManager::with_capacity(3);
        mgr.put_scope("a".to_string(), ScopeData::new("a".to_string()));
        mgr.put_scope("b".to_string(), ScopeData::new("b".to_string()));
        mgr.put_scope("c".to_string(), ScopeData::new("c".to_string()));
        assert_eq!(mgr.scope_cache_size(), 3);

        // 超出容量，淘汰最久未使用的 "a"
        mgr.put_scope("d".to_string(), ScopeData::new("d".to_string()));
        assert_eq!(mgr.scope_cache_size(), 3);
        assert!(mgr.get_scope("a").is_none());
        assert!(mgr.get_scope("b").is_some());
        assert!(mgr.get_scope("c").is_some());
        assert!(mgr.get_scope("d").is_some());
    }
}
