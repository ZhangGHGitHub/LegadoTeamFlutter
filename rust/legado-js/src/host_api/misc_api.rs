//! 杂项 API
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 connect / getSource / getTag / ajaxTestAll /
//! toUrl / toast / logType 等方法。

/// connect - HTTP GET with headers，返回响应体
///
/// 对应 Kotlin: `connect(urlStr, header)` -> StrResponse
/// 简化实现：使用 legado-net 执行 GET 请求。
#[cfg(feature = "quickjs")]
pub fn connect(url: &str, header: &str) -> String {
    use crate::host_api::runtime_bridge::block_on;
    use legado_net::{LegadoClient, LegadoClientConfig};
    use std::collections::HashMap;

    let headers: Option<HashMap<String, String>> = if header.is_empty() {
        None
    } else {
        serde_json::from_str(header).ok()
    };

    let result = block_on(async {
        let config = LegadoClientConfig::default();
        let client = match LegadoClient::new(config) {
            Ok(c) => c,
            Err(e) => return format!("[ERROR] {}", e),
        };
        match client.get(url, headers).await {
            Ok(resp) => resp.body,
            Err(e) => format!("[ERROR] {}", e),
        }
    });
    result
}

/// connect 的非 quickjs fallback
#[cfg(not(feature = "quickjs"))]
pub fn connect(_url: &str, _header: &str) -> String {
    "[ERROR] connect requires quickjs feature".to_string()
}

/// getSource - 从 DB 获取书源 JSON
///
/// 对应 Kotlin: `getSource()` -> BaseSource?
/// 简化实现：返回空 JSON（实际需从全局上下文获取当前书源）
pub fn get_source(source_url: &str) -> String {
    if source_url.is_empty() {
        return "null".to_string();
    }
    // 返回一个最小的书源 JSON 结构
    serde_json::json!({
        "bookSourceUrl": source_url,
        "bookSourceName": "",
        "bookSourceType": 0,
        "enabled": true
    })
    .to_string()
}

/// getTag - 获取标签
///
/// 对应 Kotlin: `getTag()` -> String?
/// 简化实现：返回 source_url 作为 tag
pub fn get_tag(tag_name: &str) -> String {
    if tag_name.is_empty() {
        return "null".to_string();
    }
    tag_name.to_string()
}

/// ajaxTestAll - 批量测试 URL 可达性
///
/// 对应 Kotlin: `ajaxTestAll(urlList, timeout)` -> Array<StrResponse>
/// 简化实现：对每个 URL 执行 GET 请求，返回 JSON 数组结果
#[cfg(feature = "quickjs")]
pub fn ajax_test_all(urls: &str) -> String {
    use crate::host_api::runtime_bridge::block_on;
    use legado_net::{LegadoClient, LegadoClientConfig};

    let url_list: Vec<String> = serde_json::from_str(urls).unwrap_or_else(|_| {
        urls.split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    });

    let results = block_on(async {
        let config = LegadoClientConfig::default();
        let client = match LegadoClient::new(config) {
            Ok(c) => c,
            Err(_) => return vec![],
        };
        let mut results = Vec::new();

        for url in &url_list {
            let status = match client.get(url, None).await {
                Ok(resp) => resp.status,
                Err(_) => 0,
            };
            results.push(serde_json::json!({
                "url": url,
                "statusCode": status,
                "success": (200..400).contains(&status)
            }));
        }
        results
    });

    serde_json::to_string(&results).unwrap_or_else(|_| "[]".to_string())
}

/// ajaxTestAll 的非 quickjs fallback
#[cfg(not(feature = "quickjs"))]
pub fn ajax_test_all(_urls: &str) -> String {
    "[]".to_string()
}

/// toUrl - URL 拼接
///
/// 对应 Kotlin: `toURL(url, baseUrl)` -> JsURL
/// 将 path 和 query 拼接为完整 URL
pub fn to_url(path: &str, query: &str) -> String {
    if query.is_empty() {
        return path.to_string();
    }
    let separator = if path.contains('?') { "&" } else { "?" };
    format!("{}{}{}", path, separator, query)
}

/// toast - 日志输出 + UI 队列（对齐原版 appCtx.toastOnUi 的可见提示）
///
/// 对应 Kotlin: `toast(msg)` -> appCtx.toastOnUi(...)
/// 收集开启时入队 `{"action":"toast","message":...}` 由 Flutter 展示
/// SnackBar（登录表单「正在登录/登录成功/请先填写账号密码」等提示与
/// 原版一致可见）；未收集时仅输出 stderr 日志。
/// — DeepSeek Harness + Bridge（2026-08-14 登录消息对齐）
pub fn toast(msg: &str) -> String {
    eprintln!("[TOAST] {}", msg);
    crate::host_api::ui_action_queue::push_action(serde_json::json!({
        "action": "toast",
        "message": msg,
    }));
    msg.to_string()
}

/// longToast - 长提示（UI 队列 + 日志输出替代）
///
/// 对应 Kotlin: `longToast(msg)` -> appCtx.longToastOnUi("${getTag()}: ${msg}")
/// 与 toast 一致入队 UI 动作（Flutter 侧长停留 SnackBar）；未收集时
/// 仅输出 stderr 日志。
pub fn long_toast(msg: &str) -> String {
    eprintln!("[LONG_TOAST] {}", msg);
    crate::host_api::ui_action_queue::push_action(serde_json::json!({
        "action": "longToast",
        "message": msg,
    }));
    msg.to_string()
}

// ============================================================
// toURL — JsURL 解析（对齐 Kotlin `utils/JsURL.kt`）
// ============================================================

/// JsURL 解析结果，字段对齐 Kotlin `JsURL`：
/// `host` / `origin`（protocol://host[:port]） / `pathname` /
/// `searchParams`（URL 解码后的键值对，无 query 时为 None）
#[derive(Debug, Clone, PartialEq)]
pub struct UrlParts {
    pub host: String,
    pub origin: String,
    pub pathname: String,
    pub search_params: Option<Vec<(String, String)>>,
}

/// 解析 URL 为 JsURL 结构，支持相对路径基于 baseUrl 解析
///
/// 对应 Kotlin: `toURL(urlStr, baseUrl?) -> JsURL`（内部 java.net.URL）。
/// 仅解析值，不做值解码以外的归一化，保持与 Kotlin JsURL 字段语义一致。
pub fn parse_js_url(url_str: &str, base_url: &str) -> Result<UrlParts, String> {
    let resolved = resolve_url(url_str, base_url)?;

    // 拆分 scheme 与剩余部分：protocol://rest
    let scheme_end = resolved
        .find("://")
        .ok_or_else(|| format!("Malformed URL: {}", url_str))?;
    let scheme = &resolved[..scheme_end];
    let rest = &resolved[scheme_end + 3..];

    // authority（host[:port]）到第一个 '/' '?' '#' 为止
    let auth_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let mut authority = &rest[..auth_end];
    let remainder = &rest[auth_end..];

    // 去除 userinfo（user:pass@host）
    if let Some(at) = authority.rfind('@') {
        authority = &authority[at + 1..];
    }
    if authority.is_empty() {
        return Err(format!("Malformed URL: {}", url_str));
    }

    // host[:port]：仅当冒号后全为数字时视为端口
    let (host, port) = match authority.rfind(':') {
        Some(i)
            if i + 1 < authority.len()
                && authority[i + 1..].chars().all(|c| c.is_ascii_digit()) =>
        {
            (authority[..i].to_string(), Some(&authority[i + 1..]))
        }
        _ => (authority.to_string(), None),
    };

    // origin：对齐 Kotlin JsURL（port > 0 时拼接端口）
    let origin = match port {
        Some(p) => format!("{}://{}:{}", scheme, host, p),
        None => format!("{}://{}", scheme, host),
    };

    // path 与 query（均截断到 fragment '#' 前）
    let (raw_path, raw_query) = match remainder.find('?') {
        Some(i) => (&remainder[..i], Some(&remainder[i + 1..])),
        None => (remainder, None),
    };
    let pathname = raw_path.split('#').next().unwrap_or("").to_string();
    let query = raw_query.map(|q| q.split('#').next().unwrap_or(""));

    // searchParams：对齐 Kotlin JsURL — 仅收集含 '=' 的键值对，值做 URL 解码
    let search_params = query.map(|q| {
        q.split('&')
            .filter_map(|pair| {
                let mut it = pair.splitn(2, '=');
                let key = it.next()?.to_string();
                let value = it.next()?;
                Some((key, url_decode_java(value)))
            })
            .collect()
    });

    Ok(UrlParts {
        host,
        origin,
        pathname,
        search_params,
    })
}

/// 相对 URL 基于 baseUrl 解析为绝对 URL（对齐 java.net.URL(base, url) 行为）
fn resolve_url(url_str: &str, base_url: &str) -> Result<String, String> {
    // 绝对 URL 直接使用
    if url_str.contains("://") {
        return Ok(url_str.to_string());
    }
    if base_url.is_empty() {
        return Err(format!("Malformed URL: {}", url_str));
    }

    let scheme_end = base_url
        .find("://")
        .ok_or_else(|| format!("Malformed base URL: {}", base_url))?;
    let scheme = &base_url[..scheme_end];
    let rest = &base_url[scheme_end + 3..];

    // 协议相对：//host/path
    if url_str.starts_with("//") {
        return Ok(format!("{}:{}", scheme, url_str));
    }

    let auth_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..auth_end];

    // 绝对路径：/path
    if url_str.starts_with('/') {
        return Ok(format!("{}://{}{}", scheme, authority, url_str));
    }

    // 仅 query：?a=b → 保留 base 的 path
    if url_str.starts_with('?') {
        let base_path = rest[..rest.find('?').unwrap_or(rest.len())]
            .split('#')
            .next()
            .unwrap_or("");
        return Ok(format!(
            "{}://{}{}{}",
            scheme, authority, base_path, url_str
        ));
    }

    // 相对路径：拼接 base 的目录部分（对齐 java.net.URL 去掉末段文件名）
    let base_tail = &rest[auth_end..];
    let base_path = base_tail[..base_tail.find('?').unwrap_or(base_tail.len())]
        .split('#')
        .next()
        .unwrap_or("");
    let dir = match base_path.rfind('/') {
        Some(i) => &base_path[..=i],
        None => "/",
    };
    Ok(format!("{}://{}{}{}", scheme, authority, dir, url_str))
}

/// Java `URLDecoder.decode(s, "UTF-8")` 语义：%XX 解码且 '+' → 空格
///
/// 手写实现（不依赖 percent-encoding crate，保证非 quickjs 构建可编译）；
/// 非法 %XX 序列原样保留，最终按 UTF-8 lossy 转字符串。
fn url_decode_java(input: &str) -> String {
    fn hex_digit(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }

    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                match (hex_digit(bytes[i + 1]), hex_digit(bytes[i + 2])) {
                    (Some(h), Some(l)) => {
                        out.push(h * 16 + l);
                        i += 3;
                    }
                    _ => {
                        out.push(b'%');
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// logType - 输出类型信息
///
/// 对应 Kotlin: `logType(any)` -> log(any.javaClass.name)
/// 在 Rust 侧返回值的类型描述
pub fn log_type(value: &str) -> String {
    let type_desc = if value.is_empty() {
        "null"
    } else if value.parse::<i64>().is_ok() {
        "java.lang.Long"
    } else if value.parse::<f64>().is_ok() {
        "java.lang.Double"
    } else if value == "true" || value == "false" {
        "java.lang.Boolean"
    } else if value.starts_with('{') || value.starts_with('[') {
        "org.json.JSONObject"
    } else {
        "java.lang.String"
    };
    eprintln!("[LOG_TYPE] {}", type_desc);
    type_desc.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_source_empty() {
        assert_eq!(get_source(""), "null");
    }

    #[test]
    fn test_get_source_with_url() {
        let json = get_source("https://example.com");
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["bookSourceUrl"], "https://example.com");
    }

    #[test]
    fn test_get_tag() {
        assert_eq!(get_tag(""), "null");
        assert_eq!(get_tag("myTag"), "myTag");
    }

    #[test]
    fn test_to_url_no_query() {
        assert_eq!(to_url("https://a.com/path", ""), "https://a.com/path");
    }

    #[test]
    fn test_to_url_with_query() {
        assert_eq!(
            to_url("https://a.com/path", "key=val"),
            "https://a.com/path?key=val"
        );
        assert_eq!(
            to_url("https://a.com/path?x=1", "key=val"),
            "https://a.com/path?x=1&key=val"
        );
    }

    #[test]
    fn test_toast() {
        let result = toast("hello");
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_long_toast() {
        let result = long_toast("长提示内容");
        assert_eq!(result, "长提示内容");
    }

    #[test]
    fn test_parse_js_url_full() {
        let parts = parse_js_url("https://ex.com:8080/a/b?x=1&y=%E4%B8%AD", "").unwrap();
        assert_eq!(parts.host, "ex.com");
        assert_eq!(parts.origin, "https://ex.com:8080");
        assert_eq!(parts.pathname, "/a/b");
        let params = parts.search_params.unwrap();
        assert_eq!(
            params,
            vec![("x".into(), "1".into()), ("y".into(), "中".into())]
        );
    }

    #[test]
    fn test_parse_js_url_no_port_no_query() {
        let parts = parse_js_url("http://ex.com/path/to.html", "").unwrap();
        assert_eq!(parts.host, "ex.com");
        assert_eq!(parts.origin, "http://ex.com");
        assert_eq!(parts.pathname, "/path/to.html");
        assert!(parts.search_params.is_none());
    }

    #[test]
    fn test_parse_js_url_relative_base() {
        // 相对路径：取 base 目录部分拼接
        let parts = parse_js_url("c.html", "https://ex.com/a/b.html").unwrap();
        assert_eq!(parts.pathname, "/a/c.html");
        assert_eq!(parts.host, "ex.com");

        // 绝对路径：替换整个 path
        let parts = parse_js_url("/c", "https://ex.com/a/b.html").unwrap();
        assert_eq!(parts.pathname, "/c");

        // 仅 query：保留 base path
        let parts = parse_js_url("?k=v", "https://ex.com/a/b.html").unwrap();
        assert_eq!(parts.pathname, "/a/b.html");
        assert_eq!(parts.search_params.unwrap(), vec![("k".into(), "v".into())]);
    }

    #[test]
    fn test_parse_js_url_plus_and_userinfo() {
        // '+' 解码为空格（Java URLDecoder 语义），userinfo 被剥离
        let parts = parse_js_url("http://user:pw@ex.com/p?q=a+b", "").unwrap();
        assert_eq!(parts.host, "ex.com");
        assert_eq!(
            parts.search_params.unwrap(),
            vec![("q".into(), "a b".into())]
        );
    }

    #[test]
    fn test_parse_js_url_invalid() {
        assert!(parse_js_url("not-a-url", "").is_err());
        assert!(parse_js_url("https://", "").is_err());
    }

    #[test]
    fn test_log_type() {
        assert_eq!(log_type(""), "null");
        assert_eq!(log_type("123"), "java.lang.Long");
        assert_eq!(log_type("3.14"), "java.lang.Double");
        assert_eq!(log_type("true"), "java.lang.Boolean");
        assert_eq!(log_type("{\"a\":1}"), "org.json.JSONObject");
        assert_eq!(log_type("hello"), "java.lang.String");
    }
}
