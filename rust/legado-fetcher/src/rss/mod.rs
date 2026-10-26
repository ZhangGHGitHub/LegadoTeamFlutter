//! RSS 抓取引擎（批15a：默认解析等价 + 引擎骨架）
//!
//! 对齐原版 `Rss.getArticlesAwait`（`Rss.kt:39-84`）的列表请求编排：
//!
//! ```text
//! RssSource → AnalyzeUrl(sortUrl, page, key, baseUrl = sourceUrl) → HTTP
//!   → RssParserByRule.parseXML → List<RssArticle> + nextUrl
//! ```
//!
//! ## 本批范围（15a）
//!
//! - **默认解析**：原版 `RssParserByRule.parseXML` 在 `ruleArticles` 为空/
//!   空白时走 `RssParserDefault`（`RssParserByRule.kt:32-41`）；本批只落地
//!   该路径（解析本体在 `legado-net::rss::parse_default_items`）。
//! - **Atom 为已登记超集偏离**：原版默认解析只认 `<item>`（Atom 得 0 篇）；
//!   为保留现有 Atom 订阅用户可用性，item 为空且根为 `<feed>` 时回退
//!   `parse_atom`（登记见 `docs/REFACTORING_ACTIVE_PLAN.md` 批15 拆分）。
//!
//! ## 后续批次
//!
//! - 15b：规则列表解析（`ruleArticles` / `ruleTitle` 等）、分类 `sortUrl`
//!   （`parseRssSortUrls`）、`ruleNextPage` 分页、`loginCheckJs` / 登录头；
//! - 15c：正文规则（`ruleContent` / `nextContentUrl`）与正文分页。
//!
//! 模块职责：
//! - [`models`]：中立数据结构（[`models::RssArticleItem`] / [`models::RssListPage`]）
//! - [`request`]：`AnalyzeUrl` 构造、源 header / CookieJar 标记头、响应结构
//! - [`default_parser`]：默认解析到中立结构的映射

pub mod default_parser;
pub mod models;
pub mod request;

use legado_core::models::RssSource;
use legado_core::{LegadoError, LegadoResult};
use legado_net::LegadoClient;

pub use models::{RssArticleItem, RssListPage};

/// 拉取 RSS 列表页（批15a：仅默认解析路径）
///
/// 参数对齐原版 `Rss.getArticlesAwait(sortName, sortUrl, rssSource, page, key)`：
/// - `sort_name`：分类名（批15a 宿主传空串，对齐 `parseRssSortUrls` 空值回退）；
/// - `sort_url`：列表请求 URL（批15a = 源 `sourceUrl`）；
/// - `page` / `key`：`AnalyzeUrl` 模板变量（批15a 可为 `None`）。
///
/// 错误语义（对齐原版）：
/// - HTTP 非 2xx → `Err`（`request::fetch_list`）；
/// - 响应体空白 → `Err`（原版 `RssParserByRule.parseXML` `body.isNullOrBlank()`
///   抛 `NoStackTraceException`，**不伪造文章**）；
/// - 正文非空但解析出 0 篇 → `Ok(空列表)`（原版同样如此，畸形 XML 按
///   quick-xml 宽容度处理）。
pub async fn fetch_articles(
    client: &LegadoClient,
    source: &RssSource,
    sort_name: &str,
    sort_url: &str,
    page: Option<u32>,
    key: Option<&str>,
) -> LegadoResult<RssListPage> {
    let headers = request::source_headers(source);
    let analyze_url =
        request::build_list_analyze_url(sort_url, page, key, &source.source_url, headers.clone());

    let response = request::fetch_list(client, &analyze_url, headers).await?;

    // 对齐原版 `RssParserByRule.parseXML`：body 空白 → 报错（不伪造摘要）
    if response.body.trim().is_empty() {
        return Err(LegadoError::Network(format!(
            "获取 RSS 内容失败: {sort_url}（响应体为空）"
        )));
    }

    // 批15a：`ruleArticles` 非空时的规则列表解析留批15b，本批统一走默认解析
    // （原版 ruleArticles 空 → 默认解析；非空 → 规则解析，差异登记于批15b）。
    Ok(default_parser::parse_default_list(
        sort_name,
        &response.body,
        &source.source_url,
    ))
}
