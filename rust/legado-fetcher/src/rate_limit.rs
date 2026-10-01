//! 书源 concurrentRate 固定窗口限流（G4，对齐 Kotlin ConcurrentRateLimiter）
//!
//! 原 `legado-ffi/src/api/source_rate_limit.rs` 的全局 `OnceLock` 限速表
//! 下沉为可注入的 [`RateLimiterRegistry`]：每源限流器按 `book_source_url`
//! 缓存，跨请求保持窗口状态。宿主（ffi）以进程级 OnceLock 持有单一注册表
//! 实例，语义与下沉前一致。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use legado_core::models::BookSource;
use legado_net::rate_limit::IntervalRateLimiter;

/// 每源限流器注册表
#[derive(Default)]
pub struct RateLimiterRegistry {
    limiters: Mutex<HashMap<String, Arc<IntervalRateLimiter>>>,
}

impl RateLimiterRegistry {
    /// 空注册表
    pub fn new() -> Self {
        Self {
            limiters: Mutex::new(HashMap::new()),
        }
    }

    /// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
    pub async fn acquire(&self, source: &BookSource) {
        let rate = source.concurrent_rate.as_deref().unwrap_or("").trim();
        if rate.is_empty() || rate == "0" {
            return;
        }
        let Some(limiter) = IntervalRateLimiter::parse(rate) else {
            return;
        };
        let limiter = {
            let mut guard = self.limiters.lock().unwrap_or_else(|p| p.into_inner());
            Arc::clone(
                guard
                    .entry(source.book_source_url.clone())
                    .or_insert_with(|| Arc::new(limiter)),
            )
        };
        limiter.acquire().await;
    }
}
