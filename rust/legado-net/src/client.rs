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
use std::time::{Duration, Instant};

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
    /// 强制直连（禁用系统/环境代理）。默认 false 沿用 reqwest 系统代理探测；
    /// 自定义 hosts 覆盖语义（§2.20.3）要求命中域名直连目标 IP，使用方
    /// （如 hosts e2e 测试）应置 true 防止系统代理架空 hosts 解析。
    pub no_proxy: bool,
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
            no_proxy: false,
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
        } else if config.no_proxy {
            // 强制直连：屏蔽系统/环境代理探测，保证 hosts 覆盖直连语义
            builder = builder.no_proxy();
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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
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

    /// 发送 POST 请求并返回无损原始字节（供 charset=gbk 等响应解码）
    pub async fn post_raw(
        &self,
        url: &str,
        body: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<crate::response::LegadoRawResponse> {
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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
                req.send().await
            }
        };

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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
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
                req = apply_headers_and_cookies(req, &cookie_store, &url, (*headers).clone());
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
        let t0 = Instant::now();

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

        // 分段计时：TTFB=发送到收到响应头；对端地址用于判断 IPv4/IPv6
        let ttfb = t0.elapsed();
        let remote = raw_response.remote_addr();

        let response = self.collect_response(raw_response, url).await?;

        let body_dur = t0.elapsed() - ttfb;
        crate::timing::emit_request(url, ttfb, body_dur, remote);

        Ok(response)
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
    ///
    /// **按域写通道（重要 1）**：先取该域串行锁（`domain_write_lock`，最外层
    /// D 锁），使「jar 更新 + 捕获全量串 + 持久化落库」对该域原子——并发的
    /// 同域写入者（HTTP jar 路径 / JS 宿主路径）不得在「捕获」与「落库」之间
    /// 插入，否则落库行会回退为过期视图（内存=NEW，重启回填=OLD）。
    /// 结构性不变式不回归：**jar 写锁临界区内仍不做 DB/sink 调用**——jar 锁
    /// 只覆盖更新/捕获，sink 调用在 jar 锁释放后、域通道锁内执行（锁序图见
    /// [`crate::cookie_store::DOMAIN_WRITE_LOCKS`] 文档）。
    ///
    /// **空视图不删行（重要 3）**：`cookies` 表的行与 JS 侧 `setCookie` 写入
    /// 共享（union 合并、同键 incoming 胜）。「空 jar 视图」仅说明**本次**
    /// Set-Cookie 未贡献可解析的 name=value，不能证明该行 jar 独占——整行
    /// 删除会抹掉 JS 侧键（进程内内存仍命中，重启后 JS 键丢失）。
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

        // 域键先解析（纯函数，无需持锁）
        let domain = extract_domain_for_cookie(url_for_cookie);

        // 按域写通道：最外层串行锁（D）——本域「捕获 + 写回」与并发的同域
        // 写入严格串行（drop 时放行；中毒恢复语义见 DOMAIN_WRITE_LOCKS 文档）
        let _domain_guard = crate::cookie_store::domain_write_lock(&domain);

        // 更新内存 CookieStore 并**在 jar 写锁内**捕获受影响域的全量 Cookie 串；
        // 持久化写回（DB 调用）放到**jar 锁释放后**（域通道锁仍持有）执行——
        // jar 锁临界区内不做 DB/sink 调用（避免与 cookie 合并写串行锁形成
        // 潜在锁环，池取连接等待也不得拖住 jar 读方）
        let cookie_string = {
            let Ok(mut store) = self.cookie_store.write() else {
                // 写锁 poisoned：与改造前一致，整体跳过本次写回
                return;
            };
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
            store.domain_cookie_string(&domain)
        };

        // 持久化写回（jar 写锁已释放、域通道锁内）：将变更域名的全部 Cookie
        // 序列化后 upsert 到后端（同步写入，单行 upsert 开销可接受；后端
        // 失败仅记日志不阻断请求）。
        // 视图为空时**不删行**（重要 3，见函数文档）：该行与 JS 侧共享，
        // 删除会抹掉 JS 键。
        if let Some(ref persistence) = self.cookie_persistence {
            if !cookie_string.is_empty() {
                persistence.save(&domain, &cookie_string);
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

/// 合并 DB Cookie 与规则/自定义 Cookie 头（**按键合并、规则优先**）
///
/// 对齐上游 `AnalyzeUrl.setCookie` 中 `mergeCookies(dbCookie, ruleCookie)`：
/// 同键冲突时规则值胜，非冲突键两者都保留；任一侧为空时原样返回另一侧
/// （避免无谓的重序列化）。
///
/// 该函数为纯函数，便于单测；实际注入见 [`apply_headers_and_cookies`]。
fn merge_cookie_headers(db_cookie: &str, rule_cookie: &str) -> String {
    if db_cookie.is_empty() {
        rule_cookie.to_string()
    } else if rule_cookie.is_empty() {
        db_cookie.to_string()
    } else {
        // merge_cookies_str(a, b)：b（规则）覆盖 a（DB）的同名键
        CookieStore::merge_cookies_str(db_cookie, rule_cookie)
            .unwrap_or_else(|| rule_cookie.to_string())
    }
}

/// 应用自定义请求头与 Cookie（对齐上游 `AnalyzeUrl.setCookie` 语义，静态版本）
///
/// - 默认头之外的自定义头**原样应用**（语义不变，含 UA=`"null"` 移除特判）；
/// - `Cookie` 头单独处理：DB 持久化 Cookie 与规则/自定义 Cookie **按键合并、
///   规则优先**（[`merge_cookie_headers`]），最后一次性注入，避免整体替换
///   导致规则 Cookie 丢失（P1-2 缺陷修复）。
fn apply_headers_and_cookies(
    mut req: reqwest::RequestBuilder,
    cookie_store: &Arc<RwLock<CookieStore>>,
    url: &str,
    headers: Option<HashMap<String, String>>,
) -> reqwest::RequestBuilder {
    // 规则/自定义 Cookie 头（键不区分大小写；无则为空串）
    let rule_cookie: String = headers
        .as_ref()
        .and_then(|h| {
            h.iter()
                .find(|(k, _)| k.to_lowercase() == "cookie")
                .map(|(_, v)| v.clone())
        })
        .unwrap_or_default();

    // 其余自定义头原样应用（跳过 Cookie，稍后统一合并注入）
    if let Some(hdrs) = headers {
        for (name, value) in hdrs {
            if name.to_lowercase() == "cookie" {
                continue; // Cookie 单独合并注入，避免整体替换
            }
            // 特殊处理: UA 为 "null" 时移除（对应 Kotlin 拦截器逻辑）
            if name.to_lowercase() == "user-agent" && value == "null" {
                continue;
            }
            req = req.header(&name, &value);
        }
    }

    // DB 持久化 Cookie
    let db_cookie = {
        let store = cookie_store.read().ok();
        store.map(|s| s.get_cookie_string(url)).unwrap_or_default()
    };

    // 合并注入：DB 与规则 Cookie 按键合并、规则优先
    let merged_cookie = merge_cookie_headers(&db_cookie, &rule_cookie);
    if merged_cookie.is_empty() {
        req
    } else {
        req.header("Cookie", merged_cookie)
    }
}

/// 从 URL 提取 cookie domain（ETLD+1，对齐上游 `NetworkUtils.getSubDomain`）
///
/// 解析失败时回退为 URL 本身（保持「仍能按原 URL 记录 Cookie」的旧行为）。
fn extract_domain_for_cookie(url: &str) -> String {
    crate::cookie_store::cookie_domain_key(url).unwrap_or_else(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 连接池复用验证：同一 host 的两次顺序请求应命中同一条 TCP 连接（keep-alive）
    ///
    /// 本地最小 HTTP/1.1 监听器统计 accept 次数：reqwest 池生效时 2 请求 → 仅 1
    /// accept；若每次新建连接则 2 accepts。该测试保证「共享客户端 + keep-alive」
    /// 在重复搜索时确实省去 connect+TLS（docs/LEGADO_NET_TIMING_2026-08-25.md §七）。
    #[tokio::test]
    async fn test_connection_pool_reuses_keep_alive() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let accepts = Arc::new(AtomicUsize::new(0));
        let server_accepts = accepts.clone();

        // 最小 HTTP/1.1 服务器：读请求头 → 200 keep-alive 响应；同一 socket 继续等下一个请求
        let server = tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            while let Ok((mut sock, _)) = listener.accept().await {
                server_accepts.fetch_add(1, Ordering::SeqCst);
                let mut head: Vec<u8> = Vec::new();
                // 单连接处理循环：连接断开/关闭时 break 'conn，外层继续 accept 下一连接
                'conn: loop {
                    head.clear();
                    // 逐字节读到 \r\n\r\n（GET 无请求体）；读失败或客户端关闭则未读全
                    let complete = loop {
                        let mut b = [0u8; 1];
                        let n = match sock.read(&mut b).await {
                            Ok(n) => n,
                            Err(_) => break false, // 读失败：连接已断
                        };
                        if n == 0 {
                            break false; // 客户端已关闭
                        }
                        head.push(b[0]);
                        if head.ends_with(b"\r\n\r\n") {
                            break true;
                        }
                    };
                    if !complete {
                        break 'conn; // 连接断开/关闭：结束本连接，等待下一 accept
                    }
                    let resp =
                        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok";
                    if sock.write_all(resp).await.is_err() {
                        break 'conn; // 写失败：连接已断
                    }
                }
            }
        });

        // no_proxy=true：回环测试流量不得经系统/环境变量代理路由
        //（2026-09-19 死代理实测：HTTP_PROXY 存在时本用例 127.0.0.1 流量被代理劫持而失败）
        let client = LegadoClient::new(LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        })
        .unwrap();
        let r1 = client.get(&format!("http://{addr}/r1"), None).await;
        let r2 = client.get(&format!("http://{addr}/r2"), None).await;
        assert!(r1.is_ok() && r2.is_ok());

        assert_eq!(
            accepts.load(Ordering::SeqCst),
            1,
            "两次顺序请求应复用同一条 keep-alive 连接（仅一次 accept）"
        );
        // 断言已完成。服务器任务此刻仍阻塞在读请求/accept 上；drop 句柄后
        // 任务随 #[tokio::test] 的 runtime 销毁被取消，不悬挂、不影响断言
        drop(server);
    }

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
            proxy: Some(
                crate::proxy::parse_proxy_config("socks5://alice:secret@127.0.0.1:1080").unwrap(),
            ),
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

        // no_proxy=true：回环测试流量不得经系统/环境变量代理路由
        //（2026-09-19 死代理实测：HTTP_PROXY 存在时本用例 127.0.0.1 流量被代理劫持而失败）
        let client = LegadoClient::new(LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        })
        .unwrap();
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

    // ─── 重要 1：并发同域双写（per-domain 写通道） ─────────────

    /// 并发测试用：带「过期捕获慢落库」闸门的假持久化后端
    ///
    /// 写回串缺少全量标记（= 过期捕获，未含另一线程的键）时 `save` 延迟
    /// `slow_ms`——修复前确定性地制造「过期落库最后落库」的交错：另一线程的
    /// 全量串（快速落库）已在延迟窗口内完成，最后落库必为过期视图；
    /// 修复后（`domain_write_lock` 按域串行锁）两线程严格串行：先取锁者捕获
    /// 必为单键（慢落库、先落库），后取锁者捕获必为全量串（快落库、最后
    /// 落库），最终落库行 = 内存终态。
    struct GatedPersistence {
        data: Mutex<HashMap<String, String>>,
        /// 全量串标记：写回串包含之 = 全量捕获 → 立即落库；否则慢落库
        fast_when_contains: String,
        /// 慢落库时长（毫秒）
        slow_ms: u64,
    }

    impl crate::cookie_store::CookiePersistence for GatedPersistence {
        fn load_all(&self) -> Vec<(String, String)> {
            let guard = self.data.lock().unwrap();
            guard.iter().map(|(k, v)| (k.clone(), v.clone())).collect()
        }

        fn save(&self, tag: &str, cookie: &str) {
            // 闸门：过期捕获（缺少全量标记）→ 慢落库，拉大窗口强制交错
            if !cookie.contains(&self.fast_when_contains) {
                std::thread::sleep(std::time::Duration::from_millis(self.slow_ms));
            }
            self.data
                .lock()
                .unwrap()
                .insert(tag.to_string(), cookie.to_string());
        }

        fn delete(&self, tag: &str) {
            self.data.lock().unwrap().remove(tag);
        }
    }

    /// Cookie 串按键值对排序（顺序无关的等价断言辅助）
    fn cookie_set_sorted(cookie_str: &str) -> Vec<String> {
        let mut parts: Vec<String> = cookie_str
            .split(';')
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        parts.sort();
        parts
    }

    /// 重要 1：并发同域双写，persist 后的最终状态必须等于内存终态
    ///
    /// **修复前（必红）**：无按域串行锁时，先完成 jar 写入的线程捕获「过期
    /// 视图」（写回串缺另一线程的键）→ 被慢落库闸门拖延，最后落库必为该
    /// 过期视图 → 落库行回退（内存含双键，落库行只有单键，重启回填=旧值），
    /// 断言必红；
    /// **修复后（必绿）**：`domain_write_lock` 使两线程严格串行，后取锁者
    /// 捕获必为全量串并最后落库 → 落库行 = 内存终态。
    #[test]
    fn test_concurrent_same_domain_persist_equals_memory() {
        const URL: &str = "https://www.concurrent-write.test/";
        let domain = extract_domain_for_cookie(URL);

        let persistence = Arc::new(GatedPersistence {
            data: Mutex::new(HashMap::new()),
            fast_when_contains: "kB=".to_string(),
            slow_ms: 200,
        });
        let client = Arc::new(
            LegadoClient::with_cookie_persistence(
                LegadoClientConfig::default(),
                persistence.clone(),
            )
            .unwrap(),
        );

        let mut a_headers = HashMap::new();
        a_headers.insert("Set-Cookie".to_string(), "kA=A".to_string());
        let mut b_headers = HashMap::new();
        b_headers.insert("Set-Cookie".to_string(), "kB=B".to_string());

        let c_a = client.clone();
        let c_b = client.clone();
        let handle_a = std::thread::spawn(move || {
            c_a.save_cookies_from_response(URL, URL, &a_headers);
        });
        let handle_b = std::thread::spawn(move || {
            c_b.save_cookies_from_response(URL, URL, &b_headers);
        });
        handle_a.join().unwrap();
        handle_b.join().unwrap();

        // 内存终态（两线程 jar 写入均已完成）
        let memory = {
            let store = client.cookie_store().read().unwrap();
            store.domain_cookie_string(&domain)
        };
        let saved = persistence
            .data
            .lock()
            .unwrap()
            .get(&domain)
            .cloned()
            .unwrap_or_default();

        // persist 后的最终落库状态必须等于内存终态
        assert_eq!(
            cookie_set_sorted(&saved),
            cookie_set_sorted(&memory),
            "并发同域双写：persist 后的最终落库状态必须等于内存终态（修复前过期落库可最后落库）: persisted={saved}, memory={memory}"
        );
        // 且落库行必须含双写两个键
        let saved_set = cookie_set_sorted(&saved);
        assert!(
            saved_set.contains(&"kA=A".to_string()) && saved_set.contains(&"kB=B".to_string()),
            "落库行必须含并发双写的两个键: {saved_set:?}"
        );
    }

    // ─── 重要 3：空 jar 视图不得删除共享行 ─────────────────────

    /// 重要 3：空 jar 视图（Set-Cookie 无可解析 name=value，如 `Secure; Path=/`）
    /// 不得删除该域的整条共享行
    ///
    /// 同一 DB 行由 JS 侧（sink upsert）与 HTTP jar 写回共同写入
    /// （union 合并、同键 incoming 胜）。「jar 视图为空」只说明**本次**
    /// Set-Cookie 未贡献可解析的 name=value，不能证明该行 jar 独占——
    /// 整行删除会抹掉 JS 侧 `setCookie` 写入的键（进程内内存仍命中，
    /// 重启后 JS 键丢失）。
    #[test]
    fn test_empty_jar_view_does_not_delete_shared_row() {
        let persistence = Arc::new(MockPersistence::default());
        let client = LegadoClient::with_cookie_persistence(
            LegadoClientConfig::default(),
            persistence.clone(),
        )
        .unwrap();

        // 模拟 JS 侧已为该域写入一个键（持久化层已有该行，且未经过 jar：
        // 客户端构建在预置行之前，jar 内该域为空）
        persistence.save("example.com", "js_key=js_val");

        // 触发一次「空 jar 视图」保存：Set-Cookie 无 name=value（解析被跳过）
        let mut headers = HashMap::new();
        headers.insert("Set-Cookie".to_string(), "Secure; Path=/".to_string());
        client.save_cookies_from_response(
            "https://www.example.com/page",
            "https://www.example.com/page",
            &headers,
        );

        let persisted = persistence.data.lock().unwrap();
        assert_eq!(
            persisted.get("example.com").map(String::as_str),
            Some("js_key=js_val"),
            "空 jar 视图不得删除共享行（该行含 JS 侧键；修复前整行删除导致 JS 键丢失）: {:?}",
            persisted.get("example.com")
        );
    }

    // ─── P1-1 复现：多段 TLD 站点 Cookie 隔离 ─────────────────

    /// P1-1 最小复现：两个不同 `.com.cn` 站各 Set-Cookie 一次后互访，
    /// 不应携带对方 Cookie，且持久化后端应为两条独立域名行（非塌缩的 `com.cn`）。
    #[test]
    fn test_multi_tld_sites_cookies_isolated_p1_1_repro() {
        let persistence = Arc::new(MockPersistence::default());
        let client = LegadoClient::with_cookie_persistence(
            LegadoClientConfig::default(),
            persistence.clone(),
        )
        .unwrap();

        // a 站 Set-Cookie
        let mut a_headers = HashMap::new();
        a_headers.insert("Set-Cookie".to_string(), "siteA=alice".to_string());
        client.save_cookies_from_response(
            "https://a.example.com.cn/",
            "https://a.example.com.cn/",
            &a_headers,
        );
        // b 站 Set-Cookie
        let mut b_headers = HashMap::new();
        b_headers.insert("Set-Cookie".to_string(), "siteB=bob".to_string());
        client.save_cookies_from_response(
            "https://b.other.com.cn/",
            "https://b.other.com.cn/",
            &b_headers,
        );

        // 持久化后端：应为两条独立域名行，而非塌缩成单行 `com.cn`
        let persisted = persistence.data.lock().unwrap();
        assert!(
            persisted.contains_key("example.com.cn"),
            "a 站域名行应为 example.com.cn"
        );
        assert!(
            persisted.contains_key("other.com.cn"),
            "b 站域名行应为 other.com.cn"
        );
        assert!(
            !persisted.contains_key("com.cn"),
            "不应存在塌缩的 com.cn 行"
        );
        drop(persisted);

        // 互访：各站请求 Cookie 仅携带自身 Cookie
        let store = client.cookie_store().read().unwrap();
        let a_cookie = store.get_cookie_string("https://a.example.com.cn/");
        let b_cookie = store.get_cookie_string("https://b.other.com.cn/");
        assert!(
            a_cookie.contains("siteA=alice"),
            "a 站应携带自身 cookie: {a_cookie}"
        );
        assert!(
            !a_cookie.contains("siteB=bob"),
            "a 站不应携带 b 站 cookie: {a_cookie}"
        );
        assert!(
            b_cookie.contains("siteB=bob"),
            "b 站应携带自身 cookie: {b_cookie}"
        );
        assert!(
            !b_cookie.contains("siteA=alice"),
            "b 站不应携带 a 站 cookie: {b_cookie}"
        );
    }

    // ─── P1-2：规则 Cookie 优先合并 ──────────────────────────

    /// P1-2 单测：`merge_cookie_headers` 按键合并、规则优先
    #[test]
    fn test_merge_cookie_headers_rule_priority_p1_2() {
        // 规则为空 → DB 原样
        assert_eq!(merge_cookie_headers("a=1; b=2", ""), "a=1; b=2");
        // DB 为空 → 规则原样
        assert_eq!(merge_cookie_headers("", "token=rule"), "token=rule");
        // 双方均空 → 空
        assert_eq!(merge_cookie_headers("", ""), "");
        // 同键冲突规则胜 + 非冲突键都保留
        let merged = merge_cookie_headers("a=1; b=2", "b=3; c=4");
        let map = crate::cookie_store::CookieStore::cookie_string_to_map(&merged);
        assert_eq!(
            map.get("a"),
            Some(&"1".to_string()),
            "DB 独有键应保留: {merged}"
        );
        assert_eq!(
            map.get("b"),
            Some(&"3".to_string()),
            "同键冲突应规则值胜: {merged}"
        );
        assert_eq!(
            map.get("c"),
            Some(&"4".to_string()),
            "规则独有键应保留: {merged}"
        );
        // 防「拼接式」误实现（`"{db}; {rule}"` 也能通过上面的 map 断言）：
        // 同键只允许出现一次，且 DB 旧值不得残留
        assert_eq!(
            merged.matches("b=").count(),
            1,
            "同键不得出现两次: {merged}"
        );
        assert!(
            !merged.contains("b=2"),
            "冲突键的 DB 值必须被覆盖: {merged}"
        );
    }

    /// P1-2 端到端：DB Cookie 与规则 Cookie 头同时存在时，请求实际携带的是
    /// 按键合并（规则优先）后的结果，而非 DB 整体替换。
    #[tokio::test]
    async fn test_cookie_merge_rule_priority_e2e_p1_2() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        // 最小 HTTP 服务器：读请求头，将收到的 Cookie 头原样回显为响应体
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mut head: Vec<u8> = Vec::new();
                loop {
                    let mut b = [0u8; 1];
                    let n = match sock.read(&mut b).await {
                        Ok(n) => n,
                        Err(_) => return,
                    };
                    if n == 0 {
                        return;
                    }
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head).to_string();
                let cookie_value = head_str
                    .lines()
                    .find(|l| l.to_lowercase().starts_with("cookie:"))
                    .map(|l| {
                        l.split_once(':')
                            .map(|(_, v)| v)
                            .unwrap_or("")
                            .trim()
                            .to_string()
                    })
                    .unwrap_or_default();
                let body = format!("Cookie: {cookie_value}");
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                if sock.write_all(resp.as_bytes()).await.is_err() {
                    return;
                }
                let _ = sock.shutdown().await;
            }
        });

        // 预置 DB Cookie（IP 域名键为 127.0.0.1）
        let persistence = Arc::new(MockPersistence::default());
        persistence.save("127.0.0.1", "dbcookie=fromDB; dbonly=dbvalue");
        let client = LegadoClient::with_cookie_persistence(
            LegadoClientConfig {
                no_proxy: true,
                ..LegadoClientConfig::default()
            },
            persistence,
        )
        .unwrap();

        // 规则 Cookie 头：与 DB 的 dbcookie 冲突（规则应胜）+ 规则独有键
        let mut headers = HashMap::new();
        headers.insert(
            "Cookie".to_string(),
            "dbcookie=fromRule; ruleonly=rulevalue".to_string(),
        );

        let resp = client
            .get(&format!("http://{addr}/"), Some(headers))
            .await
            .expect("请求回显 Cookie 服务器失败");
        let body = resp.body.as_str();
        assert!(
            body.contains("dbcookie=fromRule"),
            "同键冲突应规则 Cookie 胜: {body}"
        );
        assert!(
            !body.contains("dbcookie=fromDB"),
            "DB 同名 Cookie 应被规则覆盖: {body}"
        );
        assert!(
            body.contains("ruleonly=rulevalue"),
            "规则独有 Cookie 应保留: {body}"
        );
        assert!(
            body.contains("dbonly=dbvalue"),
            "DB 非冲突 Cookie 应保留: {body}"
        );
    }

    /// P3-4 钉死：非 Cookie 自定义头（Referer/X-*）经 `apply_headers_and_cookies`
    /// 仍原样到达服务端；UA="null" 不下发（保留旧拦截器语义，防合并重构误伤）
    #[tokio::test]
    async fn test_custom_headers_preserved_and_null_ua_skipped() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        // 最小 HTTP 服务器：把收到的请求头整体回显为响应体
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = listener.accept().await {
                let mut head: Vec<u8> = Vec::new();
                loop {
                    let mut b = [0u8; 1];
                    let n = match sock.read(&mut b).await {
                        Ok(n) => n,
                        Err(_) => return,
                    };
                    if n == 0 {
                        return;
                    }
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let body = String::from_utf8_lossy(&head).to_string();
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                if sock.write_all(resp.as_bytes()).await.is_err() {
                    return;
                }
                let _ = sock.shutdown().await;
            }
        });

        let client = LegadoClient::new(LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        })
        .unwrap();

        // 自定义头：Referer / X-* 必须到达；UA="null" 必须被跳过（不下发字面 "null"）
        let mut headers = HashMap::new();
        headers.insert(
            "Referer".to_string(),
            "https://referer.example/".to_string(),
        );
        headers.insert("X-Custom".to_string(), "v1".to_string());
        headers.insert("user-agent".to_string(), "null".to_string());

        let resp = client
            .get(&format!("http://{addr}/"), Some(headers))
            .await
            .expect("请求回显服务器失败");
        let body = resp.body.to_ascii_lowercase();
        assert!(
            body.contains("referer: https://referer.example/"),
            "Referer 自定义头应到达: {}",
            resp.body
        );
        assert!(
            body.contains("x-custom: v1"),
            "X-* 自定义头应到达: {}",
            resp.body
        );
        assert!(
            !body.contains("user-agent: null"),
            "UA=\"null\" 不应下发（沿用旧拦截器跳过语义）: {}",
            resp.body
        );
    }
}
