//! JsExtensions 网络相关方法
//!
//! 书源规则中常用的网络请求方法，对应 Kotlin JsExtensions 中的 ajax/connect/get/post/head 等。
//! 使用 `legado-net::LegadoClient` 异步网络栈，通过 `runtime_bridge::block_on` 提供同步接口。

#![cfg(feature = "quickjs")]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::host_api::runtime_bridge::block_on;
use legado_net::{LegadoClient, LegadoClientConfig, LegadoRequest, Method};

/// 默认请求超时（毫秒），与 Kotlin 端一致
const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// ajaxAll 有界并发数
const AJAX_ALL_CONCURRENCY: usize = 4;

/// body 反序列化：兼容字符串、对象/数组（书山聚合等源 `url,{json}` 的
/// body 是嵌套对象，须转 JSON 字符串，否则 serde 解析失败 → ajax 返回 [ERROR]）
fn de_body<'de, D>(de: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(de)?;
    Ok(v.map(|b| match b {
        serde_json::Value::String(s) => s,
        other => other.to_string(),
    }))
}

/// HTTP 请求选项（用于 `ajax` 通用接口）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct HttpOptions {
    /// HTTP 方法：GET / POST / HEAD / PUT / DELETE
    #[serde(default)]
    pub method: Option<String>,
    /// 请求 URL
    #[serde(default)]
    pub url: String,
    /// 请求头
    #[serde(default)]
    pub headers: Option<HashMap<String, String>>,
    /// 请求体（POST/PUT 时使用；兼容字符串或 JSON 对象/数组）
    #[serde(default, deserialize_with = "de_body")]
    pub body: Option<String>,
    /// 超时毫秒数
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// HTTP 响应（用于 `ajax` 通用接口返回）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    /// HTTP 状态码
    pub status_code: u16,
    /// 响应体文本
    pub body: String,
    /// 响应头
    pub headers: HashMap<String, String>,
    /// 最终 URL（connect/StrResponse raw.request.url 兼容）
    #[serde(default)]
    pub url: String,
}

/// 从 JSON 字符串解析请求头
fn parse_headers(headers_json: Option<&str>) -> Option<HashMap<String, String>> {
    headers_json.and_then(|s| serde_json::from_str::<HashMap<String, String>>(s).ok())
}

/// 请求前规范化 URL：去掉/纠正书源 `#tag` 后缀（对齐 Jsoup 忽略 fragment，
/// 并修复 `getKey()+path` 把 path/query 拼进 fragment 的假 URL）
fn sanitize_request_url(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // 复用 AnalyzeUrl 同一套规范化，避免 ajax/connectNR 与搜索主链路行为分叉
    legado_parser::AnalyzeUrl::normalize_book_source_tag_url(trimmed)
}

/// POST 有 body 时若缺 Content-Type，补 form-urlencoded（对齐 Jsoup.requestBody）
fn ensure_form_content_type(headers: &mut HashMap<String, String>, has_body: bool) {
    if !has_body {
        return;
    }
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if !has_ct {
        headers.insert(
            "Content-Type".to_string(),
            "application/x-www-form-urlencoded".to_string(),
        );
    }
}

/// 构建共享 LegadoClient（使用默认配置）
///
/// 后续可从 HostEnv 注入配置。
fn build_client() -> Result<LegadoClient, String> {
    let config = LegadoClientConfig::default();
    LegadoClient::new(config).map_err(|e| format!("build client error: {}", e))
}

/// 构建带自定义超时的 LegadoClient
fn build_client_with_timeout(timeout_ms: u64) -> Result<LegadoClient, String> {
    let config = LegadoClientConfig {
        read_timeout: std::time::Duration::from_millis(timeout_ms),
        ..Default::default()
    };
    LegadoClient::new(config).map_err(|e| format!("build client error: {}", e))
}

/// httpGet(url, headers?) → 同步 HTTP GET，返回响应体文本
///
/// 对应 Kotlin 端 `ajax(url)` / `get(url, headers)` 的简化版本。
pub fn http_get(url: &str, headers: Option<&str>) -> Result<String, String> {
    block_on(async {
        let client = build_client()?;
        let header_map = parse_headers(headers);
        let resp = client
            .get(url, header_map)
            .await
            .map_err(|e| format!("httpGet error: {}", e))?;
        Ok(resp.body)
    })
}

/// httpPost(url, body, headers?) → 同步 HTTP POST，返回响应体文本
///
/// 对应 Kotlin 端 `post(url, body, headers)` 的简化版本。
pub fn http_post(url: &str, body: &str, headers: Option<&str>) -> Result<String, String> {
    block_on(async {
        let client = build_client()?;
        let header_map = parse_headers(headers);
        let resp = client
            .post(url, body, header_map)
            .await
            .map_err(|e| format!("httpPost error: {}", e))?;
        Ok(resp.body)
    })
}

/// httpHead(url) → HEAD 请求，返回响应头 JSON 字符串
///
/// 对应 Kotlin 端 `head(urlStr, headers)` 的简化版本。
pub fn http_head(url: &str) -> Result<String, String> {
    block_on(async {
        let client = build_client()?;
        let resp = client
            .head(url, None)
            .await
            .map_err(|e| format!("httpHead error: {}", e))?;
        serde_json::to_string(&resp.headers).map_err(|e| format!("httpHead serialize error: {}", e))
    })
}

/// ajax(options) → 通用 AJAX 请求
///
/// 支持两种输入（对齐原版 JsExtensions.ajax）：
/// 1. 标准 JSON：`{"url":..., "method":..., "headers":..., "body":...}` → 返回 HttpResponse JSON
/// 2. 原版「url,{json}」格式（七猫四合一等书源）：
///    `https://api?... ,{"method":"GET","headers":{...}}` → 返回**纯响应体文本**
///    （原版 ajax 返回 StrResponse.body；七猫 qmParse 直接 JSON.parse 响应体）
pub fn ajax(input: &str) -> Result<String, String> {
    let input = input.trim();
    // 原版「url,{json}」格式：不以 `{` 开头且含 `,{`，逗号前为 URL、逗号后为 option JSON
    if !input.starts_with('{') {
        if let Some(comma) = input.find(",{") {
            let url_part = input[..comma].trim();
            let option_part = &input[comma + 1..];
            if let Ok(mut v) = serde_json::from_str::<serde_json::Value>(option_part) {
                if let Some(obj) = v.as_object_mut() {
                    obj.insert(
                        "url".to_string(),
                        serde_json::Value::String(url_part.to_string()),
                    );
                    if let Ok(opts) = serde_json::from_value::<HttpOptions>(v) {
                        return ajax_request_body(&opts);
                    }
                }
            }
        }
    }
    // 普通 URL 输入（对齐原版 ajax(url) 语义）：不含 ",{" 的裸 URL
    // 直接 GET 并返回纯响应体文本（新落秋/笔趣阁zdzn 等源 @js: 块
    // java.ajax(source.key+"/user/search.html?q="+key) 依赖）
    // — 2026-08-17
    if !input.starts_with('{') {
        let opts = HttpOptions {
            url: input.to_string(),
            ..Default::default()
        };
        return ajax_request_body(&opts);
    }
    // 标准 JSON 输入
    let opts: HttpOptions =
        serde_json::from_str(input).map_err(|e| format!("ajax parse options error: {}", e))?;

    if opts.url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let url = sanitize_request_url(&opts.url);
    if url.is_empty() {
        return Err("ajax: url is required".to_string());
    }

    let timeout = opts.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = opts.method.as_deref().unwrap_or("GET").to_uppercase();

    // 验证方法是否受支持
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("ajax: unsupported method '{}'", other)),
    };

    block_on(async {
        let client = build_client_with_timeout(timeout)?;

        let request = LegadoRequest {
            url,
            method,
            headers: ensure_json_content_type(
                merge_global_cookie(opts.headers.clone().unwrap_or_default()),
                &opts.body,
            ),
            body: opts.body.clone(),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };

        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("ajax request error: {}", e))?;

        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };

        serde_json::to_string(&result).map_err(|e| format!("ajax serialize error: {}", e))
    })
}

#[cfg(test)]
mod http_options_tests {
    use super::*;

    #[test]
    fn test_body_accepts_object() {
        // 书山目录：url,{"method":"POST","body":{...对象...}}
        let opts: HttpOptions = serde_json::from_str(
            r#"{"method":"POST","url":"https://v1.vossc.com/catalog","body":{"source":"书山","url":"x","name":"n","tab":"novel"}}"#,
        )
        .unwrap();
        assert!(opts.body.as_deref().unwrap().contains("source"));
        assert!(opts.body.as_deref().unwrap().contains("书山"));
    }

    #[test]
    fn test_body_accepts_string() {
        let opts: HttpOptions =
            serde_json::from_str(r#"{"method":"POST","body":"key=val"}"#).unwrap();
        assert_eq!(opts.body.as_deref(), Some("key=val"));
    }
}

/// 合并书源请求头与会话 Cookie（对齐 Android AnalyzeUrl(source).getHeaderMap）
///
/// - 全局请求头（GLOBAL_HEADERS）：setup 阶段执行书源 header @js 规则后经
///   java.putGlobalHeaders 写入（书山聚合固定 X-Novel-Token 等），按当前书源
///   tag 隔离；JS 显式传入的 headers 优先。
/// - 全局会话 Cookie（GLOBAL_COOKIES）：书山登录/setCookie 写入的 X-Novel-Token 等。
fn merge_global_cookie(mut headers: HashMap<String, String>) -> HashMap<String, String> {
    if let Some(tag) = crate::host_api::current_source::current_source_tag() {
        for (k, v) in crate::host_api::global_headers::headers_for(&tag) {
            headers.entry(k).or_insert(v);
        }
    }
    if !headers.contains_key("Cookie") {
        let c = crate::host_api::cookie_store::all_cookies();
        if !c.is_empty() {
            headers.insert("Cookie".to_string(), c);
        }
    }
    headers
}

/// 对齐原版 AnalyzeUrl POST 分支：body 非空且未显式指定 Content-Type 时按
/// JSON 发送（postJson(body)）——书山 /details、/catalog 等服务端校验
/// Content-Type，缺省返回「缺少必要参数」（curl 实测 application/json 必带）。
/// 仅当 body 是 JSON 形态（{/[ 开头）才设 JSON Content-Type：书山 /login 等
/// 表单接口（email=..&password=..）若被标 JSON 会解析出空字段（实测
/// 「邮箱和密码不能为空」），须保持默认 application/x-www-form-urlencoded。
fn ensure_json_content_type(
    mut headers: HashMap<String, String>,
    body: &Option<String>,
) -> HashMap<String, String> {
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if has_ct {
        return headers;
    }
    if let Some(b) = body {
        let t = b.trim_start();
        if t.starts_with('{') || t.starts_with('[') {
            // JSON 形态 body：对齐原版 postJson(body)
            headers.insert(
                "Content-Type".to_string(),
                "application/json;charset=UTF-8".to_string(),
            );
        } else if t.contains('=') && !t.contains(' ') {
            // 表单形态 body（email=..&password=..）：显式 form-urlencoded，
            // 避免 reqwest 自动 text/plain 导致服务端解析空字段
            headers.insert(
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            );
        }
    }
    headers
}

/// 「url,{json}」格式请求，返回**纯响应体文本**（对齐原版 JsExtensions.ajax 返回
/// StrResponse.body；七猫 qmParse 等直接 JSON.parse 响应体）
fn ajax_request_body(opts: &HttpOptions) -> Result<String, String> {
    if opts.url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let url = sanitize_request_url(&opts.url);
    if url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let timeout = opts.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = opts.method.as_deref().unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("ajax: unsupported method '{}'", other)),
    };
    block_on(async {
        let client = build_client_with_timeout(timeout)?;
        let request = LegadoRequest {
            url,
            method,
            headers: ensure_json_content_type(
                merge_global_cookie(opts.headers.clone().unwrap_or_default()),
                &opts.body,
            ),
            body: opts.body.clone(),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("ajax request error: {}", e))?;
        Ok(resp.body)
    })
}

/// ajaxAll(urls_json) → 批量并发请求（有界并发）
///
/// 输入为 JSON 数组（URL 列表），返回 JSON 数组（每个 URL 的响应体，失败为空字符串）。
/// 使用 `futures::stream::buffer_unordered` 实现有界并发（默认 4）。
pub fn ajax_all(urls_json: &str) -> Result<String, String> {
    block_on(async {
        let urls: Vec<String> =
            serde_json::from_str(urls_json).map_err(|e| format!("ajaxAll parse error: {}", e))?;

        let client = build_client()?;

        use futures::stream::{self, StreamExt};

        let results: Vec<String> = stream::iter(urls)
            .map(|url| {
                let c = client.clone();
                async move {
                    c.get(&url, None)
                        .await
                        .map(|resp| resp.body)
                        .unwrap_or_default()
                }
            })
            .buffer_unordered(AJAX_ALL_CONCURRENCY)
            .collect()
            .await;

        serde_json::to_string(&results).map_err(|e| format!("ajaxAll serialize error: {}", e))
    })
}

/// connectFull(url, method?, headers?, body?, timeoutMs?) → 完整 HTTP 响应 JSON
///
/// 对应 Kotlin: `connect(urlStr, header, callTimeout): StrResponse`
/// 增强版：支持指定 HTTP 方法（GET/POST/HEAD/PUT/DELETE），返回完整响应。
///
/// 返回 JSON：`{"statusCode":200,"body":"...","headers":{...}}`
pub fn connect_full(
    url: &str,
    method: Option<&str>,
    headers_json: Option<&str>,
    body: Option<&str>,
    timeout_ms: Option<u64>,
) -> Result<String, String> {
    let timeout = timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = method.unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("connect: unsupported method '{}'", other)),
    };
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        let client = build_client_with_timeout(timeout)?;
        let request = LegadoRequest {
            url: url.to_string(),
            method,
            headers,
            body: body.map(|s| s.to_string()),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("connect request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("connect serialize error: {}", e))
    })
}

/// connectNR(url, method?, headers?, body?) → 完整响应 JSON（不跟随重定向）
///
/// 对齐原版 JsExtensions.get/post/head 的 jsoup 语义（.followRedirects(false)）：
/// 拦截重定向场景（天悦小说 java.post(...).header("Location")）必须拿到
/// 302 响应的 Location 头；跟随重定向后头信息丢失 → header 返回 null。
/// — 2026-08-17
pub fn connect_no_redirect(
    url: &str,
    method: Option<&str>,
    headers_json: Option<&str>,
    body: Option<&str>,
) -> Result<String, String> {
    let method_str = method.unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("connectNR: unsupported method '{}'", other)),
    };
    let url = sanitize_request_url(url);
    let mut headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    let body_owned = body.map(|s| s.to_string());
    ensure_form_content_type(
        &mut headers,
        body_owned.as_ref().is_some_and(|b| !b.is_empty()),
    );
    block_on(async {
        let config = LegadoClientConfig {
            follow_redirects: false,
            ..LegadoClientConfig::default()
        };
        let client =
            LegadoClient::new(config).map_err(|e| format!("connectNR client error: {}", e))?;
        let request = LegadoRequest {
            url,
            method,
            headers,
            body: body_owned,
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("connectNR request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("connectNR serialize error: {}", e))
    })
}

/// headFull(url, headers?) → HEAD 请求完整响应 JSON
///
/// 对应 Kotlin: `head(urlStr, headers): Connection.Response`
/// 返回包含 statusCode / body / headers 的完整响应 JSON。
pub fn head_full(url: &str, headers_json: Option<&str>) -> Result<String, String> {
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        let client = build_client()?;
        let request = LegadoRequest {
            url: url.to_string(),
            method: Method::Head,
            headers,
            body: None,
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("head request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("head serialize error: {}", e))
    })
}

/// postFull(url, body, headers?) → POST 请求完整响应 JSON
///
/// 对应 Kotlin: `post(urlStr, body, headers): Connection.Response`
/// 返回包含 statusCode / body / headers 的完整响应 JSON。
pub fn post_full(url: &str, body: &str, headers_json: Option<&str>) -> Result<String, String> {
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        let client = build_client()?;
        let request = LegadoRequest {
            url: url.to_string(),
            method: Method::Post,
            headers,
            body: Some(body.to_string()),
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("post request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("post serialize error: {}", e))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 判断响应体是否为 httpbin 有效 JSON 响应（排除错误页面、Cloudflare 验证等）
    fn is_valid_response(body: &str) -> bool {
        !body.is_empty() && body.trim_start().starts_with('{')
    }

    /// 测试 http_get 基本请求（使用公开测试服务）
    #[test]
    fn test_http_get_basic() {
        // 使用 httpbin 风格的公开 echo 服务
        // 注意：如果网络不可用或服务异常，此测试会优雅跳过
        let result = http_get("https://httpbin.org/get", None);
        if let Ok(body) = result {
            if is_valid_response(&body) {
                assert!(body.contains("httpbin"), "响应应包含 httpbin 标识");
            }
        }
    }

    /// 测试 http_get 带自定义 headers
    #[test]
    fn test_http_get_with_headers() {
        let headers = r#"{"X-Custom-Header": "test-value"}"#;
        let result = http_get("https://httpbin.org/headers", Some(headers));
        if let Ok(body) = result {
            if is_valid_response(&body) {
                assert!(body.contains("X-Custom-Header"), "响应应包含自定义请求头");
            }
        }
    }

    /// 测试 http_post 基本请求
    #[test]
    fn test_http_post_basic() {
        let result = http_post(
            "https://httpbin.org/post",
            r#"{"key": "value"}"#,
            Some(r#"{"Content-Type": "application/json"}"#),
        );
        if let Ok(body) = result {
            if is_valid_response(&body) {
                assert!(!body.is_empty(), "POST 响应体不应为空");
                assert!(body.contains("key"), "响应应包含请求体中的 key");
            }
        }
    }

    /// 测试 http_head 返回 headers JSON
    #[test]
    fn test_http_head() {
        let result = http_head("https://httpbin.org/get");
        if let Ok(headers_json) = result {
            let parsed: Result<HashMap<String, String>, _> = serde_json::from_str(&headers_json);
            assert!(parsed.is_ok(), "httpHead 应返回有效 JSON");
        }
    }

    /// 测试 ajax 通用接口（GET）
    #[test]
    fn test_ajax_get() {
        let opts = serde_json::json!({
            "method": "GET",
            "url": "https://httpbin.org/get",
            "headers": {"Accept": "application/json"}
        });
        let result = ajax(&opts.to_string());
        if let Ok(resp_json) = result {
            let resp: HttpResponse = serde_json::from_str(&resp_json).unwrap();
            // 仅在服务正常时断言
            if resp.status_code == 200 {
                assert!(!resp.body.is_empty());
            }
        }
    }

    /// 原版「url,{json}」格式外网诊断：依赖 httpbin.org，不能作为离线 CI 门禁。
    /// URL option 解析由本地 AnalyzeUrl/JS bridge 回归覆盖。
    #[test]
    #[ignore = "依赖 httpbin.org，外部 503/验证页会改变响应体格式"]
    fn test_ajax_url_option_format_returns_body() {
        let input =
            r#"https://httpbin.org/get,{"method":"GET","headers":{"Accept":"application/json"}}"#;
        let result = ajax(input);
        if let Ok(body) = result {
            let head: String = body.chars().take(80).collect();
            assert!(
                body.trim_start().starts_with('{'),
                "应返回纯响应体文本(JSON)，而非 HttpResponse 包装: {}",
                head
            );
        }
    }

    /// 测试 ajax 通用接口（POST）
    #[test]
    fn test_ajax_post() {
        let opts = serde_json::json!({
            "method": "POST",
            "url": "https://httpbin.org/post",
            "body": "{\"hello\": \"world\"}",
            "headers": {"Content-Type": "application/json"},
            "timeout_ms": 10000
        });
        let result = ajax(&opts.to_string());
        if let Ok(resp_json) = result {
            let resp: HttpResponse = serde_json::from_str(&resp_json).unwrap();
            // 仅在服务正常时断言
            if resp.status_code == 200 {
                assert!(resp.body.contains("hello"));
            }
        }
    }

    /// 测试 ajax 空 URL 应报错
    #[test]
    fn test_ajax_empty_url() {
        let opts = r#"{"method": "GET", "url": ""}"#;
        let result = ajax(opts);
        assert!(result.is_err(), "空 URL 应返回错误");
        assert!(result.unwrap_err().contains("url is required"));
    }

    /// 测试 ajax 不支持的 HTTP 方法
    #[test]
    fn test_ajax_unsupported_method() {
        let opts = r#"{"method": "PATCH", "url": "https://httpbin.org/patch"}"#;
        let result = ajax(opts);
        assert!(result.is_err(), "PATCH 方法应返回错误");
        assert!(result.unwrap_err().contains("unsupported method"));
    }

    /// 测试 ajaxAll 批量并发请求
    #[test]
    fn test_ajax_all() {
        let urls = serde_json::json!([
            "https://httpbin.org/get",
            "https://httpbin.org/get",
            "https://httpbin.org/get"
        ]);
        let result = ajax_all(&urls.to_string());
        if let Ok(results_json) = result {
            let results: Vec<String> = serde_json::from_str(&results_json).unwrap();
            assert_eq!(results.len(), 3, "应返回 3 个结果");
            // 仅在服务正常时验证内容
            for body in &results {
                if is_valid_response(body) {
                    assert!(body.contains("httpbin"), "响应应包含 httpbin 标识");
                }
            }
        }
    }

    /// 测试 ajaxAll 无效 JSON 输入
    #[test]
    fn test_ajax_all_invalid_json() {
        let result = ajax_all("not a json array");
        assert!(result.is_err(), "无效 JSON 应返回错误");
        assert!(result.unwrap_err().contains("parse error"));
    }

    /// 测试 parse_headers 解析正确 / 异常输入
    #[test]
    fn test_parse_headers() {
        let valid = r#"{"Authorization": "Bearer token123"}"#;
        let map = parse_headers(Some(valid));
        assert!(map.is_some());
        assert_eq!(
            map.unwrap().get("Authorization").unwrap(),
            "Bearer token123"
        );

        // 无效 JSON 返回 None
        let map = parse_headers(Some("not json"));
        assert!(map.is_none());

        // None 返回 None
        let map = parse_headers(None);
        assert!(map.is_none());
    }

    /// 测试 build_client 构建成功
    #[test]
    fn test_build_client() {
        let client = build_client();
        assert!(client.is_ok(), "默认配置构建客户端应成功");
    }

    /// 测试 build_client_with_timeout 构建成功
    #[test]
    fn test_build_client_with_timeout() {
        let client = build_client_with_timeout(5000);
        assert!(client.is_ok(), "自定义超时构建客户端应成功");
    }

    /// 测试 connect_full 不支持的 HTTP 方法
    #[test]
    fn test_connect_full_unsupported_method() {
        let result = connect_full("https://httpbin.org/get", Some("PATCH"), None, None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("unsupported method"));
    }

    /// 测试 connect_full GET 请求（返回完整响应 JSON）
    #[test]
    fn test_connect_full_get() {
        let result = connect_full(
            "https://httpbin.org/get",
            Some("GET"),
            None,
            None,
            Some(10000),
        );
        if let Ok(resp_json) = result {
            let resp: HttpResponse = serde_json::from_str(&resp_json).unwrap();
            if resp.status_code == 200 {
                assert!(!resp.body.is_empty());
            }
        }
    }

    /// 测试 head_full 返回完整响应 JSON
    #[test]
    fn test_head_full() {
        let result = head_full("https://httpbin.org/get", None);
        if let Ok(resp_json) = result {
            let resp: HttpResponse = serde_json::from_str(&resp_json).unwrap();
            // HEAD 请求应有状态码
            assert!(resp.status_code > 0);
        }
    }

    /// 测试 post_full 返回完整响应 JSON
    #[test]
    fn test_post_full() {
        let result = post_full(
            "https://httpbin.org/post",
            r#"{"key":"value"}"#,
            Some(r#"{"Content-Type":"application/json"}"#),
        );
        if let Ok(resp_json) = result {
            let resp: HttpResponse = serde_json::from_str(&resp_json).unwrap();
            if resp.status_code == 200 {
                assert!(resp.body.contains("key"));
            }
        }
    }
}
