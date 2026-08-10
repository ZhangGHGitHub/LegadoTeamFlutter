//! legado-net: HTTP 客户端（基于 reqwest）
//!
//! 参考 Kotlin 实现 `HttpHelper.kt` / `CookieManager.kt` / `CookieStore.kt` / `AnalyzeUrl.kt`，
//! 为 Legado Rust 提供完整的网络层，包括：
//!
//! - [`client`] — `LegadoClient` HTTP 客户端封装
//! - [`request`] — `LegadoRequest` 请求结构
//! - [`response`] — `LegadoResponse` 响应结构
//! - [`cookie_store`] — `CookieStore` Cookie 管理
//! - [`url_template`] — URL 模板解析引擎
//! - [`rss`] — RSS/Atom Feed 解析器
//! - [`cover`] — 封面图片下载与缓存
//! - [`middleware`] — 请求中间件框架
//! - [`retry`] — 请求重试机制（指数退避）
//! - [`rate_limit`] — 请求限流器（按域名）
//! - [`user_agent`] — User-Agent 轮换器
//! - [`proxy`] — 代理池管理
//! - [`ssl_config`] — SSL/TLS 配置

pub mod client;
pub mod cookie_store;
pub mod cover;
pub mod custom_hosts;
pub mod direct_link_upload;
pub mod middleware;
pub mod proxy;
pub mod rate_limit;
pub mod remote_book;
pub mod request;
pub mod response;
pub mod retry;
pub mod rss;
pub mod rule_update_client;
pub mod source_checker;
pub mod ssl_config;
pub mod url_template;
pub mod user_agent;
pub mod verification;
pub mod webdav;

// 测试专用：SOCKS5 凭据代理 e2e（内置最小 SOCKS5/HTTP 测试服务器）
#[cfg(test)]
mod socks5_e2e;

// 常用类型重导出
pub use client::{LegadoClient, LegadoClientConfig};
pub use cookie_store::{CookiePersistence, CookieStore};
pub use cover::CoverCache;
pub use custom_hosts::{
    apply_custom_hosts, clear_custom_hosts, lookup_ips, CustomHostsResolver,
};
pub use middleware::{Middleware, MiddlewareChain};
pub use proxy::{parse_proxy_config, ProxyConfig, ProxyCredentials, ProxyPool, ProxyType};
pub use rate_limit::{DomainRateLimiter, RateLimiter};
pub use request::{LegadoRequest, Method};
pub use response::{LegadoRawResponse, LegadoResponse};
pub use retry::{RetryConfig, RetryExecutor};
pub use rss::{fetch_feed, parse_feed, RssArticle, RssFeed};
pub use rule_update_client::{
    fetch_subscription, merge_subscription, should_update, MergeResult, RuleSubscription,
    UpdateResult,
};
pub use source_checker::{CaptchaInfo, CheckResult, CheckerConfig, RedirectInfo, SourceChecker};
pub use ssl_config::SslConfig;
pub use url_template::{parse_url_template, ParsedUrl, UrlOption};
pub use user_agent::{UserAgentMiddleware, UserAgentRotator};
pub use verification::{VerificationFlightRegistry, VerificationResult};
