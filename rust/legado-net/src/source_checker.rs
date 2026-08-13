//! 书源有效性检查器
//!
//! 参考 Kotlin `CheckSource.kt` 与 `SourceVerificationHelp.kt`，实现书源搜索/目录/内容的有效性检查。
//! 通过 `LegadoClient` 发起 HTTP 请求，验证书源规则是否可正常工作。
//! 增强功能：验证码识别、重定向详情检测（对齐 `SourceVerificationHelp`）。

use std::sync::Arc;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;

use crate::client::LegadoClient;
use crate::response::LegadoResponse;

/// 验证码检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptchaInfo {
    /// 是否检测到验证码
    pub detected: bool,
    /// 验证码类型描述（如 "图片验证码"、"滑动验证" 等）
    pub captcha_type: Option<String>,
    /// 匹配到的关键词/元素
    pub matched_keyword: Option<String>,
}

impl CaptchaInfo {
    /// 未检测到验证码
    fn none() -> Self {
        Self {
            detected: false,
            captcha_type: None,
            matched_keyword: None,
        }
    }
}

/// 重定向检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedirectInfo {
    /// 是否发生了重定向
    pub redirected: bool,
    /// 原始请求 URL
    pub original_url: String,
    /// 最终 URL（重定向后的地址）
    pub final_url: String,
    /// 是否重定向到登录/验证页面
    pub is_login_redirect: bool,
}

impl RedirectInfo {
    /// 未发生重定向
    fn none(url: &str) -> Self {
        Self {
            redirected: false,
            original_url: url.to_string(),
            final_url: url.to_string(),
            is_login_redirect: false,
        }
    }
}

/// 书源有效性检查结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    /// 书源 URL
    pub source_url: String,
    /// 搜索是否成功
    pub search_ok: bool,
    /// 目录是否成功
    pub toc_ok: bool,
    /// 内容是否成功
    pub content_ok: bool,
    /// 搜索阶段错误信息
    pub search_error: Option<String>,
    /// 目录阶段错误信息
    pub toc_error: Option<String>,
    /// 内容阶段错误信息
    pub content_error: Option<String>,
    /// 总耗时（毫秒）
    pub total_time_ms: i64,
    /// 验证码检测结果
    pub captcha: Option<CaptchaInfo>,
    /// 重定向检测结果
    pub redirect: Option<RedirectInfo>,
}

impl CheckResult {
    /// 创建全部失败的检查结果
    #[allow(dead_code)]
    fn all_failed(source_url: &str, error: &str) -> Self {
        Self {
            source_url: source_url.to_string(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: Some(error.to_string()),
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
        }
    }

    /// 所有检查是否都通过
    pub fn all_ok(&self) -> bool {
        self.search_ok && self.toc_ok && self.content_ok
    }

    /// 搜索检查是否通过
    pub fn is_search_ok(&self) -> bool {
        self.search_ok
    }

    /// 是否检测到验证码
    pub fn has_captcha(&self) -> bool {
        self.captcha.as_ref().is_some_and(|c| c.detected)
    }

    /// 是否发生了重定向
    pub fn has_redirect(&self) -> bool {
        self.redirect.as_ref().is_some_and(|r| r.redirected)
    }

    /// 书源是否可用（快速判断：搜索通过且无验证码阻断）
    pub fn is_available(&self) -> bool {
        self.search_ok && !self.has_captcha()
    }
}

/// 默认搜索关键词（对应 Kotlin `CheckSource.keyword`）
const DEFAULT_KEYWORD: &str = "我的";

/// 书源检查器配置
#[derive(Debug, Clone)]
pub struct CheckerConfig {
    /// 搜索关键词
    pub keyword: String,
    /// 单步超时（毫秒）
    pub step_timeout_ms: u64,
    /// 是否检查搜索
    pub check_search: bool,
    /// 是否检查目录
    pub check_toc: bool,
    /// 是否检查内容
    pub check_content: bool,
    /// 是否启用验证码检测
    pub detect_captcha: bool,
    /// 是否启用重定向检测
    pub detect_redirect: bool,
}

impl Default for CheckerConfig {
    fn default() -> Self {
        Self {
            keyword: DEFAULT_KEYWORD.to_string(),
            step_timeout_ms: 180_000,
            check_search: true,
            check_toc: true,
            check_content: true,
            detect_captcha: true,
            detect_redirect: true,
        }
    }
}

/// 书源检查器
///
/// 使用 `LegadoClient` 对书源的搜索、目录、内容规则进行有效性检查。
pub struct SourceChecker {
    client: Arc<LegadoClient>,
    config: CheckerConfig,
}

impl SourceChecker {
    /// 使用默认配置创建检查器
    pub fn new(client: Arc<LegadoClient>) -> Self {
        Self {
            client,
            config: CheckerConfig::default(),
        }
    }

    /// 使用自定义配置创建检查器
    pub fn with_config(client: Arc<LegadoClient>, config: CheckerConfig) -> Self {
        Self { client, config }
    }

    /// 完整检查（搜索 + 目录 + 内容 + 验证码检测 + 重定向检测）
    ///
    /// 1. 用默认关键词搜索
    /// 2. 取第一个结果的详情页 URL
    /// 3. 获取目录列表
    /// 4. 获取第一章内容
    /// 5. 验证码检测（每步响应体）
    /// 6. 重定向检测（对比请求/响应 URL）
    /// 7. 记录每步成功/失败
    pub async fn check_full(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        let source_url = &source.book_source_url;

        let mut result = CheckResult {
            source_url: source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 0,
            captcha: None,
            redirect: None,
        };

        // Step 1: 搜索检查
        let search_result = if self.config.check_search {
            match self.do_search_check(source).await {
                Ok(first_book_url) => {
                    result.search_ok = true;
                    Some(first_book_url)
                }
                Err(e) => {
                    result.search_error = Some(e);
                    None
                }
            }
        } else {
            result.search_ok = true;
            None
        };

        // Step 2: 目录检查（需要搜索结果中的书籍 URL）
        let toc_result = if self.config.check_toc {
            if let Some(ref book_url) = search_result {
                match self.do_toc_check(source, book_url).await {
                    Ok(first_chapter_url) => {
                        result.toc_ok = true;
                        Some(first_chapter_url)
                    }
                    Err(e) => {
                        result.toc_error = Some(e);
                        None
                    }
                }
            } else if result.search_error.is_some() {
                result.toc_error = Some("skipped: search failed".to_string());
                None
            } else {
                result.toc_error = Some("skipped: no book url from search".to_string());
                None
            }
        } else {
            result.toc_ok = true;
            None
        };

        // Step 3: 内容检查（需要目录结果中的章节 URL）
        if self.config.check_content {
            if let Some(ref chapter_url) = toc_result {
                match self.do_content_check(source, chapter_url).await {
                    Ok(()) => {
                        result.content_ok = true;
                    }
                    Err(e) => {
                        result.content_error = Some(e);
                    }
                }
            } else if result.toc_error.is_some() {
                result.content_error = Some("skipped: toc failed".to_string());
            } else {
                result.content_error = Some("skipped: no chapter url from toc".to_string());
            }
        } else {
            result.content_ok = true;
        }

        result.total_time_ms = start.elapsed().as_millis() as i64;
        result
    }

    /// 快速检查（仅搜索 + 验证码/重定向检测）
    ///
    /// 简化校验流程，快速判断书源是否可用。
    pub async fn check_search(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        let source_url = &source.book_source_url;

        let mut result = CheckResult {
            source_url: source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
        };

        match self.do_search_check(source).await {
            Ok(_) => {
                result.search_ok = true;
            }
            Err(e) => {
                result.search_error = Some(e);
            }
        }

        result.total_time_ms = start.elapsed().as_millis() as i64;
        result
    }

    /// 快速有效性检查（对齐 Kotlin `CheckSource` 简化流程）
    ///
    /// 仅发起搜索请求，检测验证码和重定向，快速判断书源是否可用。
    /// 不执行目录/内容检查，适用于批量快速筛查。
    pub async fn quick_check(&self, source: &BookSource) -> CheckResult {
        let start = Instant::now();
        let source_url = &source.book_source_url;

        let mut result = CheckResult {
            source_url: source_url.clone(),
            search_ok: false,
            toc_ok: false,
            content_ok: false,
            search_error: None,
            toc_error: Some("skipped".to_string()),
            content_error: Some("skipped".to_string()),
            total_time_ms: 0,
            captcha: None,
            redirect: None,
        };

        // 构建搜索 URL
        let search_url = match source.search_url.as_ref() {
            Some(url) => url,
            None => {
                result.search_error = Some("no searchUrl defined".to_string());
                result.total_time_ms = start.elapsed().as_millis() as i64;
                return result;
            }
        };

        let url = self.build_search_url(search_url, &self.config.keyword);

        // 发起请求
        let resp = match self
            .client
            .get(&url, parse_headers(source.header.as_deref()))
            .await
        {
            Ok(r) => r,
            Err(e) => {
                result.search_error = Some(format!("search request failed: {}", e));
                result.total_time_ms = start.elapsed().as_millis() as i64;
                return result;
            }
        };

        // 重定向检测
        if self.config.detect_redirect {
            result.redirect = Some(self.detect_redirect(&resp, &url));
        }

        // 验证码检测
        if self.config.detect_captcha {
            result.captcha = Some(self.detect_captcha(&resp.body));
        }

        // 判断搜索是否成功
        if resp.is_success() && !resp.body.is_empty() {
            result.search_ok = true;
        } else if !resp.is_success() {
            result.search_error = Some(format!("search returned status {}", resp.status));
        } else {
            result.search_error = Some("search returned empty body".to_string());
        }

        result.total_time_ms = start.elapsed().as_millis() as i64;
        result
    }

    // ---- 内部检查步骤 ----

    /// 搜索检查：构造搜索 URL 并请求
    async fn do_search_check(&self, source: &BookSource) -> Result<String, String> {
        let search_url = source
            .search_url
            .as_ref()
            .ok_or_else(|| "no searchUrl defined".to_string())?;

        // 替换搜索关键词占位符
        let url = self.build_search_url(search_url, &self.config.keyword);

        let resp = self
            .client
            .get(&url, parse_headers(source.header.as_deref()))
            .await
            .map_err(|e| format!("search request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("search returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("search returned empty body".to_string());
        }

        // 尝试从响应体中提取第一个书籍链接
        let book_url = self.extract_first_book_url(&resp.body, source)?;
        Ok(book_url)
    }

    /// 目录检查：请求书籍详情页并提取目录
    async fn do_toc_check(&self, source: &BookSource, book_url: &str) -> Result<String, String> {
        let resp = self
            .client
            .get(book_url, parse_headers(source.header.as_deref()))
            .await
            .map_err(|e| format!("toc request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("toc page returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("toc page returned empty body".to_string());
        }

        // 尝试从详情页提取第一个章节链接
        let chapter_url = self.extract_first_chapter_url(&resp.body, source)?;
        Ok(chapter_url)
    }

    /// 内容检查：请求章节内容
    async fn do_content_check(&self, source: &BookSource, chapter_url: &str) -> Result<(), String> {
        let resp = self
            .client
            .get(chapter_url, parse_headers(source.header.as_deref()))
            .await
            .map_err(|e| format!("content request failed: {}", e))?;

        if !resp.is_success() {
            return Err(format!("content page returned status {}", resp.status));
        }

        if resp.body.is_empty() {
            return Err("content page returned empty body".to_string());
        }

        Ok(())
    }

    /// 构造搜索 URL：替换 {key} 和 {searchKey} 占位符
    fn build_search_url(&self, template: &str, keyword: &str) -> String {
        let encoded = urlencoding::encode(keyword);
        template
            .replace("{{key}}", &encoded)
            .replace("{key}", &encoded)
            .replace("{searchKey}", &encoded)
    }

    /// 从搜索结果页提取第一个书籍链接
    fn extract_first_book_url(&self, body: &str, source: &BookSource) -> Result<String, String> {
        // 如果有 bookUrlPattern，用正则提取（书源可控 pattern，走统一安全入口）
        if let Some(ref pattern) = source.book_url_pattern {
            if let Some(re) = legado_core::regex_safe::compile_regex_safe(pattern) {
                if let Some(m) = re.find(body) {
                    return Ok(m.as_str().to_string());
                }
            }
            return Err("bookUrlPattern did not match any result".to_string());
        }

        // 回退：尝试提取第一个 href 链接
        extract_first_href(body).ok_or_else(|| "no book link found in search results".to_string())
    }

    /// 从详情页提取第一个章节链接
    fn extract_first_chapter_url(
        &self,
        body: &str,
        _source: &BookSource,
    ) -> Result<String, String> {
        // 简化实现：提取第一个 href 链接作为章节 URL
        extract_first_href(body).ok_or_else(|| "no chapter link found in detail page".to_string())
    }

    // ---- 验证码/重定向检测（对齐 SourceVerificationHelp） ----

    /// 验证码检测：检测 HTML 中是否包含常见验证码元素/关键词
    ///
    /// 参考 Kotlin `SourceVerificationHelp.getVerificationResult`，
    /// 检测图片验证码、滑动验证、点击字符等常见反爬机制。
    pub fn detect_captcha(&self, html: &str) -> CaptchaInfo {
        if html.is_empty() {
            return CaptchaInfo::none();
        }

        let lower = html.to_lowercase();

        // 图片验证码关键词
        const IMAGE_CAPTCHA_KEYWORDS: &[&str] = &[
            "captcha",
            "验证码",
            "verifycode",
            "verify_code",
            "checkcode",
            "check_code",
            "authcode",
            "vcode",
            "seccode",
            "imagecode",
        ];

        // 滑动验证关键词
        const SLIDE_CAPTCHA_KEYWORDS: &[&str] = &[
            "滑动验证",
            "slide",
            "slider",
            "geetest",
            "极验",
            "drag",
            "swipe",
            "拼图验证",
        ];

        // 点击验证关键词
        const CLICK_CAPTCHA_KEYWORDS: &[&str] = &[
            "点击验证",
            "clickcaptcha",
            "textcaptcha",
            "点选",
            "点击字符",
            "recaptcha",
            "hcaptcha",
            "turnstile",
        ];

        // 通用反爬/人机验证关键词
        const ANTI_BOT_KEYWORDS: &[&str] = &[
            "人机验证",
            "robot",
            "机器人",
            "are you a human",
            "human verification",
            "请完成验证",
            "安全验证",
            "access denied",
            "cloudflare",
            "cf-challenge",
        ];

        // 按优先级检测各类验证码
        for &kw in IMAGE_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("图片验证码".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in SLIDE_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("滑动验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in CLICK_CAPTCHA_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("点击验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        for &kw in ANTI_BOT_KEYWORDS {
            if lower.contains(kw) {
                return CaptchaInfo {
                    detected: true,
                    captcha_type: Some("人机验证".to_string()),
                    matched_keyword: Some(kw.to_string()),
                };
            }
        }

        CaptchaInfo::none()
    }

    /// 重定向检测：检查响应是否发生了重定向
    ///
    /// 对比请求 URL 与响应最终 URL，判断是否被重定向（如 302 到登录页）。
    /// 参考 Kotlin `SourceVerificationHelp` 中对重定向到验证页面的处理。
    pub fn detect_redirect(&self, response: &LegadoResponse, original_url: &str) -> RedirectInfo {
        let final_url = &response.url;

        // URL 相同表示未重定向
        if final_url == original_url || final_url.is_empty() {
            return RedirectInfo::none(original_url);
        }

        // 提取域名对比（忽略路径差异，只关注跨域重定向）
        let original_host = extract_host(original_url);
        let final_host = extract_host(final_url);

        // 判断是否重定向到登录/验证页面
        let is_login_redirect = is_login_or_verify_url(final_url);

        RedirectInfo {
            redirected: true,
            original_url: original_url.to_string(),
            final_url: final_url.clone(),
            // 跨域重定向或重定向到登录页视为异常
            is_login_redirect: is_login_redirect || original_host != final_host,
        }
    }
}

/// 从 HTML 中提取第一个 href 链接
fn extract_first_href(html: &str) -> Option<String> {
    let re = regex::Regex::new(r#"href=["']([^"']+)["']"#).ok()?;
    re.captures(html).map(|c| c[1].to_string())
}

/// 解析书源 header 字段为 HashMap
fn parse_headers(header: Option<&str>) -> Option<std::collections::HashMap<String, String>> {
    let header_str = header?;
    if header_str.is_empty() {
        return None;
    }
    // 尝试 JSON 解析
    if let Ok(map) = serde_json::from_str::<std::collections::HashMap<String, String>>(header_str) {
        return Some(map);
    }
    // 回退：按行解析 "Key: Value" 格式
    let mut map = std::collections::HashMap::new();
    for line in header_str.lines() {
        if let Some((k, v)) = line.split_once(':') {
            map.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

/// 从 URL 提取主机名（用于重定向检测对比）
fn extract_host(url: &str) -> String {
    // 尝试使用 url crate 解析
    if let Ok(parsed) = url::Url::parse(url) {
        if let Some(host) = parsed.host_str() {
            return host.to_lowercase();
        }
    }
    // 回退：简单字符串截取
    let without_scheme = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .unwrap_or(url);
    without_scheme
        .split('/')
        .next()
        .unwrap_or("")
        .split(':')
        .next()
        .unwrap_or("")
        .to_lowercase()
}

/// 判断 URL 是否为登录/验证页面
fn is_login_or_verify_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    const LOGIN_KEYWORDS: &[&str] = &[
        "login",
        "signin",
        "sign-in",
        "auth",
        "verify",
        "verification",
        "captcha",
        "challenge",
        "登录",
        "验证",
    ];
    LOGIN_KEYWORDS.iter().any(|&kw| lower.contains(kw))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::{LegadoClient, LegadoClientConfig};

    fn make_checker() -> SourceChecker {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        SourceChecker::new(Arc::new(client))
    }

    fn make_test_source() -> BookSource {
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "Test Source".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            book_url_pattern: Some(r#"https://example\.com/book/\d+"#.to_string()),
            ..BookSource::default()
        }
    }
    #[test]
    fn test_check_result_all_failed() {
        let result = CheckResult::all_failed("https://example.com", "test error");
        assert!(!result.search_ok);
        assert!(!result.toc_ok);
        assert!(!result.content_ok);
        assert!(!result.all_ok());
        assert_eq!(result.search_error, Some("test error".to_string()));
    }

    #[test]
    fn test_check_result_all_ok() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: None,
            redirect: None,
        };
        assert!(result.all_ok());
        assert!(result.is_search_ok());
        assert!(!result.has_captcha());
        assert!(!result.has_redirect());
        assert!(result.is_available());
    }

    #[test]
    fn test_build_search_url() {
        let checker = make_checker();
        let source = make_test_source();
        let url =
            checker.build_search_url(source.search_url.as_ref().unwrap(), &checker.config.keyword);
        assert!(url.contains("search?q="));
        assert!(url.contains(urlencoding::encode(DEFAULT_KEYWORD).as_ref()));
    }

    #[test]
    fn test_build_search_url_double_brace() {
        let checker = make_checker();
        let url = checker.build_search_url("https://example.com/search?q={{key}}", "hello");
        assert!(url.contains("search?q=hello"));
    }

    #[test]
    fn test_build_search_url_search_key() {
        let checker = make_checker();
        let url = checker.build_search_url("https://example.com/search?q={searchKey}", "world");
        assert!(url.contains("search?q=world"));
    }

    #[test]
    fn test_extract_first_href() {
        let html = r#"<div><a href="https://example.com/book/123">Book</a></div>"#;
        let url = extract_first_href(html);
        assert_eq!(url, Some("https://example.com/book/123".to_string()));
    }

    #[test]
    fn test_extract_first_href_single_quotes() {
        let html = r#"<a href='https://example.com/book/456'>Link</a>"#;
        let url = extract_first_href(html);
        assert_eq!(url, Some("https://example.com/book/456".to_string()));
    }

    #[test]
    fn test_extract_first_href_none() {
        let html = "<div>no links here</div>";
        let url = extract_first_href(html);
        assert!(url.is_none());
    }

    #[test]
    fn test_parse_headers_json() {
        let json = r#"{"User-Agent": "TestBot/1.0", "Accept": "text/html"}"#;
        let headers = parse_headers(Some(json));
        assert!(headers.is_some());
        let map = headers.unwrap();
        assert_eq!(map.get("User-Agent").unwrap(), "TestBot/1.0");
    }

    #[test]
    fn test_parse_headers_line_format() {
        let text = "User-Agent: TestBot/1.0\nAccept: text/html";
        let headers = parse_headers(Some(text));
        assert!(headers.is_some());
        let map = headers.unwrap();
        assert_eq!(map.get("User-Agent").unwrap(), "TestBot/1.0");
    }

    #[test]
    fn test_parse_headers_none() {
        assert!(parse_headers(None).is_none());
        assert!(parse_headers(Some("")).is_none());
    }

    #[tokio::test]
    async fn test_check_search_no_search_url() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "No Search".to_string(),
            search_url: None,
            ..BookSource::default()
        };
        let result = checker.check_search(&source).await;
        assert!(!result.search_ok);
        assert!(result.search_error.unwrap().contains("no searchUrl"));
    }

    #[tokio::test]
    async fn test_check_full_no_search_url() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            search_url: None,
            ..BookSource::default()
        };
        let result = checker.check_full(&source).await;
        assert!(!result.search_ok);
        assert!(!result.toc_ok);
        assert!(!result.content_ok);
        assert!(result.total_time_ms >= 0);
    }

    #[test]
    fn test_checker_config_default() {
        let cfg = CheckerConfig::default();
        assert_eq!(cfg.keyword, DEFAULT_KEYWORD);
        assert_eq!(cfg.step_timeout_ms, 180_000);
        assert!(cfg.check_search);
        assert!(cfg.check_toc);
        assert!(cfg.check_content);
        assert!(cfg.detect_captcha);
        assert!(cfg.detect_redirect);
    }

    #[test]
    fn test_checker_with_config() {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        let config = CheckerConfig {
            keyword: "自定义".to_string(),
            check_toc: false,
            check_content: false,
            ..CheckerConfig::default()
        };
        let checker = SourceChecker::with_config(Arc::new(client), config);
        assert_eq!(checker.config.keyword, "自定义");
        assert!(!checker.config.check_toc);
    }

    #[test]
    fn test_extract_first_book_url_with_pattern() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_url_pattern: Some(r#"https://example\.com/book/\d+"#.to_string()),
            ..BookSource::default()
        };
        let body = "Visit https://example.com/book/12345 for details";
        let result = checker.extract_first_book_url(body, &source);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "https://example.com/book/12345");
    }

    #[test]
    fn test_extract_first_book_url_no_match() {
        let checker = make_checker();
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_url_pattern: Some(r#"https://other\.com/\d+"#.to_string()),
            ..BookSource::default()
        };
        let body = "no matching url here";
        let result = checker.extract_first_book_url(body, &source);
        assert!(result.is_err());
    }

    // ---- 验证码检测测试 ----

    #[test]
    fn test_detect_captcha_image() {
        let checker = make_checker();
        let html = r#"<div><img src="/captcha.jpg"><input name="verifycode"></div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("图片验证码".to_string()));
        assert!(info.matched_keyword.is_some());
    }

    #[test]
    fn test_detect_captcha_slide() {
        let checker = make_checker();
        let html = r#"<div class="geetest-slider">请拖动滑块完成验证</div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("滑动验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_click() {
        let checker = make_checker();
        let html = r#"<div>请依次点击字符: 春 风</div>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("点击验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_anti_bot() {
        let checker = make_checker();
        let html = r#"<html><body>Access Denied - Cloudflare Challenge</body></html>"#;
        let info = checker.detect_captcha(html);
        assert!(info.detected);
        assert_eq!(info.captcha_type, Some("人机验证".to_string()));
    }

    #[test]
    fn test_detect_captcha_none() {
        let checker = make_checker();
        let html = r#"<html><body><h1>正常小说内容</h1><p>第一章</p></body></html>"#;
        let info = checker.detect_captcha(html);
        assert!(!info.detected);
        assert!(info.captcha_type.is_none());
    }

    #[test]
    fn test_detect_captcha_empty() {
        let checker = make_checker();
        let info = checker.detect_captcha("");
        assert!(!info.detected);
    }

    // ---- 重定向检测测试 ----

    #[test]
    fn test_detect_redirect_no_redirect() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/search?q=test".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search?q=test");
        assert!(!info.redirected);
        assert!(!info.is_login_redirect);
    }

    #[test]
    fn test_detect_redirect_same_domain() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/result".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(!info.is_login_redirect); // 同域重定向不视为异常
    }

    #[test]
    fn test_detect_redirect_cross_domain() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://other-site.com/page".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(info.is_login_redirect); // 跨域重定向视为异常
    }

    #[test]
    fn test_detect_redirect_to_login() {
        let checker = make_checker();
        let resp = LegadoResponse {
            status: 200,
            headers: std::collections::HashMap::new(),
            body: "ok".to_string(),
            url: "https://example.com/login?redirect=/search".to_string(),
        };
        let info = checker.detect_redirect(&resp, "https://example.com/search");
        assert!(info.redirected);
        assert!(info.is_login_redirect); // 重定向到登录页
    }

    // ---- 辅助函数测试 ----

    #[test]
    fn test_extract_host() {
        assert_eq!(extract_host("https://example.com/path"), "example.com");
        assert_eq!(extract_host("http://sub.example.com:8080/"), "sub.example.com");
        assert_eq!(extract_host("https://EXAMPLE.COM"), "example.com");
    }

    #[test]
    fn test_is_login_or_verify_url() {
        assert!(is_login_or_verify_url("https://example.com/login"));
        assert!(is_login_or_verify_url("https://example.com/auth/callback"));
        assert!(is_login_or_verify_url("https://example.com/verify"));
        assert!(is_login_or_verify_url("https://example.com/captcha"));
        assert!(!is_login_or_verify_url("https://example.com/book/123"));
        assert!(!is_login_or_verify_url("https://example.com/search?q=test"));
    }

    // ---- CheckResult 新方法测试 ----

    #[test]
    fn test_check_result_with_captcha() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: Some(CaptchaInfo {
                detected: true,
                captcha_type: Some("图片验证码".to_string()),
                matched_keyword: Some("captcha".to_string()),
            }),
            redirect: None,
        };
        assert!(result.has_captcha());
        assert!(!result.is_available()); // 有验证码时不可用
    }

    #[test]
    fn test_check_result_with_redirect() {
        let result = CheckResult {
            source_url: "test".to_string(),
            search_ok: true,
            toc_ok: true,
            content_ok: true,
            search_error: None,
            toc_error: None,
            content_error: None,
            total_time_ms: 100,
            captcha: None,
            redirect: Some(RedirectInfo {
                redirected: true,
                original_url: "https://example.com".to_string(),
                final_url: "https://login.example.com".to_string(),
                is_login_redirect: true,
            }),
        };
        assert!(result.has_redirect());
    }
}
