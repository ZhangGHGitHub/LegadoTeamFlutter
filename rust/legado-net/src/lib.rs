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
pub mod middleware;
pub mod proxy;
pub mod rate_limit;
pub mod request;
pub mod response;
pub mod retry;
pub mod rss;
pub mod source_checker;
pub mod ssl_config;
pub mod url_template;
pub mod user_agent;
pub mod verification;
pub mod webdav;

// 常用类型重导出
pub use client::{LegadoClient, LegadoClientConfig};
pub use cookie_store::CookieStore;
pub use cover::CoverCache;
pub use middleware::{Middleware, MiddlewareChain};
pub use proxy::{ProxyConfig, ProxyPool, ProxyType};
pub use rate_limit::{DomainRateLimiter, RateLimiter};
pub use request::{LegadoRequest, Method};
pub use response::LegadoResponse;
pub use retry::{RetryConfig, RetryExecutor};
pub use rss::{fetch_feed, parse_feed, RssArticle, RssFeed};
pub use source_checker::{CheckResult, CheckerConfig, SourceChecker};
pub use ssl_config::SslConfig;
pub use url_template::{parse_url_template, ParsedUrl, UrlOption};
pub use user_agent::{UserAgentMiddleware, UserAgentRotator};
pub use verification::{VerificationFlightRegistry, VerificationResult};
