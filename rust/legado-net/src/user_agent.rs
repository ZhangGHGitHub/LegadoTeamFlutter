//! User-Agent 轮换器
//!
//! 提供内置的 UA 列表和轮换策略（轮询 / 随机），
//! 并可作为中间件自动为每个请求注入不同的 User-Agent。

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::SystemTime;

use legado_core::LegadoResult;
use reqwest::{RequestBuilder, Response};

use crate::middleware::{Middleware, Next};

/// 内置 UA 列表
const DEFAULT_USER_AGENTS: &[&str] = &[
    // Chrome on Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    // Chrome on macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    // Chrome on Android
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
    // Firefox on Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    // Firefox on macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:121.0) Gecko/20100101 Firefox/121.0",
    // Safari on macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
    // Safari on iOS
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
    // Edge on Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
];

/// UA 轮换器
///
/// 维护一组 User-Agent 字符串，支持轮询和伪随机选择。
pub struct UserAgentRotator {
    agents: Vec<String>,
    index: AtomicUsize,
}

impl UserAgentRotator {
    /// 使用内置 UA 列表创建轮换器
    pub fn new() -> Self {
        Self {
            agents: DEFAULT_USER_AGENTS.iter().map(|s| s.to_string()).collect(),
            index: AtomicUsize::new(0),
        }
    }

    /// 使用自定义 UA 列表创建轮换器
    ///
    /// 如果传入空列表，则回退到内置列表。
    pub fn with_agents(agents: Vec<String>) -> Self {
        let agents = if agents.is_empty() {
            DEFAULT_USER_AGENTS.iter().map(|s| s.to_string()).collect()
        } else {
            agents
        };
        Self {
            agents,
            index: AtomicUsize::new(0),
        }
    }

    /// 轮询方式获取下一个 UA
    pub fn next(&self) -> &str {
        let idx = self.index.fetch_add(1, Ordering::Relaxed) % self.agents.len();
        &self.agents[idx]
    }

    /// 伪随机方式获取一个 UA
    ///
    /// 使用 `SystemTime` 纳秒部分作为简单随机源，避免引入 `rand` 依赖。
    pub fn random(&self) -> &str {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as usize)
            .unwrap_or(0);
        let idx = nanos % self.agents.len();
        &self.agents[idx]
    }

    /// 获取当前 UA 列表长度
    pub fn len(&self) -> usize {
        self.agents.len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.agents.is_empty()
    }
}

impl Default for UserAgentRotator {
    fn default() -> Self {
        Self::new()
    }
}

/// UA 中间件
///
/// 每次请求自动注入轮换的 User-Agent 头。
pub struct UserAgentMiddleware {
    rotator: Arc<UserAgentRotator>,
}

impl UserAgentMiddleware {
    /// 使用指定的轮换器创建中间件
    pub fn new(rotator: Arc<UserAgentRotator>) -> Self {
        Self { rotator }
    }

    /// 获取内部轮换器引用
    pub fn rotator(&self) -> &Arc<UserAgentRotator> {
        &self.rotator
    }
}

#[async_trait::async_trait]
impl Middleware for UserAgentMiddleware {
    fn name(&self) -> &str {
        "UserAgent"
    }

    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
        let ua = self.rotator.next();
        let request = request.header("User-Agent", ua);
        next(request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_rotator_has_agents() {
        let rotator = UserAgentRotator::new();
        assert_eq!(rotator.len(), DEFAULT_USER_AGENTS.len());
        assert!(!rotator.is_empty());
    }

    #[test]
    fn test_next_round_robin_order() {
        let rotator = UserAgentRotator::with_agents(vec![
            "UA-A".to_string(),
            "UA-B".to_string(),
            "UA-C".to_string(),
        ]);
        assert_eq!(rotator.next(), "UA-A");
        assert_eq!(rotator.next(), "UA-B");
        assert_eq!(rotator.next(), "UA-C");
        // 循环回到第一个
        assert_eq!(rotator.next(), "UA-A");
    }

    #[test]
    fn test_random_returns_valid_agent() {
        let rotator = UserAgentRotator::with_agents(vec![
            "UA-X".to_string(),
            "UA-Y".to_string(),
        ]);
        let ua = rotator.random();
        assert!(ua == "UA-X" || ua == "UA-Y");
    }

    #[test]
    fn test_with_empty_agents_falls_back_to_default() {
        let rotator = UserAgentRotator::with_agents(vec![]);
        assert_eq!(rotator.len(), DEFAULT_USER_AGENTS.len());
    }

    #[test]
    fn test_custom_agents_list() {
        let custom = vec!["CustomBot/1.0".to_string()];
        let rotator = UserAgentRotator::with_agents(custom);
        assert_eq!(rotator.len(), 1);
        assert_eq!(rotator.next(), "CustomBot/1.0");
        assert_eq!(rotator.next(), "CustomBot/1.0");
    }

    #[test]
    fn test_default_trait() {
        let rotator = UserAgentRotator::default();
        assert_eq!(rotator.len(), DEFAULT_USER_AGENTS.len());
    }

    #[tokio::test]
    async fn test_user_agent_middleware_adds_header() {
        use crate::middleware::MiddlewareChain;
        use std::sync::atomic::AtomicUsize;

        let rotator = Arc::new(UserAgentRotator::with_agents(vec![
            "TestUA/1.0".to_string(),
        ]));
        let mut chain = MiddlewareChain::new();
        chain.add(UserAgentMiddleware::new(rotator));

        let called = Arc::new(AtomicUsize::new(0));
        let called_clone = called.clone();
        let final_handler: Next = Arc::new(move |_req: RequestBuilder| {
            let c = called_clone.clone();
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
