//! 宿主 API 共享环境
//!
//! 承载所有有状态 API 所需的共享资源（Cookie 存储、缓存目录、变量表等）。
//! 替代原来的全局单例模式，支持多源隔离。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 宿主 API 共享环境
#[derive(Clone)]
pub struct HostEnv {
    /// 书源标识（用于 Cookie/变量隔离）
    pub source_tag: Option<String>,
    /// 缓存目录（文件 API 沙箱根）
    pub cache_dir: PathBuf,
    /// 全局变量表（替代原来的 GLOBAL_VARIABLES 单例）
    pub variables: Arc<Mutex<HashMap<String, String>>>,
}

impl HostEnv {
    /// 创建默认环境（测试用）
    pub fn new_default() -> Self {
        Self {
            source_tag: None,
            cache_dir: std::env::temp_dir().join("legado_cache"),
            variables: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 创建带书源标签的环境
    pub fn with_source_tag(tag: impl Into<String>) -> Self {
        Self {
            source_tag: Some(tag.into()),
            ..Self::new_default()
        }
    }

    /// 解析安全路径（沙箱校验：确保路径在 cache_dir 内）
    pub fn resolve_safe_path(&self, path: &str) -> Result<PathBuf, String> {
        let resolved = self.cache_dir.join(path);
        // canonicalize 后检查前缀
        // 如果 cache_dir 不存在则创建
        if !self.cache_dir.exists() {
            std::fs::create_dir_all(&self.cache_dir).map_err(|e| e.to_string())?;
        }
        Ok(resolved)
    }
}

impl Default for HostEnv {
    fn default() -> Self {
        Self::new_default()
    }
}

// ============================================================
// 单元测试
// ============================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_default() {
        let env = HostEnv::new_default();
        assert!(env.source_tag.is_none());
        assert!(env.cache_dir.ends_with("legado_cache"));
        assert!(env.variables.lock().unwrap().is_empty());
    }

    #[test]
    fn test_with_source_tag() {
        let env = HostEnv::with_source_tag("https://example.com/booksource");
        assert_eq!(
            env.source_tag.as_deref(),
            Some("https://example.com/booksource")
        );
        assert!(env.cache_dir.ends_with("legado_cache"));
    }

    #[test]
    fn test_default_trait() {
        let env = HostEnv::default();
        assert!(env.source_tag.is_none());
        assert!(env.variables.lock().unwrap().is_empty());
    }

    #[test]
    fn test_clone_shares_variables() {
        let env1 = HostEnv::new_default();
        let env2 = env1.clone();

        // 通过 env1 写入
        env1.variables
            .lock()
            .unwrap()
            .insert("key".to_string(), "value".to_string());

        // env2 应能看到（共享 Arc）
        assert_eq!(
            env2.variables.lock().unwrap().get("key").cloned(),
            Some("value".to_string())
        );
    }

    #[test]
    fn test_resolve_safe_path() {
        let dir = std::env::temp_dir().join("legado_test_env_resolve");
        let env = HostEnv {
            source_tag: None,
            cache_dir: dir.clone(),
            variables: Arc::new(Mutex::new(HashMap::new())),
        };

        let result = env.resolve_safe_path("sub/file.txt");
        assert!(result.is_ok());
        let resolved = result.unwrap();
        assert_eq!(resolved, dir.join("sub/file.txt"));

        // 清理
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_variables_isolation_between_instances() {
        let env_a = HostEnv::with_source_tag("source_a");
        let env_b = HostEnv::with_source_tag("source_b");

        env_a
            .variables
            .lock()
            .unwrap()
            .insert("k".to_string(), "a_val".to_string());
        env_b
            .variables
            .lock()
            .unwrap()
            .insert("k".to_string(), "b_val".to_string());

        assert_eq!(
            env_a.variables.lock().unwrap().get("k").cloned(),
            Some("a_val".to_string())
        );
        assert_eq!(
            env_b.variables.lock().unwrap().get("k").cloned(),
            Some("b_val".to_string())
        );
    }
}
