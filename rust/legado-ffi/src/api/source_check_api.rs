//! 书源校验 API（Task #87）
//!
//! 对 `legado-fetcher::source_check` 完整规则链的 FFI 包装，暴露单本校验与
//! 批量流式校验，供 Flutter 书源校验页面接入。
//!
//! - 单本校验：[`check_source`]（搜索→详情→目录→正文 + 发现链 + 域名探测）
//! - 批量校验：[`run_check_sources_stream`]（**串行**逐个回推进度，
//!   对齐 Kotlin `CheckSourceService` 的 flow 顺序校验）
//!
//! 与 server 端点的关系：规则级判定由 `legado-fetcher::source_check` 单一实现
//! 承担（`legado-server` 的 `/startBookSourceCheck` 同一实现）。批量校验采用
//! 串行执行（对齐 Kotlin 原版），避免对书源站产生并发压力；取消为**会话级**
//! （对齐 Kotlin `CheckSource.stop`，P1-1 修复：每个流持有独立令牌，互不干扰）。
//!
//! 批44（失效分组落库）：
//! - 每个源完成后把 [`SourceCheckOutcome::invalid_groups`] 按参考版语义写回
//!   `book_sources.bookSourceGroup` + `bookSourceComment` **两列**
//!   （失败追加具体分组 + `// Error:` 注释；成功清除旧失效分组与历史错误块）；
//! - 写回带 `lastUpdateTime`/分组/注释快照 CAS（校验期间源被编辑 → 不写回）；
//! - 不使用参考版的整行 `@Update`，避免覆盖并发编辑的其它列。
//!
//! 语义差异登记：`captcha` / `redirect` 字段与 `detect_captcha` / `detect_redirect`
//! 配置保留（形状不变），但规则级链路不单独做验证码/重定向检测——与 Android
//! 原版 `CheckSourceService` 一致（验证码拦截表现为搜索结果为空 → `搜索失效`）。
//!
//! P1-5（超时/取消接线）：`step_timeout_ms` 作为**整源总预算**（对齐原版
//! `withTimeout(CheckSource.timeout)`），取消令牌经 `select!` 轮询，卡住的请求
//! 可在 100ms 内被丢弃。取消结果以 [`CheckResult::cancelled`] 标记，不计为书源
//! 失败，也不写回分组。

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use legado_db::BookSourceRepository;
use legado_fetcher::source_check::{
    add_error_comment, add_groups, persistable_groups, remove_error_comment,
    remove_stale_check_groups, run_source_check, SourceCheckConfig, SourceCheckOutcome,
};
use legado_net::source_checker::CancelToken;

use crate::db_state::with_database;

// ─── 会话级取消登记 ───────────────────────────────────────────────────────────

/// 活动校验会话注册表（会话 id → 该会话专属取消令牌）
///
/// P1-1：取消令牌由「进程级单例」改为「会话级」——
/// - 每个 [`run_check_sources_stream`] 调用创建**独立**令牌并登记自增 id，
///   两个并发流互不干扰：取消 A 不波及 B，A 的启动/结束也不清 B 的取消；
/// - 令牌在**加载书源之前**登记（见 [`run_check_sources_stream`]），
///   源加载窗口内到达的取消不会再被进入循环时的 `reset()` 清掉；
/// - 会话结束（正常/提前 break/sink 关闭/panic/unwind）由 [`CheckSession`]
///   的 `Drop` 移除登记，避免泄漏与误取消后续会话。
///
/// 之所以用 `HashMap` 而非单槽 `Option<(u64, CancelToken)>`：审查要求的
/// 「两个并发流，取消 A 不影响 B」需要同时寻址 A 与 B；单槽会在 B 登记时
/// 覆盖 A，导致 A 无法被按 id 取消。`current` 记录最近登记的会话，
/// 供无参 [`cancel_check_sources`]（Dart 兼容入口）使用。
#[derive(Default)]
struct CheckSessionRegistry {
    /// 下一个会话 id（自增，从 1 开始；会话结束后不复用）
    next_id: u64,
    /// 进行中的会话
    sessions: HashMap<u64, CancelToken>,
    /// 最近登记的会话 id（无参取消的兼容目标）
    current: Option<u64>,
}

impl CheckSessionRegistry {
    fn new() -> Self {
        Self {
            next_id: 1,
            ..Self::default()
        }
    }
}

/// 全局会话注册表（仅保存令牌，不持锁跨 await/网络）
static CHECK_SESSIONS: LazyLock<Mutex<CheckSessionRegistry>> =
    LazyLock::new(|| Mutex::new(CheckSessionRegistry::new()));

/// 获取注册表锁（容忍 poison：注册表只做 HashMap 操作，不会留下半更新状态）
fn session_registry() -> std::sync::MutexGuard<'static, CheckSessionRegistry> {
    CHECK_SESSIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 一次批量校验会话：持有专属取消令牌，`Drop` 时注销登记
///
/// 令牌为会话私有：新会话天然是「未取消」态，**不需要**（也不应）对
/// 共享标志做 `reset()`——那正是修复前「加载窗口取消被吞」与「互相
/// 取消」的根因。
struct CheckSession {
    id: u64,
    token: CancelToken,
}

impl CheckSession {
    /// 创建并登记新会话（在加载书源等任何耗时操作之前调用）
    fn start() -> Self {
        let token = CancelToken::new();
        let id = {
            let mut registry = session_registry();
            let id = registry.next_id;
            registry.next_id += 1;
            registry.sessions.insert(id, token.clone());
            registry.current = Some(id);
            id
        };
        Self { id, token }
    }

    /// 会话 id
    fn id(&self) -> u64 {
        self.id
    }

    /// 本会话的取消令牌（克隆共享同一底层标志）
    fn token(&self) -> CancelToken {
        self.token.clone()
    }
}

impl Drop for CheckSession {
    fn drop(&mut self) {
        let mut registry = session_registry();
        registry.sessions.remove(&self.id);
        if registry.current == Some(self.id) {
            // 最近会话结束：无参取消回退到仍存活的最大 id（最近登记的）
            registry.current = registry.sessions.keys().copied().max();
        }
    }
}

// ─── 配置 DTO ─────────────────────────────────────────────────────────────────

/// 校验配置 JSON DTO（所有字段可选，缺省回落 [`SourceCheckConfig::default`]）
///
/// 字段：`keyword` / `step_timeout_ms` / `check_search` / `check_toc` /
/// `check_content` / `detect_captcha` / `detect_redirect`。
///
/// `detect_captcha` / `detect_redirect` 自批44 起**解析但不再影响判定**
/// （规则级链路与 Android 原版一致，不做独立验证码/重定向检测），保留字段
/// 以维持既有 configJson 契约不破坏。
#[derive(Debug, Clone, Default, Deserialize)]
struct CheckerConfigDto {
    keyword: Option<String>,
    step_timeout_ms: Option<u64>,
    check_search: Option<bool>,
    check_toc: Option<bool>,
    check_content: Option<bool>,
    /// 批44 起**解析但不再影响判定**（规则级链路与 Android 原版一致，不做独立
    /// 验证码检测）。保留字段只为既有 configJson 契约不被破坏。
    #[allow(dead_code)]
    detect_captcha: Option<bool>,
    /// 同上：解析但不再影响判定（不做独立重定向检测）。
    #[allow(dead_code)]
    detect_redirect: Option<bool>,
}

/// 解析校验配置 JSON（空字符串 / `"{}"` 均使用默认配置）
fn parse_config(config_json: &str) -> LegadoResult<SourceCheckConfig> {
    let defaults = SourceCheckConfig::default();
    if config_json.trim().is_empty() {
        return Ok(defaults);
    }
    let dto: CheckerConfigDto = serde_json::from_str(config_json)
        .map_err(|e| LegadoError::Ffi(format!("校验配置 JSON 解析失败: {e}")))?;
    Ok(SourceCheckConfig {
        keyword: dto
            .keyword
            .filter(|s| !s.is_empty())
            .unwrap_or(defaults.keyword),
        timeout_ms: dto.step_timeout_ms.unwrap_or(defaults.timeout_ms),
        check_search: dto.check_search.unwrap_or(defaults.check_search),
        check_category: dto.check_toc.unwrap_or(defaults.check_category),
        check_content: dto.check_content.unwrap_or(defaults.check_content),
        // 规则级链路恒不单独探测验证码/重定向（对齐原版）
        ..defaults
    })
}

/// 组装 ffi 宿主注入面（共享客户端 + 登录头/DB 变量/setup + 副内容 sink）
///
/// 复用 `web_book::ffi_deps()`（与搜索/取章链路同一注入面，避免漂移）。
fn check_deps() -> LegadoResult<legado_fetcher::deps::FetcherDeps> {
    crate::api::web_book::ffi_deps()
}

// ─── 单本校验 ─────────────────────────────────────────────────────────────────

/// 校验单个书源（搜索→详情→目录→正文 + 发现链 + 域名探测）
///
/// `source_json` — BookSource JSON（字段名对齐 Android 原版 camelCase）
/// `config_json` — 可选校验配置 JSON（见 [`CheckerConfigDto`]），空串使用默认配置
///
/// 返回 [`CheckResult`]（同步阻塞执行，内部走全局 tokio runtime）。
/// 单本校验**不写回**分组/注释（无并发快照语义，且调用方只关心判定结果）。
pub fn check_source(source_json: &str, config_json: &str) -> LegadoResult<CheckResult> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("BookSource JSON 解析失败: {e}")))?;
    let config = parse_config(config_json)?;
    let deps = check_deps()?;
    Ok(crate::runtime::block_on(async move {
        let started = std::time::Instant::now();
        let outcome = run_source_check(&deps, &source, &config, None).await;
        let mut result = outcome_to_check_result(&source.book_source_url, outcome);
        result.total_time_ms = started.elapsed().as_millis() as i64;
        result
    }))
}

/// [`SourceCheckOutcome`] → FFI [`CheckResult`]
///
/// `total_time_ms` 由调用方按源计时后覆写（此处置 0 占位）。
fn outcome_to_check_result(source_url: &str, outcome: SourceCheckOutcome) -> CheckResult {
    CheckResult {
        source_url: source_url.to_string(),
        search_ok: outcome.search_ok,
        toc_ok: outcome.toc_ok,
        content_ok: outcome.content_ok,
        search_error: outcome.search_error,
        toc_error: outcome.toc_error,
        content_error: outcome.content_error,
        // 规则级链路不单独检测验证码/重定向（与 Android 原版一致）
        captcha: None,
        redirect: None,
        cancelled: outcome.cancelled,
        invalid_groups: outcome.invalid_groups,
        total_time_ms: 0,
    }
}

// ─── 校验结果 DTO（FFI 契约面） ───────────────────────────────────────────────

/// 书源校验结果（FFI 契约 §2.3 `checkSource` / `CheckProgress.result`）
///
/// 独立于 `legado-net::source_checker::CheckResult`（后者服务 server 的
/// `/api/sources/check*` 与 MCP，形状冻结），本 DTO 是 FFI 侧的契约形状：
/// 在其基础上追加 `invalid_groups`（批44）。`serde` 键名与旧形状逐字一致，
/// 新增字段 `#[serde(default)]`，旧 Dart 端忽略未知键不破坏反序列化。
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
    /// 验证码检测结果（批44 起规则级链路恒为 `None`，字段保留兼容）
    pub captcha: Option<CaptchaInfo>,
    /// 重定向检测结果（批44 起规则级链路恒为 `None`，字段保留兼容）
    pub redirect: Option<RedirectInfo>,
    /// 是否被用户主动取消
    ///
    /// `true` 表示校验在完成前收到取消请求，此时各步错误字段为
    /// `"cancelled"` / `"skipped: cancelled"`，**不表示书源不可用**；
    /// 批量流遇到该结果会静默结束，不再回推后续进度。
    #[serde(default)]
    pub cancelled: bool,
    /// 失效分组名（批44，加法式）
    ///
    /// 由 `legado-fetcher::source_check` 完整规则链判定：`校验超时` / `js失效` /
    /// `域名失效` / `搜索失效` / `发现失效` / `发现规则为空` / `${bookType}正文失效` /
    /// `${bookType}目录失效` / `网站失效`。取消态恒为空数组。
    #[serde(default)]
    pub invalid_groups: Vec<String>,
}

impl CheckResult {
    /// 是否被用户主动取消（取消不计为书源不可用）
    fn is_cancelled(&self) -> bool {
        self.cancelled
    }
}

/// 验证码检测结果（契约形状保留；规则级链路不产生）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptchaInfo {
    /// 是否检测到验证码
    pub detected: bool,
    /// 验证码类型描述
    pub captcha_type: Option<String>,
    /// 匹配到的关键词/元素
    pub matched_keyword: Option<String>,
}

/// 重定向检测结果（契约形状保留；规则级链路不产生）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedirectInfo {
    /// 是否发生了重定向
    pub redirected: bool,
    /// 原始请求 URL
    pub original_url: String,
    /// 最终 URL
    pub final_url: String,
    /// 是否重定向到登录/验证页面
    pub is_login_redirect: bool,
}

// ─── 批量流式校验 ─────────────────────────────────────────────────────────────

/// 批量校验进度项（每完成一个书源推送一条）
///
/// 以 JSON 字符串跨 FFI 传递，字段：
/// - `index` — 当前书源在请求列表中的索引（从 0 开始）
/// - `total` — 本次校验的书源总数
/// - `is_last` — 是否为最后一条（`index == total - 1`）
/// - `source_name` — 书源名称（便于 UI 展示）
/// - `result` — 该书源的 [`CheckResult`] 完整结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckProgress {
    /// 当前书源索引（从 0 开始）
    pub index: usize,
    /// 书源总数
    pub total: usize,
    /// 是否为最后一条
    pub is_last: bool,
    /// 书源名称
    pub source_name: String,
    /// 该书源的校验结果
    pub result: CheckResult,
}

/// 批量校验书源（串行），逐个回推进度
///
/// 与 [`check_source`] 不同：本函数按请求顺序**串行**校验每个书源
/// （对齐 Kotlin `CheckSourceService` flow 顺序执行），每完成一个书源
/// 即调用一次 `on_result`（传入 [`CheckProgress`] 的 JSON 字符串）。
///
/// `source_urls_json` — 待校验书源 URL 的 JSON 数组；为空（空串/`[]`）则校验全部书源
/// `config_json` — 可选校验配置 JSON，空串使用默认配置
/// `on_result` — 每个书源完成时的回调；返回 `Err` 时提前终止（如 sink 已关闭）
///
/// 配合 [`cancel_check_sources`] / [`cancel_check_sources_by_id`] 可提前中止。
/// 每次调用创建独立会话与取消令牌（见 [`CheckSession`]）。
pub async fn run_check_sources_stream<F>(
    source_urls_json: String,
    config_json: String,
    mut on_result: F,
) where
    F: FnMut(String) -> Result<(), String>,
{
    // P1-1：会话令牌必须在加载书源**之前**登记。`load_check_sources` 是
    // 同步 DB 查询，可能耗时；此窗口内到达的取消必须落在本会话令牌上，
    // 而不是像修复前那样被进入循环时的 `reset()` 清掉。
    let session = CheckSession::start();
    // 书源加载失败时以空流结束（Dart 侧表现为无结果）
    let sources = load_check_sources(&source_urls_json).unwrap_or_default();
    run_check_sources_stream_inner(session, sources, &config_json, &mut on_result).await;
}

/// 测试注入入口：与生产入口同序（先登记会话，再执行加载）
///
/// `loader` 替代 `load_check_sources`，用于在「会话已登记、循环未开始」
/// 的窗口内注入取消（P1-1 回归用例）。
#[cfg(test)] // 测试专用：注入「加载窗口」以复现 P1-1
async fn run_check_sources_stream_with_loader<L, F>(loader: L, config_json: &str, mut on_result: F)
where
    L: FnOnce() -> Vec<Option<BookSource>>,
    F: FnMut(String) -> Result<(), String>,
{
    // 与生产入口同序：先登记会话，再执行可能耗时的加载（测试注入点）
    let session = CheckSession::start();
    let sources = loader();
    run_check_sources_stream_inner(session, sources, config_json, &mut on_result).await;
}

/// 批量校验内层实现（接收会话与书源列表）
///
/// 串行逐个校验并回推 [`CheckProgress`] JSON；本会话令牌置位或
/// `on_result` 返回 `Err` 时提前终止。`session` 的 `Drop` 负责注销登记。
async fn run_check_sources_stream_inner<F>(
    session: CheckSession,
    sources: Vec<Option<BookSource>>,
    config_json: &str,
    mut on_result: F,
) where
    F: FnMut(String) -> Result<(), String>,
{
    // P1-1：不再 reset 任何共享标志——令牌是会话私有的新实例，
    // 天然为未取消态；调用方（含加载窗口内）已置位的取消保持有效。
    let token = session.token();
    let total = sources.len();
    if total == 0 {
        return;
    }

    // 源加载窗口内已收到取消：不进入循环、不推送任何结果
    if token.is_cancelled() {
        log::debug!(
            "书源校验：源加载窗口内收到取消，会话 #{} 终止",
            session.id()
        );
        return;
    }

    let config = parse_config(config_json).unwrap_or_default();
    let deps = match check_deps() {
        Ok(deps) => deps,
        Err(e) => {
            log::error!("书源校验：抓取组件初始化失败: {e}");
            return;
        }
    };

    // 串行逐个校验（对齐 Kotlin CheckSourceService，避免对书源站并发压力）
    for (index, source) in sources.into_iter().enumerate() {
        if token.is_cancelled() {
            break;
        }

        let started = std::time::Instant::now();
        let (result, write_back) = match source {
            Some(ref src) => {
                let outcome = run_source_check(&deps, src, &config, Some(token.clone())).await;
                let result = outcome_to_check_result(&src.book_source_url, outcome.clone());
                (result, Some((src.clone(), outcome)))
            }
            // 书源不存在：对齐 Kotlin source == null 分支，推送失败结果
            None => (
                CheckResult {
                    source_url: String::new(),
                    search_ok: false,
                    toc_ok: false,
                    content_ok: false,
                    search_error: Some("书源不存在".to_string()),
                    toc_error: Some("skipped".to_string()),
                    content_error: Some("skipped".to_string()),
                    total_time_ms: 0,
                    captcha: None,
                    redirect: None,
                    cancelled: false,
                    invalid_groups: Vec::new(),
                },
                None,
            ),
        };
        let mut result = result;
        result.total_time_ms = started.elapsed().as_millis() as i64;

        // P1-5：取消发生在某个书源内部时，该结果标记为「已取消」而非
        // 「书源不可用」——流按取消静默结束，不回推这条半成品结果
        //（对齐 Kotlin `flow` 取消语义：被取消的调用不发射结果）。
        if result.is_cancelled() {
            log::debug!("书源校验：用户取消，终止流（已完成 {index}/{total}）");
            break;
        }

        // 批44：按本次判定结果写回分组/注释（成功则清旧失效分组）。
        // 写回失败不阻断流（分组是增强副作用，判定结果仍要回推）。
        if let Some((source, outcome)) = write_back {
            write_back_check_groups(&source, &outcome, config.w_source_comment);
            // [B13] 响应时间写回（对齐原版 `Debug.getRespondTime` 与
            // Web 侧 `legado-server/src/legacy/source_check_api.rs`）：
            // 此前 FFI 校验链完全不写 `respondTime`，书源管理页的响应耗时
            // 永远停在导入值（默认 180000），校验结果对用户不可见。
            write_back_respond_time(&source, &outcome, &config, result.total_time_ms);
        }

        let progress = CheckProgress {
            index,
            total,
            is_last: index + 1 >= total,
            source_name: source
                .as_ref()
                .map(|s| s.book_source_name.clone())
                .unwrap_or_default(),
            result,
        };

        if let Ok(json) = serde_json::to_string(&progress) {
            // sink 关闭（Err）时提前终止
            if on_result(json).is_err() {
                break;
            }
        }
    }
}

/// 写回单源校验分组与注释（批44，参考版语义 + 定向两列 CAS）
///
/// 语义（对齐原版 `CheckSourceService.doCheckSource` 的**先清后加** +
/// 参考版 `BookSourceCheckRepository.kt` 的落库）：
///
/// 原版 `doCheckSource` 起始即 `removeInvalidGroups()` + `removeErrorComment()`，
/// 随后按失败项 `addGroup(...)`，失败时再 `addErrorComment(本次异常)`。因此
/// 一次校验的最终态是「**本次判定的失效分组**」而非「历史分组累积」：
/// - **失败**：先清旧失效分组（含「失效」或等于「校验超时」），再追加本次
///   判定的具体分组（`,` 分隔去重）；注释先清历史 `// Error:` 块，再前置本次
///   `// Error: {消息}`（`w_source_comment=false` 时不写）；
/// - **成功**：清除旧失效分组与历史 `// Error:` 块（正常分组/正常注释保留）；
/// - **取消**：不改动（取消不计为源缺陷）。
///
/// **落库集合 = `is_invalid_group` 认可的域内分组**（批39 审查 P1-2）：
/// `发现规则为空` 属「分组判定」但不在原版 `getInvalidGroupNames()` 取值域，
/// 原版只把它当异常消息、从不 `addGroup`。若把它写进 `bookSourceGroup`，
/// 后续成功清理匹配不到 → 永久残留且与已清掉的 `// Error:` 注释矛盾。
/// 因此本函数用 [`persistable_groups`] 过滤后再追加，写集与清集天然一致；
/// 该判定仍以 `// Error: 发现规则为空` 消息形式保留。
/// 同时用 [`remove_stale_check_groups`] 清掉历史版本误写入的该分组（幂等）。
///
/// **只更新 `bookSourceGroup` + `bookSourceComment` 两列**（不是参考版整行
/// `@Update`），并带 `lastUpdateTime`/分组/注释快照 CAS——校验期间源被编辑
/// 则整笔丢弃，不覆盖并发修改。
fn write_back_check_groups(source: &BookSource, outcome: &SourceCheckOutcome, w_comment: bool) {
    let url = &source.book_source_url;
    if url.trim().is_empty() {
        return;
    }
    let old_group = source.book_source_group.as_deref();
    let old_comment = source.book_source_comment.as_deref();

    let (new_group, new_comment) = if outcome.cancelled {
        // 取消不计为源缺陷，也不改动分组/注释
        return;
    } else {
        // 共同起点：清旧失效分组 + 历史遗留域外分组 + 清历史错误注释
        // （对齐 doCheckSource 起始两步；域外分组清理见 P1-2 说明）
        let base_group = remove_stale_check_groups(old_group);
        let base_comment = remove_error_comment(old_comment);
        if outcome.is_failed() {
            // 失败消息：硬失败消息优先，否则用分组串（对齐原版 resultMessage）
            let message = outcome
                .failure
                .clone()
                .unwrap_or_else(|| outcome.invalid_group_text());
            // P1-2：只落 `is_invalid_group` 域内的分组（`发现规则为空` 仅入消息）
            let groups = persistable_groups(&outcome.invalid_groups);
            let group = if groups.is_empty() {
                base_group
            } else {
                add_groups(base_group.as_deref(), &groups)
            };
            let comment = if w_comment && !message.is_empty() {
                add_error_comment(base_comment.as_deref(), &message)
            } else {
                base_comment
            };
            (group, comment)
        } else {
            (base_group, base_comment)
        }
    };

    // 无变化则不发起写（避免无谓 DB 写与 CAS 竞争）
    if new_group.as_deref() == old_group && new_comment.as_deref() == old_comment {
        return;
    }

    let written = crate::db_state::with_database(|db| {
        BookSourceRepository::new(db.connection()).update_check_groups_and_comment(
            url,
            new_group.as_deref(),
            new_comment.as_deref(),
            source.last_update_time,
            old_group,
            old_comment,
        )
    });
    match written {
        Ok(true) => {}
        Ok(false) => log::debug!("书源 {url} 校验分组未写回：校验期间源已变更（CAS 未命中）"),
        Err(e) => log::warn!("书源 {url} 校验分组写回失败: {e}"),
    }
}

/// 写回单源校验耗时到 `book_sources.respondTime`（B13）
///
/// 口径逐条对齐原版 `Debug.getRespondTime(...)` 与 Web 侧实现
/// （`legado-server/src/legacy/source_check_api.rs::write_back_check_result`）：
/// - **失败** → `timeout_ms + 实测耗时`（超时基数 + 实际等待）；
/// - **成功 / 不可判定** → 实测耗时；
/// - **取消** → 不写（取消不计为源性能）。
///
/// 单列 UPDATE，不参与分组/注释的 CAS（响应耗时是观测值，不构成并发写回
/// 风险）；写失败只记日志，不影响校验判定结果。
fn write_back_respond_time(
    source: &BookSource,
    outcome: &SourceCheckOutcome,
    config: &SourceCheckConfig,
    total_time_ms: i64,
) {
    if outcome.cancelled {
        return;
    }
    let url = &source.book_source_url;
    if url.trim().is_empty() {
        return;
    }
    let elapsed = total_time_ms.max(0);
    let respond_time = if outcome.is_failed() {
        config.timeout_ms as i64 + elapsed
    } else {
        elapsed
    };
    if let Err(e) = crate::db_state::with_database(|db| {
        BookSourceRepository::new(db.connection()).update_respond_time(url, respond_time)
    }) {
        log::warn!("书源 {url} 响应时间写回失败: {e}");
    }
}

/// 取消正在进行的批量校验（兼容 Dart 侧无会话 id 的既有 FFI 入口）
///
/// 会话化后的兼容语义：只取消**最近登记且仍在进行**的会话
/// （[`CheckSessionRegistry::current`]）；无活动会话时为 no-op。
/// 正常 UI 同时只有一个校验流，因此等价于「停止当前校验」。
///
/// 需要精确取消某个并发会话时用 [`cancel_check_sources_by_id`]。
/// 置位后，正在进行的网络步骤会在 100ms 轮询周期内被 `select!` 打断
///（不再等当前书源的 1~3 个 HTTP 请求自然结束）。
pub fn cancel_check_sources() {
    let token = {
        let registry = session_registry();
        registry
            .current
            .and_then(|id| registry.sessions.get(&id).cloned())
    };
    if let Some(token) = token {
        token.cancel();
    }
}

/// 按会话 id 取消指定的批量校验（只影响该会话）
///
/// 返回 `true` 表示命中并置位；`false` 表示该会话已结束/从未存在
/// （已由 `Drop` 清理，不会误伤后续会话）。
pub fn cancel_check_sources_by_id(session_id: u64) -> bool {
    let token = session_registry().sessions.get(&session_id).cloned();
    match token {
        Some(token) => {
            token.cancel();
            true
        }
        None => false,
    }
}

/// 当前活动会话 id（升序；测试断言登记清理用）
#[cfg(test)]
fn active_session_ids() -> Vec<u64> {
    let mut ids: Vec<u64> = session_registry().sessions.keys().copied().collect();
    ids.sort_unstable();
    ids
}

// ─── 内部实现 ─────────────────────────────────────────────────────────────────

/// 按 URL 列表从数据库加载待校验的书源
///
/// 与搜索链路不同：校验针对用户选中的书源，**不过滤禁用状态**
/// （对齐 Kotlin `CheckSourceService` 直接按 URL 取完整书源）。
/// 空串/空数组表示校验全部书源；列表中不存在的 URL 以 `None` 占位，
/// 保持推送顺序与请求列表一致。
fn load_check_sources(source_urls_json: &str) -> LegadoResult<Vec<Option<BookSource>>> {
    if source_urls_json.trim().is_empty() {
        return all_sources_as_options();
    }
    let urls: Vec<String> = serde_json::from_str(source_urls_json)
        .map_err(|e| LegadoError::Ffi(format!("书源 URL 列表解析失败: {e}")))?;
    if urls.is_empty() {
        return all_sources_as_options();
    }
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        let mut sources = Vec::with_capacity(urls.len());
        for url in &urls {
            sources.push(repo.find_by_url(url)?);
        }
        Ok(sources)
    })
}

/// 全部书源以 `Some` 包装返回（空列表语义：校验全部）
fn all_sources_as_options() -> LegadoResult<Vec<Option<BookSource>>> {
    let all = crate::api::source::list_sources()?;
    Ok(all.into_iter().map(Some).collect())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_db::repository::Repository;
    use std::sync::atomic::Ordering;

    /// 流式测试共享进程级会话注册表，并行执行会互相影响取消目标，
    /// 故串行化所有流式测试。使用 tokio 异步锁：其守卫为 Send，
    /// 可跨 `.await` 全程持有。
    async fn lock_stream_tests() -> tokio::sync::MutexGuard<'static, ()> {
        static STREAM_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        STREAM_TEST_LOCK.lock().await
    }

    /// 构造无 searchUrl 的书源（校验走纯错误路径，无需网络）
    fn make_source_no_search(url: &str, name: &str) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            book_source_name: name.to_string(),
            search_url: None,
            ..BookSource::default()
        }
    }

    /// 构造走搜索链路的书源（搜索 URL 指向本地回环）
    fn make_source_with_search(url: &str, name: &str, search_url: String) -> BookSource {
        BookSource {
            book_source_url: url.to_string(),
            book_source_name: name.to_string(),
            search_url: Some(search_url),
            ..BookSource::default()
        }
    }

    /// 卡死站点：接受连接、读完请求头后 60s 不回包
    fn spawn_hanging_http_server() -> u16 {
        use std::io::Read;

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("绑定回环服务器");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            while let Ok((mut sock, _)) = listener.accept() {
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let _ = sock.read(&mut buf);
                    std::thread::sleep(std::time::Duration::from_secs(60));
                });
            }
        });
        port
    }

    /// 慢站点：每次请求固定延迟后返回同一 HTML 响应体
    fn spawn_delayed_http_server(delay: std::time::Duration, body: &'static str) -> u16 {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("绑定回环服务器");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            while let Ok((mut sock, _)) = listener.accept() {
                std::thread::spawn(move || {
                    let mut buf = [0u8; 4096];
                    let _ = sock.read(&mut buf);
                    std::thread::sleep(delay);
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = sock.write_all(response.as_bytes());
                });
            }
        });
        port
    }

    /// 仅检查搜索步骤的配置（避免慢站点把目录/正文也拖进用例）
    const SEARCH_ONLY_CONFIG: &str = r#"{"check_toc":false,"check_content":false}"#;

    // ─── 配置解析 ─────────────────────────────────────────────

    #[test]
    fn test_parse_config_empty_uses_default() {
        let cfg = parse_config("").unwrap();
        let defaults = SourceCheckConfig::default();
        assert_eq!(cfg.keyword, defaults.keyword);
        assert_eq!(cfg.timeout_ms, defaults.timeout_ms);
        assert!(cfg.check_search && cfg.check_category && cfg.check_content);
    }

    #[test]
    fn test_parse_config_partial_override() {
        let cfg =
            parse_config(r#"{"keyword":"自定义","step_timeout_ms":5000,"check_content":false}"#)
                .unwrap();
        assert_eq!(cfg.keyword, "自定义");
        assert_eq!(cfg.timeout_ms, 5000);
        assert!(!cfg.check_content);
        // 未指定字段回落默认
        assert!(cfg.check_search);
        assert!(cfg.check_category);
    }

    #[test]
    fn test_parse_config_invalid_json() {
        assert!(parse_config("{invalid").is_err());
    }

    // ─── 单本校验 ─────────────────────────────────────────────

    /// 无 searchUrl 规则源：搜索判失败（「搜索链接规则为空」），后续步骤跳过
    #[test]
    fn test_check_source_no_search_url() {
        let source = make_source_no_search("https://example.com", "测试源");
        let json = serde_json::to_string(&source).unwrap();

        let result = check_source(&json, "").expect("单本校验失败");
        assert!(!result.search_ok);
        assert!(!result.toc_ok);
        assert!(!result.content_ok);
        assert!(
            result.search_error.unwrap().contains("搜索链接规则为空"),
            "规则级链路应判搜索规则为空（不是 searchUrl 解析错误）"
        );
        // 「搜索链接规则为空」对齐原版 NoStackTraceException：不加失效分组
        assert!(result.invalid_groups.is_empty());
    }

    /// 自定义配置生效：关闭后续检查时 toc/content 直接置通过
    #[test]
    fn test_check_source_with_config_skip_steps() {
        let source = make_source_no_search("https://example.com", "测试源");
        let json = serde_json::to_string(&source).unwrap();

        let result = check_source(&json, r#"{"check_toc":false,"check_content":false}"#)
            .expect("单本校验失败");
        assert!(!result.search_ok);
        // 关闭的检查步骤直接视为通过（对齐原版 checkInfo/checkCategory/checkContent）
        assert!(result.toc_ok);
        assert!(result.content_ok);
    }

    /// 非法书源 JSON 应报错
    #[test]
    fn test_check_source_invalid_json() {
        assert!(check_source("{not json", "").is_err());
    }

    /// P1-5：DTO → `SourceCheckConfig` 全链路字段不丢失
    #[test]
    fn test_parse_config_carries_all_fields() {
        let config = parse_config(
            r#"{
                "keyword":"校验词",
                "step_timeout_ms":5000,
                "check_search":false,
                "check_toc":false,
                "check_content":false,
                "detect_captcha":false,
                "detect_redirect":false
            }"#,
        )
        .unwrap();
        assert_eq!(config.keyword, "校验词");
        assert_eq!(config.timeout_ms, 5_000);
        assert!(!config.check_search);
        assert!(!config.check_category);
        assert!(!config.check_content);
        // 规则级链路恒不单独探测验证码/重定向（字段解析但不影响判定）
        assert_eq!(
            config.w_source_comment,
            SourceCheckConfig::default().w_source_comment
        );
    }

    /// P1-1：会话级取消只影响目标会话；无参入口取消最近登记的会话
    #[tokio::test]
    async fn test_session_cancel_isolation() {
        let _guard = lock_stream_tests().await;

        let session_a = CheckSession::start();
        let session_b = CheckSession::start();
        let (id_a, id_b) = (session_a.id(), session_b.id());
        assert_eq!(active_session_ids(), vec![id_a, id_b]);

        // 按 id 取消 A：只置位 A
        assert!(cancel_check_sources_by_id(id_a));
        assert!(session_a.token().is_cancelled());
        assert!(!session_b.token().is_cancelled(), "取消 A 不得影响 B");

        // 无参入口（Dart 兼容）取消 current（最近登记的 B）
        cancel_check_sources();
        assert!(session_b.token().is_cancelled());

        // 会话结束后按 id 取消返回 false（不会误伤后续会话）
        drop(session_a);
        drop(session_b);
        assert!(active_session_ids().is_empty());
        assert!(!cancel_check_sources_by_id(id_a));
    }

    /// P1-5：批量校验中取消必须打断卡住的请求（而非等当前书源跑完）
    ///
    /// 本地回环服务器 accept 后不回包；200ms 后取消当前会话，
    /// 断言整条流 1s 内结束，且不为在途书源回推「失败」结果。
    /// 修复前该用例会等满客户端 read_timeout（60s）。
    #[tokio::test]
    async fn test_stream_cancel_interrupts_hanging_request() {
        let _guard = lock_stream_tests().await;
        let port = spawn_hanging_http_server();

        let mut source = make_source_no_search(&format!("http://127.0.0.1:{port}"), "卡死源");
        source.search_url = Some(format!("http://127.0.0.1:{port}/search?q={{key}}"));

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();

        let canceller = tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            cancel_check_sources();
        });

        let started = std::time::Instant::now();
        run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(source)],
            "",
            move |json| {
                collected_cb.lock().unwrap().push(json);
                Ok(())
            },
        )
        .await;
        let elapsed = started.elapsed();
        canceller.await.unwrap();

        assert!(
            elapsed < std::time::Duration::from_secs(1),
            "取消应在 1s 内返回，实际 {elapsed:?}"
        );
        assert!(
            collected.lock().unwrap().is_empty(),
            "被用户取消的书源不得回推结果（不计为书源失败）"
        );
    }

    /// 上一轮会话残留的取消不得吞掉新一轮批量校验
    #[tokio::test]
    async fn test_stream_run_ignores_cancel_from_previous_session() {
        let _guard = lock_stream_tests().await;

        // 上一轮会话被取消并结束
        let stale = CheckSession::start();
        cancel_check_sources();
        assert!(stale.token().is_cancelled());
        drop(stale);

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();
        run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_no_search("https://a.example.com", "源A"))],
            "",
            move |json| {
                collected_cb.lock().unwrap().push(json);
                Ok(())
            },
        )
        .await;

        assert_eq!(
            collected.lock().unwrap().len(),
            1,
            "上一轮会话的取消不得影响新会话"
        );
    }

    /// P1-1 症状 1：取消落在「源加载窗口」内（进入校验循环之前）也必须
    /// 让整批停止。
    ///
    /// 修复前：`reset()` 写在 `run_check_sources_stream_inner` 首行，晚于
    /// `load_check_sources`；加载期间置位的取消标志会被 `reset()` 清掉，
    /// 整批继续跑（本用例会推送 1 条结果 → 红）。
    #[tokio::test]
    async fn test_cancel_during_source_load_window_stops_batch() {
        let _guard = lock_stream_tests().await;

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();

        run_check_sources_stream_with_loader(
            || {
                // 模拟「书源加载（DB 查询）窗口内」用户点取消：此刻会话令牌
                // 已登记，尚未进入校验循环。
                cancel_check_sources();
                vec![Some(make_source_no_search("https://a.example.com", "源A"))]
            },
            "",
            move |json| {
                collected_cb.lock().unwrap().push(json);
                Ok(())
            },
        )
        .await;

        assert!(
            collected.lock().unwrap().is_empty(),
            "加载窗口内的取消必须使整批停止，不得被后续 reset 清掉"
        );
    }

    /// P1-1 症状 2：两个并发流共享同一令牌——取消 A 不得波及 B。
    ///
    /// B 先启动（慢站点 800ms），A 后启动（卡死站点），无参取消命中最近
    /// 登记的 A。修复前两者共享全局令牌：B 也被取消、不推送结果（红）；
    /// 修复后只有 A 停止，B 等自己的响应到达后正常推送 1 条结果。
    #[tokio::test]
    async fn test_cancel_current_session_does_not_cancel_concurrent_stream() {
        let _guard = lock_stream_tests().await;
        cancel_check_sources(); // 清掉上一个用例可能残留的取消

        let slow_port = spawn_delayed_http_server(
            std::time::Duration::from_millis(800),
            r#"<a href="/book/1">book</a>"#,
        );
        let hanging_port = spawn_hanging_http_server();

        let results_b = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let results_a = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));

        let cb_b = results_b.clone();
        let b_handle = tokio::spawn(run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_with_search(
                "https://b.example.com",
                "源B",
                format!("http://127.0.0.1:{slow_port}/search?q={{key}}"),
            ))],
            SEARCH_ONLY_CONFIG,
            move |json| {
                cb_b.lock().unwrap().push(json);
                Ok(())
            },
        ));

        // 等 B 的请求进入在途状态，再启动 A（A 成为最近登记的会话）
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;

        let cb_a = results_a.clone();
        let a_handle = tokio::spawn(run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_with_search(
                "https://a.example.com",
                "源A",
                format!("http://127.0.0.1:{hanging_port}/search?q={{key}}"),
            ))],
            SEARCH_ONLY_CONFIG,
            move |json| {
                cb_a.lock().unwrap().push(json);
                Ok(())
            },
        ));

        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        cancel_check_sources(); // 只应命中 A

        tokio::time::timeout(std::time::Duration::from_secs(1), a_handle)
            .await
            .expect("A 应被取消并在 1s 内结束")
            .unwrap();
        assert!(
            results_a.lock().unwrap().is_empty(),
            "被取消的 A 不得回推结果"
        );

        tokio::time::timeout(std::time::Duration::from_secs(2), b_handle)
            .await
            .expect("B 不应被 A 的取消波及")
            .unwrap();
        assert_eq!(
            results_b.lock().unwrap().len(),
            1,
            "B 应在自身响应到达后正常推送结果"
        );
    }

    /// P1-1 症状 2（反向）：新一轮的 reset 不得清掉另一会话在途的取消。
    ///
    /// B 在途时取消 B，紧接着启动 A（修复前 A 首行 reset 会清掉全局标志，
    /// B 的取消被吞、继续卡死 → 1s 超时红）。修复后 A 使用独立令牌，
    /// B 的取消保持在 B 自己的令牌上，B 在下一个 100ms 轮询点结束。
    #[tokio::test]
    async fn test_new_session_does_not_clear_other_session_cancel() {
        let _guard = lock_stream_tests().await;
        cancel_check_sources();

        let hanging_port = spawn_hanging_http_server();

        let results_b = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let cb_b = results_b.clone();
        let b_handle = tokio::spawn(run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_with_search(
                "https://b.example.com",
                "源B",
                format!("http://127.0.0.1:{hanging_port}/search?q={{key}}"),
            ))],
            SEARCH_ONLY_CONFIG,
            move |json| {
                cb_b.lock().unwrap().push(json);
                Ok(())
            },
        ));

        // 等 B 的请求在途，并跨过前两个 100ms 取消轮询点
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        cancel_check_sources(); // B 是此刻最近登记的会话

        // 立即启动 A：修复前 A 的 reset 会清掉 B 的取消
        let results_a = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let cb_a = results_a.clone();
        let a_handle = tokio::spawn(run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_no_search("https://a.example.com", "源A"))],
            "",
            move |json| {
                cb_a.lock().unwrap().push(json);
                Ok(())
            },
        ));

        tokio::time::timeout(std::time::Duration::from_secs(1), b_handle)
            .await
            .expect("B 的取消不得被 A 的启动清掉（B 应在 1s 内结束）")
            .unwrap();
        assert!(
            results_b.lock().unwrap().is_empty(),
            "被取消的 B 不得回推结果"
        );

        tokio::time::timeout(std::time::Duration::from_secs(1), a_handle)
            .await
            .expect("A 应正常完成")
            .unwrap();
        assert_eq!(results_a.lock().unwrap().len(), 1);
    }

    /// P1-1：会话结束（正常完成 / sink 关闭提前 break / 取消提前 break）
    /// 都必须从注册表清理，避免泄漏与误取消后续会话。
    #[tokio::test]
    async fn test_session_registry_cleaned_on_all_exit_paths() {
        let _guard = lock_stream_tests().await;
        assert!(active_session_ids().is_empty(), "用例开始前不应有残留会话");

        // 路径 1：正常完成
        let completed_id = {
            let session = CheckSession::start();
            let id = session.id();
            assert_eq!(active_session_ids(), vec![id]);
            run_check_sources_stream_inner(
                session,
                vec![Some(make_source_no_search("https://a.example.com", "源A"))],
                "",
                |_json| Ok(()),
            )
            .await;
            id
        };
        assert!(active_session_ids().is_empty(), "正常结束后会话应已注销");
        assert!(
            !cancel_check_sources_by_id(completed_id),
            "已结束会话不得再被取消"
        );

        // 路径 2：sink 关闭导致提前 break
        run_check_sources_stream_inner(
            CheckSession::start(),
            vec![Some(make_source_no_search("https://b.example.com", "源B"))],
            "",
            |_json| Err("sink closed".to_string()),
        )
        .await;
        assert!(active_session_ids().is_empty(), "sink 关闭后会话应已注销");

        // 路径 3：取消导致提前 break
        let cancelled_id = {
            let session = CheckSession::start();
            let id = session.id();
            let token = session.token();
            token.cancel();
            run_check_sources_stream_inner(
                session,
                vec![Some(make_source_no_search("https://c.example.com", "源C"))],
                "",
                |_json| Ok(()),
            )
            .await;
            id
        };
        assert!(active_session_ids().is_empty(), "取消结束后会话应已注销");
        assert!(!cancel_check_sources_by_id(cancelled_id));
    }

    // ─── 批量流式校验 ─────────────────────────────────────────

    /// 串行推送：顺序、进度字段与 is_last 标记
    #[tokio::test]
    async fn test_check_sources_stream_order_and_progress() {
        let _guard = lock_stream_tests().await;
        let sources = vec![
            Some(make_source_no_search("https://a.example.com", "源A")),
            Some(make_source_no_search("https://b.example.com", "源B")),
            Some(make_source_no_search("https://c.example.com", "源C")),
        ];

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();

        run_check_sources_stream_inner(CheckSession::start(), sources, "", move |json| {
            collected_cb.lock().unwrap().push(json);
            Ok(())
        })
        .await;

        let items = collected.lock().unwrap();
        assert_eq!(items.len(), 3, "应推送 3 条进度");

        for (i, json) in items.iter().enumerate() {
            let progress: CheckProgress = serde_json::from_str(json).unwrap();
            assert_eq!(progress.index, i, "推送顺序应与请求顺序一致");
            assert_eq!(progress.total, 3);
            assert_eq!(progress.is_last, i == 2);
            assert!(!progress.result.search_ok);
        }
        assert_eq!(items.len(), 3);
        let first: CheckProgress = serde_json::from_str(&items[0]).unwrap();
        assert_eq!(first.source_name, "源A");
    }

    /// 不存在的书源（None 占位）推送失败结果而非跳过，保持序号连续
    #[tokio::test]
    async fn test_check_sources_stream_missing_source() {
        let _guard = lock_stream_tests().await;
        let sources = vec![
            Some(make_source_no_search("https://a.example.com", "源A")),
            None,
        ];

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();

        run_check_sources_stream_inner(CheckSession::start(), sources, "", move |json| {
            collected_cb.lock().unwrap().push(json);
            Ok(())
        })
        .await;

        let items = collected.lock().unwrap();
        assert_eq!(items.len(), 2);
        let missing: CheckProgress = serde_json::from_str(&items[1]).unwrap();
        assert_eq!(missing.index, 1);
        assert!(missing.is_last);
        assert!(missing.result.search_error.unwrap().contains("书源不存在"));
    }

    /// sink 关闭（回调返回 Err）时应提前终止
    #[tokio::test]
    async fn test_check_sources_stream_sink_closed() {
        let _guard = lock_stream_tests().await;
        let sources = vec![
            Some(make_source_no_search("https://a.example.com", "源A")),
            Some(make_source_no_search("https://b.example.com", "源B")),
            Some(make_source_no_search("https://c.example.com", "源C")),
        ];

        let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count_cb = count.clone();

        run_check_sources_stream_inner(CheckSession::start(), sources, "", move |_json| {
            count_cb.fetch_add(1, Ordering::SeqCst);
            Err("sink closed".to_string())
        })
        .await;

        assert_eq!(count.load(Ordering::SeqCst), 1, "sink 关闭后应立即终止");
    }

    /// 空列表：不推送任何进度
    #[tokio::test]
    async fn test_check_sources_stream_empty() {
        let _guard = lock_stream_tests().await;
        let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count_cb = count.clone();
        run_check_sources_stream_inner(CheckSession::start(), Vec::new(), "", move |_json| {
            count_cb.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .await;
        assert_eq!(count.load(Ordering::SeqCst), 0);
    }

    /// 取消标志：校验过程中置位后不再推送后续结果
    #[tokio::test]
    async fn test_check_sources_stream_cancel() {
        let _guard = lock_stream_tests().await;
        let sources = vec![
            Some(make_source_no_search("https://a.example.com", "源A")),
            Some(make_source_no_search("https://b.example.com", "源B")),
            Some(make_source_no_search("https://c.example.com", "源C")),
        ];

        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let collected_cb = collected.clone();

        // 第一条回调中触发取消，后续书源不应再推送
        run_check_sources_stream_inner(CheckSession::start(), sources, "", move |json| {
            collected_cb.lock().unwrap().push(json);
            cancel_check_sources();
            Ok(())
        })
        .await;

        assert_eq!(collected.lock().unwrap().len(), 1, "取消后应停止推送");
    }

    /// URL 列表解析失败应报错
    #[test]
    fn test_load_check_sources_invalid_json() {
        assert!(load_check_sources("{bad").is_err());
    }

    /// CheckProgress 序列化字段契约（snake_case）
    #[test]
    fn test_check_progress_serialize_contract() {
        let progress = CheckProgress {
            index: 0,
            total: 2,
            is_last: false,
            source_name: "测试源".to_string(),
            result: CheckResult {
                source_url: "https://example.com".to_string(),
                search_ok: true,
                toc_ok: true,
                content_ok: false,
                search_error: None,
                toc_error: None,
                content_error: Some("skipped: toc failed".to_string()),
                total_time_ms: 100,
                captcha: None,
                redirect: None,
                cancelled: false,
                invalid_groups: vec!["搜索失效".to_string()],
            },
        };
        let json = serde_json::to_string(&progress).unwrap();
        for field in [
            "\"index\"",
            "\"total\"",
            "\"is_last\"",
            "\"source_name\"",
            "\"result\"",
            "\"search_ok\"",
            "\"toc_ok\"",
            "\"content_ok\"",
            "\"total_time_ms\"",
            "\"cancelled\"",
            "\"invalid_groups\"",
        ] {
            assert!(json.contains(field), "缺少字段 {field}: {json}");
        }
        assert!(
            json.contains("\"invalid_groups\":[\"搜索失效\"]"),
            "invalid_groups 应以数组形式序列化: {json}"
        );
    }

    // ─── 批44：失效分组写回（参考版语义 + 定向两列 CAS） ─────────

    /// 校验失败 → 追加具体分组 + `// Error:` 注释
    #[test]
    fn test_write_back_appends_groups_and_comment_on_failure() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-fail.example.com";
        let mut source = make_source_no_search(url, "写回失败源");
        source.book_source_group = Some("玄幻".to_string());
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string()],
            failure: Some("搜索失效".to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("玄幻,搜索失效"),
            "失败应追加具体分组"
        );
        assert_eq!(
            stored.book_source_comment.as_deref(),
            Some("// Error: 搜索失效"),
            "失败应写入本次错误注释"
        );
    }

    /// 失败写回是「先清旧失效分组再追加本次」，不是历史累积
    /// （对齐原版 `doCheckSource` 起始 `removeInvalidGroups()`）
    #[test]
    fn test_write_back_replaces_previous_invalid_groups_on_failure() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-replace.example.com";
        let mut source = make_source_no_search(url, "替换分组源");
        source.book_source_group = Some("玄幻,发现失效,网站失效".to_string());
        source.book_source_comment = Some("// Error: 上一轮错误".to_string());
        source.last_update_time = 150;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string()],
            failure: Some("搜索失效".to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("玄幻,搜索失效"),
            "旧失效分组（发现失效/网站失效）应被清掉，只留本轮判定"
        );
        assert_eq!(
            stored.book_source_comment.as_deref(),
            Some("// Error: 搜索失效"),
            "历史错误注释应被替换为本轮消息"
        );
    }

    /// `w_source_comment=false` → 不写 `// Error:` 注释，但分组照常写回
    #[test]
    fn test_write_back_without_comment_when_disabled() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-nocomment.example.com";
        let mut source = make_source_no_search(url, "无注释源");
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["域名失效".to_string()],
            failure: Some("源地址不可访问".to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &outcome, false);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(stored.book_source_group.as_deref(), Some("域名失效"));
        assert_eq!(
            stored.book_source_comment, None,
            "w_source_comment=false 时不得写错误注释"
        );
    }

    /// 校验成功 → 清除旧失效分组与历史 `// Error:` 块
    #[test]
    fn test_write_back_clears_invalid_groups_on_success() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-ok.example.com";
        let mut source = make_source_no_search(url, "写回成功源");
        source.book_source_group = Some("玄幻,搜索失效,校验超时".to_string());
        source.book_source_comment = Some("// Error: 旧错误\n\n正常注释".to_string());
        source.last_update_time = 200;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome::default();
        write_back_check_groups(&source, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("玄幻"),
            "成功应只保留正常分组"
        );
        assert_eq!(
            stored.book_source_comment.as_deref(),
            Some("正常注释"),
            "成功应清除历史错误块、保留正常注释"
        );
    }

    /// 并发安全：校验期间源被编辑（lastUpdateTime 变化）→ 不写回
    #[test]
    fn test_write_back_skipped_when_source_edited_during_check() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-cas.example.com";
        let mut snapshot = make_source_no_search(url, "CAS 源");
        snapshot.book_source_group = Some("玄幻".to_string());
        snapshot.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&snapshot)
        })
        .unwrap();

        // 模拟校验期间另一会话编辑了源（lastUpdateTime 推进 + 分组被改）
        let mut edited = snapshot.clone();
        edited.last_update_time = 300;
        edited.book_source_group = Some("都市".to_string());
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&edited)
        })
        .unwrap();

        // 用旧快照写回：CAS 应拒绝
        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string()],
            failure: Some("搜索失效".to_string()),
            ..Default::default()
        };
        write_back_check_groups(&snapshot, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("都市"),
            "快照过期不得覆盖并发编辑"
        );
        assert_eq!(stored.book_source_comment, None);
    }

    /// 取消态不写回分组/注释
    #[test]
    fn test_write_back_skipped_when_cancelled() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-cancel.example.com";
        let mut source = make_source_no_search(url, "取消源");
        source.book_source_group = Some("玄幻".to_string());
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            cancelled: true,
            search_error: Some("cancelled".to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(stored.book_source_group.as_deref(), Some("玄幻"));
        assert_eq!(stored.book_source_comment, None);
    }

    // ─── 批39 审查 P1-2：域外分组（发现规则为空）不得落库 ─────────────

    /// 失败判定为 `发现规则为空` → 分组串**不含**该值，但错误消息仍保留
    ///
    /// 根因：`is_invalid_group` 只认「含『失效』」或「== 校验超时」，
    /// `发现规则为空` 两条都不满足 → 一旦落库，后续任何成功校验的
    /// `remove_invalid_groups` 都清不掉它（永久残留）。原版
    /// `CheckSourceService` 也只把它当 `NoStackTraceException` 消息。
    #[test]
    fn test_write_back_does_not_persist_discovery_rule_empty_group() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-discovery-empty.example.com";
        let mut source = make_source_no_search(url, "发现规则为空源");
        source.book_source_group = Some("玄幻".to_string());
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            invalid_groups: vec![
                legado_fetcher::source_check::GROUP_DISCOVERY_RULE_EMPTY.to_string()
            ],
            failure: Some(legado_fetcher::source_check::GROUP_DISCOVERY_RULE_EMPTY.to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &outcome, true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        let group = stored.book_source_group.as_deref().unwrap_or("");
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("玄幻"),
            "「发现规则为空」不得写入分组，实际: {group}"
        );
        assert!(
            !group.contains("发现规则为空"),
            "分组串不得含域外判定，实际: {group}"
        );
        assert_eq!(
            stored.book_source_comment.as_deref(),
            Some("// Error: 发现规则为空"),
            "该判定应作为错误消息呈现"
        );
    }

    /// **失败 → 成功幂等回归**：`发现规则为空` 失败后，成功校验必须把分组清干净
    ///
    /// 现有 `test_write_back_clears_invalid_groups_on_success` 用「搜索失效」
    /// （域内值）覆盖不到本路径；此处断言写集/清集一致。
    #[test]
    fn test_write_back_discovery_rule_empty_then_success_leaves_group_clean() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-discovery-empty-idem.example.com";
        let mut source = make_source_no_search(url, "发现规则为空幂等源");
        source.book_source_group = Some("玄幻".to_string());
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        // 第一轮：失败（发现规则为空）
        let failed = SourceCheckOutcome {
            invalid_groups: vec![
                legado_fetcher::source_check::GROUP_DISCOVERY_RULE_EMPTY.to_string()
            ],
            failure: Some(legado_fetcher::source_check::GROUP_DISCOVERY_RULE_EMPTY.to_string()),
            ..Default::default()
        };
        write_back_check_groups(&source, &failed, true);
        let after_fail = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            after_fail.book_source_group.as_deref(),
            Some("玄幻"),
            "失败后分组仍应干净"
        );

        // 第二轮：成功（用第一轮后的库内快照，模拟下次校验读到最新值）
        write_back_check_groups(&after_fail, &SourceCheckOutcome::default(), true);
        let after_ok = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            after_ok.book_source_group.as_deref(),
            Some("玄幻"),
            "成功校验后分组必须干净（幂等）"
        );
        assert!(
            after_ok
                .book_source_comment
                .as_deref()
                .is_none_or(|c| c.trim().is_empty()),
            "成功校验应清掉 // Error: 块（对齐原版 joinToString 空串语义），实际: {:?}",
            after_ok.book_source_comment
        );
    }

    /// 存量修复：历史版本误写入分组的 `发现规则为空` 会被成功校验清掉
    ///
    /// 幂等性：即便库内残留该值（旧版本写的），成功校验也必须剔除。
    #[test]
    fn test_write_back_clears_legacy_discovery_rule_empty_group() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://write-back-discovery-empty-legacy.example.com";
        let mut source = make_source_no_search(url, "存量域外分组源");
        // 模拟旧版本误写入的域外分组
        source.book_source_group = Some("玄幻,发现规则为空,搜索失效".to_string());
        source.book_source_comment = Some("// Error: 发现规则为空\n\n正常注释".to_string());
        source.last_update_time = 100;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        write_back_check_groups(&source, &SourceCheckOutcome::default(), true);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.book_source_group.as_deref(),
            Some("玄幻"),
            "存量域外分组 + 旧失效分组都应被清掉"
        );
        assert_eq!(
            stored.book_source_comment.as_deref(),
            Some("正常注释"),
            "历史 // Error: 块应清除、正常注释保留"
        );
    }

    // ─── [B13] 校验耗时写回 respondTime ─────────────────────────────

    /// 失败 → `timeout_ms + 实测耗时`（对齐原版 Debug.getRespondTime）
    #[test]
    fn test_write_back_respond_time_on_failure_adds_timeout_base() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://b13-respond-fail.example.com";
        let source = make_source_no_search(url, "响应时间失败源");
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            invalid_groups: vec!["搜索失效".to_string()],
            failure: Some("搜索失效".to_string()),
            ..Default::default()
        };
        let config = SourceCheckConfig {
            timeout_ms: 5000,
            ..Default::default()
        };
        write_back_respond_time(&source, &outcome, &config, 1234);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            stored.respond_time, 6234,
            "失败应叠加超时基数（5000 + 1234）"
        );

        crate::db_state::with_database(|db| BookSourceRepository::new(db.connection()).delete(url))
            .unwrap();
    }

    /// 成功 → 实测耗时（不加超时基数）
    #[test]
    fn test_write_back_respond_time_on_success_uses_elapsed() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://b13-respond-ok.example.com";
        let source = make_source_no_search(url, "响应时间成功源");
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let config = SourceCheckConfig {
            timeout_ms: 5000,
            ..Default::default()
        };
        write_back_respond_time(&source, &SourceCheckOutcome::default(), &config, 777);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(stored.respond_time, 777, "成功只写实测耗时");

        crate::db_state::with_database(|db| BookSourceRepository::new(db.connection()).delete(url))
            .unwrap();
    }

    /// 取消 → 不写（取消不计为源性能）
    #[test]
    fn test_write_back_respond_time_skipped_when_cancelled() {
        let _db = crate::db_state::ensure_test_db();
        let url = "https://b13-respond-cancel.example.com";
        let mut source = make_source_no_search(url, "响应时间取消源");
        source.respond_time = 999;
        crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&source)
        })
        .unwrap();

        let outcome = SourceCheckOutcome {
            cancelled: true,
            ..Default::default()
        };
        write_back_respond_time(&source, &outcome, &SourceCheckConfig::default(), 5000);

        let stored = crate::db_state::with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(stored.respond_time, 999, "取消态不得改动 respondTime");

        crate::db_state::with_database(|db| BookSourceRepository::new(db.connection()).delete(url))
            .unwrap();
    }
}
