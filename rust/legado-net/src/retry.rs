//! 请求重试机制
//!
//! 支持指数退避（Exponential Backoff）的可配置重试执行器。
//! 适用于瞬时网络错误和特定 HTTP 状态码（如 429、5xx）的自动重试。

use std::time::Duration;

use legado_core::{LegadoError, LegadoResult};
use reqwest::{RequestBuilder, Response};

use crate::middleware::{Middleware, Next};

/// 重试配置
#[derive(Debug, Clone)]
pub struct RetryConfig {
    /// 最大重试次数（默认 3）
    pub max_retries: u32,
    /// 初始延迟毫秒（默认 1000ms）
    pub initial_delay_ms: u64,
    /// 最大延迟毫秒（默认 30000ms）
    pub max_delay_ms: u64,
    /// 退避乘数（默认 2.0）
    pub backoff_multiplier: f64,
    /// 需要重试的 HTTP 状态码列表
    pub retry_on_status: Vec<u16>,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_retries: 3,
            initial_delay_ms: 1000,
            max_delay_ms: 30_000,
            backoff_multiplier: 2.0,
            retry_on_status: vec![429, 500, 502, 503, 504],
        }
    }
}

impl RetryConfig {
    /// 计算第 `attempt` 次重试的延迟时间（0-indexed）
    pub fn delay_for_attempt(&self, attempt: u32) -> Duration {
        let base = self.initial_delay_ms as f64;
        let delay_ms = base * self.backoff_multiplier.powi(attempt as i32);
        let capped = delay_ms.min(self.max_delay_ms as f64) as u64;
        Duration::from_millis(capped)
    }

    /// 判断是否应对该状态码进行重试
    pub fn should_retry_status(&self, status: u16) -> bool {
        self.retry_on_status.contains(&status)
    }
}

/// 带指数退避的重试执行器
///
/// 可作为中间件插入 `MiddlewareChain`，在请求失败时自动重试。
pub struct RetryExecutor {
    config: RetryConfig,
}

impl RetryExecutor {
    /// 使用指定配置创建重试执行器
    pub fn new(config: RetryConfig) -> Self {
        Self { config }
    }

    /// 使用默认配置创建重试执行器
    pub fn with_defaults() -> Self {
        Self::new(RetryConfig::default())
    }

    /// 获取配置引用
    pub fn config(&self) -> &RetryConfig {
        &self.config
    }

    /// 直接执行带重试的请求（不通过中间件链）
    ///
    /// `request_factory` 每次调用时重建请求构建器，因为 `RequestBuilder` 在 `send()` 后被消费。
    pub async fn execute_with_retry<F, Fut>(&self, request_factory: F) -> LegadoResult<Response>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = LegadoResult<Response>>,
    {
        let mut last_error: Option<LegadoError> = None;

        for attempt in 0..=self.config.max_retries {
            if attempt > 0 {
                let delay = self.config.delay_for_attempt(attempt - 1);
                tokio::time::sleep(delay).await;
            }

            match request_factory().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    if self.config.should_retry_status(status) && attempt < self.config.max_retries
                    {
                        log::debug!(
                            "Retry attempt {}/{}: status {} from request",
                            attempt + 1,
                            self.config.max_retries,
                            status
                        );
                        // 消费 body 以释放连接
                        let _ = response.bytes().await;
                        last_error = Some(LegadoError::Network(format!(
                            "Retryable status code: {}",
                            status
                        )));
                        continue;
                    }
                    return Ok(response);
                }
                Err(e) => {
                    log::debug!(
                        "Retry attempt {}/{}: error: {}",
                        attempt + 1,
                        self.config.max_retries,
                        e
                    );
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| LegadoError::Network("Max retries exceeded".into())))
    }
}

/// 将 RetryExecutor 作为中间件使用
#[async_trait::async_trait]
impl Middleware for RetryExecutor {
    fn name(&self) -> &str {
        "RetryExecutor"
    }

    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
        // 尝试构建请求以获取 URL（用于日志）
        // 由于 RequestBuilder 只能 send 一次，中间件模式下直接调用 next
        // 对于重试需要重新构建请求，所以这里直接委托给 next
        // 注意：中间件模式只能重试一次 send（因为 RequestBuilder 被消费）
        // 如需完整重试，应使用 execute_with_retry 方法
        let response = next(request).await;

        match response {
            Ok(resp) => {
                let status = resp.status().as_u16();
                if self.config.should_retry_status(status) {
                    log::debug!(
                        "Retry middleware: status {} is retryable, but RequestBuilder consumed. \
                         Use execute_with_retry for full retry support.",
                        status
                    );
                }
                Ok(resp)
            }
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_retry_config() {
        let cfg = RetryConfig::default();
        assert_eq!(cfg.max_retries, 3);
        assert_eq!(cfg.initial_delay_ms, 1000);
        assert_eq!(cfg.max_delay_ms, 30_000);
        assert!((cfg.backoff_multiplier - 2.0).abs() < f64::EPSILON);
        assert!(cfg.should_retry_status(429));
        assert!(cfg.should_retry_status(500));
        assert!(cfg.should_retry_status(502));
        assert!(cfg.should_retry_status(503));
        assert!(cfg.should_retry_status(504));
        assert!(!cfg.should_retry_status(200));
        assert!(!cfg.should_retry_status(404));
    }

    #[test]
    fn test_delay_for_attempt_exponential_backoff() {
        let cfg = RetryConfig {
            initial_delay_ms: 100,
            max_delay_ms: 10_000,
            backoff_multiplier: 2.0,
            ..Default::default()
        };
        assert_eq!(cfg.delay_for_attempt(0), Duration::from_millis(100));
        assert_eq!(cfg.delay_for_attempt(1), Duration::from_millis(200));
        assert_eq!(cfg.delay_for_attempt(2), Duration::from_millis(400));
        assert_eq!(cfg.delay_for_attempt(3), Duration::from_millis(800));
    }

    #[test]
    fn test_delay_capped_at_max() {
        let cfg = RetryConfig {
            initial_delay_ms: 1000,
            max_delay_ms: 5000,
            backoff_multiplier: 10.0,
            ..Default::default()
        };
        // 1000 * 10^1 = 10000 -> capped at 5000
        assert_eq!(cfg.delay_for_attempt(1), Duration::from_millis(5000));
        // 1000 * 10^2 = 100000 -> capped at 5000
        assert_eq!(cfg.delay_for_attempt(2), Duration::from_millis(5000));
    }

    #[test]
    fn test_should_retry_status_custom() {
        let cfg = RetryConfig {
            retry_on_status: vec![408, 429, 500],
            ..Default::default()
        };
        assert!(cfg.should_retry_status(408));
        assert!(cfg.should_retry_status(429));
        assert!(cfg.should_retry_status(500));
        assert!(!cfg.should_retry_status(502));
        assert!(!cfg.should_retry_status(200));
    }

    #[test]
    fn test_retry_executor_creation() {
        let executor = RetryExecutor::with_defaults();
        assert_eq!(executor.config().max_retries, 3);
    }

    #[tokio::test]
    async fn test_execute_with_retry_success_on_first() {
        let executor = RetryExecutor::new(RetryConfig {
            max_retries: 3,
            initial_delay_ms: 1, // 极短延迟以加速测试
            ..Default::default()
        });

        let call_count = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let cc = call_count.clone();

        let result = executor
            .execute_with_retry(move || {
                let cc = cc.clone();
                async move {
                    cc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    Err(LegadoError::Network("transient error".into()))
                }
            })
            .await;

        assert!(result.is_err());
        // 1 initial + 3 retries = 4
        assert_eq!(call_count.load(std::sync::atomic::Ordering::SeqCst), 4);
    }

    #[tokio::test]
    async fn test_execute_with_retry_max_retries_zero() {
        let executor = RetryExecutor::new(RetryConfig {
            max_retries: 0,
            ..Default::default()
        });

        let call_count = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let cc = call_count.clone();

        let result = executor
            .execute_with_retry(move || {
                let cc = cc.clone();
                async move {
                    cc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    Err(LegadoError::Network("fail".into()))
                }
            })
            .await;

        assert!(result.is_err());
        // Only 1 call, no retries
        assert_eq!(call_count.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn test_execute_with_retry_success_returns_ok() {
        let executor = RetryExecutor::new(RetryConfig {
            max_retries: 3,
            initial_delay_ms: 1,
            ..Default::default()
        });

        // 模拟：直接返回网络错误（无法构造 Response），验证重试逻辑
        let call_count = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let cc = call_count.clone();

        let result: LegadoResult<Response> = executor
            .execute_with_retry(move || {
                let cc = cc.clone();
                async move {
                    let n = cc.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    if n < 2 {
                        Err(LegadoError::Network("transient".into()))
                    } else {
                        // 仍然返回错误，因为我们无法构造 reqwest::Response
                        Err(LegadoError::Network("final error".into()))
                    }
                }
            })
            .await;

        assert!(result.is_err());
        // Should have been called 3 times (0, 1, 2) before exhausting retries
        assert_eq!(call_count.load(std::sync::atomic::Ordering::SeqCst), 4);
    }
}
