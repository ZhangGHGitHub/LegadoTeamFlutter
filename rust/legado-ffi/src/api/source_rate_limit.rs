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
/// `RATE_LIMITER`）。ffi 与 server 可同进程并存（同一进程同时启用 ffi 抓取
/// 路径与 REST 端点），但两者各持独立 static registry，本批不做共享单例
/// 收敛；源编辑保存会在各自保存路径刷新各自 registry（ffi `source.rs`
/// add/update/import；server handlers/source_update.rs 批量导入与 REST
/// create/update）。REST/FFI 同时抓取同一源时窗口仍会分叉（弱于真单例）
/// ——收敛为单例（如注册表句柄经共享 crate 静态化或宿主注入同一份 Arc）
/// 留待后续裁决。
static REGISTRY: OnceLock<Arc<RateLimiterRegistry>> = OnceLock::new();

/// 取进程级注册表（装配 `FetcherDeps.rate_limiter` 用）
pub(crate) fn registry() -> Arc<RateLimiterRegistry> {
    Arc::clone(REGISTRY.get_or_init(|| Arc::new(RateLimiterRegistry::new())))
}

/// 书源保存成功后的限速配置刷新入口（宿主保存路径：source add/update/import 调用）
///
/// 走 [`RateLimiterRegistry::refresh`] 的保存侧分发：空 / `"0"`（忽略首尾
/// 空白）→ 移除既有 limiter（对齐原版「空即不限流」，保存显式 null/空串后
/// 不再沿用旧限速）；合法 rate → 原位刷新；非法 rate 与未注册 key → 不改动/
/// 不预创建。可在写库成功后无条件调用；写库失败不得调用（避免未落库的配置
/// 提前生效）。
pub(crate) fn refresh_source_rate_limit(source_url: &str, concurrent_rate: &str) {
    registry().refresh(source_url, concurrent_rate);
}

/// 按书源 `concurrentRate` 获取访问许可（空/"0"/非法 → 立即返回）
pub async fn acquire_source_rate_limit(source: &BookSource) {
    registry().acquire(source).await;
}
