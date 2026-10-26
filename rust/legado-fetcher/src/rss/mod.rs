//! RSS 抓取引擎（批15a 默认解析等价 + 批15b 规则列表/分类/登录/分页 + 批15c 正文）
//!
//! 对齐原版 `Rss.getArticlesAwait`（`Rss.kt:39-84`）的列表请求编排：
//!
//! ```text
//! RssSource → AnalyzeUrl(sortUrl, page, key, baseUrl = sourceUrl) → HTTP
//!   → loginCheckJs 检测 → RssParserByRule.parseXML → List<RssArticle> + nextUrl
//! ```
//!
//! ## 本批范围（15a + 15b + 15c）
//!
//! - **默认解析**（15a）：原版 `RssParserByRule.parseXML` 在 `ruleArticles`
//!   为空/空白时走 `RssParserDefault`（`RssParserByRule.kt:32-41`；解析本体在
//!   `legado-net::rss::parse_default_items`）；
//! - **Atom 为已登记超集偏离**（15a）：原版默认解析只认 `<item>`（Atom 得
//!   0 篇）；为保留现有 Atom 订阅用户可用性，item 为空且根为 `<feed>` 时回退
//!   `parse_atom`（登记见 `docs/REFACTORING_ACTIVE_PLAN.md` 批15 拆分）；
//! - **规则列表 / 分类 / 登录 / 分页**（15b）：[`parser_rule`] 对齐
//!   `RssParserByRule.kt:22-140`，[`sort_urls`] 对齐
//!   `RssSourceExtensions.kt:49-113`，[`login`] 对齐 `Rss.kt:57-81`；
//! - **正文规则 / 正文分页**（15c）：[`content`] 对齐 `Rss.kt:99-242`
//!   （`ruleContent` 求值、`nextContentUrl` 单链顺序 / 多链保序并发、`"\n"`
//!   拼接；写回由宿主 FFI 完成）。
//!
//! ## 后续批次
//!
//! - 15d：Dart 分类/分页/搜索 UI 收敛；
//! - 15e：服务端 `/rssSourceDebug` 接引擎；
//! - 15f：singleUrl / WebView / 图片 header 等增强。
//!
//! 模块职责：
//! - [`models`]：中立数据结构（[`models::RssArticleItem`] / [`models::RssListPage`]）
//! - [`request`]：`AnalyzeUrl` 构造、源 header + 登录头合并、响应结构
//! - [`default_parser`]：默认解析到中立结构的映射
//! - [`parser_rule`]：规则列表解析与 `ruleNextPage`
//! - [`sort_urls`]：分类 `sortUrl` 解析、脚本求值与缓存
//! - [`login`]：`loginCheckJs` 成功/失败两路检测（列表与正文共用）
//! - [`content`]：正文规则求值与正文分页

pub mod content;
pub mod default_parser;
pub mod login;
pub mod models;
pub mod parser_rule;
pub mod request;
pub mod sort_urls;

use legado_core::models::RssSource;
use legado_core::{LegadoError, LegadoResult};
use legado_net::LegadoClient;

pub use models::{RssArticleItem, RssListPage};
pub use sort_urls::RssSortUrl;

/// 拉取 RSS 列表页（批15b：规则列表 + 登录检测 + 分类/分页请求）
///
/// 参数对齐原版 `Rss.getArticlesAwait(sortName, sortUrl, rssSource, page, key)`：
/// - `sort_name`：分类名（`parse_sort_urls` 的空值回退为 `""`）；
/// - `sort_url`：列表请求 URL（`AnalyzeUrl(sortUrl, page, key, baseUrl=sourceUrl)`）；
/// - `page` / `key`：`AnalyzeUrl` 模板变量（刷新 `Some(1)`，翻页为下一页页码）；
/// - `login_header_json`：宿主从 DB 读取的 `loginHeader_<sourceUrl>`
///   （**仅同源请求**合并进请求头并预置到 RSS setup 脚本；`None` = 未登录；
///   跨域 `nextUrl` 不附加，见 [`request::is_same_origin`]）；
/// - `login_info_json`：宿主从 DB 读取的 `userInfo_<sourceUrl>`（同样仅同源
///   请求预置到 RSS setup 脚本，供 `source.getLoginInfo()` 使用）。
///
/// 错误语义：
/// - HTTP 非 2xx → 先走 `loginCheckJs` 错误路径（二次 eval 可放行），否则 `Err`
///   （`request::fetch_list`）。**差异登记（审查 P2-1）**：上游
///   `Rss.getArticlesAwait` 不校验状态码，直接把响应体交给解析；本实现保留
///   既有非 2xx 报错（更严格，避免把错误页当正文）；
/// - `loginCheckJs` 判定未登录 → `Err(LegadoError::LoginRequired)`（对齐原版
///   「throw throwable」整源失败语义）；
/// - 响应体空白 → `Err`（原版 `RssParserByRule.parseXML` `body.isNullOrBlank()`
///   抛 `NoStackTraceException`，**不伪造文章**）；
/// - 正文非空但解析出 0 篇 → `Ok(空列表)`（原版同样如此，畸形 XML 按
///   quick-xml 宽容度处理）。
///
/// ## 已登记边界差异（对齐原版 `RssParserDefault`，2026-10-26 审查 P2-3/P2-8）
///
/// - **`pubDate` 内嵌标签被吞**：原版 `next()` 后 `continue@loop`，嵌套标签仍
///   会被外层循环处理（如 `<pubDate><time>x</time></pubDate>` 由 `time` 分支
///   覆盖 pubDate）；本实现 `read_direct_text` 消费掉嵌套起始事件后返回
///   `None`，内嵌标签不再参与后续解析；
/// - **空白裁剪口径**：`title`/`link`/`description`/`content` 与原版一样 trim，
///   `time` 与原版一样不 trim；但 Kotlin `trim()`（`Char.isWhitespace ||
///   isSpaceChar`）与 Rust `str::trim()`（Unicode `White_Space`）在极端空白
///   字符（NBSP、控制字符等）上不完全一致，不逐字符模拟；
/// - **嵌套 `<item>` 重置**：原版 START item 不复位当前文章（内层 item 继承外层
///   已解析字段，外层闭合再产出一条空文章）；本实现 START item 复位当前文章
///   （内层 item 之前的字段丢失）。仅畸形 feed 可触发；
/// - **未声明实体**：原版 `XmlPullParser` 抛异常；本实现按字面保留 `&name;`
///   （已登记宽容度，避免整篇文本丢失）；
/// - **命名空间前缀**：`<rss:item>` 等带前缀的元素按原版字面名规则
///   （`namespaceAware = false`，`xmlPullParser.name` 含前缀）**不解析**，
///   本实现同样不识别；旧 `parse_feed`（`legado-net`）用 local-name 匹配，
///   会识别 `<rss:item>`，两者行为不同（旧 API 仅 REST 调试/兼容保留）。
#[allow(clippy::too_many_arguments)] // 参数集与 Kotlin `getArticlesAwait` 入参 + 宿主登录缓存注入对齐，不拆结构体
pub async fn fetch_articles(
    client: &LegadoClient,
    source: &RssSource,
    sort_name: &str,
    sort_url: &str,
    page: Option<u32>,
    key: Option<&str>,
    login_header_json: Option<&str>,
    login_info_json: Option<&str>,
) -> LegadoResult<RssListPage> {
    // 批15b：先展开请求 URL（URL 模板与 header 无关），再做同源门控——
    // 登录头 / 用户信息只在请求 URL 与 sourceUrl 同源（scheme+host+port）时附加，
    // 跨域 nextUrl（第三方跳转/聚合外链）绝不外发登录凭据（审查 P1-2）。
    let probe_url = request::build_list_analyze_url(sort_url, page, key, &source.source_url, None)
        .url()
        .to_string();
    let same_origin = request::is_same_origin(&probe_url, &source.source_url);
    let effective_login_header = login_header_json.filter(|_| same_origin);
    let effective_login_info = login_info_json.filter(|_| same_origin);
    // 源静态 header + 同源登录头合并（登录头覆盖同名键）
    let headers = request::source_headers_with_login(source, effective_login_header);
    let analyze_url =
        request::build_list_analyze_url(sort_url, page, key, &source.source_url, headers.clone());
    // RSS 源 JS 最小绑定（ruleArticles/loginCheckJs 的 @js:/<js> 可用 source/java；
    // 登录缓存只注入同源请求的 JS 上下文，跨域页面读不到凭据）
    let setup_script = Some(crate::source_setup::rss_source_js_setup_script(
        source,
        effective_login_header,
        effective_login_info,
    )?);

    let request_url = analyze_url.url().to_string();

    // [Rss.kt:57-81] 成功/失败两路 loginCheckJs 检测（列表与正文共用门控）
    let fetched = request::fetch_list(client, &analyze_url, headers).await;
    let response = login::gate_login(source, &request_url, setup_script.clone(), fetched)?;

    // 对齐原版 `RssParserByRule.parseXML`：body 空白 → 报错（不伪造摘要）
    if response.body.trim().is_empty() {
        return Err(LegadoError::Network(format!(
            "获取 RSS 内容失败: {sort_url}（响应体为空）"
        )));
    }

    // 规则列表解析；`ruleArticles` 空/空白时内部回退默认解析
    parser_rule::parse_rule_list(
        source,
        sort_name,
        sort_url,
        &response.final_url,
        &response.body,
        setup_script,
    )
}
