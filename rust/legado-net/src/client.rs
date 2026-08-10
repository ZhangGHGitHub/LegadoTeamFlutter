//! HTTP 客户端封装模块
//!
//! 参考 Kotlin `HttpHelper.kt` 基于 reqwest 构建，特性包括：
//! - 可配置的超时、UA、代理（含 SOCKS5 用户名/密码认证）
//! - 信任所有证书（与原 Kotlin SSLHelper.unsafeSSLSocketFactory 一致）
//! - 自动重定向
//! - 透明解压缩（gzip/brotli/deflate，对齐上游 OkHttp）
//! - Cookie 管理集成（可选 DB 持久化，由上层注入 [`CookiePersistence`]）
//! - 默认 Keep-Alive / Cache-Control 头
//! - 可选重试（指数退避）和按域名限流
//! - UA 轮换与代理池中间件
//! - SSL/TLS 配置（证书验证控制、自定义 CA）

use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use reqwest::redirect::Policy;
use reqwest::ClientBuilder;

use legado_core::{LegadoError, LegadoResult};

use crate::cookie_store::{CookiePersistence, CookieStore};
use crate::middleware::MiddlewareChain;
use crate::proxy::{ProxyConfig, ProxyMiddleware, ProxyPool};
use crate::rate_limit::DomainRateLimiter;
use crate::response::LegadoResponse;
use crate::retry::{RetryConfig, RetryExecutor};
use crate::ssl_config::SslConfig;
use crate::user_agent::{UserAgentMiddleware, UserAgentRotator};

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
        }
    }
}

/// Legado HTTP 客户端
///
/// 基于 `reqwest::Client`，附带 Cookie 存储、可选重试、按域名限流，
/// 以及可选的 UA 轮换和代理池中间件。
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
    /// Cookie 持久化后端（可选，由上层注入，如 legado-ffi 的 DB 实现）
    cookie_persistence: Option<Arc<dyn CookiePersistence>>,
}

impl LegadoClient {
    /// 根据配置创建新的 HTTP 客户端
    pub fn new(config: LegadoClientConfig) -> LegadoResult<Self> {
        Self::build(config, None)
    }

    /// 创建带 Cookie 持久化后端的 HTTP 客户端
    ///
    /// 构建时立即从后端加载已持久化的 Cookie 到内存 CookieStore；
    /// 后续响应中的 Set-Cookie 变更会同步写回后端（按域名 upsert）。
    pub fn with_cookie_persistence(
        config: LegadoClientConfig,
        persistence: Arc<dyn CookiePersistence>,
    ) -> LegadoResult<Self> {
        Self::build(config, Some(persistence))
    }

    /// 内部构建入口：可选携带 Cookie 持久化后端
    fn build(
        config: LegadoClientConfig,
        cookie_persistence: Option<Arc<dyn CookiePersistence>>,
    ) -> LegadoResult<Self> {
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

        // 自定义 hosts DNS 覆盖（契约 §2.20.3，Task #73）：
        // resolver 每次解析实时读取全局映射，setCustomHosts 变更对已构建
        // 的客户端即时生效（命中映射直连 IP，未命中回落系统 DNS）
        builder = builder.dns_resolver(crate::custom_hosts::resolver());

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

        // Cookie 持久化：启动时从后端加载到内存 CookieStore
        let cookie_store = {
            let mut store = CookieStore::new();
            if let Some(ref persistence) = cookie_persistence {
                let entries = persistence.load_all();
                let count = entries.len();
                store.load_persisted(entries);
                log::info!("从持久化后端加载 {} 条域名 Cookie 记录", count);
            }
            Arc::new(RwLock::new(store))
        };

        Ok(Self {
            client,
            cookie_store,
            config,
            retry_executor,
            domain_rate_limiter,
            middleware_chain,
            ua_rotator,
            proxy_pool,
            cookie_persistence,
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

    /// 获取 Cookie 持久化后端引用（如有）
    pub fn cookie_persistence(&self) -> Option<&Arc<dyn CookiePersistence>> {
        self.cookie_persistence.as_ref()
    }

    /// 获取重试执行器引用（如有）
    pub fn retry_executor(&self) -> Option<&Arc<RetryExecutor>> {
        self.retry_executor.as_ref()
    }

    /// 获取域名限流器引用（如有）
    pub fn domain_rate_limiter(&self) -> Option<&Arc<DomainRateLimiter>> {
        self.domain_rate_limiter.as_ref()
    }

    /// 发送 GET 请求
    pub async fn get(
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

    /// 发送 GET 请求并返回无损原始字节响应（Task #113：TTS 音频等二进制资源）
    ///
    /// 与 [`get_bytes`](Self::get_bytes) 的区别：本方法直接读取 `resp.bytes()`，
    /// 不经过 UTF-8 文本解码（避免二进制音频被有损转换），并保留状态码/响应头，
    /// 保留重试与限流机制。
    pub async fn get_raw(
        &self,
        url: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<crate::response::LegadoRawResponse> {
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

        // 限流：获取域名许可（在整个重试期间持有）
        let _permit = if let Some(ref limiter) = self.domain_rate_limiter {
            let domain = crate::rate_limit::extract_domain(&url_for_retry);
            let slot = limiter.get_or_create(&domain);
            Some(slot.acquire().await?)
        } else {
            None
        };

        let response = if let Some(ref executor) = self.retry_executor {
            executor
                .execute_with_retry(|| async { factory().await.map_err(map_reqwest_error) })
                .await?
        } else {
            factory().await.map_err(map_reqwest_error)?
        };

        self.collect_raw_response(response, &url_for_retry).await
    }

    /// 发送 POST 请求
    pub async fn post(
        &self,
        url: &str,
        body: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<LegadoResponse> {
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
    ///
    /// 保留原客户端的 Cookie 持久化后端（共享同一 `Arc`）。
    pub fn with_proxy(&self, proxy_url: &str) -> LegadoResult<Self> {
        let mut config = self.config.clone();
        config.proxy = Some(ProxyConfig::from_url(proxy_url));
        Self::build(config, self.cookie_persistence.clone())
    }

    // ---------- 内部方法 ----------

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

    /// 收集二进制响应数据并保存 Cookie（Task #113：无损字节读取，对照 [`collect_response`](Self::collect_response)）
    async fn collect_raw_response(
        &self,
        response: reqwest::Response,
        original_url: &str,
    ) -> LegadoResult<crate::response::LegadoRawResponse> {
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

        // 读取原始字节（不经 UTF-8 解码）
        let body = response
            .bytes()
            .await
            .map_err(|e| LegadoError::Network(format!("Failed to read response bytes: {}", e)))?
            .to_vec();

        Ok(crate::response::LegadoRawResponse {
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

            // 持久化写回：将变更域名的全部 Cookie 序列化后 upsert 到后端
            //（同步写入，单行 upsert 开销可接受；后端失败仅记日志不阻断请求）
            if let Some(ref persistence) = self.cookie_persistence {
                let cookie_string = store.domain_cookie_string(&domain);
                if cookie_string.is_empty() {
                    persistence.delete(&domain);
                } else {
                    persistence.save(&domain, &cookie_string);
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
    use std::sync::Mutex;

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
    fn test_build_client_with_socks5_credentials() {
        // SOCKS5 携带 user:pass 凭据的客户端应构建成功
        //（reqwest socks feature 原生解析代理 URL 中的凭据，不实际连接）
        let cfg = LegadoClientConfig {
            proxy: Some(crate::proxy::parse_proxy_config(
                "socks5://alice:secret@127.0.0.1:1080",
            ).unwrap()),
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

    // ─── gzip 透明解压缩测试 ──────────────────────────────

    /// 启动一个一次性本地 HTTP 服务器，返回 gzip 压缩的响应体
    ///
    /// 返回监听地址（如 `127.0.0.1:53211`）。验证 reqwest 启用 gzip feature 后
    /// 自动设置 Accept-Encoding 并透明解压响应体（对齐上游 OkHttp 行为）。
    async fn spawn_gzip_server(plain_body: &'static str) -> std::net::SocketAddr {
        use flate2::write::GzEncoder;
        use flate2::Compression;
        use std::io::Write;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        // 预构造 gzip 压缩体
        let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(plain_body.as_bytes()).unwrap();
        let gzipped = encoder.finish().unwrap();

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                // 读取请求头（简化：读到空行为止，不关心具体内容）
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                // 返回 gzip 压缩响应（仅支持单次请求）
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    gzipped.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.write_all(&gzipped).await;
                let _ = stream.flush().await;
            }
        });
        addr
    }

    #[tokio::test]
    async fn test_gzip_response_decompressed() {
        let plain = "你好，这是一段用于验证 gzip 透明解压的响应文本。hello gzip!";
        let addr = spawn_gzip_server(plain).await;

        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        let resp = client
            .get(&format!("http://{}/", addr), None)
            .await
            .expect("请求 gzip 服务器失败");
        assert_eq!(resp.status, 200);
        // reqwest 应已透明解压：body 为原始明文而非压缩字节
        assert_eq!(resp.body, plain);
    }

    // ─── Cookie 持久化测试（内存模拟后端） ────────────────────

    /// 测试用内存持久化后端
    #[derive(Default)]
    struct MockPersistence {
        data: Mutex<HashMap<String, String>>,
    }

    impl crate::cookie_store::CookiePersistence for MockPersistence {
        fn load_all(&self) -> Vec<(String, String)> {
            let guard = self.data.lock().unwrap();
            guard.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
        }

        fn save(&self, tag: &str, cookie: &str) {
            self.data
                .lock()
                .unwrap()
                .insert(tag.to_string(), cookie.to_string());
        }

        fn delete(&self, tag: &str) {
            self.data.lock().unwrap().remove(tag);
        }
    }

    #[test]
    fn test_cookie_persistence_load_on_build() {
        // 后端预置 Cookie，构建客户端时应载入内存 CookieStore
        let persistence = Arc::new(MockPersistence::default());
        persistence.save("example.com", "session=abc123; theme=dark");

        let client = LegadoClient::with_cookie_persistence(
            LegadoClientConfig::default(),
            persistence.clone(),
        )
        .unwrap();
        let store = client.cookie_store().read().unwrap();
        assert_eq!(
            store.get_key("example.com", "session"),
            Some("abc123".to_string())
        );
        assert_eq!(
            store.get_key("example.com", "theme"),
            Some("dark".to_string())
        );
    }

    #[test]
    fn test_cookie_persistence_writeback_on_set_cookie() {
        // 模拟响应 Set-Cookie 后应写回后端
        let persistence = Arc::new(MockPersistence::default());
        let client = LegadoClient::with_cookie_persistence(
            LegadoClientConfig::default(),
            persistence.clone(),
        )
        .unwrap();

        let mut headers = HashMap::new();
        headers.insert("set-cookie".to_string(), "token=xyz789".to_string());
        client.save_cookies_from_response(
            "https://www.example.com/page",
            "https://www.example.com/page",
            &headers,
        );

        // 内存与后端均应包含新 Cookie
        let store = client.cookie_store().read().unwrap();
        assert_eq!(
            store.get_key("example.com", "token"),
            Some("xyz789".to_string())
        );
        drop(store);
        let saved = persistence.data.lock().unwrap().get("example.com").cloned();
        assert_eq!(saved, Some("token=xyz789".to_string()));
    }

    #[test]
    fn test_cookie_persistence_not_attached_by_default() {
        // 默认构建不携带持久化后端，行为不变
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        assert!(client.cookie_persistence().is_none());
    }
}
