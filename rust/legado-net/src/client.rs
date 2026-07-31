//! HTTP 客户端封装模块
//!
//! 参考 Kotlin `HttpHelper.kt` 基于 reqwest 构建，特性包括：
//! - 可配置的超时、UA、代理
//! - 信任所有证书（与原 Kotlin SSLHelper.unsafeSSLSocketFactory 一致）
//! - 自动重定向
//! - Cookie 管理集成
//! - 默认 Keep-Alive / Cache-Control 头
//! - 可选重试（指数退避）和按域名限流
//! - UA 轮换与代理池中间件
//! - SSL/TLS 配置（证书验证控制、自定义 CA）
//! - 可选 QUIC/HTTP3 传输（启用后 HTTPS 请求优先走 QUIC，失败自动 fallback 到 HTTP/2）

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use reqwest::redirect::Policy;
use reqwest::ClientBuilder;

use legado_core::{LegadoError, LegadoResult};

use crate::cookie_store::CookieStore;
use crate::middleware::MiddlewareChain;
use crate::proxy::{ProxyConfig, ProxyMiddleware, ProxyPool};
use crate::quic::{QuinnClient, QuinnConfig};
use crate::rate_limit::DomainRateLimiter;
use crate::response::LegadoResponse;
use crate::retry::{RetryConfig, RetryExecutor};
use crate::ssl_config::SslConfig;
use crate::user_agent::{UserAgentMiddleware, UserAgentRotator};

// ─── 全局 QUIC 开关 ────────────────────────────────────────────────────────────

/// 全局 QUIC 启用标志（默认关闭，不影响现有请求路径）
static QUIC_ENABLED: AtomicBool = AtomicBool::new(false);

/// 设置全局 QUIC 传输开关
///
/// 启用后，所有新创建的 `LegadoClient` 对 HTTPS 请求将优先尝试 QUIC/HTTP3，
/// 失败时自动 fallback 到 reqwest HTTP/2 路径。
pub fn set_quic_enabled(enabled: bool) {
    QUIC_ENABLED.store(enabled, Ordering::SeqCst);
    log::info!("全局 QUIC 传输已{}", if enabled { "启用" } else { "禁用" });
}

/// 查询全局 QUIC 传输开关状态
pub fn is_quic_enabled() -> bool {
    QUIC_ENABLED.load(Ordering::SeqCst)
}

/// HTTP 客户端配置
///
/// 默认值参考 `HttpHelper.kt` 中 `okHttpClient` 的构建参数。
#[derive(Debug, Clone)]
pub struct LegadoClientConfig {
    /// 连接超时，默认 15s（对应 OkHttp `.connectTimeout(15, TimeUnit.SECONDS)`）
    pub connect_timeout: Duration,
    /// 读取超时，默认 60s（对应 OkHttp `.readTimeout(60, TimeUnit.SECONDS)`）
    pub read_timeout: Duration,
    /// User-Agent 字符串（默认 UA，轮换优先级低于 `user_agents`）
    pub user_agent: String,
    /// 代理配置（单一代理，兼容旧接口）
    pub proxy: Option<ProxyConfig>,
    /// 是否接受无效证书，默认 true（对应 `SSLHelper.unsafeSSLSocketFactory`）
    pub accept_invalid_certs: bool,
    /// 是否跟随重定向，默认 true（对应 `.followRedirects(true)`）
    pub follow_redirects: bool,
    /// 重试配置（None 表示不启用重试）
    pub retry: Option<RetryConfig>,
    /// 每域名最大并发数（None 表示不限流）
    pub rate_limit: Option<usize>,
    /// 自定义 UA 列表（启用后自动添加 UA 轮换中间件）
    pub user_agents: Option<Vec<String>>,
    /// 代理池（启用后自动添加代理中间件）
    pub proxies: Option<Vec<ProxyConfig>>,
    /// SSL/TLS 配置（如设置则覆盖 `accept_invalid_certs`）
    pub ssl: Option<SslConfig>,
    /// 是否启用 QUIC/HTTP3 传输（默认关闭）
    ///
    /// 启用后，HTTPS 请求将优先尝试 QUIC，失败自动 fallback 到 HTTP/2。
    /// 也可通过全局 `set_quic_enabled(true)` 开启，无需逐个配置。
    pub enable_quic: bool,
}

impl Default for LegadoClientConfig {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(15),
            read_timeout: Duration::from_secs(60),
            user_agent: "Legado/1.0".to_string(),
            proxy: None,
            accept_invalid_certs: true,
            follow_redirects: true,
            retry: None,
            rate_limit: None,
            user_agents: None,
            proxies: None,
            ssl: None,
            enable_quic: false,
        }
    }
}

/// Legado HTTP 客户端
///
/// 基于 `reqwest::Client`，附带 Cookie 存储、可选重试、按域名限流，
/// 以及可选的 UA 轮换和代理池中间件。
/// 启用 QUIC 后，HTTPS 请求优先走 HTTP/3，失败自动 fallback 到 HTTP/2。
#[derive(Clone)]
pub struct LegadoClient {
    client: reqwest::Client,
    cookie_store: Arc<RwLock<CookieStore>>,
    config: LegadoClientConfig,
    retry_executor: Option<Arc<RetryExecutor>>,
    domain_rate_limiter: Option<Arc<DomainRateLimiter>>,
    middleware_chain: Option<Arc<MiddlewareChain>>,
    ua_rotator: Option<Arc<UserAgentRotator>>,
    proxy_pool: Option<Arc<ProxyPool>>,
    /// QUIC 客户端（仅在 enable_quic 时初始化）
    quic_client: Option<Arc<QuinnClient>>,
}

impl LegadoClient {
    /// 根据配置创建新的 HTTP 客户端
    pub fn new(config: LegadoClientConfig) -> LegadoResult<Self> {
        let mut builder = ClientBuilder::new()
            .connect_timeout(config.connect_timeout)
            .timeout(config.read_timeout)
            .user_agent(&config.user_agent)
            .cookie_store(true);

        // SSL 配置：优先使用 ssl 字段，否则回退到 accept_invalid_certs
        if let Some(ref ssl) = config.ssl {
            builder = ssl.apply(builder);
        } else if config.accept_invalid_certs {
            builder = builder.danger_accept_invalid_certs(true);
        }

        // 重定向策略
        if config.follow_redirects {
            builder = builder.redirect(Policy::default());
        } else {
            builder = builder.redirect(Policy::none());
        }

        // 单一代理（兼容旧接口）
        if let Some(ref proxy_cfg) = config.proxy {
            let proxy = crate::proxy::to_reqwest_proxy(proxy_cfg)?;
            builder = builder.proxy(proxy);
        }

        let client = builder
            .build()
            .map_err(|e| LegadoError::Network(format!("Failed to build HTTP client: {}", e)))?;

        // 限流器
        let domain_rate_limiter = config
            .rate_limit
            .map(|n| Arc::new(DomainRateLimiter::new(n)));

        // 重试执行器
        let retry_executor = config
            .retry
            .as_ref()
            .map(|c| Arc::new(RetryExecutor::new(c.clone())));

        // UA 轮换器
        let ua_rotator = config
            .user_agents
            .as_ref()
            .map(|agents| Arc::new(UserAgentRotator::with_agents(agents.clone())));

        // 代理池
        let proxy_pool = config
            .proxies
            .as_ref()
            .map(|proxies| Arc::new(ProxyPool::new(proxies.clone())));

        // 构建中间件链
        let middleware_chain = {
            let mut chain = MiddlewareChain::new();
            if let Some(ref rotator) = ua_rotator {
                chain.add(UserAgentMiddleware::new(Arc::clone(rotator)));
            }
            if let Some(ref pool) = proxy_pool {
                chain.add(ProxyMiddleware::new(Arc::clone(pool)));
            }
            if chain.is_empty() {
                None
            } else {
                Some(Arc::new(chain))
            }
        };

        // QUIC 客户端初始化：配置显式启用 或 全局开关启用
        let quic_enabled = config.enable_quic || is_quic_enabled();
        let quic_client = if quic_enabled {
            let quinn_config = QuinnConfig {
                connect_timeout: config.connect_timeout,
                request_timeout: config.read_timeout,
                ..Default::default()
            };
            match QuinnClient::new(quinn_config) {
                Ok(c) => {
                    log::info!("QUIC 客户端已初始化，HTTPS 请求将优先尝试 HTTP/3");
                    Some(Arc::new(c))
                }
                Err(e) => {
                    log::warn!("QUIC 客户端初始化失败，将仅使用 HTTP/2: {}", e);
                    None
                }
            }
        } else {
            None
        };

        Ok(Self {
            client,
            cookie_store: Arc::new(RwLock::new(CookieStore::new())),
            config,
            retry_executor,
            domain_rate_limiter,
            middleware_chain,
            ua_rotator,
            proxy_pool,
            quic_client,
        })
    }

    /// 获取 UA 轮换器引用（如有）
    pub fn ua_rotator(&self) -> Option<&Arc<UserAgentRotator>> {
        self.ua_rotator.as_ref()
    }

    /// 获取代理池引用（如有）
    pub fn proxy_pool(&self) -> Option<&Arc<ProxyPool>> {
        self.proxy_pool.as_ref()
    }

    /// 获取中间件链引用（如有）
    pub fn middleware_chain(&self) -> Option<&Arc<MiddlewareChain>> {
        self.middleware_chain.as_ref()
    }

    /// 获取 CookieStore 引用
    pub fn cookie_store(&self) -> &Arc<RwLock<CookieStore>> {
        &self.cookie_store
    }

    /// 获取重试执行器引用（如有）
    pub fn retry_executor(&self) -> Option<&Arc<RetryExecutor>> {
        self.retry_executor.as_ref()
    }

    /// 获取域名限流器引用（如有）
    pub fn domain_rate_limiter(&self) -> Option<&Arc<DomainRateLimiter>> {
        self.domain_rate_limiter.as_ref()
    }

    /// 获取 QUIC 客户端引用（如有）
    pub fn quic_client(&self) -> Option<&Arc<QuinnClient>> {
        self.quic_client.as_ref()
    }

    /// 发送 GET 请求
    ///
    /// 启用 QUIC 且 URL 为 HTTPS 时，优先尝试 HTTP/3，失败自动 fallback 到 HTTP/2。
    pub async fn get(
        &self,
        url: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<LegadoResponse> {
        // QUIC 优先路径：仅对 HTTPS URL 尝试
        if let Some(resp) = self.try_quic_get(url, headers.as_ref()).await {
            return resp;
        }

        // 标准 reqwest HTTP/2 路径
        let client = self.client.clone();
        let cookie_store = self.cookie_store.clone();
        let headers = Arc::new(headers);
        let url = url.to_string();
        let url_for_retry = url.clone();

        let factory = move || {
            let client = client.clone();
            let cookie_store = cookie_store.clone();
            let headers = Arc::clone(&headers);
            let url = url.clone();
            async move {
                let mut req = client.get(&url);
                req = apply_default_headers_static(req);
                req = apply_custom_headers(req, (*headers).clone());
                req = apply_cookie_static(req, &cookie_store, &url);
                req.send().await
            }
        };

        self.execute_with_retry_and_limit(url_for_retry.as_str(), factory)
            .await
    }

    /// 发送 GET 请求并返回原始字节（用于图片等二进制资源）
    pub async fn get_bytes(
        &self,
        url: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<Vec<u8>> {
        let resp = self.get(url, headers).await?;
        Ok(resp.body.into_bytes())
    }

    /// 发送 POST 请求
    ///
    /// 启用 QUIC 且 URL 为 HTTPS 时，优先尝试 HTTP/3，失败自动 fallback 到 HTTP/2。
    pub async fn post(
        &self,
        url: &str,
        body: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<LegadoResponse> {
        // QUIC 优先路径：仅对 HTTPS URL 尝试
        if let Some(resp) = self.try_quic_post(url, body, headers.as_ref()).await {
            return resp;
        }

        // 标准 reqwest HTTP/2 路径
        let client = self.client.clone();
        let cookie_store = self.cookie_store.clone();
        let headers = Arc::new(headers);
        let url = url.to_string();
        let body = body.to_string();
        let url_for_retry = url.clone();

        let factory = move || {
            let client = client.clone();
            let cookie_store = cookie_store.clone();
            let headers = Arc::clone(&headers);
            let url = url.clone();
            let body = body.clone();
            async move {
                let mut req = client.post(&url).body(body);
                req = apply_default_headers_static(req);
                req = apply_custom_headers(req, (*headers).clone());
                req = apply_cookie_static(req, &cookie_store, &url);
                req.send().await
            }
        };

        self.execute_with_retry_and_limit(url_for_retry.as_str(), factory)
            .await
    }

    /// 发送 HEAD 请求
    pub async fn head(
        &self,
        url: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<LegadoResponse> {
        let client = self.client.clone();
        let cookie_store = self.cookie_store.clone();
        let headers = Arc::new(headers);
        let url = url.to_string();
        let url_for_retry = url.clone();

        let factory = move || {
            let client = client.clone();
            let cookie_store = cookie_store.clone();
            let headers = Arc::clone(&headers);
            let url = url.clone();
            async move {
                let mut req = client.head(&url);
                req = apply_default_headers_static(req);
                req = apply_custom_headers(req, (*headers).clone());
                req = apply_cookie_static(req, &cookie_store, &url);
                req.send().await
            }
        };

        self.execute_with_retry_and_limit(url_for_retry.as_str(), factory)
            .await
    }

    /// 发送通用请求（基于 `LegadoRequest`）
    pub async fn send(
        &self,
        request: &crate::request::LegadoRequest,
    ) -> LegadoResult<LegadoResponse> {
        let client = self.client.clone();
        let cookie_store = self.cookie_store.clone();
        let method = request.method.to_reqwest();
        let url = request.url.clone();
        let body = request.body.clone();
        let timeout = request.timeout;
        let headers = Arc::new(Some(request.headers.clone()));

        let factory = move || {
            let client = client.clone();
            let cookie_store = cookie_store.clone();
            let headers = Arc::clone(&headers);
            let url = url.clone();
            let body = body.clone();
            let method = method.clone();
            async move {
                let mut req = client.request(method, &url);
                if let Some(ref b) = body {
                    req = req.body(b.clone());
                }
                if let Some(t) = timeout {
                    req = req.timeout(t);
                }
                req = apply_default_headers_static(req);
                req = apply_custom_headers(req, (*headers).clone());
                req = apply_cookie_static(req, &cookie_store, &url);
                req.send().await
            }
        };

        self.execute_with_retry_and_limit(&request.url, factory)
            .await
    }

    /// 创建使用自定义代理的客户端副本（对应 Kotlin `getProxyClient`）
    pub fn with_proxy(&self, proxy_url: &str) -> LegadoResult<Self> {
        let mut config = self.config.clone();
        config.proxy = Some(ProxyConfig::from_url(proxy_url));
        Self::new(config)
    }

    // ---------- 内部方法 ----------

    /// 尝试通过 QUIC/HTTP3 发送 GET 请求
    ///
    /// 返回 `Some(Ok(response))` 表示 QUIC 成功，
    /// 返回 `None` 表示应 fallback 到 reqwest 路径（QUIC 未启用/非 HTTPS/连接失败）。
    async fn try_quic_get(
        &self,
        url: &str,
        headers: Option<&HashMap<String, String>>,
    ) -> Option<LegadoResult<LegadoResponse>> {
        let quic = self.quic_client.as_ref()?;
        if !is_https_url(url) {
            return None;
        }

        log::debug!("尝试 QUIC GET: {}", url);
        match quic.get(url, headers.cloned()).await {
            Ok(quinn_resp) => {
                log::debug!("QUIC GET 成功: {} (status={})", url, quinn_resp.status);
                Some(Ok(quinn_response_to_legado(quinn_resp)))
            }
            Err(e) => {
                // QUIC 失败不向上抛错，记录日志后 fallback
                log::warn!("QUIC GET 失败，fallback 到 HTTP/2: {} | 错误: {}", url, e);
                None
            }
        }
    }

    /// 尝试通过 QUIC/HTTP3 发送 POST 请求
    ///
    /// 返回 `Some(Ok(response))` 表示 QUIC 成功，
    /// 返回 `None` 表示应 fallback 到 reqwest 路径。
    async fn try_quic_post(
        &self,
        url: &str,
        body: &str,
        headers: Option<&HashMap<String, String>>,
    ) -> Option<LegadoResult<LegadoResponse>> {
        let quic = self.quic_client.as_ref()?;
        if !is_https_url(url) {
            return None;
        }

        log::debug!("尝试 QUIC POST: {}", url);
        match quic.post(url, body.as_bytes(), headers.cloned()).await {
            Ok(quinn_resp) => {
                log::debug!("QUIC POST 成功: {} (status={})", url, quinn_resp.status);
                Some(Ok(quinn_response_to_legado(quinn_resp)))
            }
            Err(e) => {
                // QUIC 失败不向上抛错，记录日志后 fallback
                log::warn!("QUIC POST 失败，fallback 到 HTTP/2: {} | 错误: {}", url, e);
                None
            }
        }
    }

    /// 带重试和限流的请求执行核心
    ///
    /// `factory` 是一个请求工厂：每次调用时重建 RequestBuilder 并发送，
    /// 以支持重试时重新发起请求（`RequestBuilder` 在 `send()` 后被消费）。
    async fn execute_with_retry_and_limit<F, Fut>(
        &self,
        url: &str,
        factory: F,
    ) -> LegadoResult<LegadoResponse>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<reqwest::Response, reqwest::Error>>,
    {
        // 限流：获取域名许可（在整个重试期间持有）
        let _permit = if let Some(ref limiter) = self.domain_rate_limiter {
            let domain = crate::rate_limit::extract_domain(url);
            let slot = limiter.get_or_create(&domain);
            Some(slot.acquire().await?)
        } else {
            None
        };

        let raw_response = if let Some(ref executor) = self.retry_executor {
            executor
                .execute_with_retry(|| async { factory().await.map_err(map_reqwest_error) })
                .await?
        } else {
            factory().await.map_err(map_reqwest_error)?
        };

        self.collect_response(raw_response, url).await
    }

    /// 收集响应数据并保存 Cookie
    async fn collect_response(
        &self,
        response: reqwest::Response,
        original_url: &str,
    ) -> LegadoResult<LegadoResponse> {
        let final_url = response.url().to_string();
        let status = response.status().as_u16();

        // 收集响应头
        let mut headers = HashMap::new();
        for (name, value) in response.headers() {
            if let Ok(v) = value.to_str() {
                headers.insert(name.as_str().to_string(), v.to_string());
            }
        }

        // 保存 Set-Cookie 到 CookieStore
        self.save_cookies_from_response(original_url, &final_url, &headers);

        // 读取响应体
        let body = response
            .text()
            .await
            .map_err(|e| LegadoError::Network(format!("Failed to read response body: {}", e)))?;

        Ok(LegadoResponse {
            status,
            headers,
            body,
            url: final_url,
        })
    }

    /// 从响应头中提取 Set-Cookie 并保存到 CookieStore
    fn save_cookies_from_response(
        &self,
        original_url: &str,
        final_url: &str,
        headers: &HashMap<String, String>,
    ) {
        // 优先使用 final_url 提取 domain
        let url_for_cookie = if final_url.is_empty() {
            original_url
        } else {
            final_url
        };

        // 从 headers 中收集 set-cookie
        let set_cookie_values: Vec<&String> = headers
            .iter()
            .filter(|(k, _)| k.to_lowercase() == "set-cookie")
            .map(|(_, v)| v)
            .collect();

        if set_cookie_values.is_empty() {
            return;
        }

        if let Ok(mut store) = self.cookie_store.write() {
            // 解析 domain
            let domain = extract_domain_for_cookie(url_for_cookie);
            for cookie_str in set_cookie_values {
                // 简单解析：取 `name=value` 部分
                if let Some(name_value) = cookie_str.split(';').next() {
                    let name_value = name_value.trim();
                    if let Some((name, value)) = name_value.split_once('=') {
                        store.set_cookie(crate::cookie_store::Cookie {
                            name: name.trim().to_string(),
                            value: value.trim().to_string(),
                            domain: domain.clone(),
                            path: "/".to_string(),
                            expires: None,
                            secure: false,
                            http_only: false,
                        });
                    }
                }
            }
        }
    }
}

/// 将 reqwest::Error 映射为 LegadoError
fn map_reqwest_error(e: reqwest::Error) -> LegadoError {
    if e.is_timeout() {
        LegadoError::Timeout(format!("Request timeout: {}", e))
    } else if e.is_connect() {
        LegadoError::Network(format!("Connection failed: {}", e))
    } else {
        LegadoError::Network(format!("Request failed: {}", e))
    }
}

/// 判断 URL 是否为 HTTPS 协议
///
/// QUIC 仅适用于 HTTPS，HTTP 明文请求不走 QUIC 路径。
fn is_https_url(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("HTTPS://")
}

/// 将 QuinnResponse 转换为 LegadoResponse
///
/// 两种响应结构字段一致，直接映射。
fn quinn_response_to_legado(resp: crate::quic::QuinnResponse) -> LegadoResponse {
    LegadoResponse {
        status: resp.status,
        headers: resp.headers,
        body: resp.body,
        url: resp.url,
    }
}

/// 应用默认请求头（静态版本，不依赖 &self）
fn apply_default_headers_static(req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    req.header("Keep-Alive", "300")
        .header("Connection", "Keep-Alive")
        .header("Cache-Control", "no-cache")
}

/// 将 CookieStore 中的 Cookie 注入到请求中（静态版本）
fn apply_cookie_static(
    req: reqwest::RequestBuilder,
    cookie_store: &Arc<RwLock<CookieStore>>,
    url: &str,
) -> reqwest::RequestBuilder {
    let cookie_string = {
        let store = cookie_store.read().ok();
        store.map(|s| s.get_cookie_string(url)).unwrap_or_default()
    };
    if cookie_string.is_empty() {
        req
    } else {
        req.header("Cookie", cookie_string)
    }
}

/// 应用自定义请求头
fn apply_custom_headers(
    mut req: reqwest::RequestBuilder,
    headers: Option<HashMap<String, String>>,
) -> reqwest::RequestBuilder {
    if let Some(hdrs) = headers {
        for (name, value) in hdrs {
            // 特殊处理: UA 为 "null" 时移除（对应 Kotlin 拦截器逻辑）
            if name.to_lowercase() == "user-agent" && value == "null" {
                continue;
            }
            req = req.header(&name, &value);
        }
    }
    req
}

/// 从 URL 提取 cookie domain（简化版）
fn extract_domain_for_cookie(url: &str) -> String {
    if let Ok(parsed) = url::Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            let parts: Vec<&str> = host.split('.').collect();
            if parts.len() >= 2 {
                return parts[parts.len() - 2..].join(".");
            }
            return host.to_string();
        }
    }
    url.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let cfg = LegadoClientConfig::default();
        assert_eq!(cfg.connect_timeout, Duration::from_secs(15));
        assert_eq!(cfg.read_timeout, Duration::from_secs(60));
        assert!(cfg.accept_invalid_certs);
        assert!(cfg.follow_redirects);
        assert!(cfg.retry.is_none());
        assert!(cfg.rate_limit.is_none());
    }

    #[test]
    fn test_build_client() {
        let client = LegadoClient::new(LegadoClientConfig::default());
        assert!(client.is_ok());
    }

    #[test]
    fn test_build_client_with_proxy() {
        let cfg = LegadoClientConfig {
            proxy: Some(ProxyConfig::from_url("http://127.0.0.1:7890")),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg);
        assert!(client.is_ok());
    }

    #[test]
    fn test_build_client_with_retry() {
        let cfg = LegadoClientConfig {
            retry: Some(RetryConfig::default()),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.retry_executor().is_some());
    }

    #[test]
    fn test_build_client_with_rate_limit() {
        let cfg = LegadoClientConfig {
            rate_limit: Some(5),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.domain_rate_limiter().is_some());
    }

    #[test]
    fn test_build_client_with_all_middleware() {
        let cfg = LegadoClientConfig {
            retry: Some(RetryConfig {
                max_retries: 5,
                ..Default::default()
            }),
            rate_limit: Some(10),
            proxy: Some(ProxyConfig::from_url("socks5://127.0.0.1:1080")),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg);
        assert!(client.is_ok());
        let client = client.unwrap();
        assert!(client.retry_executor().is_some());
        assert!(client.domain_rate_limiter().is_some());
    }

    #[test]
    fn test_build_client_with_user_agents() {
        let cfg = LegadoClientConfig {
            user_agents: Some(vec!["UA-Test/1.0".to_string(), "UA-Test/2.0".to_string()]),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.ua_rotator().is_some());
        assert!(client.middleware_chain().is_some());
        let rotator = client.ua_rotator().unwrap();
        assert_eq!(rotator.len(), 2);
    }

    #[test]
    fn test_build_client_with_proxy_pool() {
        let cfg = LegadoClientConfig {
            proxies: Some(vec![
                ProxyConfig::from_url("http://p1:8080"),
                ProxyConfig::from_url("http://p2:8080"),
            ]),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.proxy_pool().is_some());
        assert_eq!(client.proxy_pool().unwrap().len(), 2);
    }

    #[test]
    fn test_build_client_with_ssl_config() {
        let cfg = LegadoClientConfig {
            ssl: Some(SslConfig::unsafe_ssl()),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg);
        assert!(client.is_ok());
    }

    #[test]
    fn test_build_client_with_full_config() {
        let cfg = LegadoClientConfig {
            user_agents: Some(vec!["Bot/1.0".to_string()]),
            proxies: Some(vec![ProxyConfig::from_url("http://proxy:8080")]),
            ssl: Some(SslConfig::default()),
            retry: Some(RetryConfig::default()),
            rate_limit: Some(5),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.ua_rotator().is_some());
        assert!(client.proxy_pool().is_some());
        assert!(client.retry_executor().is_some());
        assert!(client.domain_rate_limiter().is_some());
        assert!(client.middleware_chain().is_some());
    }

    // ─── QUIC 集成测试 ───────────────────────────────────────────────

    #[test]
    fn test_default_config_quic_disabled() {
        // 默认配置不启用 QUIC
        let cfg = LegadoClientConfig::default();
        assert!(!cfg.enable_quic);
    }

    #[test]
    fn test_build_client_quic_disabled_no_quic_client() {
        // QUIC 关闭时，客户端不包含 QuinnClient
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        assert!(client.quic_client().is_none());
    }

    #[test]
    fn test_build_client_quic_enabled_has_quic_client() {
        // 配置显式启用 QUIC 时，客户端包含 QuinnClient
        let cfg = LegadoClientConfig {
            enable_quic: true,
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.quic_client().is_some());
    }

    #[test]
    fn test_global_quic_toggle() {
        // 全局开关控制 QUIC 启用
        set_quic_enabled(true);
        assert!(is_quic_enabled());

        // 全局启用后，默认配置创建的客户端也包含 QUIC
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        assert!(client.quic_client().is_some());

        // 关闭全局开关
        set_quic_enabled(false);
        assert!(!is_quic_enabled());

        // 关闭后新建客户端不包含 QUIC
        let client2 = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        assert!(client2.quic_client().is_none());
    }

    #[test]
    fn test_is_https_url() {
        assert!(is_https_url("https://example.com"));
        assert!(is_https_url("HTTPS://EXAMPLE.COM"));
        assert!(!is_https_url("http://example.com"));
        assert!(!is_https_url("ftp://example.com"));
        assert!(!is_https_url("example.com"));
    }

    #[test]
    fn test_quinn_response_to_legado_conversion() {
        let quinn_resp = crate::quic::QuinnResponse {
            status: 200,
            headers: HashMap::from([("content-type".to_string(), "text/html".to_string())]),
            body: "<html>hello</html>".to_string(),
            url: "https://example.com".to_string(),
        };
        let legado_resp = quinn_response_to_legado(quinn_resp);
        assert_eq!(legado_resp.status, 200);
        assert_eq!(legado_resp.body, "<html>hello</html>");
        assert_eq!(legado_resp.url, "https://example.com");
        assert_eq!(legado_resp.headers.get("content-type").unwrap(), "text/html");
    }

    #[tokio::test]
    async fn test_quic_fallback_on_non_https() {
        // QUIC 启用时，HTTP URL 不走 QUIC 路径（直接 fallback）
        let cfg = LegadoClientConfig {
            enable_quic: true,
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();
        assert!(client.quic_client().is_some());

        // 对非 HTTPS URL，try_quic_get 应返回 None（fallback）
        let result = client.try_quic_get("http://example.com", None).await;
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_quic_fallback_on_connection_failure() {
        // QUIC 启用时，对不支持 HTTP/3 的服务器应 fallback
        // 使用一个不可能支持 QUIC 的地址（本地回环 + 短超时）
        let cfg = LegadoClientConfig {
            enable_quic: true,
            connect_timeout: Duration::from_secs(2),
            ..Default::default()
        };
        let client = LegadoClient::new(cfg).unwrap();

        // 对不可达的 HTTPS 地址，try_quic_get 应返回 None（fallback）
        let result = client
            .try_quic_get("https://192.0.2.1:443", None)
            .await;
        assert!(result.is_none());
    }
}
