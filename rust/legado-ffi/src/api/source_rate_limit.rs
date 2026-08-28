//! 书源 concurrentRate 固定窗口限流（G4，对齐 Kotlin ConcurrentRateLimiter）
//!
//! 每源限流器按 `book_source_url` 缓存，跨请求保持窗口状态。

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use legado_core::models::BookSource;
use legado_net::rate_limit::IntervalRateLimiter;

static RATE_LIMITERS: OnceLock<Mutex<HashMap<String, Arc<IntervalRateLimiter>>>> = OnceLock::new();

/// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
pub async fn acquire_source_rate_limit(source: &BookSource) {
    let rate = source.concurrent_rate.as_deref().unwrap_or("").trim();
    if rate.is_empty() || rate == "0" {
        return;
    }
    let Some(limiter) = IntervalRateLimiter::parse(rate) else {
        return;
    };
    let map = RATE_LIMITERS.get_or_init(|| Mutex::new(HashMap::new()));
    let limiter = {
        let mut guard = map.lock().unwrap();
        Arc::clone(
            guard
                .entry(source.book_source_url.clone())
                .or_insert_with(|| Arc::new(limiter)),
        )
    };
    limiter.acquire().await;
}
