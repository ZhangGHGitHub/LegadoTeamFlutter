//! 书源 concurrentRate 固定窗口限流（G4，对齐 Kotlin ConcurrentRateLimiter）
//!
//! P5 子批 2a：限速表本体（`RateLimiterRegistry`）已下沉 `legado-fetcher`；
//! 本模块保留进程级注册表单例与同名函数薄壳（`search.rs` 调用点零改动）。

use std::sync::{Arc, OnceLock};

use legado_core::models::BookSource;

pub use legado_fetcher::rate_limit::RateLimiterRegistry;

/// 进程级限流注册表（跨请求保持各源窗口状态；原全局 OnceLock HashMap 的等价物）
static REGISTRY: OnceLock<Arc<RateLimiterRegistry>> = OnceLock::new();

/// 取进程级注册表（装配 `FetcherDeps.rate_limiter` 用）
pub(crate) fn registry() -> Arc<RateLimiterRegistry> {
    Arc::clone(REGISTRY.get_or_init(|| Arc::new(RateLimiterRegistry::new())))
}

/// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
pub async fn acquire_source_rate_limit(source: &BookSource) {
    registry().acquire(source).await;
}
