//! 书源 concurrentRate 固定窗口限流（G4，对齐 Kotlin ConcurrentRateLimiter）
//!
//! P5 子批 2a：限速表本体（`RateLimiterRegistry`）已下沉 `legado-fetcher`；
//! 本模块保留进程级注册表单例与同名函数薄壳（`search.rs` 调用点零改动）。

use std::sync::{Arc, OnceLock};

use legado_core::models::BookSource;

pub use legado_fetcher::rate_limit::RateLimiterRegistry;

/// 进程级限流注册表（跨请求保持各源窗口状态；原全局 OnceLock HashMap 的等价物）
///
/// [P2 互认] legado-server 侧另有一份同名 static（handlers/web_book.rs
/// `RATE_LIMITER`）。当前 ffi 与 server 分属不同进程/使用形态，无双实例；
/// 若未来同进程同时启用 ffi 抓取路径与 REST 端点，concurrentRate 窗口将按
/// 路径分叉（弱于真单例）——届时须收敛为单例（如注册表句柄经共享 crate
/// 静态化或宿主注入同一份 Arc）。
static REGISTRY: OnceLock<Arc<RateLimiterRegistry>> = OnceLock::new();

/// 取进程级注册表（装配 `FetcherDeps.rate_limiter` 用）
pub(crate) fn registry() -> Arc<RateLimiterRegistry> {
    Arc::clone(REGISTRY.get_or_init(|| Arc::new(RateLimiterRegistry::new())))
}

/// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
pub async fn acquire_source_rate_limit(source: &BookSource) {
    registry().acquire(source).await;
}
