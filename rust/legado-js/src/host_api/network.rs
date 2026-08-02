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
    /// 请求体（POST/PUT 时使用）
    #[serde(default)]
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
}

/// 从 JSON 字符串解析请求头
fn parse_headers(headers_json: Option<&str>) -> Option<HashMap<String, String>> {
    headers_json.and_then(|s| serde_json::from_str::<HashMap<String, String>>(s).ok())
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

/// ajax(options_json) → 通用 AJAX 请求，返回 HttpResponse JSON
///
/// 支持通过 JSON 配置 method / url / headers / body / timeout_ms。
/// 对应 Kotlin 端 `ajax(url)` 和 `connect(url, header, timeout)` 的通用版本。
pub fn ajax(options_json: &str) -> Result<String, String> {
    let opts: HttpOptions = serde_json::from_str(options_json)
        .map_err(|e| format!("ajax parse options error: {}", e))?;

    if opts.url.is_empty() {
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
            url: opts.url.clone(),
            method,
            headers: opts.headers.unwrap_or_default(),
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
        };

        serde_json::to_string(&result).map_err(|e| format!("ajax serialize error: {}", e))
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
        };
        serde_json::to_string(&result).map_err(|e| format!("connect serialize error: {}", e))
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
        };
        serde_json::to_string(&result).map_err(|e| format!("head serialize error: {}", e))
    })
}

/// postFull(url, body, headers?) → POST 请求完整响应 JSON
///
/// 对应 Kotlin: `post(urlStr, body, headers): Connection.Response`
/// 返回包含 statusCode / body / headers 的完整响应 JSON。
pub fn post_full(
    url: &str,
    body: &str,
    headers_json: Option<&str>,
) -> Result<String, String> {
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
        let result = connect_full("https://httpbin.org/get", Some("GET"), None, None, Some(10000));
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
