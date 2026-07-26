//! URL 模板解析模块
//!
//! 参考 Kotlin `AnalyzeUrl.kt` 的 URL 模板部分，实现基础版本：
//! - `{key}` 参数替换
//! - `<page1,page2,...>` 页数替换
//! - `,` 后 JSON 参数解析（UrlOption）
//! - `{{...}}` 内嵌表达式占位（此处仅做文本替换，不执行 JS）

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::LazyLock;

/// `{key}` 形式的参数占位符
static KEY_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\{(\w+)\}").expect("invalid regex"));

/// `<page1,page2,...>` 页数占位符（对应 AnalyzeUrl 中的 `pagePattern`）
static PAGE_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<([^>]+)>").expect("invalid regex"));

/// URL 后 `,` 分隔的 JSON 参数（对应 `paramPattern`）
/// 匹配 `,` 后紧跟 `{` 的位置，用于分割 URL 和 JSON 选项
static PARAM_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*,\s*\{").expect("invalid regex"));

/// URL 选项参数（对应 Kotlin `UrlOption`）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UrlOption {
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default, alias = "Headers")]
    pub headers: Option<HashMap<String, String>>,
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub r#type: Option<String>,
    #[serde(default)]
    pub retry: Option<u32>,
    #[serde(default)]
    pub timeout: Option<u64>,
    #[serde(default, alias = "useWebView")]
    pub use_web_view: Option<bool>,
    #[serde(default, alias = "webJs")]
    pub web_js: Option<String>,
    #[serde(default, alias = "bodyJs")]
    pub body_js: Option<String>,
    #[serde(default, alias = "followRedirects")]
    pub follow_redirects: Option<bool>,
    #[serde(default, alias = "dnsIp")]
    pub dns_ip: Option<String>,
    #[serde(default)]
    pub proxy: Option<String>,
    #[serde(default, alias = "js")]
    pub js: Option<String>,
    #[serde(default, alias = "serverID")]
    pub server_id: Option<i64>,
}

impl UrlOption {
    /// 返回 HTTP 方法（大写），默认 GET
    pub fn get_method(&self) -> String {
        self.method.as_deref().unwrap_or("GET").to_uppercase()
    }
}

/// URL 模板解析结果
#[derive(Debug, Clone)]
pub struct ParsedUrl {
    /// 处理后的最终 URL
    pub url: String,
    /// 从 URL 中提取的 JSON 选项
    pub option: Option<UrlOption>,
    /// 请求方法
    pub method: String,
    /// 请求头（从选项合并）
    pub headers: HashMap<String, String>,
    /// 请求体
    pub body: Option<String>,
}

/// 解析 URL 模板，替换参数并提取选项
///
/// # 参数
/// - `template`: 原始 URL 模板字符串
/// - `key`: 搜索关键字（替换 `{key}` 和 `searchKey`）
/// - `page`: 当前页码（从 1 开始，用于 `<...>` 页数替换）
/// - `base_url`: 基础 URL，用于相对路径解析
/// - `params`: 额外的键值对参数，用于 `{xxx}` 替换
pub fn parse_url_template(
    template: &str,
    key: Option<&str>,
    page: Option<u32>,
    base_url: &str,
    params: &HashMap<String, String>,
) -> ParsedUrl {
    let mut url = template.to_string();

    // 1. 替换 {key} 参数
    url = replace_key_params(&url, key, params);

    // 2. 替换页数 <page1,page2,...>
    if let Some(p) = page {
        url = replace_page(&url, p);
    }

    // 3. 分离 URL 和 JSON 选项（以首个 `,` 后跟 `{` 为分隔）
    let (url_part, option) = split_url_option(&url);
    let url = resolve_url(base_url, &url_part);

    // 4. 从选项中提取方法、请求头、请求体
    let method = option
        .as_ref()
        .map(|o| o.get_method())
        .unwrap_or_else(|| "GET".to_string());

    let mut headers = HashMap::new();
    if let Some(ref opt) = option {
        if let Some(ref h) = opt.headers {
            headers.extend(h.iter().map(|(k, v)| (k.clone(), v.clone())));
        }
    }

    let body = option.as_ref().and_then(|o| o.body.clone());

    ParsedUrl {
        url,
        option,
        method,
        headers,
        body,
    }
}

/// 替换 `{key}` 形式的参数占位符
///
/// 特殊键: `key` / `searchKey` 使用传入的 `key` 参数值
fn replace_key_params(url: &str, key: Option<&str>, params: &HashMap<String, String>) -> String {
    KEY_PATTERN
        .replace_all(url, |caps: &regex::Captures| {
            let name = &caps[1];
            // 特殊键
            if name == "key" || name == "searchKey" {
                if let Some(k) = key {
                    return urlencoded(k);
                }
            }
            // 自定义参数
            if let Some(v) = params.get(name) {
                return urlencoded(v);
            }
            // 未找到则保留原样
            caps[0].to_string()
        })
        .to_string()
}

/// 替换 `<page1,page2,...>` 页数占位符
fn replace_page(url: &str, page: u32) -> String {
    PAGE_PATTERN
        .replace_all(url, |caps: &regex::Captures| {
            let pages: Vec<&str> = caps[1].split(',').collect();
            if pages.is_empty() {
                return String::new();
            }
            // page 从 1 开始，索引从 0 开始
            let idx = if page >= 1 { (page as usize) - 1 } else { 0 };
            let idx = idx.min(pages.len() - 1);
            pages[idx].trim().to_string()
        })
        .to_string()
}

/// 以 `,` 分隔 URL 和 JSON 选项
fn split_url_option(url: &str) -> (String, Option<UrlOption>) {
    if let Some(m) = PARAM_PATTERN.find(url) {
        let url_part = url[..m.start()].to_string();
        // 匹配中包含 `{`，需要从 `{` 开始截取 JSON 部分
        let json_start = url[m.start()..]
            .find('{')
            .map(|i| m.start() + i)
            .unwrap_or(m.end());
        let json_part = &url[json_start..];
        let option = serde_json::from_str::<UrlOption>(json_part).ok();
        (url_part, option)
    } else {
        (url.to_string(), None)
    }
}

/// 将相对 URL 解析为绝对 URL
fn resolve_url(base: &str, relative: &str) -> String {
    if relative.starts_with("http://") || relative.starts_with("https://") {
        return relative.to_string();
    }
    if base.is_empty() {
        return relative.to_string();
    }
    match url::Url::parse(base) {
        Ok(base_url) => base_url
            .join(relative)
            .map(|u| u.to_string())
            .unwrap_or(relative.to_string()),
        Err(_) => relative.to_string(),
    }
}

/// 简易 URL 编码（仅编码常见特殊字符）
fn urlencoded(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(b as char);
            }
            _ => {
                result.push_str(&format!("%{:02X}", b));
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replace_key() {
        let params = HashMap::new();
        let result = replace_key_params(
            "https://example.com/search?q={key}",
            Some("rust编程"),
            &params,
        );
        assert!(result.contains("q="));
        assert!(!result.contains("{key}"));
    }

    #[test]
    fn test_replace_custom_param() {
        let mut params = HashMap::new();
        params.insert("category".to_string(), "books".to_string());
        let result = replace_key_params("https://example.com/{category}/list", None, &params);
        assert_eq!(result, "https://example.com/books/list");
    }

    #[test]
    fn test_replace_page() {
        let result = replace_page("https://example.com/page/<1,2,3,4>", 2);
        assert_eq!(result, "https://example.com/page/2");
    }

    #[test]
    fn test_replace_page_overflow() {
        // page 超出范围时使用最后一个
        let result = replace_page("https://example.com/page/<1,2,3>", 10);
        assert_eq!(result, "https://example.com/page/3");
    }

    #[test]
    fn test_split_url_option() {
        let input = r#"https://example.com/api,{"method":"POST","body":"data"}"#;
        let (url, opt) = split_url_option(input);
        assert_eq!(url, "https://example.com/api");
        assert!(opt.is_some());
        let opt = opt.unwrap();
        assert_eq!(opt.get_method(), "POST");
        assert_eq!(opt.body, Some("data".to_string()));
    }

    #[test]
    fn test_parse_url_template_full() {
        let params = HashMap::new();
        let result = parse_url_template(
            "https://example.com/search?q={key}",
            Some("test"),
            None,
            "",
            &params,
        );
        assert!(result.url.starts_with("https://example.com/search?q="));
        assert_eq!(result.method, "GET");
    }

    #[test]
    fn test_url_option_default_method() {
        let opt = UrlOption::default();
        assert_eq!(opt.get_method(), "GET");
    }

    #[test]
    fn test_url_option_post_method() {
        let opt = UrlOption {
            method: Some("post".to_string()),
            ..UrlOption::default()
        };
        assert_eq!(opt.get_method(), "POST");
    }

    #[test]
    fn test_parse_url_template_with_post_option() {
        let params = HashMap::new();
        let result = parse_url_template(
            r#"https://example.com/api,{"method":"POST","body":"hello"}"#,
            None,
            None,
            "",
            &params,
        );
        assert_eq!(result.url, "https://example.com/api");
        assert_eq!(result.method, "POST");
        assert_eq!(result.body, Some("hello".to_string()));
    }

    #[test]
    fn test_parse_url_template_with_headers() {
        let params = HashMap::new();
        let result = parse_url_template(
            r#"https://example.com/api,{"Headers":{"X-Key":"abc123"}}"#,
            None,
            None,
            "",
            &params,
        );
        assert_eq!(result.headers.get("X-Key"), Some(&"abc123".to_string()));
    }

    #[test]
    fn test_resolve_relative_url() {
        let result = resolve_url("https://example.com/books/", "chapter1.html");
        assert_eq!(result, "https://example.com/books/chapter1.html");
    }

    #[test]
    fn test_resolve_absolute_url() {
        let result = resolve_url("https://example.com/", "https://other.com/page");
        assert_eq!(result, "https://other.com/page");
    }

    #[test]
    fn test_urlencoded_special_chars() {
        let encoded = urlencoded("hello world&foo=bar");
        assert!(encoded.contains("%20"));
        assert!(encoded.contains("%26"));
        assert!(encoded.contains("%3D"));
    }

    #[test]
    fn test_replace_key_search_key() {
        let params = HashMap::new();
        let result = replace_key_params(
            "https://example.com/search?q={searchKey}",
            Some("rust"),
            &params,
        );
        assert!(!result.contains("{searchKey}"));
        assert!(result.contains("rust"));
    }

    #[test]
    fn test_replace_key_missing_param_preserved() {
        let params = HashMap::new();
        let result = replace_key_params("https://example.com/{unknown}", None, &params);
        assert!(result.contains("{unknown}"));
    }

    #[test]
    fn test_replace_page_first() {
        let result = replace_page("https://example.com/<a,b,c>", 1);
        assert_eq!(result, "https://example.com/a");
    }
}
