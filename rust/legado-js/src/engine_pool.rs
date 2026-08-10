//! QuickJS 引擎池
//!
//! 按 source_tag 缓存 QuickJsEngine 实例，避免每源重复创建 Runtime + Context + 全量 API 注册。

#[cfg(feature = "quickjs")]
use crate::engine::QuickJsEngine;
#[cfg(feature = "quickjs")]
use crate::sandbox::SandboxConfig;
#[cfg(feature = "quickjs")]
use legado_core::LegadoError;
#[cfg(feature = "quickjs")]
use std::collections::HashMap;
#[cfg(feature = "quickjs")]
use std::sync::{Arc, Mutex};

/// 引擎池
///
/// 按 source_tag 缓存 QuickJsEngine 实例。当池满时采用简单淘汰策略（移除最早插入的条目）。
/// 线程安全：内部使用 `Arc<Mutex<...>>` 保护。
#[cfg(feature = "quickjs")]
pub struct EnginePool {
    engines: Arc<Mutex<HashMap<String, Arc<Mutex<QuickJsEngine>>>>>,
    max_size: usize,
    /// 沙箱配置（创建新引擎时使用）
    sandbox_config: SandboxConfig,
}

#[cfg(feature = "quickjs")]
impl EnginePool {
    /// 创建引擎池
    ///
    /// - `max_size`: 池中最大引擎数量
    ///
    /// [UI-fix 2026-08-10 | Reasonix] 默认允许 `eval`/`Function`（allow_script_run）：
    /// 对齐原版 Rhino 书源 JS 环境——yckceo 书源大量使用
    /// `<js>eval(String(Reload('...')))` 动态加载模式，禁 eval 致这些书源
    /// URL 构建失败。书源即用户显式导入的可信代码（与原版信任模型一致）；
    /// 敏感入口（js_eval 调试端点等）应显式传严格 SandboxConfig::default()。
    pub fn new(max_size: usize) -> Self {
        Self {
            engines: Arc::new(Mutex::new(HashMap::new())),
            max_size,
            sandbox_config: SandboxConfig::default().with_allow_script_run(true),
        }
    }

    /// 使用指定沙箱配置创建引擎池
    pub fn with_sandbox_config(max_size: usize, sandbox_config: SandboxConfig) -> Self {
        Self {
            engines: Arc::new(Mutex::new(HashMap::new())),
            max_size,
            sandbox_config,
        }
    }

    /// 获取或创建引擎
    ///
    /// 如果 source_tag 对应的引擎已存在，直接返回；否则创建新引擎并缓存。
    /// 当池已满时，随机淘汰一个条目。
    ///
    /// 创建失败（如内存不足/初始化异常）时返回 `Err` 而非 panic，
    /// 遵循 FFI 禁 panic 规范，由调用方决定降级/报错。
    pub fn get_or_create(
        &self,
        source_tag: &str,
    ) -> Result<Arc<Mutex<QuickJsEngine>>, LegadoError> {
        let mut pool = self.engines.lock().unwrap();

        if let Some(engine) = pool.get(source_tag) {
            return Ok(engine.clone());
        }

        // 随机淘汰：如果池已满，移除第一个（HashMap 迭代顺序不确定，后续可改为真正的 LRU）
        if pool.len() >= self.max_size {
            if let Some(key) = pool.keys().next().cloned() {
                pool.remove(&key);
            }
        }

        let engine = QuickJsEngine::new(self.sandbox_config.clone())?;
        let engine = Arc::new(Mutex::new(engine));
        pool.insert(source_tag.to_string(), engine.clone());
        Ok(engine)
    }

    /// 清除指定引擎
    pub fn remove(&self, source_tag: &str) {
        let mut pool = self.engines.lock().unwrap();
        pool.remove(source_tag);
    }

    /// 清空所有引擎
    pub fn clear(&self) {
        let mut pool = self.engines.lock().unwrap();
        pool.clear();
    }

    /// 池中引擎数量
    pub fn len(&self) -> usize {
        self.engines.lock().unwrap().len()
    }

    /// 池是否为空
    pub fn is_empty(&self) -> bool {
        self.engines.lock().unwrap().is_empty()
    }

    /// 最大容量
    pub fn max_size(&self) -> usize {
        self.max_size
    }

    /// 检查是否包含指定 source_tag 的引擎
    pub fn contains(&self, source_tag: &str) -> bool {
        self.engines.lock().unwrap().contains_key(source_tag)
    }
}

// ============================================================
// 测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;
    use crate::engine::JsEngine;

    #[test]
    fn test_pool_new_empty() {
        let pool = EnginePool::new(4);
        assert_eq!(pool.len(), 0);
        assert!(pool.is_empty());
        assert_eq!(pool.max_size(), 4);
    }

    #[test]
    fn test_pool_get_or_create_returns_same_engine() {
        let pool = EnginePool::new(4);
        let e1 = pool.get_or_create("source_a").unwrap();
        let e2 = pool.get_or_create("source_a").unwrap();
        // 同一个 source_tag 应返回同一个 Arc
        assert!(Arc::ptr_eq(&e1, &e2));
        assert_eq!(pool.len(), 1);
    }

    #[test]
    fn test_pool_different_tags_create_different_engines() {
        let pool = EnginePool::new(4);
        let e1 = pool.get_or_create("source_a").unwrap();
        let e2 = pool.get_or_create("source_b").unwrap();
        assert!(!Arc::ptr_eq(&e1, &e2));
        assert_eq!(pool.len(), 2);
    }

    #[test]
    fn test_pool_eviction_on_max_size() {
        let pool = EnginePool::new(2);
        let _e1 = pool.get_or_create("s1").unwrap();
        let _e2 = pool.get_or_create("s2").unwrap();
        // 池已满，再插入应淘汰一个
        let _e3 = pool.get_or_create("s3").unwrap();
        assert_eq!(pool.len(), 2);
        // s3 必须存在
        assert!(pool.contains("s3"));
    }

    #[test]
    fn test_pool_remove() {
        let pool = EnginePool::new(4);
        let _e1 = pool.get_or_create("source_x").unwrap();
        assert!(pool.contains("source_x"));
        pool.remove("source_x");
        assert!(!pool.contains("source_x"));
        assert_eq!(pool.len(), 0);
    }

    #[test]
    fn test_pool_clear() {
        let pool = EnginePool::new(8);
        let _e1 = pool.get_or_create("a").unwrap();
        let _e2 = pool.get_or_create("b").unwrap();
        let _e3 = pool.get_or_create("c").unwrap();
        assert_eq!(pool.len(), 3);
        pool.clear();
        assert_eq!(pool.len(), 0);
        assert!(pool.is_empty());
    }

    #[test]
    fn test_pool_engine_is_functional() {
        let pool = EnginePool::new(4);
        let engine = pool.get_or_create("func_test").unwrap();
        let guard = engine.lock().unwrap();
        let result = guard.eval("1 + 2");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "3");
    }

    #[test]
    fn test_pool_with_sandbox_config() {
        let config = SandboxConfig::permissive();
        let pool = EnginePool::with_sandbox_config(4, config);
        let engine = pool.get_or_create("sandbox_test").unwrap();
        let guard = engine.lock().unwrap();
        let result = guard.eval("'hello' + ' ' + 'world'");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "hello world");
    }
}
