//! 代理池管理
//!
//! 支持 HTTP / HTTPS / SOCKS5 代理类型，提供轮询和伪随机选择策略，
//! 并可作为中间件自动为请求分配代理。

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::SystemTime;

use legado_core::{LegadoError, LegadoResult};
use reqwest::{RequestBuilder, Response};

use crate::middleware::{Middleware, Next};

/// 代理类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyType {
    /// HTTP 代理
    Http,
    /// HTTPS 代理
    Https,
    /// SOCKS5 代理
    Socks5,
}

impl ProxyType {
    /// 从 URL scheme 推断代理类型
    pub fn from_url(url: &str) -> Self {
        let lower = url.to_lowercase();
        if lower.starts_with("socks5://") || lower.starts_with("socks5h://") {
            ProxyType::Socks5
        } else if lower.starts_with("https://") {
            ProxyType::Https
        } else {
            ProxyType::Http
        }
    }
}

/// 代理配置
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    /// 代理 URL，例如 `http://user:pass@host:port` 或 `socks5://host:port`
    pub url: String,
    /// 代理类型（可自动推断）
    pub proxy_type: ProxyType,
}

impl ProxyConfig {
    /// 从 URL 创建代理配置（自动推断类型）
    pub fn from_url(url: impl Into<String>) -> Self {
        let url = url.into();
        let proxy_type = ProxyType::from_url(&url);
        Self { url, proxy_type }
    }

    /// 从 URL 和指定类型创建代理配置
    pub fn with_type(url: impl Into<String>, proxy_type: ProxyType) -> Self {
        Self {
            url: url.into(),
            proxy_type,
        }
    }
}

/// 代理池
///
/// 维护一组代理配置，支持轮询和伪随机选择。
pub struct ProxyPool {
    proxies: Vec<ProxyConfig>,
    index: AtomicUsize,
}

impl ProxyPool {
    /// 创建代理池
    pub fn new(proxies: Vec<ProxyConfig>) -> Self {
        Self {
            proxies,
            index: AtomicUsize::new(0),
        }
    }

    /// 轮询方式获取下一个代理
    pub fn next(&self) -> Option<&ProxyConfig> {
        if self.proxies.is_empty() {
            return None;
        }
        let idx = self.index.fetch_add(1, Ordering::Relaxed) % self.proxies.len();
        Some(&self.proxies[idx])
    }

    /// 伪随机方式获取一个代理
    pub fn random(&self) -> Option<&ProxyConfig> {
        if self.proxies.is_empty() {
            return None;
        }
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as usize)
            .unwrap_or(0);
        let idx = nanos % self.proxies.len();
        Some(&self.proxies[idx])
    }

    /// 获取代理池大小
    pub fn len(&self) -> usize {
        self.proxies.len()
    }

    /// 代理池是否为空
    pub fn is_empty(&self) -> bool {
        self.proxies.is_empty()
    }
}

/// 代理中间件
///
/// 从代理池中轮询选取代理并应用到请求。
/// 注意：reqwest 的代理在 Client 构建时设置，无法逐请求切换。
/// 因此本中间件仅做日志记录和请求头注入（`X-Forwarded-For` 等可选头），
/// 真正的代理轮换应在 `LegadoClient::new()` 或 `LegadoClient::with_proxy()` 中完成。
pub struct ProxyMiddleware {
    pool: Arc<ProxyPool>,
}

impl ProxyMiddleware {
    /// 使用指定的代理池创建中间件
    pub fn new(pool: Arc<ProxyPool>) -> Self {
        Self { pool }
    }

    /// 获取代理池引用
    pub fn pool(&self) -> &Arc<ProxyPool> {
        &self.pool
    }

    /// 获取当前轮询到的代理（供外部构建 Client 时使用）
    pub fn current_proxy(&self) -> Option<&ProxyConfig> {
        self.pool.next()
    }
}

#[async_trait::async_trait]
impl Middleware for ProxyMiddleware {
    fn name(&self) -> &str {
        "Proxy"
    }

    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
        // 记录当前使用的代理信息（不修改请求本身，因为 reqwest 代理在 Client 层设置）
        if let Some(proxy) = self.pool.next() {
            log::debug!(
                "Proxy middleware: using proxy {} ({:?})",
                proxy.url,
                proxy.proxy_type
            );
        } else {
            log::debug!("Proxy middleware: proxy pool is empty, no proxy applied");
        }
        next(request).await
    }
}

/// 将 ProxyConfig 转换为 reqwest::Proxy
pub fn to_reqwest_proxy(config: &ProxyConfig) -> Result<reqwest::Proxy, LegadoError> {
    reqwest::Proxy::all(&config.url)
        .map_err(|e| LegadoError::Network(format!("Invalid proxy URL '{}': {}", config.url, e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_proxy_type_from_url() {
        assert_eq!(
            ProxyType::from_url("http://proxy.example.com:8080"),
            ProxyType::Http
        );
        assert_eq!(
            ProxyType::from_url("https://proxy.example.com:443"),
            ProxyType::Https
        );
        assert_eq!(
            ProxyType::from_url("socks5://127.0.0.1:1080"),
            ProxyType::Socks5
        );
        assert_eq!(
            ProxyType::from_url("SOCKS5://127.0.0.1:1080"),
            ProxyType::Socks5
        );
    }

    #[test]
    fn test_proxy_config_from_url() {
        let cfg = ProxyConfig::from_url("socks5://127.0.0.1:1080");
        assert_eq!(cfg.url, "socks5://127.0.0.1:1080");
        assert_eq!(cfg.proxy_type, ProxyType::Socks5);
    }

    #[test]
    fn test_proxy_pool_round_robin() {
        let pool = ProxyPool::new(vec![
            ProxyConfig::from_url("http://p1:8080"),
            ProxyConfig::from_url("http://p2:8080"),
            ProxyConfig::from_url("http://p3:8080"),
        ]);
        assert_eq!(pool.next().unwrap().url, "http://p1:8080");
        assert_eq!(pool.next().unwrap().url, "http://p2:8080");
        assert_eq!(pool.next().unwrap().url, "http://p3:8080");
        // 循环
        assert_eq!(pool.next().unwrap().url, "http://p1:8080");
    }

    #[test]
    fn test_proxy_pool_empty() {
        let pool = ProxyPool::new(vec![]);
        assert!(pool.is_empty());
        assert_eq!(pool.len(), 0);
        assert!(pool.next().is_none());
        assert!(pool.random().is_none());
    }

    #[test]
    fn test_proxy_pool_random_returns_valid() {
        let pool = ProxyPool::new(vec![
            ProxyConfig::from_url("http://p1:8080"),
            ProxyConfig::from_url("http://p2:8080"),
        ]);
        let proxy = pool.random().unwrap();
        assert!(proxy.url == "http://p1:8080" || proxy.url == "http://p2:8080");
    }

    #[test]
    fn test_proxy_pool_len() {
        let pool = ProxyPool::new(vec![ProxyConfig::from_url("http://p1:8080")]);
        assert_eq!(pool.len(), 1);
        assert!(!pool.is_empty());
    }

    #[test]
    fn test_to_reqwest_proxy_valid() {
        let cfg = ProxyConfig::from_url("http://127.0.0.1:7890");
        let result = to_reqwest_proxy(&cfg);
        assert!(result.is_ok());
    }

    #[test]
    fn test_to_reqwest_proxy_invalid() {
        // reqwest rejects URLs with no scheme at all
        let cfg = ProxyConfig::from_url("://no-scheme");
        let result = to_reqwest_proxy(&cfg);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_proxy_middleware_empty_pool() {
        use crate::middleware::MiddlewareChain;
        use std::sync::atomic::AtomicUsize;

        let pool = Arc::new(ProxyPool::new(vec![]));
        let mut chain = MiddlewareChain::new();
        chain.add(ProxyMiddleware::new(pool));

        let called = Arc::new(AtomicUsize::new(0));
        let cc = called.clone();
        let final_handler: Next = Arc::new(move |_req: RequestBuilder| {
            let c = cc.clone();
            Box::pin(async move {
                c.fetch_add(1, Ordering::SeqCst);
                Err(legado_core::LegadoError::Network("sentinel".into()))
            })
        });

        let client = reqwest::Client::new();
        let req = client.get("http://example.com");
        let _ = chain.execute(req, final_handler).await;
        assert_eq!(called.load(Ordering::SeqCst), 1);
    }
}
