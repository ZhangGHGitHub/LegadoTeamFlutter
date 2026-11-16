//! 书源校验完整规则链（server / ffi 单一实现）
//!
//! 对齐 Android 原版 `CheckSourceService.kt` 的 `doCheckSource` / `checkBook`：
//!
//! 1. 源地址可访问性（可选 TCP 探测）→ `域名失效`
//! 2. 搜索：`webbook_search`，0 条结果 → `搜索失效`
//! 3. 搜索书详情 → 目录 → 正文：目录空 → `搜索目录失效`，正文空 → `搜索正文失效`
//! 4. 发现：`webbook_explore_first_book`，0 条结果 → `发现失效`；发现书同理带 `发现` 前缀
//!
//! 失败归类对齐原版 `CheckSourceService.kt:287-289`（`TimeoutCancellationException`
//! → `校验超时`、`ScriptException`/`WrappedException` → `js失效`、其余非
//! `NoStackTraceException` → `网站失效`）与 `:336,347,367,415-416`
//! （`域名失效`/`搜索失效`/`发现失效`/`${bookType}正文失效`/`${bookType}目录失效`）。
//!
//! 设计取舍：
//! - 本模块是 `legado-server` 的 `/startBookSourceCheck` 与 `legado-ffi` 的
//!   `checkSource` / `checkSourcesStream` 的**唯一**规则级实现（下沉前 server
//!   侧私有副本已删除）；`legado-net::source_checker` 的简化实现保留给
//!   `legado-server` 的 `POST /api/sources/check`、`/check-batch` 与 MCP
//!   `check_sources`（其 HTTP 响应形状不变）。
//! - 取消令牌与整源超时在 [`run_source_check`] 内统一处理：整源预算对齐原版
//!   `withTimeout(CheckSource.timeout)`，超时即判 `校验超时`。
//! - 只返回判定结果，不触库：分组/注释落库由宿主（ffi 侧）决定，避免本 crate
//!   反向依赖 `legado-db`。

use std::time::Duration;

use legado_core::explore::parse_explore_url;
use legado_core::models::book_source_type;
use legado_core::models::BookSource;
use legado_core::web_book::{WebBookInfo, WebChapter, WebSearchResult};
use legado_core::LegadoError;
use legado_net::source_checker::CancelToken;

use crate::deps::FetcherDeps;
use crate::web_book;

// ─── 失效分组名（对齐原版 `BookSource.addGroup` 的取值域） ─────────────────

/// 整源超时
pub const GROUP_TIMEOUT: &str = "校验超时";
/// JS 引擎异常（原版 `ScriptException` / `WrappedException`）
pub const GROUP_JS_FAILED: &str = "js失效";
/// 源地址 TCP 不可达
pub const GROUP_DOMAIN_FAILED: &str = "域名失效";
/// 搜索请求成功但解析出 0 条
pub const GROUP_SEARCH_FAILED: &str = "搜索失效";
/// 发现页请求成功但解析出 0 条
pub const GROUP_DISCOVERY_FAILED: &str = "发现失效";
/// 发现规则无可用分类 URL
pub const GROUP_DISCOVERY_RULE_EMPTY: &str = "发现规则为空";
/// 其余硬失败（网络/状态码/规则求值/解析异常）
pub const GROUP_SITE_FAILED: &str = "网站失效";

/// `${bookType}目录失效`
pub fn toc_group(book_type_label: &str) -> String {
    format!("{book_type_label}目录失效")
}

/// `${bookType}正文失效`
pub fn content_group(book_type_label: &str) -> String {
    format!("{book_type_label}正文失效")
}

/// 失效分组判定：含「失效」子串或等于「校验超时」
///
/// 对齐原版 `BookSource.getInvalidGroupNames()`：
/// `"失效" in it || it == "校验超时"`。用于校验成功时清除旧失效分组。
pub fn is_invalid_group(group: &str) -> bool {
    group.contains("失效") || group == GROUP_TIMEOUT
}

/// 是否为「异常归类」类分组（而非「分组判定」类）
///
/// 供宿主按自身 detail 口径取舍：`legado-server` 的 `/startBookSourceCheck`
/// 历史 detail 只把分组判定类（`域名失效`/`搜索失效`/`发现失效`/`发现规则为空`/
/// `${bookType}目录失效`/`${bookType}正文失效`）拼进首段，异常归类类
/// （`校验超时`/`js失效`/`网站失效`）以消息形式呈现；FFI 的
/// `CheckResult.invalid_groups` 则保留**全部**分组。
pub fn is_error_class_group(group: &str) -> bool {
    matches!(group, GROUP_TIMEOUT | GROUP_JS_FAILED | GROUP_SITE_FAILED)
}

// ─── 分组串操作（对齐 `BookSource.addGroup/removeGroup/removeInvalidGroups`） ─

/// 分组分隔符（对齐 `AppPattern.splitGroupRegex = Regex("[,;，；]")`）
fn split_groups(raw: &str) -> Vec<String> {
    raw.split([',', ';', '，', '；'])
        .map(str::trim)
        .filter(|g| !g.is_empty())
        .map(str::to_string)
        .collect()
}

/// 追加分组（对齐原版 `BookSource.addGroup`）
///
/// 原版语义：现有串按分隔符拆分去空后并入新分组，`","` 连接；现有串为
/// `None`/空白时直接以新分组串作为结果。返回 `None` 表示「不修改」
/// （新分组为空且原值为 `None`）。
pub fn add_groups(group: Option<&str>, groups: &[String]) -> Option<String> {
    let mut merged: Vec<String> = group.map(split_groups).unwrap_or_default();
    for group in groups {
        for name in split_groups(group) {
            if !merged.contains(&name) {
                merged.push(name);
            }
        }
    }
    if merged.is_empty() {
        return group.map(str::to_string);
    }
    Some(merged.join(","))
}

/// 移除分组（对齐原版 `BookSource.removeGroup`）
///
/// 原版语义：现有串为 `None` 时不改动（返回原值）；否则拆分后移除指定分组，
/// 以 `","` 重新连接（可能得到空串）。
pub fn remove_groups(group: Option<&str>, groups: &[String]) -> Option<String> {
    let raw = group?;
    let mut remove: Vec<String> = Vec::new();
    for group in groups {
        remove.extend(split_groups(group));
    }
    let kept: Vec<String> = split_groups(raw)
        .into_iter()
        .filter(|name| !remove.contains(name))
        .collect();
    Some(kept.join(","))
}

/// 当前串中的失效分组名（对齐 `BookSource.getInvalidGroupNames()`）
pub fn invalid_group_names(group: Option<&str>) -> Vec<String> {
    group
        .map(split_groups)
        .unwrap_or_default()
        .into_iter()
        .filter(|name| is_invalid_group(name))
        .collect()
}

/// 清除全部失效分组（对齐 `BookSource.removeInvalidGroups()`）
pub fn remove_invalid_groups(group: Option<&str>) -> Option<String> {
    let names = invalid_group_names(group);
    if names.is_empty() {
        return group.map(str::to_string);
    }
    remove_groups(group, &names)
}

/// 本次判定中**可落库**的失效分组（域内过滤）
///
/// 批39 审查 P1-2：`发现规则为空` 这类「分组判定」不属于
/// `is_invalid_group` 的取值域（原版 `getInvalidGroupNames()` 也不认它，
/// 因此原版 `CheckSourceService` 只把它当异常消息、从不落库）。若把它写进
/// `bookSourceGroup`，之后的成功清理（`remove_invalid_groups`）匹配不到它
/// → 该分组永久留在用户分组里，且与「清掉 `// Error:` 注释」自相矛盾。
///
/// 因此落库集合 = `is_invalid_group` 认可的分组；域外判定只作为
/// detail / 错误消息呈现。写集与清理集由此天然一致。
pub fn persistable_groups(groups: &[String]) -> Vec<String> {
    groups
        .iter()
        .filter(|group| is_invalid_group(group))
        .cloned()
        .collect()
}

/// 清除旧失效分组 + 历史遗留的域外判定分组（`发现规则为空`）
///
/// 批39 审查 P1-2 的**存量**修复：历史版本把 `发现规则为空` 写进了分组串，
/// 而 `is_invalid_group` 不认可它 → 后续成功校验永远清不掉。本函数在
/// [`remove_invalid_groups`] 之上额外剔除该遗留值。
///
/// 刻意不改 `is_invalid_group` 的语义（保持与原版 `getInvalidGroupNames()`
/// 逐字一致）：清理只针对本模块自己曾误写入的域外值，且幂等。
pub fn remove_stale_check_groups(group: Option<&str>) -> Option<String> {
    let cleaned = remove_invalid_groups(group);
    remove_groups(
        cleaned.as_deref(),
        &[GROUP_DISCOVERY_RULE_EMPTY.to_string()],
    )
}

/// 清除历史 `// Error:` 注释块（对齐 `BookSource.removeErrorComment`）
///
/// 原版按 `"\n\n"` 分段并丢弃以 `// Error: ` 开头的段，再以 `"\n"` 连接。
pub fn remove_error_comment(comment: Option<&str>) -> Option<String> {
    let raw = comment?;
    let kept: Vec<&str> = raw
        .split("\n\n")
        .filter(|block| !block.starts_with("// Error: "))
        .collect();
    Some(kept.join("\n"))
}

/// 前置本次失败注释（对齐 `BookSource.addErrorComment`）
///
/// 原版：`"// Error: {message}"` + 非空旧注释时追加 `"\n\n{旧注释}"`。
pub fn add_error_comment(comment: Option<&str>, message: &str) -> Option<String> {
    let message = message.trim();
    if message.is_empty() {
        return comment.map(str::to_string);
    }
    match comment.map(str::trim).filter(|c| !c.is_empty()) {
        Some(existing) => Some(format!("// Error: {message}\n\n{existing}")),
        None => Some(format!("// Error: {message}")),
    }
}

// ─── 配置 ──────────────────────────────────────────────────────────────────

/// 整源超时下界（防御 0 值：避免每次校验立即超时）
const MIN_TIMEOUT_MS: u64 = 100;
/// 整源超时上界（防异常配置：避免 `Instant` 加法溢出/长期占用）
const MAX_TIMEOUT_MS: u64 = 24 * 60 * 60 * 1000;

/// 取消标志轮询间隔（「停止校验」的响应上界）
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// 源地址 TCP 探测总超时（对齐原版 `isDomainReachable`：withTimeout 2000 / connect 1600）
const DOMAIN_PROBE_TIMEOUT: Duration = Duration::from_millis(1_600);
/// 单地址连接子超时（多 A/AAAA 记录不得让首个慢地址吃掉全部预算）
const DOMAIN_PROBE_PER_ADDRESS_TIMEOUT: Duration = Duration::from_millis(500);

/// 校验配置（`CheckSource` 对象字段的可达子集）
#[derive(Debug, Clone)]
pub struct SourceCheckConfig {
    /// 搜索关键词（默认「我的」）
    pub keyword: String,
    /// 整源超时（毫秒，对齐原版 `CheckSource.timeout`）
    pub timeout_ms: u64,
    /// 是否校验源地址可访问性（默认关，对齐原版）
    pub check_domain: bool,
    /// 是否校验搜索
    pub check_search: bool,
    /// 是否校验发现
    pub check_discovery: bool,
    /// 是否校验详情
    pub check_info: bool,
    /// 是否校验目录
    pub check_category: bool,
    /// 是否校验正文
    pub check_content: bool,
    /// 失败时是否把 `// Error: {消息}` 写入书源注释（对齐原版 `CheckSource.wSourceComment`）
    pub w_source_comment: bool,
}

impl Default for SourceCheckConfig {
    fn default() -> Self {
        Self {
            keyword: "我的".to_string(),
            timeout_ms: 180_000,
            check_domain: false,
            check_search: true,
            check_discovery: true,
            check_info: true,
            check_category: true,
            check_content: true,
            w_source_comment: true,
        }
    }
}

impl SourceCheckConfig {
    /// 生效的整源超时（夹取 `100ms..24h`）
    fn effective_timeout(&self) -> Duration {
        Duration::from_millis(self.timeout_ms.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS))
    }
}

// ─── 结果 ──────────────────────────────────────────────────────────────────

/// 校验结果（规则级判定 + 分步状态）
///
/// `failure` 为硬失败消息（未加「校验失败:」前缀）；`invalid_groups` 为本次判定
/// 出的失效分组。仅 `invalid_groups` 非空、`failure` 为空时，调用方按原版
/// `getInvalidGroupNames()` 语义以分组名拼出消息。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SourceCheckOutcome {
    /// 本次判定的失效分组（按判定顺序，可能含重复语义的目录/正文分组）
    pub invalid_groups: Vec<String>,
    /// 硬失败消息（`None` 表示无硬失败）
    pub failure: Option<String>,
    /// 源地址不是 http(s)（原版 `UNCHECKABLE`）
    pub domain_unchecked: bool,
    /// 搜索步骤通过
    pub search_ok: bool,
    /// 目录步骤通过
    pub toc_ok: bool,
    /// 正文步骤通过
    pub content_ok: bool,
    /// 搜索步骤错误
    pub search_error: Option<String>,
    /// 目录步骤错误
    pub toc_error: Option<String>,
    /// 正文步骤错误
    pub content_error: Option<String>,
    /// 用户取消（不计为书源缺陷）
    pub cancelled: bool,
}

impl SourceCheckOutcome {
    /// 是否全部通过（取消态不算通过）
    pub fn all_ok(&self) -> bool {
        !self.cancelled && self.failure.is_none() && self.invalid_groups.is_empty()
    }

    /// 是否判为失败（取消态不算失败）
    pub fn is_failed(&self) -> bool {
        !self.cancelled && (self.failure.is_some() || !self.invalid_groups.is_empty())
    }

    /// 失败详情首段：分组名以 `, ` 连接（对齐原版 `getInvalidGroupNames()` 的
    /// `joinToString()`）
    pub fn invalid_group_text(&self) -> String {
        self.invalid_groups.join(", ")
    }
}

// ─── 入口 ──────────────────────────────────────────────────────────────────

/// 执行完整规则级校验（整源超时 + 可取消）
///
/// 返回的 [`SourceCheckOutcome`] 携带分步状态与失效分组；网络/解析异常一律
/// 收敛进结果（不向上抛错），与 `CheckSourceService` 的 `runCatching` 语义一致。
pub async fn run_source_check(
    deps: &FetcherDeps,
    source: &BookSource,
    config: &SourceCheckConfig,
    cancel: Option<CancelToken>,
) -> SourceCheckOutcome {
    if cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
        return cancelled_outcome(config);
    }

    let timeout = config.effective_timeout();
    tokio::select! {
        biased;
        _ = wait_for_cancel(cancel.clone()) => cancelled_outcome(config),
        result = tokio::time::timeout(timeout, check_source(deps, source, config)) => {
            match result {
                Ok(outcome) => outcome,
                Err(_) => timeout_outcome(config),
            }
        }
    }
}

/// 等待取消令牌置位（`None` 表示无取消能力：永不返回）
async fn wait_for_cancel(token: Option<CancelToken>) {
    match token {
        Some(token) => {
            while !token.is_cancelled() {
                tokio::time::sleep(CANCEL_POLL_INTERVAL).await;
            }
        }
        None => std::future::pending::<()>().await,
    }
}

/// 取消态结果（各步错误标记为取消，不判为书源缺陷）
fn cancelled_outcome(config: &SourceCheckConfig) -> SourceCheckOutcome {
    SourceCheckOutcome {
        search_ok: !config.check_search,
        toc_ok: !config.check_category,
        content_ok: !config.check_content,
        search_error: config.check_search.then(|| "cancelled".to_string()),
        toc_error: config
            .check_category
            .then(|| "skipped: cancelled".to_string()),
        content_error: config
            .check_content
            .then(|| "skipped: cancelled".to_string()),
        cancelled: true,
        ..Default::default()
    }
}

/// 整源超时结果（对齐原版 `TimeoutCancellationException` → `校验超时`）
fn timeout_outcome(config: &SourceCheckConfig) -> SourceCheckOutcome {
    SourceCheckOutcome {
        invalid_groups: vec![GROUP_TIMEOUT.to_string()],
        failure: Some(GROUP_TIMEOUT.to_string()),
        search_ok: !config.check_search,
        toc_ok: !config.check_category,
        content_ok: !config.check_content,
        search_error: config.check_search.then(|| "timeout".to_string()),
        toc_error: config.check_category.then(|| "timeout".to_string()),
        content_error: config.check_content.then(|| "timeout".to_string()),
        ..Default::default()
    }
}

// ─── 主流程 ────────────────────────────────────────────────────────────────

/// 检验流程（决定详情/目录/正文失效分组前缀，对齐原版 `checkBook(isSearchBook)`）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CheckFlow {
    Search,
    Discovery,
}

impl CheckFlow {
    fn book_type_label(self) -> &'static str {
        match self {
            CheckFlow::Search => "搜索",
            CheckFlow::Discovery => "发现",
        }
    }
}

/// 详情/目录/正文校验报告
#[derive(Debug, Default, Clone)]
struct BookCheck {
    toc_ok: bool,
    content_ok: bool,
    toc_error: Option<String>,
    content_error: Option<String>,
    /// 失效分组（目录/正文为空）
    group: Option<String>,
    /// 硬失败消息（网络/解析异常）
    failure: Option<String>,
}

/// 单源校验主流程（对齐 `CheckSourceService.doCheckSource` 的可达子集）
async fn check_source(
    deps: &FetcherDeps,
    source: &BookSource,
    config: &SourceCheckConfig,
) -> SourceCheckOutcome {
    let mut outcome = SourceCheckOutcome {
        search_ok: !config.check_search,
        toc_ok: !config.check_category,
        content_ok: !config.check_content,
        ..Default::default()
    };

    // 源地址可访问性（对齐原版 checkDomain 分支）
    if config.check_domain {
        match parse_check_source_endpoint(&source.book_source_url) {
            None => outcome.domain_unchecked = true,
            Some((host, port)) => {
                if !is_domain_reachable(&host, port).await {
                    outcome.invalid_groups.push(GROUP_DOMAIN_FAILED.to_string());
                    outcome.failure = Some("源地址不可访问".to_string());
                    return outcome;
                }
            }
        }
    }

    let source_json = match serde_json::to_string(source) {
        Ok(json) => json,
        Err(e) => return fail_site(outcome, format!("源序列化失败: {e}")),
    };

    // 搜索
    let mut searched_book: Option<WebSearchResult> = None;
    if config.check_search {
        let search_rule_empty = !source.is_js_source()
            && source
                .search_url
                .as_deref()
                .map(str::trim)
                .unwrap_or("")
                .is_empty();
        if search_rule_empty {
            // 原版 `throw NoStackTraceException("搜索链接规则为空")`：只记消息、不加分组
            outcome.search_ok = false;
            outcome.search_error = Some("搜索链接规则为空".to_string());
            outcome.failure = Some("搜索链接规则为空".to_string());
            outcome.toc_error = Some("skipped: search failed".to_string());
            outcome.content_error = Some("skipped: toc failed".to_string());
            return outcome;
        }
        let keyword = effective_keyword(source, &config.keyword);
        match web_book::webbook_search(deps.clone(), &source_json, &keyword, 1).await {
            Err(e) => {
                outcome.search_ok = false;
                outcome.search_error = Some(e.to_string());
                outcome.toc_error = Some("skipped: search failed".to_string());
                outcome.content_error = Some("skipped: toc failed".to_string());
                return fail_error(outcome, &e);
            }
            Ok(raw) => match serde_json::from_str::<Vec<WebSearchResult>>(&raw) {
                Err(e) => {
                    outcome.search_ok = false;
                    outcome.search_error = Some(format!("搜索结果解析失败: {e}"));
                    outcome.toc_error = Some("skipped: search failed".to_string());
                    outcome.content_error = Some("skipped: toc failed".to_string());
                    return fail_site(outcome, format!("搜索结果解析失败: {e}"));
                }
                Ok(results) if results.is_empty() => {
                    outcome.search_ok = false;
                    outcome.search_error = Some(GROUP_SEARCH_FAILED.to_string());
                    outcome.toc_error = Some("skipped: no book url from search".to_string());
                    outcome.content_error = Some("skipped: toc failed".to_string());
                    outcome.invalid_groups.push(GROUP_SEARCH_FAILED.to_string());
                }
                Ok(mut results) => {
                    outcome.search_ok = true;
                    searched_book = Some(results.remove(0));
                }
            },
        }
    }

    // 搜索书详情/目录/正文（原版在发现校验之前执行；空目录/空正文只记分组）
    if let Some(book) = searched_book.as_ref() {
        let report = check_book(deps, source, &source_json, book, config, CheckFlow::Search).await;
        if let Some(failure) = report.failure.clone() {
            outcome.toc_ok = report.toc_ok;
            outcome.content_ok = report.content_ok;
            outcome.toc_error = report.toc_error;
            outcome.content_error = report.content_error;
            return fail_site(outcome, failure);
        }
        outcome.toc_ok = report.toc_ok;
        outcome.content_ok = report.content_ok;
        outcome.toc_error = report.toc_error;
        outcome.content_error = report.content_error;
        if let Some(group) = report.group {
            outcome.invalid_groups.push(group);
        }
    }

    // 发现校验（对齐原版 `checkDiscovery && !exploreUrl.isNullOrBlank()`）
    if config.check_discovery
        && source
            .explore_url
            .as_deref()
            .map(str::trim)
            .is_some_and(|url| !url.is_empty())
    {
        let setup_script = deps.setup_script_for(source);
        match first_explore_category_url(
            source.explore_url.as_deref().unwrap_or(""),
            source,
            setup_script,
        ) {
            // 无可用分类 URL：原版抛「发现规则为空」；本实现按分组处理（既有语义）
            Err(ExploreRuleError::Empty) => outcome
                .invalid_groups
                .push(GROUP_DISCOVERY_RULE_EMPTY.to_string()),
            // 求值异常：原版异常上抛 → js失效 + 硬失败
            Err(ExploreRuleError::Eval(message)) => {
                let mut outcome = outcome;
                outcome.invalid_groups.push(GROUP_JS_FAILED.to_string());
                return fail_plain(outcome, format!("发现规则求值失败: {message}"));
            }
            // 宿主未启用 JS 引擎：能力缺口而非源缺陷，跳过发现校验
            Err(ExploreRuleError::Unavailable(message)) => {
                log::warn!(
                    "书源 {} 的 JS 发现规则跳过求值（{message}；非 quickjs 边界）",
                    source.book_source_url
                );
            }
            Ok(category_url) => {
                match web_book::webbook_explore_first_book(
                    deps.clone(),
                    &source_json,
                    &category_url,
                    1,
                )
                .await
                {
                    Err(e) => return fail_site(outcome, format!("发现页请求失败: {e}")),
                    Ok(None) => outcome
                        .invalid_groups
                        .push(GROUP_DISCOVERY_FAILED.to_string()),
                    Ok(Some(book)) => {
                        let report = check_book(
                            deps,
                            source,
                            &source_json,
                            &book,
                            config,
                            CheckFlow::Discovery,
                        )
                        .await;
                        if let Some(failure) = report.failure {
                            return fail_site(outcome, failure);
                        }
                        if let Some(group) = report.group {
                            outcome.invalid_groups.push(group);
                        }
                    }
                }
            }
        }
    }

    outcome
}

/// 搜索/发现结果的详情/目录/正文校验（对齐 `CheckSourceService.checkBook`）
async fn check_book(
    deps: &FetcherDeps,
    source: &BookSource,
    source_json: &str,
    book: &WebSearchResult,
    config: &SourceCheckConfig,
    flow: CheckFlow,
) -> BookCheck {
    let mut report = BookCheck {
        toc_ok: !config.check_category,
        content_ok: !config.check_content,
        ..Default::default()
    };
    if !config.check_info {
        return report;
    }
    let label = flow.book_type_label();

    // 搜索结果不含 tocUrl → 与原版「tocUrl 为空则取详情」一致，恒取详情
    let info_raw = match web_book::webbook_info(deps.clone(), source_json, &book.book_url).await {
        Ok(raw) => raw,
        Err(e) => {
            report.failure = Some(format!("详情页解析失败: {e}"));
            return report;
        }
    };
    let info: WebBookInfo = match serde_json::from_str(&info_raw) {
        Ok(info) => info,
        Err(e) => {
            report.failure = Some(format!("详情结果解析失败: {e}"));
            return report;
        }
    };

    if !config.check_category || source.book_source_type == book_source_type::FILE {
        return report;
    }

    let chapters_raw = match web_book::webbook_chapters(
        deps.clone(),
        source_json,
        &info.book_url,
        &info.toc_url,
        &info.name,
    )
    .await
    {
        Ok(raw) => raw,
        // 批39 审查 P2-2：JS 单文件源的 `getChapters` 空数组抛
        // `LegadoError::TocEmpty`（`js_source_book.rs` 的 `get_chapter_list`），
        // 与规则源「解析出 0 章」同属**目录为空**而非站点故障。对齐原版
        // `checkBook` 的 `TocEmptyException → ${bookType}目录失效`：走与正文
        // `ContentEmpty` 对称的分组分支，不再误判 `网站失效`。
        Err(LegadoError::TocEmpty(_)) => {
            let group = toc_group(label);
            report.toc_ok = false;
            report.toc_error = Some(group.clone());
            report.group = Some(group);
            return report;
        }
        Err(e) => {
            report.failure = Some(format!("目录解析失败: {e}"));
            return report;
        }
    };
    let chapters: Vec<WebChapter> = match serde_json::from_str(&chapters_raw) {
        Ok(chapters) => chapters,
        Err(e) => {
            report.failure = Some(format!("目录结果解析失败: {e}"));
            return report;
        }
    };
    let chapter = match select_check_chapter(&chapters) {
        Some(chapter) => chapter,
        None => {
            let group = toc_group(label);
            report.toc_ok = false;
            report.toc_error = Some(group.clone());
            report.group = Some(group);
            return report;
        }
    };
    report.toc_ok = true;

    if !config.check_content {
        return report;
    }
    let chapter_json = match serde_json::to_string(chapter) {
        Ok(json) => json,
        Err(e) => {
            report.failure = Some(format!("章节序列化失败: {e}"));
            return report;
        }
    };
    match web_book::webbook_content(deps.clone(), source_json, &chapter_json).await {
        Ok(content) if !content.trim().is_empty() => {
            report.content_ok = true;
        }
        Ok(_) => {
            let group = content_group(label);
            report.content_ok = false;
            report.content_error = Some(group.clone());
            report.group = Some(group);
        }
        // 原版 `ContentEmptyException` 由 checkBook 捕获转分组，不是硬失败
        Err(LegadoError::ContentEmpty(message)) => {
            let group = content_group(label);
            report.content_ok = false;
            report.content_error = Some(group.clone());
            report.group = Some(group);
            let _ = message;
        }
        Err(e) => {
            report.content_ok = false;
            report.content_error = Some(e.to_string());
            report.failure = Some(format!("正文解析失败: {e}"));
        }
    }
    report
}

// ─── 失败归类 ──────────────────────────────────────────────────────────────

/// 按 `LegadoError` 变体归类失效分组（对齐原版异常类型分支）
fn group_for_error(error: &LegadoError) -> Option<&'static str> {
    match error {
        LegadoError::JsEngine(_) => Some(GROUP_JS_FAILED),
        LegadoError::Timeout(_) => Some(GROUP_TIMEOUT),
        // 目录/正文为空由 `check_book` 转 `${bookType}目录/正文失效`
        LegadoError::TocEmpty(_) | LegadoError::ContentEmpty(_) => None,
        // 其余（网络/状态码/解析/内部）对齐原版「非 NoStackTraceException」→ 网站失效
        _ => Some(GROUP_SITE_FAILED),
    }
}

/// 硬失败（按错误变体归类）
fn fail_error(mut outcome: SourceCheckOutcome, error: &LegadoError) -> SourceCheckOutcome {
    if let Some(group) = group_for_error(error) {
        if !outcome.invalid_groups.iter().any(|g| g == group) {
            outcome.invalid_groups.push(group.to_string());
        }
    }
    outcome.failure = Some(error.to_string());
    outcome
}

/// 硬失败（归类为「网站失效」）
fn fail_site(mut outcome: SourceCheckOutcome, message: impl Into<String>) -> SourceCheckOutcome {
    if !outcome
        .invalid_groups
        .iter()
        .any(|g| g == GROUP_SITE_FAILED)
    {
        outcome.invalid_groups.push(GROUP_SITE_FAILED.to_string());
    }
    outcome.failure = Some(message.into());
    outcome
}

/// 硬失败（不额外加分组：调用方已自行判定分组/规则为空）
fn fail_plain(mut outcome: SourceCheckOutcome, message: impl Into<String>) -> SourceCheckOutcome {
    outcome.failure = Some(message.into());
    outcome
}

// ─── 发现规则求值 ──────────────────────────────────────────────────────────

/// 发现规则求值失败原因（区分「规则为空/无可用分类」与「求值异常」）
#[derive(Debug, Clone, PartialEq, Eq)]
enum ExploreRuleError {
    /// 无可用分类 URL（exploreUrl 为空、只含分组标题、或分类列表为空）
    Empty,
    /// 规则求值异常（`@js:`/`<js>` 脚本失败、分类 JSON 解析失败）
    Eval(String),
    /// 宿主未启用 JS 引擎（能力缺口，调用方跳过发现校验）
    #[cfg_attr(feature = "quickjs", allow(dead_code))]
    Unavailable(String),
}

/// 取首个可用分类 URL（对齐原版 `exploreKinds().firstOrNull { !it.url.isNullOrBlank() }`）
fn first_explore_category_url(
    explore_url: &str,
    source: &BookSource,
    setup_script: Option<String>,
) -> Result<String, ExploreRuleError> {
    let rule_str = resolve_explore_rule_str(explore_url, source, setup_script)?;
    let categories = parse_explore_url(&rule_str);
    for category in categories {
        // parse_explore_url 在 JSON 解析失败时合成 ERROR 分类（url 为原文），
        // 上游会把它当 URL 抓取；检验场景直接判「求值失败」更准确
        if let Some(message) = category.title.strip_prefix("ERROR:") {
            return Err(ExploreRuleError::Eval(message.trim().to_string()));
        }
        if let Some(url) = category
            .url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty())
        {
            return Ok(url.to_string());
        }
    }
    Err(ExploreRuleError::Empty)
}

/// 将 exploreUrl 解析为可分类的规则字符串
fn resolve_explore_rule_str(
    explore_url: &str,
    source: &BookSource,
    setup_script: Option<String>,
) -> Result<String, ExploreRuleError> {
    let trimmed = explore_url.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("@js:") {
        let code = trimmed.get(4..).unwrap_or("").trim();
        if code.is_empty() {
            return Ok(String::new());
        }
        return eval_explore_kinds_js(code, source, setup_script);
    }
    if lower.starts_with("<js>") {
        let code = extract_js_tag_body(trimmed);
        if code.is_empty() {
            return Ok(String::new());
        }
        return eval_explore_kinds_js(&code, source, setup_script);
    }
    Ok(trimmed.to_string())
}

fn extract_js_tag_body(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let Some(start) = lower.find("<js>") else {
        return String::new();
    };
    let content_start = start + "<js>".len();
    match lower.rfind("</js>") {
        Some(end) if end >= content_start => text[content_start..end].trim().to_string(),
        _ => text[content_start..].trim().to_string(),
    }
}

/// `@js:` / `<js>` 发现规则求值（携带 jsLib + 书源 setup；infoMap 空对象）
#[cfg(feature = "quickjs")]
fn eval_explore_kinds_js(
    js_code: &str,
    source: &BookSource,
    setup_script: Option<String>,
) -> Result<String, ExploreRuleError> {
    use legado_js::host_api::current_source::with_current_source_tag;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::{JsEngine, QuickJsEngine};

    let sandbox = SandboxConfig::default()
        .with_allow_script_run(true)
        .with_memory_limit(64 * 1024 * 1024);
    let engine = QuickJsEngine::new(sandbox)
        .map_err(|e| ExploreRuleError::Eval(format!("JS 引擎初始化失败: {e}")))?;

    // 前导：jsLib（去 Rhino 特有行）+ 书源 setup + 检验场景常量
    let mut prelude = String::new();
    if let Some(js_lib) = source.js_lib.as_deref().filter(|s| !s.trim().is_empty()) {
        prelude.push_str(&crate::js_adapter::sanitize_js_lib_for_quickjs(js_lib));
        prelude.push('\n');
    }
    if let Some(setup) = setup_script.filter(|s| !s.trim().is_empty()) {
        prelude.push_str(&setup);
        prelude.push('\n');
    }
    prelude.push_str("var infoMap = {};\nvar page = 1;\nvar baseUrl = ");
    prelude.push_str(
        &serde_json::to_string(&source.book_source_url).unwrap_or_else(|_| "\"\"".to_string()),
    );
    prelude.push(';');

    let tag = source.book_source_url.clone();
    with_current_source_tag(&tag, || {
        if !prelude.trim().is_empty() {
            engine
                .eval(&prelude)
                .map_err(|e| ExploreRuleError::Eval(format!("发现规则上下文加载失败: {e}")))?;
        }
        // 非严格包装：Rhino 裸调用函数 this=全局，QuickJS `ctx.eval` 严格模式下
        // this=undefined（书山等聚合源依赖）
        let encoded = serde_json::to_string(js_code)
            .map_err(|e| ExploreRuleError::Eval(format!("发现规则脚本编码失败: {e}")))?;
        let wrapped = format!(
            r#"new Function('__legadoCode', 'var __r = eval(__legadoCode); if (__r === null || __r === undefined) return ""; if (typeof __r === "string") return String(__r).trim(); try {{ return JSON.stringify(__r); }} catch (e) {{ return String(__r); }}')({encoded})"#
        );
        engine
            .eval(&wrapped)
            .map(|value| value.trim().to_string())
            .map_err(|e| ExploreRuleError::Eval(format!("发现规则脚本执行失败: {e}")))
    })
}

/// 未启用 quickjs：`@js:` / `<js>` 发现规则无法求值（能力缺口，调用方跳过）
#[cfg(not(feature = "quickjs"))]
fn eval_explore_kinds_js(
    _js_code: &str,
    _source: &BookSource,
    _setup_script: Option<String>,
) -> Result<String, ExploreRuleError> {
    Err(ExploreRuleError::Unavailable(
        "当前构建未启用 quickjs".to_string(),
    ))
}

// ─── 源地址可访问性探测 ────────────────────────────────────────────────────

/// 解析源地址的 TCP 探测端点（对齐原版 `parseCheckSourceEndpoint`）
///
/// 仅接受 http(s) 且带主机名的地址；端口缺省按协议取 80/443。
fn parse_check_source_endpoint(domain: &str) -> Option<(String, u16)> {
    let raw = domain.split('#').next().unwrap_or("");
    let parsed = url::Url::parse(raw).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    let host = parsed.host_str().filter(|h| !h.is_empty())?;
    let port = parsed.port_or_known_default()?;
    Some((host.to_string(), port))
}

/// TCP 连接探测（对齐原版 `isDomainReachable`：withTimeout 2000 / connect 1600）
async fn is_domain_reachable(host: &str, port: u16) -> bool {
    let probe = async {
        let Ok(addrs) = tokio::net::lookup_host((host, port)).await else {
            return false;
        };
        for addr in addrs {
            if matches!(
                tokio::time::timeout(
                    DOMAIN_PROBE_PER_ADDRESS_TIMEOUT,
                    tokio::net::TcpStream::connect(addr)
                )
                .await,
                Ok(Ok(_))
            ) {
                return true;
            }
        }
        false
    };
    matches!(
        tokio::time::timeout(DOMAIN_PROBE_TIMEOUT, probe).await,
        Ok(true)
    )
}

// ─── 目录首章 / 关键词 ─────────────────────────────────────────────────────

/// 目录首章选择（对齐 `CheckSourceChapterSelection.kt:11-25`）
///
/// 原版先 `filterNot { it.isVolume && it.url.startsWith(it.title) }` 再取首章：
/// 目录解析把空 URL 的卷章头合成为 `{title}{index}`（对齐
/// `BookChapterList.kt:263-264`），这类条目不是正文页，直接 `first()` 会拿合成
/// URL 去抓正文 → 假失败。
fn select_check_chapter(chapters: &[WebChapter]) -> Option<&WebChapter> {
    chapters
        .iter()
        .find(|chapter| !(chapter.is_volume && chapter.url.starts_with(&chapter.title)))
}

/// 有效搜索关键词（对齐 `BookSource.getCheckKeyword`）
///
/// 原版 `isNotBlank()` 只做判定、**返回原串**（不做 trim）。
fn effective_keyword(source: &BookSource, default: &str) -> String {
    if let Some(keyword) = source
        .rule_search
        .as_ref()
        .and_then(|rule| rule.check_key_word.as_deref())
    {
        if !keyword.trim().is_empty()
            && !keyword.contains("http")
            && !keyword.contains("::")
            && !keyword.contains("++")
            && !keyword.contains("--")
        {
            return keyword.to_string();
        }
    }
    default.to_string()
}

// ─── 测试 ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::SearchRule;

    fn web_chapter(index: i32, title: &str, url: &str, is_volume: bool) -> WebChapter {
        WebChapter {
            index,
            title: title.to_string(),
            url: url.to_string(),
            is_vip: false,
            is_volume,
            is_pay: false,
            tag: None,
            variable: None,
            word_count: None,
        }
    }

    fn source(url: &str) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            ..BookSource::default()
        }
    }

    /// 测试注入面：独立默认 HTTP 客户端 + 宿主闭包全 None（同 web_book 测试）
    ///
    /// 仅 quickjs 档的 JS 源用例使用（非 quickjs 档无调用者，按 feature 门控
    /// 避免 `-D dead_code`）。
    #[cfg(feature = "quickjs")]
    fn test_deps() -> FetcherDeps {
        static DEPS: std::sync::OnceLock<FetcherDeps> = std::sync::OnceLock::new();
        DEPS.get_or_init(|| {
            let client = legado_net::LegadoClient::new(legado_net::LegadoClientConfig::default())
                .expect("test http client");
            FetcherDeps::new(client)
        })
        .clone()
    }

    /// 空 URL 卷章头（合成为 `{title}{index}`）不得当正文章抓取
    #[test]
    fn test_select_check_chapter_skips_volume_header() {
        let chapters = vec![
            web_chapter(0, "第一卷 开端", "第一卷 开端0", true),
            web_chapter(1, "第一章", "https://a.example.com/1", false),
            web_chapter(2, "第二章", "https://a.example.com/2", false),
        ];
        let chapter = select_check_chapter(&chapters).expect("应选到正文章");
        assert_eq!(chapter.title, "第一章");
    }

    #[test]
    fn test_select_check_chapter_keeps_volume_with_real_url() {
        let chapters = vec![web_chapter(0, "卷", "https://a.example.com/vol", true)];
        assert_eq!(
            select_check_chapter(&chapters).map(|c| c.url.as_str()),
            Some("https://a.example.com/vol")
        );
    }

    #[test]
    fn test_select_check_chapter_none_when_only_volume_headers() {
        let chapters = vec![web_chapter(0, "第一卷", "第一卷0", true)];
        assert!(select_check_chapter(&chapters).is_none());
        assert!(select_check_chapter(&[]).is_none());
    }

    /// 批39 审查 P2-2：JS 单文件源空目录 → `搜索目录失效`（不是 `网站失效`）
    ///
    /// JS 源的 `getChapters` 返回空数组时抛 `LegadoError::TocEmpty`
    /// （`legado_js::js_source::js_source_book::get_chapter_list`）。改前
    /// `check_book` 的目录 `Err(e)` 分支一律 `report.failure = 目录解析失败`
    /// → `check_source` 走 `fail_site` → 误判 `网站失效`；而原版
    /// `checkBook` 把 `TocEmptyException` 归为 `${bookType}目录失效`。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_source_empty_toc_maps_to_search_toc_group() {
        let source = BookSource {
            book_source_url: "https://js-empty-toc.example.com".to_string(),
            book_source_name: "JS 空目录源".to_string(),
            main_js: Some(
                r#"
function search(key, page) {
  return JSON.stringify([{name: '测试书', bookUrl: 'https://js-empty-toc.example.com/book/1'}]);
}
function getBookInfo(book) {
  return JSON.stringify({name: '测试书', tocUrl: 'https://js-empty-toc.example.com/book/1'});
}
function getChapters(book) { return JSON.stringify([]); }
function getContent(chapter, book) { return '正文内容'; }
"#
                .to_string(),
            ),
            ..BookSource::default()
        };
        let config = SourceCheckConfig {
            check_search: true,
            check_discovery: false,
            check_info: true,
            check_category: true,
            check_content: true,
            check_domain: false,
            timeout_ms: 10_000,
            ..SourceCheckConfig::default()
        };

        let outcome =
            crate::test_support::block_on(run_source_check(&test_deps(), &source, &config, None));

        assert!(
            outcome
                .invalid_groups
                .iter()
                .any(|g| g == &toc_group("搜索")),
            "空目录应归入「搜索目录失效」，实际: {:?}",
            outcome.invalid_groups
        );
        assert!(
            !outcome
                .invalid_groups
                .iter()
                .any(|g| g == GROUP_SITE_FAILED),
            "空目录不得误判为「网站失效」，实际: {:?}",
            outcome.invalid_groups
        );
        assert!(
            outcome.failure.is_none(),
            "空目录不是硬失败（应只记分组），实际 failure: {:?}",
            outcome.failure
        );
        assert!(!outcome.toc_ok);
    }

    #[test]
    fn test_effective_keyword() {
        let mut source = source("https://a.example.com");
        assert_eq!(effective_keyword(&source, "我的"), "我的");
        source.rule_search = Some(SearchRule {
            check_key_word: Some("  自定义  ".to_string()),
            ..Default::default()
        });
        assert_eq!(
            effective_keyword(&source, "我的"),
            "  自定义  ",
            "对齐原版 getCheckKeyword：isNotBlank 只判定、原串返回（不 trim）"
        );
        source.rule_search = Some(SearchRule {
            check_key_word: Some("http://x".to_string()),
            ..Default::default()
        });
        assert_eq!(effective_keyword(&source, "我的"), "我的");
        source.rule_search = Some(SearchRule {
            check_key_word: Some("   ".to_string()),
            ..Default::default()
        });
        assert_eq!(effective_keyword(&source, "我的"), "我的");
    }

    #[test]
    fn test_parse_check_source_endpoint() {
        assert_eq!(
            parse_check_source_endpoint("https://a.example.com"),
            Some(("a.example.com".to_string(), 443))
        );
        assert_eq!(
            parse_check_source_endpoint("http://a.example.com/path#frag"),
            Some(("a.example.com".to_string(), 80))
        );
        assert_eq!(
            parse_check_source_endpoint("http://a.example.com:8080/x"),
            Some(("a.example.com".to_string(), 8080))
        );
        assert_eq!(parse_check_source_endpoint("ftp://a.example.com"), None);
        assert_eq!(parse_check_source_endpoint("a.example.com"), None);
        assert_eq!(parse_check_source_endpoint(""), None);
    }

    #[test]
    fn test_first_explore_category_url() {
        let source = source("https://a.example.com");
        assert_eq!(
            first_explore_category_url(
                "分组\n&&玄幻::https://a.example.com/xh\n都市::https://a.example.com/ds",
                &source,
                None
            )
            .unwrap(),
            "https://a.example.com/xh"
        );
        assert_eq!(
            first_explore_category_url(
                r#"[{"title":"玄幻","url":"https://a.example.com/xh"}]"#,
                &source,
                None
            )
            .unwrap(),
            "https://a.example.com/xh"
        );
        assert_eq!(
            first_explore_category_url("玄幻\n都市", &source, None),
            Err(ExploreRuleError::Empty)
        );
        assert_eq!(
            first_explore_category_url("分组::\n玄幻::https://a.example.com/xh", &source, None)
                .unwrap(),
            "https://a.example.com/xh"
        );
        assert!(matches!(
            first_explore_category_url("[{\"title\":}]", &source, None),
            Err(ExploreRuleError::Eval(_))
        ));
    }

    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn test_explore_js_rule_unavailable_without_quickjs() {
        let source = source("https://a.example.com");
        assert!(matches!(
            first_explore_category_url("@js:'[{\"title\":\"x\",\"url\":\"u\"}]'", &source, None),
            Err(ExploreRuleError::Unavailable(_))
        ));
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_js_rule_evaluates_with_quickjs() {
        let source = source("https://a.example.com");
        let js = "JSON.stringify([{title:'玄幻',url:'https://a.example.com/xh'}])";
        assert_eq!(
            first_explore_category_url(&format!("@js:{js}"), &source, None).unwrap(),
            "https://a.example.com/xh"
        );
        assert_eq!(
            first_explore_category_url(&format!("<js>{js}</js>"), &source, None).unwrap(),
            "https://a.example.com/xh"
        );
        assert!(matches!(
            first_explore_category_url("@js:throw new Error('boom')", &source, None),
            Err(ExploreRuleError::Eval(message)) if message.contains("boom")
        ));
    }

    /// 失效分组判定（对齐 `getInvalidGroupNames`）
    #[test]
    fn test_is_invalid_group() {
        assert!(is_invalid_group("搜索失效"));
        assert!(is_invalid_group("域名失效"));
        assert!(is_invalid_group("发现正文失效"));
        assert!(is_invalid_group("校验超时"));
        assert!(!is_invalid_group("玄幻"));
        assert!(!is_invalid_group("校验成功"));
    }

    /// 错误归类：JS 异常 → js失效，其余 → 网站失效
    #[test]
    fn test_group_for_error_matches_upstream() {
        assert_eq!(
            group_for_error(&LegadoError::JsEngine("boom".into())),
            Some(GROUP_JS_FAILED)
        );
        assert_eq!(
            group_for_error(&LegadoError::Timeout("slow".into())),
            Some(GROUP_TIMEOUT)
        );
        assert_eq!(
            group_for_error(&LegadoError::Network("dns".into())),
            Some(GROUP_SITE_FAILED)
        );
        assert_eq!(
            group_for_error(&LegadoError::Parser("rule".into())),
            Some(GROUP_SITE_FAILED)
        );
        assert_eq!(
            group_for_error(&LegadoError::ContentEmpty("x".into())),
            None
        );
        assert_eq!(group_for_error(&LegadoError::TocEmpty("x".into())), None);
    }

    /// 整源超时结果：`校验超时` 分组 + 硬失败消息
    #[test]
    fn test_timeout_outcome_has_group() {
        let outcome = timeout_outcome(&SourceCheckConfig::default());
        assert_eq!(outcome.invalid_groups, vec![GROUP_TIMEOUT.to_string()]);
        assert_eq!(outcome.failure.as_deref(), Some(GROUP_TIMEOUT));
        assert!(!outcome.all_ok());
        assert!(outcome.is_failed());
        assert_eq!(outcome.search_error.as_deref(), Some("timeout"));
    }

    /// 取消态不计为失败
    #[test]
    fn test_cancelled_outcome_not_failed() {
        let outcome = cancelled_outcome(&SourceCheckConfig::default());
        assert!(outcome.cancelled);
        assert!(!outcome.all_ok());
        assert!(!outcome.is_failed());
        assert!(outcome.invalid_groups.is_empty());
    }

    /// 分组消息拼接：`", "` 连接（对齐 `joinToString()`）
    #[test]
    fn test_invalid_group_text_joins() {
        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string(), "发现失效".to_string()],
            ..Default::default()
        };
        assert_eq!(outcome.invalid_group_text(), "搜索失效, 发现失效");
    }

    /// 硬失败保留已累计分组（原版 `fail_check` 语义）
    #[test]
    fn test_fail_keeps_accumulated_groups() {
        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string()],
            ..Default::default()
        };
        let outcome = fail_plain(outcome, "发现规则求值失败: boom");
        assert_eq!(outcome.invalid_groups, vec!["搜索失效".to_string()]);
        assert_eq!(outcome.failure.as_deref(), Some("发现规则求值失败: boom"));
    }

    /// 整源超时配置夹取
    #[test]
    fn test_effective_timeout_clamps() {
        let mut config = SourceCheckConfig {
            timeout_ms: 0,
            ..Default::default()
        };
        assert_eq!(
            config.effective_timeout(),
            Duration::from_millis(MIN_TIMEOUT_MS)
        );
        config.timeout_ms = u64::MAX;
        assert_eq!(
            config.effective_timeout(),
            Duration::from_millis(MAX_TIMEOUT_MS)
        );
    }

    /// 分组分隔符：`,` `;` `，` `；` 均为分隔符（对齐 splitGroupRegex）
    #[test]
    fn test_split_groups_accepts_all_separators() {
        assert_eq!(
            split_groups("玄幻,都市;历史，科幻；武侠"),
            vec!["玄幻", "都市", "历史", "科幻", "武侠"]
        );
        assert!(split_groups("  ").is_empty());
    }

    /// addGroup：并入现有分组、去重、`,` 连接；原值为空直接取新分组
    #[test]
    fn test_add_groups_matches_upstream() {
        assert_eq!(
            add_groups(Some("玄幻,都市"), &["搜索失效".to_string()]).as_deref(),
            Some("玄幻,都市,搜索失效")
        );
        // 已存在不重复追加
        assert_eq!(
            add_groups(Some("玄幻,搜索失效"), &["搜索失效".to_string()]).as_deref(),
            Some("玄幻,搜索失效")
        );
        // 原值为 None → 直接取新分组
        assert_eq!(
            add_groups(None, &["搜索失效".to_string()]).as_deref(),
            Some("搜索失效")
        );
        // 原值为空串 + 空新分组 → 保持原值
        assert_eq!(add_groups(Some(""), &[]).as_deref(), Some(""));
        assert_eq!(add_groups(None, &[]), None);
    }

    /// removeGroup：None 不动；移除后可能为空串
    #[test]
    fn test_remove_groups_matches_upstream() {
        assert_eq!(
            remove_groups(Some("玄幻,搜索失效,都市"), &["搜索失效".to_string()]).as_deref(),
            Some("玄幻,都市")
        );
        assert_eq!(
            remove_groups(Some("搜索失效"), &["搜索失效".to_string()]).as_deref(),
            Some("")
        );
        assert_eq!(remove_groups(None, &["搜索失效".to_string()]), None);
    }

    /// getInvalidGroupNames：含「失效」或等于「校验超时」
    #[test]
    fn test_invalid_group_names() {
        assert_eq!(
            invalid_group_names(Some("玄幻,搜索失效,校验超时,网站失效,都市")),
            vec!["搜索失效", "校验超时", "网站失效"]
        );
        assert!(invalid_group_names(Some("玄幻,都市")).is_empty());
        assert!(invalid_group_names(None).is_empty());
    }

    /// removeInvalidGroups：只清失效分组、保留正常分组
    #[test]
    fn test_remove_invalid_groups() {
        assert_eq!(
            remove_invalid_groups(Some("玄幻,搜索失效,校验超时,都市")).as_deref(),
            Some("玄幻,都市")
        );
        // 无失效分组 → 原值不动
        assert_eq!(
            remove_invalid_groups(Some("玄幻,都市")).as_deref(),
            Some("玄幻,都市")
        );
        assert_eq!(remove_invalid_groups(None), None);
    }

    /// persistable_groups：只保留 `is_invalid_group` 域内分组
    ///
    /// 批39 审查 P1-2：`发现规则为空` 不在取值域（原版 `getInvalidGroupNames()`
    /// 也不认它），落库前必须剔除，否则成功清理永远匹配不到 → 永久残留。
    #[test]
    fn test_persistable_groups_filters_out_of_domain_groups() {
        let groups = vec![
            GROUP_SEARCH_FAILED.to_string(),
            GROUP_DISCOVERY_RULE_EMPTY.to_string(),
            GROUP_TIMEOUT.to_string(),
            GROUP_SITE_FAILED.to_string(),
        ];
        assert_eq!(
            persistable_groups(&groups),
            vec![
                GROUP_SEARCH_FAILED.to_string(),
                GROUP_TIMEOUT.to_string(),
                GROUP_SITE_FAILED.to_string()
            ],
            "域外的「发现规则为空」不得进入落库集合"
        );
        assert!(
            !is_invalid_group(GROUP_DISCOVERY_RULE_EMPTY),
            "is_invalid_group 语义须与原版 getInvalidGroupNames 一致"
        );
        assert!(persistable_groups(&[GROUP_DISCOVERY_RULE_EMPTY.to_string()]).is_empty());
        assert!(persistable_groups(&[]).is_empty());
    }

    /// remove_stale_check_groups：清理历史误写入的域外分组（幂等）
    #[test]
    fn test_remove_stale_check_groups_clears_legacy_discovery_empty() {
        assert_eq!(
            remove_stale_check_groups(Some("玄幻,发现规则为空,搜索失效,都市")).as_deref(),
            Some("玄幻,都市"),
            "存量域外分组与旧失效分组都应清掉"
        );
        // 已干净 → 原值不变（幂等）
        assert_eq!(
            remove_stale_check_groups(Some("玄幻,都市")).as_deref(),
            Some("玄幻,都市")
        );
        // 只剩域外分组 → 空串（原版 removeGroup 语义）
        assert_eq!(
            remove_stale_check_groups(Some("发现规则为空")).as_deref(),
            Some("")
        );
        assert_eq!(remove_stale_check_groups(None), None);
    }

    /// removeErrorComment：按空行分段丢弃 `// Error: ` 开头的段
    #[test]
    fn test_remove_error_comment() {
        assert_eq!(
            remove_error_comment(Some("// Error: boom\n\n正常注释")).as_deref(),
            Some("正常注释")
        );
        assert_eq!(
            remove_error_comment(Some("正常注释")).as_deref(),
            Some("正常注释")
        );
        assert_eq!(remove_error_comment(None), None);
    }

    /// addErrorComment：前置本次消息 + 保留旧注释（空行分隔）
    #[test]
    fn test_add_error_comment() {
        assert_eq!(
            add_error_comment(Some("旧注释"), "校验失败:搜索失效").as_deref(),
            Some("// Error: 校验失败:搜索失效\n\n旧注释")
        );
        assert_eq!(
            add_error_comment(None, "boom").as_deref(),
            Some("// Error: boom")
        );
        assert_eq!(add_error_comment(Some("旧"), "").as_deref(), Some("旧"));
    }
}
