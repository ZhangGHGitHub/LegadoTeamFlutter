//! 代理池管理
//!
//! 支持 HTTP / HTTPS / SOCKS5 代理类型，提供轮询和伪随机选择策略，
//! 并可作为中间件自动为请求分配代理。
//!
//! SOCKS5 支持用户名/密码认证（对齐上游 `HttpProxyConfig.kt` 的凭据校验逻辑
//! 与 `Socks5Proxy.kt` 的认证实现）：
//! - 标准 URI 格式：`socks5://user:pass@host:port`
//! - 上游遗留格式：`socks5://host:port@user@pass`
//!
//! reqwest 的 `socks` feature 原生支持代理 URL 中的 `user:pass` 凭据形式，
//! 因此认证在 reqwest/hyper 层完成，无需自行实现 SOCKS5 握手。

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::SystemTime;

use legado_core::{LegadoError, LegadoResult};
use regex::Regex;
use reqwest::{RequestBuilder, Response};
use url::Url;

use crate::middleware::{Middleware, Next};

/// 代理类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyType {
    /// HTTP 代理
    Http,
    /// HTTPS 代理
    Https,
    /// SOCKS5 代理
    Socks5,
}

impl ProxyType {
    /// 从 URL scheme 推断代理类型
    pub fn from_url(url: &str) -> Self {
        let lower = url.to_lowercase();
        if lower.starts_with("socks5://") || lower.starts_with("socks5h://") {
            ProxyType::Socks5
        } else if lower.starts_with("https://") {
            ProxyType::Https
        } else {
            ProxyType::Http
        }
    }
}

/// 代理认证凭据
///
/// 对应上游 `HttpProxyConfig.kt` 的 `ProxyCredentials`。
/// Debug 输出屏蔽密码，避免凭据泄漏到日志。
#[derive(Clone, PartialEq, Eq)]
pub struct ProxyCredentials {
    /// 用户名（UTF-8 字节长度须在 1..=255，SOCKS5 协议限制）
    pub username: String,
    /// 密码（UTF-8 字节长度须在 1..=255，SOCKS5 协议限制）
    pub password: String,
}

impl std::fmt::Debug for ProxyCredentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // 对齐上游 `ProxyCredentials.toString()`：密码永不打印
        f.write_str("ProxyCredentials(***)")
    }
}

/// 代理配置
#[derive(Debug, Clone)]
pub struct ProxyConfig {
    /// 代理 URL，例如 `http://host:port` 或 `socks5://host:port`
    ///
    /// 凭据单独存于 [`ProxyConfig::credentials`]，构建 reqwest 代理时
    /// 由 [`ProxyConfig::effective_url`] 拼接回 URL。
    pub url: String,
    /// 代理类型（可自动推断）
    pub proxy_type: ProxyType,
    /// 代理认证凭据（可选，对应上游 `ProxyConfig.credentials`）
    pub credentials: Option<ProxyCredentials>,
}

/// 上游遗留代理格式：`protocol://host:port@username@password`
///
/// 对齐上游 `HttpProxyConfig.kt` 的 `legacyProxyPattern`（主机组为贪婪 `.+`，
/// 正则回溯保证 `:port@user@pass` 后缀正确切分；主机在 [`normalize_host`]
/// 中会拒绝含 `@` 的值）。
static LEGACY_PROXY_PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(http|https|socks4|socks5)://(.+):(\d+)@([^@\s]+)@(.+)$").unwrap()
});

impl ProxyConfig {
    /// 从 URL 创建代理配置（自动推断类型，宽容提取凭据）
    ///
    /// 若 URL 中携带 `user:pass@` 凭据则一并提取；解析失败时不报错，
    /// 保持与旧接口的兼容行为。
    pub fn from_url(url: impl Into<String>) -> Self {
        let url = url.into();
        let proxy_type = ProxyType::from_url(&url);
        let credentials = extract_credentials_lenient(&url);
        Self {
            url,
            proxy_type,
            credentials,
        }
    }

    /// 从 URL 和指定类型创建代理配置
    pub fn with_type(url: impl Into<String>, proxy_type: ProxyType) -> Self {
        let url = url.into();
        let credentials = extract_credentials_lenient(&url);
        Self {
            url,
            proxy_type,
            credentials,
        }
    }

    /// 附加认证凭据（构建器风格）
    pub fn with_credentials(mut self, credentials: ProxyCredentials) -> Self {
        self.credentials = Some(credentials);
        self
    }

    /// 生成实际传给 reqwest 的代理 URL
    ///
    /// 有凭据时拼接为 `scheme://user:pass@host:port`（凭据做百分号编码）；
    /// reqwest 的 `socks`/HTTP 代理均原生支持该凭据形式。
    pub fn effective_url(&self) -> String {
        let Some(creds) = self.credentials.as_ref() else {
            return self.url.clone();
        };
        // 优先用 url crate 重建，避免 URL 中已有 userinfo 时重复拼接
        if let Ok(mut parsed) = Url::parse(&self.url) {
            let user = urlencoding::encode(&creds.username);
            let pass = urlencoding::encode(&creds.password);
            if parsed.set_username(&user).is_ok() && parsed.set_password(Some(&pass)).is_ok() {
                return parsed.to_string();
            }
        }
        // 回退：手工插入 `user:pass@`
        if let Some((scheme, rest)) = self.url.split_once("://") {
            let rest = strip_userinfo(rest);
            format!(
                "{}://{}:{}@{}",
                scheme,
                urlencoding::encode(&creds.username),
                urlencoding::encode(&creds.password),
                rest
            )
        } else {
            self.url.clone()
        }
    }
}

/// 校验代理凭据（对齐上游 `ProxyCredentials.validated()`）
///
/// - 用户名不得为空，均不得含控制字符
/// - SOCKS5 协议限制用户名/密码 UTF-8 字节长度为 1..=255
fn validate_credentials(creds: &ProxyCredentials, proxy_type: ProxyType) -> LegadoResult<()> {
    if creds.username.trim().is_empty()
        || creds.username.chars().any(char::is_control)
        || creds.password.chars().any(char::is_control)
    {
        return Err(LegadoError::Network(
            "代理凭据非法：用户名不能为空且不得包含控制字符".into(),
        ));
    }
    if proxy_type == ProxyType::Socks5 {
        let user_len = creds.username.as_bytes().len();
        let pass_len = creds.password.as_bytes().len();
        if !(1..=255).contains(&user_len) || !(1..=255).contains(&pass_len) {
            return Err(LegadoError::Network(
                "SOCKS5 凭据非法：用户名/密码 UTF-8 字节长度须在 1..=255".into(),
            ));
        }
    }
    Ok(())
}

/// 严格解析代理配置（对齐上游 `HttpProxyConfig.parseProxyConfig`）
///
/// 支持两种格式：
/// 1. 遗留格式 `protocol://host:port@username@password`
/// 2. 标准 URI `scheme://[user:pass@]host:port`
///
/// 校验内容：scheme 必须为 http/https/socks5(socks5h)，必须显式携带端口（1..=65535），
/// 不得携带 path/query/fragment，凭据通过 [`validate_credentials`] 校验。
/// SOCKS4 协议 reqwest 不支持，直接报错。
pub fn parse_proxy_config(raw_proxy: &str) -> LegadoResult<ProxyConfig> {
    let proxy = raw_proxy.trim();
    if proxy.is_empty() {
        return Err(invalid_proxy());
    }

    // 格式 1：遗留格式 protocol://host:port@username@password
    if let Some(caps) = LEGACY_PROXY_PATTERN.captures(proxy) {
        let scheme = caps[1].to_lowercase();
        let proxy_type = match_scheme(&scheme)?;
        let credentials = ProxyCredentials {
            username: caps[4].to_string(),
            password: caps[5].to_string(),
        };
        validate_credentials(&credentials, proxy_type)?;
        let host = normalize_host(&caps[2])?;
        let port = parse_port(&caps[3])?;
        return Ok(ProxyConfig {
            url: format!("{}://{}:{}", scheme, host, port),
            proxy_type,
            credentials: Some(credentials),
        });
    }

    // 格式 2：标准 URI
    // 预检：原始输入含控制字符直接拒绝（url crate 会将其转义为 %XX 绕过后续校验，
    // 对齐上游对凭据/主机中 ISO 控制字符的拒绝语义）
    if proxy.chars().any(char::is_control) {
        return Err(invalid_proxy());
    }
    let parsed = Url::parse(proxy)
        .map_err(|e| LegadoError::Network(format!("代理 URL 格式非法 '{}': {}", proxy, e)))?;
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(invalid_proxy());
    }
    if !parsed.path().is_empty() && parsed.path() != "/" {
        return Err(invalid_proxy());
    }

    let scheme = parsed.scheme().to_lowercase();
    let proxy_type = match_scheme(&scheme)?;

    // 凭据：username 必须非空；存在 username 时密码分隔符必须存在
    // 注：url crate 的 username()/password() 返回未解码原文，需手工百分号解码
    //（对齐上游 decodeUserInfo 行为）
    let credentials = if !parsed.username().is_empty() {
        let password = parsed.password().ok_or_else(invalid_proxy)?;
        let credentials = ProxyCredentials {
            username: decode_userinfo(parsed.username()),
            password: decode_userinfo(password),
        };
        validate_credentials(&credentials, proxy_type)?;
        Some(credentials)
    } else if parsed.password().is_some() {
        return Err(invalid_proxy());
    } else {
        None
    };

    let host = parsed
        .host_str()
        .ok_or_else(invalid_proxy)
        .and_then(|h| normalize_host(h))?;
    // 上游要求显式端口；url crate 对非特殊 scheme 不做默认端口填充
    let port = parsed
        .port()
        .ok_or_else(invalid_proxy)
        .and_then(|p| parse_port(&p.to_string()))?;

    Ok(ProxyConfig {
        url: format!("{}://{}:{}", scheme, host, port),
        proxy_type,
        credentials,
    })
}

/// scheme 到代理类型的映射（不支持 SOCKS4）
fn match_scheme(scheme: &str) -> LegadoResult<ProxyType> {
    match scheme {
        "http" => Ok(ProxyType::Http),
        "https" => Ok(ProxyType::Https),
        "socks5" | "socks5h" => Ok(ProxyType::Socks5),
        "socks4" => Err(LegadoError::Network(
            "SOCKS4 代理不受支持（reqwest 无 socks4 实现）".into(),
        )),
        _ => Err(invalid_proxy()),
    }
}

/// 校验并规范化主机名（对齐上游 `normalizeProxyHost` 的核心约束）
fn normalize_host(value: &str) -> LegadoResult<String> {
    // 去除 IPv6 方括号
    let host = value.strip_prefix('[').unwrap_or(value);
    let host = host.strip_suffix(']').unwrap_or(host);
    if host.is_empty()
        || host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "/@?#%".contains(c))
    {
        return Err(invalid_proxy());
    }
    Ok(host.to_string())
}

/// 解析端口（1..=65535，对齐上游 `parseProxyPort`）
fn parse_port(value: &str) -> LegadoResult<u16> {
    match value.parse::<u16>() {
        Ok(0) => Err(invalid_proxy_port()),
        Ok(p) => Ok(p),
        Err(_) => Err(invalid_proxy_port()),
    }
}

fn invalid_proxy() -> LegadoError {
    LegadoError::Network("代理必须包含受支持的协议头、主机和端口".into())
}

fn invalid_proxy_port() -> LegadoError {
    LegadoError::Network("代理端口必须在 1..=65535 范围内".into())
}

/// 从 `host:port` 部分去除已存在的 `user:pass@` 前缀
fn strip_userinfo(host_port: &str) -> &str {
    match host_port.rfind('@') {
        Some(idx) => &host_port[idx + 1..],
        None => host_port,
    }
}

/// 宽容提取 URL 中的凭据（不报错，用于兼容旧接口 `from_url`）
fn extract_credentials_lenient(url: &str) -> Option<ProxyCredentials> {
    let parsed = Url::parse(url).ok()?;
    if parsed.username().is_empty() {
        return None;
    }
    Some(ProxyCredentials {
        username: decode_userinfo(parsed.username()),
        password: decode_userinfo(parsed.password().unwrap_or_default()),
    })
}

/// 百分号解码 userinfo 片段（对齐上游 `decodeUserInfo`）
///
/// 解码失败时保留原文，不阻断解析。
fn decode_userinfo(value: &str) -> String {
    urlencoding::decode(value)
        .map(|cow| cow.into_owned())
        .unwrap_or_else(|_| value.to_string())
}

/// 代理池
///
/// 维护一组代理配置，支持轮询和伪随机选择。
pub struct ProxyPool {
    proxies: Vec<ProxyConfig>,
    index: AtomicUsize,
}

impl ProxyPool {
    /// 创建代理池
    pub fn new(proxies: Vec<ProxyConfig>) -> Self {
        Self {
            proxies,
            index: AtomicUsize::new(0),
        }
    }

    /// 轮询方式获取下一个代理
    pub fn next(&self) -> Option<&ProxyConfig> {
        if self.proxies.is_empty() {
            return None;
        }
        let idx = self.index.fetch_add(1, Ordering::Relaxed) % self.proxies.len();
        Some(&self.proxies[idx])
    }

    /// 伪随机方式获取一个代理
    pub fn random(&self) -> Option<&ProxyConfig> {
        if self.proxies.is_empty() {
            return None;
        }
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as usize)
            .unwrap_or(0);
        let idx = nanos % self.proxies.len();
        Some(&self.proxies[idx])
    }

    /// 获取代理池大小
    pub fn len(&self) -> usize {
        self.proxies.len()
    }

    /// 代理池是否为空
    pub fn is_empty(&self) -> bool {
        self.proxies.is_empty()
    }
}

/// 代理中间件
///
/// 从代理池中轮询选取代理并应用到请求。
/// 注意：reqwest 的代理在 Client 构建时设置，无法逐请求切换。
/// 因此本中间件仅做日志记录和请求头注入（`X-Forwarded-For` 等可选头），
/// 真正的代理轮换应在 `LegadoClient::new()` 或 `LegadoClient::with_proxy()` 中完成。
pub struct ProxyMiddleware {
    pool: Arc<ProxyPool>,
}

impl ProxyMiddleware {
    /// 使用指定的代理池创建中间件
    pub fn new(pool: Arc<ProxyPool>) -> Self {
        Self { pool }
    }

    /// 获取代理池引用
    pub fn pool(&self) -> &Arc<ProxyPool> {
        &self.pool
    }

    /// 获取当前轮询到的代理（供外部构建 Client 时使用）
    pub fn current_proxy(&self) -> Option<&ProxyConfig> {
        self.pool.next()
    }
}

#[async_trait::async_trait]
impl Middleware for ProxyMiddleware {
    fn name(&self) -> &str {
        "Proxy"
    }

    async fn handle(&self, request: RequestBuilder, next: Next) -> LegadoResult<Response> {
        // 记录当前使用的代理信息（不修改请求本身，因为 reqwest 代理在 Client 层设置）
        if let Some(proxy) = self.pool.next() {
            log::debug!(
                "Proxy middleware: using proxy {} ({:?})",
                proxy.url,
                proxy.proxy_type
            );
        } else {
            log::debug!("Proxy middleware: proxy pool is empty, no proxy applied");
        }
        next(request).await
    }
}

/// 将 ProxyConfig 转换为 reqwest::Proxy
///
/// 使用 [`ProxyConfig::effective_url`] 拼接凭据后的 URL；
/// reqwest `socks` feature 原生支持 `socks5://user:pass@host:port`。
pub fn to_reqwest_proxy(config: &ProxyConfig) -> Result<reqwest::Proxy, LegadoError> {
    let url = config.effective_url();
    reqwest::Proxy::all(&url)
        .map_err(|e| LegadoError::Network(format!("Invalid proxy URL '{}': {}", url, e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_proxy_type_from_url() {
        assert_eq!(
            ProxyType::from_url("http://proxy.example.com:8080"),
            ProxyType::Http
        );
        assert_eq!(
            ProxyType::from_url("https://proxy.example.com:443"),
            ProxyType::Https
        );
        assert_eq!(
            ProxyType::from_url("socks5://127.0.0.1:1080"),
            ProxyType::Socks5
        );
        assert_eq!(
            ProxyType::from_url("SOCKS5://127.0.0.1:1080"),
            ProxyType::Socks5
        );
    }

    #[test]
    fn test_proxy_config_from_url() {
        let cfg = ProxyConfig::from_url("socks5://127.0.0.1:1080");
        assert_eq!(cfg.url, "socks5://127.0.0.1:1080");
        assert_eq!(cfg.proxy_type, ProxyType::Socks5);
    }

    #[test]
    fn test_proxy_pool_round_robin() {
        let pool = ProxyPool::new(vec![
            ProxyConfig::from_url("http://p1:8080"),
            ProxyConfig::from_url("http://p2:8080"),
            ProxyConfig::from_url("http://p3:8080"),
        ]);
        assert_eq!(pool.next().unwrap().url, "http://p1:8080");
        assert_eq!(pool.next().unwrap().url, "http://p2:8080");
        assert_eq!(pool.next().unwrap().url, "http://p3:8080");
        // 循环
        assert_eq!(pool.next().unwrap().url, "http://p1:8080");
    }

    #[test]
    fn test_proxy_pool_empty() {
        let pool = ProxyPool::new(vec![]);
        assert!(pool.is_empty());
        assert_eq!(pool.len(), 0);
        assert!(pool.next().is_none());
        assert!(pool.random().is_none());
    }

    #[test]
    fn test_proxy_pool_random_returns_valid() {
        let pool = ProxyPool::new(vec![
            ProxyConfig::from_url("http://p1:8080"),
            ProxyConfig::from_url("http://p2:8080"),
        ]);
        let proxy = pool.random().unwrap();
        assert!(proxy.url == "http://p1:8080" || proxy.url == "http://p2:8080");
    }

    #[test]
    fn test_proxy_pool_len() {
        let pool = ProxyPool::new(vec![ProxyConfig::from_url("http://p1:8080")]);
        assert_eq!(pool.len(), 1);
        assert!(!pool.is_empty());
    }

    #[test]
    fn test_to_reqwest_proxy_valid() {
        let cfg = ProxyConfig::from_url("http://127.0.0.1:7890");
        let result = to_reqwest_proxy(&cfg);
        assert!(result.is_ok());
    }

    #[test]
    fn test_to_reqwest_proxy_invalid() {
        // reqwest rejects URLs with no scheme at all
        let cfg = ProxyConfig::from_url("://no-scheme");
        let result = to_reqwest_proxy(&cfg);
        assert!(result.is_err());
    }

    // ─── SOCKS5 凭据解析测试（不实际连接代理） ───────────────────

    #[test]
    fn test_from_url_extracts_socks5_credentials() {
        let cfg = ProxyConfig::from_url("socks5://alice:secret@127.0.0.1:1080");
        assert_eq!(cfg.proxy_type, ProxyType::Socks5);
        let creds = cfg.credentials.unwrap();
        assert_eq!(creds.username, "alice");
        assert_eq!(creds.password, "secret");
    }

    #[test]
    fn test_from_url_no_credentials() {
        let cfg = ProxyConfig::from_url("socks5://127.0.0.1:1080");
        assert!(cfg.credentials.is_none());
    }

    #[test]
    fn test_from_url_percent_encoded_credentials() {
        // 凭据含特殊字符（@ 与空格）时 URL 中应百分号编码
        let cfg = ProxyConfig::from_url("socks5://us%40er:p%20ass@proxy.local:1080");
        let creds = cfg.credentials.unwrap();
        assert_eq!(creds.username, "us@er");
        assert_eq!(creds.password, "p ass");
    }

    #[test]
    fn test_parse_proxy_config_standard_socks5_with_credentials() {
        let cfg = parse_proxy_config("socks5://alice:secret@proxy.example.com:1080").unwrap();
        assert_eq!(cfg.proxy_type, ProxyType::Socks5);
        assert_eq!(cfg.url, "socks5://proxy.example.com:1080");
        let creds = cfg.credentials.unwrap();
        assert_eq!(creds.username, "alice");
        assert_eq!(creds.password, "secret");
    }

    #[test]
    fn test_parse_proxy_config_http_without_credentials() {
        let cfg = parse_proxy_config("http://127.0.0.1:7890").unwrap();
        assert_eq!(cfg.proxy_type, ProxyType::Http);
        assert_eq!(cfg.url, "http://127.0.0.1:7890");
        assert!(cfg.credentials.is_none());
    }

    #[test]
    fn test_parse_proxy_config_legacy_format() {
        // 上游遗留格式：protocol://host:port@username@password（双 @ 分隔）
        let cfg = parse_proxy_config("socks5://proxy.example.com:1080@alice@secret").unwrap();
        assert_eq!(cfg.proxy_type, ProxyType::Socks5);
        assert_eq!(cfg.url, "socks5://proxy.example.com:1080");
        let creds = cfg.credentials.unwrap();
        assert_eq!(creds.username, "alice");
        assert_eq!(creds.password, "secret");
    }

    #[test]
    fn test_parse_proxy_config_rejects_invalid() {
        // 空配置
        assert!(parse_proxy_config("").is_err());
        assert!(parse_proxy_config("   ").is_err());
        // 无 scheme
        assert!(parse_proxy_config("127.0.0.1:1080").is_err());
        // 不支持的 scheme
        assert!(parse_proxy_config("ftp://127.0.0.1:21").is_err());
        // SOCKS4 不受支持
        assert!(parse_proxy_config("socks4://127.0.0.1:1080").is_err());
        // 缺少显式端口
        assert!(parse_proxy_config("socks5://127.0.0.1").is_err());
        // 端口越界
        assert!(parse_proxy_config("socks5://127.0.0.1:0").is_err());
        assert!(parse_proxy_config("socks5://127.0.0.1:70000").is_err());
        // 携带 path / query
        assert!(parse_proxy_config("http://127.0.0.1:8080/path").is_err());
        assert!(parse_proxy_config("http://127.0.0.1:8080?a=1").is_err());
        // 用户名为空
        assert!(parse_proxy_config("socks5://:pass@127.0.0.1:1080").is_err());
    }

    #[test]
    fn test_parse_proxy_config_rejects_oversized_socks5_credentials() {
        // SOCKS5 协议限制凭据 UTF-8 字节长度 ≤ 255
        let long_user = "u".repeat(256);
        let raw = format!("socks5://{}:pass@127.0.0.1:1080", long_user);
        assert!(parse_proxy_config(&raw).is_err());
        let long_pass = "p".repeat(256);
        let raw = format!("socks5://user:{}@127.0.0.1:1080", long_pass);
        assert!(parse_proxy_config(&raw).is_err());
    }

    #[test]
    fn test_parse_proxy_config_rejects_control_chars() {
        assert!(parse_proxy_config("socks5://us\ner:pass@127.0.0.1:1080").is_err());
    }

    #[test]
    fn test_credentials_debug_masks_password() {
        let creds = ProxyCredentials {
            username: "alice".into(),
            password: "top-secret".into(),
        };
        let debug = format!("{:?}", creds);
        assert!(!debug.contains("top-secret"));
    }

    #[test]
    fn test_effective_url_inserts_credentials() {
        let cfg = ProxyConfig::from_url("socks5://127.0.0.1:1080")
            .with_credentials(ProxyCredentials {
                username: "alice".into(),
                password: "secret".into(),
            });
        assert_eq!(
            cfg.effective_url(),
            "socks5://alice:secret@127.0.0.1:1080"
        );
    }

    #[test]
    fn test_effective_url_encodes_special_credentials() {
        let cfg = ProxyConfig::from_url("socks5://127.0.0.1:1080")
            .with_credentials(ProxyCredentials {
                username: "us@er".into(),
                password: "p:ss".into(),
            });
        let url = cfg.effective_url();
        assert!(url.contains("us%40er"));
        assert!(url.contains("p%3Ass"));
        // 重建后的 URL 可被 reqwest 接受（socks feature 原生解析凭据）
        assert!(to_reqwest_proxy(&cfg).is_ok());
    }

    #[test]
    fn test_to_reqwest_proxy_socks5_with_credentials() {
        let cfg = parse_proxy_config("socks5://alice:secret@127.0.0.1:1080").unwrap();
        assert!(to_reqwest_proxy(&cfg).is_ok());
    }

    #[tokio::test]
    async fn test_proxy_middleware_empty_pool() {
        use crate::middleware::MiddlewareChain;
        use std::sync::atomic::AtomicUsize;

        let pool = Arc::new(ProxyPool::new(vec![]));
        let mut chain = MiddlewareChain::new();
        chain.add(ProxyMiddleware::new(pool));

        let called = Arc::new(AtomicUsize::new(0));
        let cc = called.clone();
        let final_handler: Next = Arc::new(move |_req: RequestBuilder| {
            let c = cc.clone();
            Box::pin(async move {
                c.fetch_add(1, Ordering::SeqCst);
                Err(legado_core::LegadoError::Network("sentinel".into()))
            })
        });

        let client = reqwest::Client::new();
        let req = client.get("http://example.com");
        let _ = chain.execute(req, final_handler).await;
        assert_eq!(called.load(Ordering::SeqCst), 1);
    }
}
