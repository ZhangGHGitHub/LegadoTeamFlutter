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
//! - 发送走 [`crate::analyze_request::send_text`]，`followRedirects` / `retry`
//!   语义与书源搜索、正文一致（`data:` URI 亦沿用该模块的本地解码短路）。
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
/// 对齐原版 `BaseSource.getHeaderMap()`：仅解析源静态 `header` 字段；
/// `hasLoginHeader = false`（`Rss.kt:56` 构造 AnalyzeUrl 时传 `false`，
/// 登录头合并属批15b）。
///
/// header 非法 JSON 时按空处理（与书源 `parse_source_headers` 同口径）；
/// `enabledCookieJar == Some(true)` 补 [`legado_net::COOKIE_JAR_HEADER`] 标记，
/// 只补不覆盖（源显式配置同名头时不重复写入）。
pub fn source_headers(source: &RssSource) -> Option<HashMap<String, String>> {
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .and_then(|raw| serde_json::from_str::<HashMap<String, String>>(raw).ok())
        .unwrap_or_default();

    crate::web_book::apply_cookie_jar_marker_by_flag(&mut headers, source.enabled_cookie_jar);

    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
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
/// 非 2xx 直接报错（对齐上游 `StrResponse` 的 `isSuccessful` 检查，绝不把
/// 错误页当正文解析）。
pub async fn fetch_list(
    client: &LegadoClient,
    analyze_url: &AnalyzeUrl,
    source_headers: Option<HashMap<String, String>>,
) -> LegadoResult<RssListResponse> {
    let headers = merge_request_headers(analyze_url, source_headers);
    let response: LegadoResponse =
        crate::analyze_request::send_text(client, analyze_url, headers).await?;

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
fn merge_request_headers(
    analyze_url: &AnalyzeUrl,
    source_headers: Option<HashMap<String, String>>,
) -> Option<HashMap<String, String>> {
    let mut headers = source_headers.unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    if headers.is_empty() {
        None
    } else {
        Some(headers)
    }
}
