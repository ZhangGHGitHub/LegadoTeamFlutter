//! RSS 列表请求构造与响应结构（批15a 骨架）
//!
//! 对齐原版 `Rss.getArticlesAwait`（`Rss.kt:39-84`）的请求段：
//!
//! ```text
//! AnalyzeUrl(sortUrl, page = page, key = key, baseUrl = rssSource.sourceUrl,
//!            source = rssSource, ...)  →  getStrResponseAwait()
//! ```
//!
//! 与书源共用同一套请求语义：
//! - 源静态 `header`（JSON map）→ 请求头；`enabledCookieJar == true` 时补内部
//!   标记头（复用 [`crate::web_book::apply_cookie_jar_marker_by_flag`]，单一实现，
//!   标记头在 `legado-net` 发送前剥离、绝不出网）；
//! - URL 模板 / `page` / `key` / urlOption header 由 [`AnalyzeUrl`] 解析
//!   （urlOption header 覆盖源同名 header，对齐原版 `AnalyzeUrl` 的 putAll 顺序）；
//! - **`proxy` 是代理配置而非 HTTP 头**：上游 `AnalyzeUrl` 把源 header 中的
//!   `proxy` 键提取到独立字段后删除（`AnalyzeUrl.kt:142-146`），发送时经
//!   `getProxyClient(proxy)` 派生代理客户端。本模块同样把 `proxy` 交给
//!   [`AnalyzeUrl::proxy`]，并在合并请求头后由
//!   [`crate::web_book::strip_proxy_header`] 剔除该键（大小写不敏感），
//!   既保证代理生效、也保证凭据绝不出网；
//! - 发送走 [`crate::analyze_request::send_text`]，`followRedirects` / `retry`
//!   语义与书源搜索、正文一致（`data:` URI 亦沿用该模块的本地解码短路）；
//! - **登录头同源门控**（2026-10-26 审查 P1-2）：`loginHeader_<url>` 仅在
//!   请求 URL 与 `sourceUrl` 同源（scheme + host + port）时合并；跨域
//!   `nextUrl` / 分类 `sortUrl` 绝不携带登录凭据，见 [`is_same_origin`]。
//!
//! 批15b 起在此扩展：`sortUrl` 分类解析、`ruleNextPage` 分页、`loginCheckJs`。

use std::collections::HashMap;

use legado_core::models::RssSource;
use legado_core::{LegadoError, LegadoResult};
use legado_net::{LegadoClient, LegadoResponse};
use legado_parser::AnalyzeUrl;

/// 列表请求响应（正文 + 最终 URL + 状态码）
///
/// `final_url` 对齐原版 `StrResponse.url`（重定向后的最终地址），批15b 起
/// 供 `ruleNextPage` 相对路径拼装与 `checkRedirect` 使用。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RssListResponse {
    /// 响应正文
    pub body: String,
    /// 重定向后的最终 URL
    pub final_url: String,
    /// HTTP 状态码
    pub status: u16,
}

/// 源静态 header（JSON map）→ 请求头（含 CookieJar 写侧门控标记）
///
/// 对齐原版 `BaseSource.getHeaderMap()`：仅解析源静态 `header` 字段，
/// 不含登录头（等价原版 `Rss.kt:56` 构造 AnalyzeUrl 时的
/// `hasLoginHeader = false`）；登录头由 [`source_headers_with_login`]
/// 在**同源门控通过后**合并。
///
/// header 非法 JSON 时按空处理（与书源 `parse_source_headers` 同口径）；
/// `enabledCookieJar == Some(true)` 补 [`legado_net::COOKIE_JAR_HEADER`] 标记，
/// 只补不覆盖（源显式配置同名头时不重复写入）。
pub fn source_headers(source: &RssSource) -> Option<HashMap<String, String>> {
    source_headers_with_login(source, None)
}

/// 源静态 header + 登录头合并（批15b）
///
/// 对齐书源版 `RealBookSourceFetcher::parse_source_headers`
/// （`web_book.rs:955-988`）：
/// 1. 先解析源静态 `header`；
/// 2. 再合并 `loginHeader_<sourceUrl>`（覆盖同名键，对齐原版 `putAll` 顺序）；
/// 3. 最后补 CookieJar 写侧门控标记（只补不覆盖）。
///
/// **同源门控（2026-10-26 审查 P1-2）**：`login_header_json` 由调用方
/// 按 [`is_same_origin`] 判定后再传入（跨域 `nextUrl` 传 `None`），
/// 本函数自身不再判断目标站点——保证「登录头只在源自身站点出网」。
///
/// **已登记超集**：原版 `Rss.kt:56` 构造 `AnalyzeUrl` 时传
/// `hasLoginHeader = false`，即 RSS 列表请求不合并登录头；批15b 按任务
/// 要求合并（登录后列表请求需携带登录态），且收敛为**仅同源附加**
/// （跨域不外发），差异登记于 `docs/API_CONTRACT.md` §2.5 批15b 注。
pub fn source_headers_with_login(
    source: &RssSource,
    login_header_json: Option<&str>,
) -> Option<HashMap<String, String>> {
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .and_then(|raw| serde_json::from_str::<HashMap<String, String>>(raw).ok())
        .unwrap_or_default();

    if let Some(raw) = login_header_json {
        if let Ok(login_headers) = serde_json::from_str::<HashMap<String, String>>(raw) {
            // 登录头覆盖源同名 header（对齐原版 loginHeader putAll 在后）
            headers.extend(login_headers);
        }
    }

    crate::web_book::apply_cookie_jar_marker_by_flag(&mut headers, source.enabled_cookie_jar);

    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
}

/// 判断请求 URL 与源 URL 是否同源（scheme + host + port 全等）
///
/// 登录凭据（`loginHeader_<url>` 中的 Authorization/Cookie 等）只允许发往
/// 源自身站点：RSS `ruleNextPage` / 分类 `sortUrl` 可以指向第三方域名，
/// 跨域请求一律不附加登录头（2026-10-26 审查 P1-2，收敛方向对齐原版
/// `Rss.kt:56 hasLoginHeader = false`）。
///
/// 端口按 scheme 默认值归一（`http` → 80、`https` → 443），显式写默认端口
/// 与省略端口视为同源；scheme/host 大小写不敏感。无法解析为绝对 URL
/// （`data:` URI、相对路径、畸形串）时返回 `false`——宁可不发凭据。
pub fn is_same_origin(request_url: &str, source_url: &str) -> bool {
    match (origin_of(request_url), origin_of(source_url)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// 提取 `(scheme, host, 有效端口)`；scheme/host 小写归一
fn origin_of(url: &str) -> Option<(String, String, u16)> {
    let url = url.trim();
    let sep = url.find("://")?;
    let scheme = url[..sep].to_ascii_lowercase();
    let rest = &url[sep + 3..];
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    // 丢弃 userinfo（`user:pass@host:port`）
    let host_port = authority.rsplit('@').next().unwrap_or(authority);
    if host_port.is_empty() {
        return None;
    }
    let (host, port_str) = if let Some(after_bracket) = host_port.strip_prefix('[') {
        // IPv6 字面量：`[::1]:8080`
        let close = after_bracket.find(']')?;
        (
            host_port[..close + 2].to_string(),
            host_port[close + 2..].strip_prefix(':'),
        )
    } else {
        match host_port.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), Some(p)),
            None => (host_port.to_string(), None),
        }
    };
    if host.is_empty() {
        return None;
    }
    let port = match port_str {
        Some(p) if !p.is_empty() => p.parse::<u16>().ok()?,
        _ => match scheme.as_str() {
            "http" => 80,
            "https" => 443,
            // 其他 scheme 未显式给端口时无法定义默认值 → 不同源
            _ => return None,
        },
    };
    Some((scheme, host.to_ascii_lowercase(), port))
}

/// 构造列表请求（对齐原版 `AnalyzeUrl(sortUrl, page, key, baseUrl = sourceUrl)`）
///
/// `page` / `key` 在批15a 均可为 `None`（默认解析无分页、无搜索）。
pub fn build_list_analyze_url(
    sort_url: &str,
    page: Option<u32>,
    key: Option<&str>,
    base_url: &str,
    headers: Option<HashMap<String, String>>,
) -> AnalyzeUrl {
    AnalyzeUrl::new(sort_url, key, page, base_url, headers)
}

/// 发送列表请求并校验 HTTP 状态
///
/// **行为登记（审查 P2-1）**：上游 `Rss.getArticlesAwait`（`Rss.kt:47-84`）
/// 取到 `StrResponse` 后**不校验状态码**，直接把 `res.body` 交给
/// `RssParserByRule.parseXML`；本实现保留既有的非 2xx 报错（比上游更严格，
/// 避免把错误页当正文解析），登记为差异而非「对齐上游」。
///
/// `proxy` 接线对齐上游 `AnalyzeUrl.getClient()` → `getProxyClient(proxy)`：
/// 代理 URL 存在时本次请求改由 [`LegadoClient::with_proxy`] 派生的客户端发送
/// （共享 CookieStore / 持久化后端；按请求派生、无跨请求缓存，RSS 列表
/// 请求频次低，成本可接受）。
pub async fn fetch_list(
    client: &LegadoClient,
    analyze_url: &AnalyzeUrl,
    source_headers: Option<HashMap<String, String>>,
) -> LegadoResult<RssListResponse> {
    let headers = merge_request_headers(analyze_url, source_headers);

    // per-request proxy：`Some` 时派生代理客户端，`None` 沿用共享客户端
    let proxied_client;
    let effective_client = match analyze_url.proxy() {
        Some(proxy) => {
            proxied_client = client.with_proxy(proxy)?;
            &proxied_client
        }
        None => client,
    };

    let response: LegadoResponse =
        crate::analyze_request::send_text(effective_client, analyze_url, headers).await?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "获取 RSS 内容失败: HTTP {}（{}）",
            response.status,
            analyze_url.url()
        )));
    }

    Ok(RssListResponse {
        body: response.body,
        final_url: response.url,
        status: response.status,
    })
}

/// 合并源 header 与 `AnalyzeUrl` 解析出的 urlOption header
///
/// urlOption header 覆盖同名键（对齐原版 `AnalyzeUrl.initUrl`：
/// `headers.putAll(urlOption.headers)` 在源 header 之后）。
///
/// 合并后统一剔除 `proxy` 键（大小写不敏感）：`AnalyzeUrl` 只删除自己持有的
/// header 副本，原始 `source_headers` 仍带该键；不剔除就会作为普通 HTTP 头
/// 发送（上游 `BaseSource.getHeaderMap` 返回的 map 也同样保留该键，由
/// `AnalyzeUrl` 消费为代理配置）。
fn merge_request_headers(
    analyze_url: &AnalyzeUrl,
    source_headers: Option<HashMap<String, String>>,
) -> Option<HashMap<String, String>> {
    let mut headers = source_headers.unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    crate::web_book::strip_proxy_header(&mut headers);
    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    /// 单篇文章的回环 feed 正文
    const FEED_BODY: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>代理回环</title>
<item><title>经代理取回</title><link>http://rss.invalid/a1</link></item>
</channel></rss>"#;

    /// 回环「代理」记录器：reqwest 对 HTTP 代理发送**绝对形式**请求行
    /// （`GET http://target/path HTTP/1.1`），故目标主机无需可解析；
    /// 服务器记录完整请求头并直接回 200 + feed 正文。
    fn spawn_proxy_server() -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环代理端口");
        let port = listener.local_addr().expect("读取端口").port();
        let heads = Arc::new(Mutex::new(Vec::new()));
        let heads_thread = Arc::clone(&heads);
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => head.push(byte[0]),
                        _ => break,
                    }
                    if head.len() > 16 * 1024 {
                        break;
                    }
                }
                heads_thread
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(&head).into_owned());
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml; charset=utf-8\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    FEED_BODY.len(),
                    FEED_BODY
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://127.0.0.1:{port}"), heads)
    }

    /// 回环测试客户端（no_proxy：未配置代理时测试流量直连）
    fn test_client() -> LegadoClient {
        LegadoClient::new(legado_net::LegadoClientConfig {
            no_proxy: true,
            ..legado_net::LegadoClientConfig::default()
        })
        .expect("test http client")
    }

    /// 同源判定：scheme + host + 有效端口全等才算同源；
    /// 跨域 / 跨端口 / 跨 scheme / 非绝对 URL 一律不同源（不附加登录头）
    #[test]
    fn same_origin_requires_scheme_host_and_port() {
        assert!(is_same_origin(
            "https://example.com/feed?p=2",
            "https://example.com/feed"
        ));
        assert!(
            is_same_origin("https://example.com:443/feed", "https://EXAMPLE.com/feed"),
            "显式默认端口与省略端口等价，host 大小写不敏感"
        );
        assert!(
            is_same_origin("http://127.0.0.1:8080/a", "http://127.0.0.1:8080/"),
            "同 host 同端口"
        );
        assert!(
            !is_same_origin("https://other.example.com/feed", "https://example.com/feed"),
            "跨主机不得同源"
        );
        assert!(
            !is_same_origin("http://127.0.0.1:9090/a", "http://127.0.0.1:8080/"),
            "同 host 不同端口是不同源"
        );
        assert!(
            !is_same_origin("http://example.com/feed", "https://example.com/feed"),
            "跨 scheme 不得同源"
        );
        assert!(
            is_same_origin("http://[::1]:8080/a", "http://[::1]:8080/b"),
            "IPv6 字面量"
        );
        assert!(
            !is_same_origin("data:text/plain,hi", "https://example.com/feed"),
            "非绝对 URL 解析失败 → 不同源"
        );
        assert!(
            !is_same_origin("/relative?p=2", "https://example.com/feed"),
            "相对路径解析失败 → 不同源"
        );
    }

    /// `strip_proxy_header` 大小写不敏感：`proxy` / `Proxy` / `PROXY` 全部剔除，
    /// 其他头保留（上游只按精确小写键提取代理，本函数兜住其余大小写变体）
    #[test]
    fn strip_proxy_header_removes_all_case_variants() {
        let mut headers = HashMap::from([
            ("proxy".to_string(), "http://u:p@h:1".to_string()),
            ("Proxy".to_string(), "http://u:p@h:2".to_string()),
            ("PROXY".to_string(), "http://u:p@h:3".to_string()),
            ("X-Rss-Test".to_string(), "v".to_string()),
        ]);
        crate::web_book::strip_proxy_header(&mut headers);
        assert_eq!(headers.len(), 1, "仅保留非 proxy 头: {headers:#?}");
        assert_eq!(headers.get("X-Rss-Test").map(String::as_str), Some("v"));
    }

    /// 合并语义：urlOption header 覆盖源同名 header；`proxy` 键不进入发送头
    #[test]
    fn merge_headers_url_option_wins_and_proxy_is_stripped() {
        let source_headers = HashMap::from([
            ("X-Test".to_string(), "source".to_string()),
            ("proxy".to_string(), "http://u:p@h:1".to_string()),
        ]);
        let analyze_url = AnalyzeUrl::new(
            r#"http://127.0.0.1/feed,{"headers":{"X-Test":"urlopt"}}"#,
            None,
            None,
            "http://127.0.0.1/",
            Some(source_headers.clone()),
        );

        let merged = merge_request_headers(&analyze_url, Some(source_headers)).expect("应产出头");
        assert_eq!(
            merged.get("X-Test").map(String::as_str),
            Some("urlopt"),
            "urlOption header 应覆盖源 header"
        );
        assert!(
            !merged.keys().any(|k| k.eq_ignore_ascii_case("proxy")),
            "proxy 配置键不得进入发送头: {merged:#?}"
        );
    }

    /// P1-1 端到端：源 header 的 `proxy` 既作为代理生效（请求走代理），
    /// 又绝不出网（代理侧收到的头里没有 `proxy`）。
    #[tokio::test]
    async fn fetch_list_routes_via_proxy_header_without_leaking_it() {
        let (proxy_url, heads) = spawn_proxy_server();
        // 目标主机不可解析：若未走代理，DNS 解析会直接失败
        let source = RssSource {
            source_url: "http://rss.invalid/feed".to_string(),
            header: Some(format!(r#"{{"proxy":"{proxy_url}","X-Rss-Test":"v"}}"#)),
            ..RssSource::default()
        };
        let client = test_client();

        let page = crate::rss::fetch_articles(
            &client,
            &source,
            "",
            &source.source_url,
            None,
            None,
            None,
            None,
        )
        .await
        .expect("应经回环代理取回 feed");
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].title, "经代理取回");

        let heads = heads.lock().unwrap();
        let head = heads.first().expect("代理应收到 1 次请求");
        let lower = head.to_ascii_lowercase();
        assert!(lower.contains("x-rss-test: v"), "源 header 应透传: {head}");
        assert!(
            !head
                .lines()
                .any(|line| line.to_ascii_lowercase().starts_with("proxy:")),
            "`proxy` 配置键不得作为 HTTP 头发送: {head}"
        );
        let request_line = head.lines().next().unwrap_or_default();
        assert!(
            request_line.starts_with("GET http://rss.invalid/feed"),
            "请求应经代理（绝对形式请求行）: {request_line}"
        );
    }

    /// 批15b：`<1,2,3>` 页码列表与 `{{key}}` 搜索词经 AnalyzeUrl 展开
    #[test]
    fn analyze_url_expands_page_list_and_search_key() {
        // 原版 RssSource.sortUrl 支持 `<1,2,3>` 页码与 `{{key}}` 搜索模板
        let analyze_url = build_list_analyze_url(
            "https://feed.example.com/list/<1,2,3>?q={{key}}&p={{page}}",
            Some(2),
            Some("搜索词"),
            "https://feed.example.com",
            None,
        );
        assert_eq!(
            analyze_url.url(),
            "https://feed.example.com/list/2?q=%E6%90%9C%E7%B4%A2%E8%AF%8D&p=2",
            "页码列表取第 2 项、{{key}} URL 编码、{{page}} 替换"
        );

        // 首页（page=1）
        let analyze_url = build_list_analyze_url(
            "https://feed.example.com/list/<1,2,3>",
            Some(1),
            None,
            "https://feed.example.com",
            None,
        );
        assert_eq!(analyze_url.url(), "https://feed.example.com/list/1");
    }

    /// 批15b：登录头覆盖源同名 header，其余源 header 保留；非法 JSON 忽略
    #[test]
    fn login_header_overrides_source_header() {
        let source = RssSource {
            source_url: "https://rss-header.example.com/feed".to_string(),
            header: Some(r#"{"X-Token":"source","X-Keep":"1"}"#.to_string()),
            ..RssSource::default()
        };
        let headers =
            source_headers_with_login(&source, Some(r#"{"X-Token":"login","X-New":"2"}"#))
                .expect("应产出头");
        assert_eq!(headers.get("X-Token").map(String::as_str), Some("login"));
        assert_eq!(headers.get("X-Keep").map(String::as_str), Some("1"));
        assert_eq!(headers.get("X-New").map(String::as_str), Some("2"));

        // 非法登录头 JSON：忽略，源 header 原样
        let headers = source_headers_with_login(&source, Some("not-json")).expect("源 header");
        assert_eq!(headers.get("X-Token").map(String::as_str), Some("source"));

        // 无源 header + 登录头：只产出登录头
        let source = RssSource {
            source_url: "https://rss-header.example.com/feed".to_string(),
            ..RssSource::default()
        };
        let headers =
            source_headers_with_login(&source, Some(r#"{"X-Login":"v"}"#)).expect("登录头");
        assert_eq!(headers.len(), 1);
        assert_eq!(headers.get("X-Login").map(String::as_str), Some("v"));
    }
}
