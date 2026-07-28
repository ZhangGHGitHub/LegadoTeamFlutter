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

/// toast - 日志输出（弹窗提示的替代）
///
/// 对应 Kotlin: `toast(msg)` -> appCtx.toastOnUi(...)
/// 在 Rust 侧输出到 stderr 日志
pub fn toast(msg: &str) -> String {
    eprintln!("[TOAST] {}", msg);
    msg.to_string()
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
    fn test_log_type() {
        assert_eq!(log_type(""), "null");
        assert_eq!(log_type("123"), "java.lang.Long");
        assert_eq!(log_type("3.14"), "java.lang.Double");
        assert_eq!(log_type("true"), "java.lang.Boolean");
        assert_eq!(log_type("{\"a\":1}"), "org.json.JSONObject");
        assert_eq!(log_type("hello"), "java.lang.String");
    }
}
