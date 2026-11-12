//! 原版书源检验状态与检验会话端点（批30，4 条）
//!
//! 原版依据（upstream）：
//!
//! | 端点 | 原版实现 | 令牌 | 备注 |
//! |---|---|---|---|
//! | GET `/getBookSourcesForManagement?urls=` | `BookSourceCheckController.sources`（:22-43） | **有**（受保护读面，原版 `PROTECTED_HTTP_LOG_READ_ROUTES`；handler 前置校验 + `no-store`） | 返回 `{sources, states}`；`urls` 为 JSON 字符串数组，缺省全量；坏 JSON →「书源地址参数无效」 |
//! | GET `/getBookSourceCheckStates` | `BookSourceCheckController.states`（:15-20） | **有**（同受保护读面） | 返回 `{states, sessionToken}`（无进行中会话时 `sessionToken: null`） |
//! | POST `/startBookSourceCheck` | `BookSourceCheckController.start`（:48-85） | **有**（`PROTECTED_SOURCE_WRITE_ROUTES`） | 请求 `{sources:[BookSource], keyword}`；返回 `{sessionToken, sourceRevisions}`；校验提交源与库内 `checkContent()` 一致；单会话 |
//! | POST `/stopBookSourceCheck` | `BookSourceCheckController.stop`（:87-96） | **有** | 请求 `{sessionToken}`；会话不匹配 →「检验会话已结束或已更换」；成功 `data=""` |
//!
//! 令牌实现选择（审查批 P1-2）：两条 GET 在 handler 内用与
//! [`super::source_api::get_http_logs`] 同款
//! `load_js_source_api_config(...).has_valid_token(&headers)` 前置，而不是
//! 新增路由级中间件——GET 无请求体，不存在「未授权先读 body」的放大面；
//! 与既有受保护读端点保持同一实现，`create_router` 单测也无须额外挂载守卫。
//! `Cache-Control: no-store` 由 `web_assets::with_api_headers` 按路径追加。
//!
//! 状态机（对齐 `BookSourceCheckState.kt` / `BookSourceDao.kt` / `CheckSourceService.kt`）：
//! 1. 书源保存（新增/规则变更）→ 状态重建为 `NEEDS_CHECK`，生成新
//!    `revision` + `sourceRevision`；仅改启用/排序等不影响规则的字段时保留状态
//!    （见 [`legado_db::BookSourceRepository::insert_with_check_state`] /
//!    [`legado_db::BookSourceRepository::update_with_check_state`]）；
//! 2. `start`：校验提交源与库内内容一致后，单会话排队，逐源把状态重置为
//!    `NEEDS_CHECK`（新 `revision`、保留 `sourceRevision`），服务端后台
//!    **有界并发**检验（批42，见登记差异 2）；
//! 3. 每源完成：`finish_check` 以 `(url, revision, status='NEEDS_CHECK')` CAS
//!    写回 `PASSED`/`FAILED`/`UNCHECKABLE` + `detail` + `checkedAt`，并更新
//!    `book_sources.respondTime`；
//! 4. `stop`：取消并中止后台任务；未完成源保持 `NEEDS_CHECK`（与原版停止语义一致）。
//!
//! 前端消费（`modules/web/src` 新构建产物已内嵌）：
//! - 列表页打开 → `getBookSourcesForManagement` 取全量源 + 状态；
//! - `SourceCheckControls` 每 3 秒轮询 `getBookSourceCheckStates`；
//! - 检验按钮 → `startBookSourceCheck`；停止 → `stopBookSourceCheck`；
//! - 状态展示由前端把「本地内容快照」与 `state.sourceRevision` 比对后决定
//!   （`utils/sourceCheckState.js`），服务端只需保证 revision 语义正确。
//!
//! 登记差异（不改变网页端可见语义者优先说明）：
//! 1. **发现页检验（批42 已接入）**：`exploreUrl` 非空时取首个可用分类 URL，
//!    经 `legado-fetcher` 的发现链（AnalyzeUrl + `ruleExplore.bookList`，空则
//!    回退 `ruleSearch.bookList`）抓取首个书籍，再跑详情/目录/正文。失败口径：
//!    - 无可用分类（仅分组标题/空 URL）→ 失效分组「发现规则为空」；
//!    - `@js:` / `<js>` / 损坏分类 JSON 求值异常 → FAILED「发现规则求值失败: …」；
//!    - 请求/解析异常 → FAILED「发现页请求失败: …」；
//!    - 请求成功但列表与详情页都解析不出书 → 失效分组「发现失效」；
//!    - 发现书的目录/正文为空 → 失效分组「发现目录失效 / 发现正文失效」
//!      （搜索书对应「搜索目录失效 / 搜索正文失效」，对齐原版 `checkBook`）。
//!
//!    **非 quickjs 边界（批42b P3-7）**：未启用 quickjs 的构建只缺「JS 求值」
//!    能力——纯文本 `分类::URL` 与 JSON 分类数组仍正常解析，仅 `@js:` / `<js>`
//!    的 exploreUrl 无法求值。此时跳过发现项并按能力缺口登记（warn + stderr，
//!    不判 FAILED），不把 `Unavailable` 计入失效分组。
//!
//!    发现链是 `legado-fetcher` 新增的检验专用入口，ffi 旧 `explore_api` 仍
//!    保留自有 exploreKinds 实现（`[收敛项 B42-C1]`，见 `webbook_explore_first_book`
//!    与 `legado-ffi/src/api/explore_api.rs` 同名标记；后续批次收敛到单一入口）；
//! 2. **并发模型（批42）**：原版按 `AppConfig.threadCount`（默认 32）并行；本实现
//!    有界并发：缺省 CPU 核数夹逼 4~8，可经 caches `config:checkThreadCount`
//!    覆盖（硬上限 32）。单会话、停止（AbortHandle + JoinSet 连带取消在途工作
//!    线程）、CAS 写回语义不变；DB 写经 `AppState.db` 互斥锁串行；
//! 3. **校验配置来源**：原版读 SharedPreferences（`CheckSource.timeout` 等）；
//!    Rust 侧无对应 UI，改读 caches 表 `config:checkSourceTimeout` /
//!    `config:wSourceComment` / `config:checkDomain` / `config:checkSearch` /
//!    `config:checkDiscovery` / `config:checkInfo` / `config:checkCategory` /
//!    `config:checkContent` / `config:checkThreadCount`，缺键取原版默认值
//!    （180s / true / false / 五个 true / CPU 夹逼 4~8）；
//! 4. **调试通道互斥**：原版 `Debug.tryStartCheckSession` 与书源/RSS 调试共用
//!    通道；Rust 侧 WS 调试会话独立，本实现只保证「检验单会话」，
//!    不能阻止同时发起 WS 调试（登记）；
//! 5. `getBookSourcesForManagement` 的 `sources` 顺序按 `customOrder` 升序、
//!    `states` 按 `bookSourceUrl` 升序（原版无显式排序，属稳定化增强）；
//! 6. 不重建 `book_sources_part` 视图（Rust 无消费方，见 `schema.rs` v115 注）；
//! 7. **失败分组细节**：原版按失败类型维护「域名失效/js失效/网站失效/校验超时/
//!    搜索失效/发现失效…」等分组并拼进 `detail` 首段；本实现保留「域名失效/
//!    搜索失效/发现规则为空/发现失效/{搜索,发现}目录失效/{搜索,发现}正文失效」
//!    与超时/错误消息，网络/JS 类失败仍以消息形式呈现（原版分组只用于 detail
//!    组合、不落库），故这类 detail 会比原版少「网站失效/js失效」分组前缀。
//!    批42b P2-2：硬失败早退也携带**此前已累计**的失效分组（如搜索已判
//!    「搜索失效」后，发现规则求值又抛错），detail 首段不再丢失已判分组；
//! 8. **源地址可访问性（批42 已接入）**：`checkDomain=true` 时对源地址做 TCP
//!    探测（整体 1.6s 上限，单地址 500ms 子超时，批42b P3-5），对齐原版
//!    `isDomainReachable`（withTimeout 2000 / connect 1600）；不可达 → 失效
//!    分组「域名失效」+ FAILED「源地址不可访问」；非 http(s) → UNCHECKABLE。
//!    默认 `checkDomain=false` 与原版一致；
//! 9. **并行检验的流程变量作用域风险（登记项 B42-C2）**：`legado-fetcher` 的
//!    流程会话变量（`begin_book_flow` → `legado_js` 单槽 `FLOW_SCOPE`）是
//!    进程级单槽，多源并行时**不只会按空值降级**：A 源 `@put` 前后若 B 源
//!    切换了 scope，A 写入的会话变量会落进 B 的 `lgflow::{scope}` 命名空间，
//!    B 后续 `@get` 可读到 A 的值（跨源串读）；同理 B 的 `@put` 也会覆盖 A
//!    已写值。并行度 >1 且存在 ≥2 个使用 `@put`/`@get`/`java.put`/`java.get`
//!    的源时，`run_check_session` 输出一次可观测 warn（tracing + stderr）。
//!    彻底消除需把 variable_store 改为 task-local（跨宿主改动，登记项
//!    B42-C2 留待裁决）。

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;
use serde_json::{json, Value};

use legado_core::explore::parse_explore_url;
use legado_core::models::book_source_check_state::check_status;
use legado_core::models::book_source_type;
use legado_core::models::{BookSource, BookSourceCheckState};
use legado_core::web_book::{WebBookInfo, WebChapter, WebSearchResult};
use legado_db::connection::in_transaction;
use legado_db::repository::book_source_check_state_repository::{
    BookSourceCheckStateRepository, BOOK_SOURCE_QUERY_CHUNK_SIZE,
};
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;

use super::source_api::load_js_source_api_config;
use super::source_api::token_error_response;
use super::{origin_of, to_response, ReturnData};
use crate::handlers::web_book::server_deps;
use crate::state::AppState;

/// caches 表校验配置键（对齐原版 `CheckSource` 的 CacheManager 键名，
/// 仅加 `config:` 前缀与本轨设置约定一致）
const CONFIG_CHECK_TIMEOUT: &str = "config:checkSourceTimeout";
const CONFIG_W_SOURCE_COMMENT: &str = "config:wSourceComment";
const CONFIG_CHECK_DOMAIN: &str = "config:checkDomain";
const CONFIG_CHECK_SEARCH: &str = "config:checkSearch";
const CONFIG_CHECK_DISCOVERY: &str = "config:checkDiscovery";
const CONFIG_CHECK_INFO: &str = "config:checkInfo";
const CONFIG_CHECK_CATEGORY: &str = "config:checkCategory";
const CONFIG_CHECK_CONTENT: &str = "config:checkContent";
/// 并行检验线程数（对齐原版 `AppConfig.threadCount` 的配置面；缺省按 CPU）
const CONFIG_CHECK_THREAD_COUNT: &str = "config:checkThreadCount";

/// 校验超时上限（毫秒）：防 caches 被写入超大值导致单源长期占用
const MAX_CHECK_TIMEOUT_MS: u64 = 600_000;

/// 并行检验默认并发下限 / 上限（按 CPU 数取夹逼，任务口径 4~8）
const CHECK_CONCURRENCY_MIN: usize = 4;
const CHECK_CONCURRENCY_MAX: usize = 8;
/// 配置显式覆盖的硬上限（防 caches 写入超大值打爆连接池/线程）
const CHECK_CONCURRENCY_HARD_MAX: usize = 32;

/// 源地址 TCP 探测总超时（对齐原版 `isDomainReachable`：withTimeout 2000 /
/// connect 1600）
const DOMAIN_PROBE_TIMEOUT: Duration = Duration::from_millis(1_600);
/// 单地址连接子超时（批42b P3-5）：多 A/AAAA 记录不得让首个慢地址吃掉
/// 全部预算，按 500ms/地址逐个尝试，整体仍受 [`DOMAIN_PROBE_TIMEOUT`] 约束
const DOMAIN_PROBE_PER_ADDRESS_TIMEOUT: Duration = Duration::from_millis(500);

/// 默认并发数：CPU 核数夹逼到 4~8（原版默认 `threadCount=32`，本批按任务
/// 口径收敛；显式配置经 `config:checkThreadCount` 覆盖）
fn default_check_concurrency() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(CHECK_CONCURRENCY_MIN)
        .clamp(CHECK_CONCURRENCY_MIN, CHECK_CONCURRENCY_MAX)
}

/// 规范化并发数：显式配置夹逼到 1~32，非法回落默认
fn normalize_check_concurrency(configured: Option<usize>) -> usize {
    configured
        .filter(|n| *n > 0)
        .map(|n| n.min(CHECK_CONCURRENCY_HARD_MAX))
        .unwrap_or_else(default_check_concurrency)
}

/// 检验配置（`CheckSource` 对象字段的 Rust 对应物）
#[derive(Debug, Clone)]
pub struct CheckConfig {
    /// 单源超时（毫秒）
    pub timeout_ms: u64,
    /// 失败详情是否附书源注释里的 `// Error:` 首行
    pub w_source_comment: bool,
    /// 是否校验源地址可访问性（默认关，对齐原版）
    pub check_domain: bool,
    /// 是否校验搜索
    pub check_search: bool,
    /// 是否校验发现（批42 接入；`@js:`/`<js>` 规则依赖 quickjs，非 quickjs
    /// 构建按能力缺口跳过该源发现项，见模块登记 1 的边界说明）
    pub check_discovery: bool,
    /// 是否校验详情
    pub check_info: bool,
    /// 是否校验目录
    pub check_category: bool,
    /// 是否校验正文
    pub check_content: bool,
    /// 并行检验并发数（对齐原版 `AppConfig.threadCount`，本批夹逼 4~8/配置）
    pub concurrency: usize,
    /// 搜索关键词（默认「我的」，请求 keyword 非空时覆盖）
    pub keyword: String,
}

impl Default for CheckConfig {
    fn default() -> Self {
        Self {
            timeout_ms: 180_000,
            w_source_comment: true,
            check_domain: false,
            check_search: true,
            check_discovery: true,
            check_info: true,
            check_category: true,
            check_content: true,
            concurrency: default_check_concurrency(),
            keyword: "我的".to_string(),
        }
    }
}

fn parse_bool(raw: Option<String>, default: bool) -> bool {
    match raw.as_deref().map(str::trim) {
        Some("true") | Some("1") => true,
        Some("false") | Some("0") => false,
        _ => default,
    }
}

/// 从 caches 表读取校验配置（缺键取原版默认值）
async fn load_check_config(state: &Arc<AppState>) -> CheckConfig {
    let defaults = CheckConfig::default();
    let db = state.db.lock().await;
    let repo = CacheRepository::new(db.connection());
    let get = |key: &str| repo.get(key).ok().flatten();
    let timeout_ms = get(CONFIG_CHECK_TIMEOUT)
        .and_then(|v| v.trim().parse::<u64>().ok())
        .map(|v| v.clamp(1_000, MAX_CHECK_TIMEOUT_MS))
        .unwrap_or(defaults.timeout_ms);
    CheckConfig {
        timeout_ms,
        w_source_comment: parse_bool(get(CONFIG_W_SOURCE_COMMENT), defaults.w_source_comment),
        check_domain: parse_bool(get(CONFIG_CHECK_DOMAIN), defaults.check_domain),
        check_search: parse_bool(get(CONFIG_CHECK_SEARCH), defaults.check_search),
        check_discovery: parse_bool(get(CONFIG_CHECK_DISCOVERY), defaults.check_discovery),
        check_info: parse_bool(get(CONFIG_CHECK_INFO), defaults.check_info),
        check_category: parse_bool(get(CONFIG_CHECK_CATEGORY), defaults.check_category),
        check_content: parse_bool(get(CONFIG_CHECK_CONTENT), defaults.check_content),
        concurrency: normalize_check_concurrency(
            get(CONFIG_CHECK_THREAD_COUNT).and_then(|v| v.trim().parse::<usize>().ok()),
        ),
        keyword: defaults.keyword,
    }
}

// ─── 检验会话管理（对齐原版 Debug.check session 单例） ─────────────────────

struct ActiveCheck {
    token: String,
    cancel: Arc<AtomicBool>,
    abort: Option<tokio::task::AbortHandle>,
}

/// 进程内检验会话管理器：同一时刻最多一个检验会话（原版 `Debug.isChecking`）
pub struct SourceCheckManager {
    inner: StdMutex<Option<ActiveCheck>>,
    /// 粘滞搜索关键词（对齐原版全局 `CheckSource.keyword`，初始「我的」）：
    /// 请求带非空白 keyword 时更新，缺省时沿用上次值（P3-4）
    keyword: StdMutex<String>,
    process_token: String,
    next_session_id: AtomicU64,
}

impl Default for SourceCheckManager {
    fn default() -> Self {
        Self {
            inner: StdMutex::new(None),
            keyword: StdMutex::new("我的".to_string()),
            process_token: uuid::Uuid::new_v4().to_string(),
            next_session_id: AtomicU64::new(0),
        }
    }
}

impl SourceCheckManager {
    fn lock(&self) -> std::sync::MutexGuard<'_, Option<ActiveCheck>> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn keyword_lock(&self) -> std::sync::MutexGuard<'_, String> {
        self.keyword.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// 当前粘滞关键词（`startBookSourceCheck` 缺省 keyword 时使用）
    pub fn keyword(&self) -> String {
        self.keyword_lock().clone()
    }

    /// 更新粘滞关键词（调用方负责 trim 与空白判定，对齐
    /// `BookSourceCheckController.start` 的 `takeIf { it.isNotEmpty() }`）
    pub fn set_keyword(&self, keyword: &str) {
        *self.keyword_lock() = keyword.to_string();
    }

    /// 当前进行中的会话令牌（`None` = 无检验）
    pub fn current_token(&self) -> Option<String> {
        self.lock().as_ref().map(|active| active.token.clone())
    }

    /// 尝试开始会话；已有会话返回 `None`（对齐 `Debug.tryStartCheckSession`）
    fn try_start(&self) -> Option<(String, Arc<AtomicBool>)> {
        let mut guard = self.lock();
        if guard.is_some() {
            return None;
        }
        let session_id = self.next_session_id.fetch_add(1, Ordering::SeqCst) + 1;
        let token = format!("{}:{}", self.process_token, session_id);
        let cancel = Arc::new(AtomicBool::new(false));
        *guard = Some(ActiveCheck {
            token: token.clone(),
            cancel: Arc::clone(&cancel),
            abort: None,
        });
        Some((token, cancel))
    }

    fn attach_abort(&self, token: &str, abort: tokio::task::AbortHandle) {
        if let Some(active) = self.lock().as_mut() {
            if active.token == token {
                active.abort = Some(abort);
            }
        }
    }

    /// 会话自然结束：仅当令牌匹配时清理
    fn finish(&self, token: &str) {
        let mut guard = self.lock();
        if guard.as_ref().is_some_and(|active| active.token == token) {
            *guard = None;
        }
    }

    /// 停止指定会话（令牌不匹配返回 false）
    fn stop(&self, token: &str) -> bool {
        let mut guard = self.lock();
        let Some(active) = guard.as_mut() else {
            return false;
        };
        if active.token != token {
            return false;
        }
        active.cancel.store(true, Ordering::SeqCst);
        if let Some(abort) = active.abort.take() {
            abort.abort();
        }
        *guard = None;
        true
    }

    /// 会话是否已被停止（令牌失效也视为停止）
    fn is_cancelled(&self, token: &str) -> bool {
        match self.lock().as_ref() {
            Some(active) if active.token == token => active.cancel.load(Ordering::SeqCst),
            _ => true,
        }
    }
}

// ─── 端点实现 ───────────────────────────────────────────────────────────────

fn post_data(body: &Bytes) -> Option<String> {
    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// GET `/getBookSourcesForManagement?urls=`（BookSourceCheckController.sources）
///
/// 令牌（审查批 P1-2）：原版 `HttpServer.kt:266-271` 把本端点纳入
/// `PROTECTED_HTTP_LOG_READ_ROUTES`，与 [`super::source_api::get_http_logs`]
/// 同一判定；响应含完整 `Vec<BookSource>`（`variable` 为登录态），必须
/// 前置校验后才查库。`no-store` 见 `web_assets::with_api_headers`。
pub async fn get_book_sources_for_management(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSourcesForManagement";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let urls = match params.get("urls") {
        None => None,
        Some(raw) => match serde_json::from_str::<Vec<String>>(raw) {
            Ok(urls) => {
                let mut seen = HashSet::new();
                Some(
                    urls.into_iter()
                        .filter(|url| seen.insert(url.clone()))
                        .collect::<Vec<_>>(),
                )
            }
            Err(_) => {
                return to_response(
                    &ReturnData::error("书源地址参数无效"),
                    uri,
                    origin.as_deref(),
                )
            }
        },
    };

    let rd = {
        let db = state.db.lock().await;
        let source_repo = BookSourceRepository::new(db.connection());
        let state_repo = BookSourceCheckStateRepository::new(db.connection());
        let (sources, states): (Vec<BookSource>, Vec<BookSourceCheckState>) = match &urls {
            // 批30b P2-2：全量分支原 `unwrap_or_default()` 会把查询失败吞成空
            // 列表（前端表现为「没有书源」）；与 urls 分支一致返回错误信封。
            None => {
                let sources = match source_repo.find_all() {
                    Ok(rows) => rows,
                    Err(e) => {
                        return to_response(
                            &ReturnData::error(e.to_string()),
                            uri,
                            origin.as_deref(),
                        )
                    }
                };
                let states = match state_repo.find_all() {
                    Ok(rows) => rows,
                    Err(e) => {
                        return to_response(
                            &ReturnData::error(e.to_string()),
                            uri,
                            origin.as_deref(),
                        )
                    }
                };
                (sources, states)
            }
            Some(urls) => {
                let mut sources = Vec::new();
                for chunk in urls.chunks(BOOK_SOURCE_QUERY_CHUNK_SIZE) {
                    match source_repo.find_by_urls(chunk) {
                        Ok(rows) => sources.extend(rows),
                        Err(e) => {
                            return to_response(
                                &ReturnData::error(e.to_string()),
                                uri,
                                origin.as_deref(),
                            )
                        }
                    }
                }
                let existing: HashSet<&str> =
                    sources.iter().map(|s| s.book_source_url.as_str()).collect();
                let mut states = Vec::new();
                for chunk in urls.chunks(BOOK_SOURCE_QUERY_CHUNK_SIZE) {
                    match state_repo.find_by_urls(chunk) {
                        Ok(rows) => states.extend(
                            rows.into_iter()
                                .filter(|s| existing.contains(s.book_source_url.as_str())),
                        ),
                        Err(e) => {
                            return to_response(
                                &ReturnData::error(e.to_string()),
                                uri,
                                origin.as_deref(),
                            )
                        }
                    }
                }
                (sources, states)
            }
        };
        match serde_json::to_value(json!({
            "sources": sources,
            "states": states,
        })) {
            Ok(value) => ReturnData::success(value),
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

/// GET `/getBookSourceCheckStates`（BookSourceCheckController.states）
///
/// 令牌（审查批 P1-2）：同 [`get_book_sources_for_management`]——原版
/// `PROTECTED_HTTP_LOG_READ_ROUTES` 成员；响应含 `sessionToken` 与状态详情，
/// 未鉴权客户端不得轮询。
pub async fn get_book_source_check_states(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSourceCheckStates";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let token = state.source_check.current_token();
    let rd = {
        let db = state.db.lock().await;
        match BookSourceCheckStateRepository::new(db.connection()).find_all() {
            Ok(states) => match serde_json::to_value(json!({
                "states": states,
                "sessionToken": token,
            })) {
                Ok(value) => ReturnData::success(value),
                Err(e) => ReturnData::error(e.to_string()),
            },
            Err(e) => ReturnData::error(e.to_string()),
        }
    };
    to_response(&rd, uri, origin.as_deref())
}

#[derive(Debug, Deserialize)]
struct StartRequest {
    #[serde(default)]
    sources: Option<Vec<BookSource>>,
    #[serde(default)]
    keyword: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StopRequest {
    #[serde(rename = "sessionToken", default)]
    session_token: Option<String>,
}

/// 已校验的待检验源（源当前内容 + 状态快照）
struct SelectedSource {
    source: BookSource,
    state: BookSourceCheckState,
}

/// POST `/startBookSourceCheck`（BookSourceCheckController.start）
pub async fn start_book_source_check(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/startBookSourceCheck";
    let token_config = load_js_source_api_config(&state).await;
    if !token_config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }

    let request =
        match post_data(&body).and_then(|text| serde_json::from_str::<StartRequest>(&text).ok()) {
            Some(request) => request,
            None => return to_response(&ReturnData::error("检验参数无效"), uri, origin.as_deref()),
        };
    let mut seen = HashSet::new();
    let submitted: Vec<BookSource> = request
        .sources
        .unwrap_or_default()
        .into_iter()
        .filter(|source| seen.insert(source.book_source_url.clone()))
        .collect();
    if submitted.is_empty() {
        return to_response(
            &ReturnData::error("请选择需要检验的书源"),
            uri,
            origin.as_deref(),
        );
    }

    // 1) 提交源必须与库内版本一致（原版 current.checkContent() != source.checkContent()）
    let mut parts: Vec<SelectedSource> = Vec::new();
    let mut changed = false;
    {
        let db = state.db.lock().await;
        let source_repo = BookSourceRepository::new(db.connection());
        let state_repo = BookSourceCheckStateRepository::new(db.connection());
        for source in submitted {
            let current = match source_repo.find_by_url(&source.book_source_url) {
                Ok(current) => current,
                Err(e) => {
                    return to_response(&ReturnData::error(e.to_string()), uri, origin.as_deref())
                }
            };
            let state = match state_repo.find_by_url(&source.book_source_url) {
                Ok(state) => {
                    state.unwrap_or_else(|| BookSourceCheckState::missing(&source.book_source_url))
                }
                Err(e) => {
                    return to_response(&ReturnData::error(e.to_string()), uri, origin.as_deref())
                }
            };
            match current {
                Some(current) if current.check_content() == source.check_content() => {
                    parts.push(SelectedSource {
                        source: current,
                        state,
                    });
                }
                _ => changed = true,
            }
        }
    }
    if changed {
        return to_response(
            &ReturnData::error("书源尚未保存或设备版本已变更，请先保存或重新拉取"),
            uri,
            origin.as_deref(),
        );
    }

    // 2) 单会话占用（对齐 Debug.tryStartCheckSession）
    let Some((session_token, _cancel)) = state.source_check.try_start() else {
        return to_response(
            &ReturnData::error("书源调试通道占用中，请稍后重试"),
            uri,
            origin.as_deref(),
        );
    };

    let mut config = load_check_config(&state).await;
    // P3-4：请求 keyword trim 后非空 → 更新粘滞值；缺省 → 沿用上次（原版
    // `CheckSource.keyword` 是进程级全局，网页连续检验不重复传也会沿用）
    if let Some(keyword) = request.keyword.as_deref().map(str::trim) {
        if !keyword.is_empty() {
            state.source_check.set_keyword(keyword);
        }
    }
    config.keyword = state.source_check.keyword();

    // 3) 排队：逐源重置状态（对齐 BookSourceDao.beginCheck）
    let mut revisions: BTreeMap<String, String> = BTreeMap::new();
    let mut queued: Vec<SelectedSource> = Vec::new();
    {
        let db = state.db.lock().await;
        let prepared = in_transaction(db.connection(), "书源检验排队", |conn| {
            let state_repo = BookSourceCheckStateRepository::new(conn);
            for part in parts {
                let url = part.source.book_source_url.clone();
                let next = state_repo.begin_check(
                    &url,
                    part.source.last_update_time,
                    &part.state.revision,
                )?;
                let state = match next {
                    Some(state) => state,
                    None => part.state.clone(),
                };
                revisions.insert(url, state.source_revision.clone());
                queued.push(SelectedSource {
                    source: part.source,
                    state,
                });
            }
            Ok(())
        });
        if let Err(e) = prepared {
            state.source_check.finish(&session_token);
            return to_response(&ReturnData::error(e.to_string()), uri, origin.as_deref());
        }
    }

    // 4) 后台逐源检验（单任务；stop 通过 AbortHandle 中止）
    let task_state = Arc::clone(&state);
    let task_token = session_token.clone();
    let handle = tokio::spawn(async move {
        run_check_session(task_state, task_token, queued, config).await;
    });
    state
        .source_check
        .attach_abort(&session_token, handle.abort_handle());

    to_response(
        &ReturnData::success(json!({
            "sessionToken": session_token,
            "sourceRevisions": revisions,
        })),
        uri,
        origin.as_deref(),
    )
}

/// POST `/stopBookSourceCheck`（BookSourceCheckController.stop）
pub async fn stop_book_source_check(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/stopBookSourceCheck";
    let token_config = load_js_source_api_config(&state).await;
    if !token_config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let request = post_data(&body).and_then(|text| serde_json::from_str::<StopRequest>(&text).ok());
    let matched = match request.and_then(|request| request.session_token) {
        Some(token) => state.source_check.stop(&token),
        None => false,
    };
    if !matched {
        return to_response(
            &ReturnData::error("检验会话已结束或已更换"),
            uri,
            origin.as_deref(),
        );
    }
    to_response(
        &ReturnData::success(Value::String(String::new())),
        uri,
        origin.as_deref(),
    )
}

// ─── 后台检验执行 ───────────────────────────────────────────────────────────

/// 检验结果（对齐原版 `CheckOutcome` + 失效分组）
#[derive(Debug, Clone)]
struct CheckOutcome {
    status: &'static str,
    message: String,
    invalid_groups: Vec<String>,
}

impl CheckOutcome {
    fn passed() -> Self {
        Self {
            status: check_status::PASSED,
            message: "校验成功".to_string(),
            invalid_groups: Vec::new(),
        }
    }

    /// 统一「校验失败:」前缀（原版 resultMessage 恒带该前缀）
    fn normalize_failed_message(message: impl Into<String>) -> String {
        let message = message.into();
        if message.starts_with("校验失败:") {
            message
        } else {
            format!("校验失败:{message}")
        }
    }

    fn failed(message: impl Into<String>) -> Self {
        Self {
            status: check_status::FAILED,
            message: Self::normalize_failed_message(message),
            invalid_groups: Vec::new(),
        }
    }

    /// 带失效分组的硬失败（批42b P2-2）：早退时也携带已累计分组
    fn failed_with_groups(message: impl Into<String>, groups: Vec<String>) -> Self {
        Self {
            status: check_status::FAILED,
            message: Self::normalize_failed_message(message),
            invalid_groups: groups,
        }
    }

    fn uncheckable() -> Self {
        Self {
            status: check_status::UNCHECKABLE,
            message: "无法校验:源地址不是http链接".to_string(),
            invalid_groups: Vec::new(),
        }
    }
}

/// 会话占用守卫：任务正常结束或 panic 展开时都释放会话（批30b P2-3）
///
/// 修复前只在 `run_check_session` 末尾调用 `finish(&token)`：任务 panic 时
/// future 被丢弃、该行不执行，会话永久占用（`getBookSourceCheckStates` 持续
/// 返回 sessionToken，新检验恒报「书源调试通道占用中」）。Drop 在 unwindsafe
/// 的栈展开中同样执行，故用守卫兜底。
struct SessionGuard {
    manager: Arc<SourceCheckManager>,
    token: String,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        self.manager.finish(&self.token);
    }
}

/// 源是否可能使用流程会话变量（`@put`/`@get`，JS 源视为可能）
///
/// 批42b P2-5：用于在并行检验前识别 FLOW_SCOPE 串读高风险源。判定基于
/// 序列化后的规则文本（`@put`/`@get`/`java.put`/`java.get`），JS 源恒为真；
/// 宁可多报（规则里出现同名子串）也不漏报，告警只用于可观测性。
fn source_uses_flow_variables(source: &BookSource) -> bool {
    if source.is_js_source() {
        return true;
    }
    match serde_json::to_string(source) {
        Ok(json) => ["@put", "@get", "java.put", "java.get"]
            .iter()
            .any(|needle| json.contains(needle)),
        Err(_) => false,
    }
}

/// 后台检验会话：有界并发执行，每源完成立即写回（对齐 CheckSourceService）
///
/// 并发模型对齐原版 `flow.mapParallel(threadCount)`（有界协程并发）：
/// - 并发数取 `CheckConfig.concurrency`（缺省 CPU 核数夹逼 4~8，可用
///   `config:checkThreadCount` 覆盖）；
/// - 工作线程从共享队列取源，任一源完成即写回（不按顺序等待）；
/// - `stop` 通过 AbortHandle 中止本任务，`JoinSet` 随 future 丢弃一并中止
///   在途工作线程，未完成源保持 `NEEDS_CHECK`（与原版取消语义一致）；
/// - DB 写回仍经 `AppState.db` 互斥锁串行 + `finish_check` 的
///   `(url, revision, status='NEEDS_CHECK')` CAS，并发下不丢写、不覆盖新状态。
async fn run_check_session(
    state: Arc<AppState>,
    token: String,
    parts: Vec<SelectedSource>,
    config: CheckConfig,
) {
    // P2-3：守卫在函数返回/panic 展开时释放会话，替代末尾的显式 finish
    let _session_guard = SessionGuard {
        manager: Arc::clone(&state.source_check),
        token: token.clone(),
    };
    let total = parts.len();
    if total == 0 {
        return;
    }
    // P3-3：FetcherDeps（连接池 + 回调）会话级复用一次；原版共用 OkHttp
    // client。并发工作线程各自 clone（LegadoClient/注册表/闭包均为共享句柄）。
    let deps = server_deps(&state).map_err(|e| format!("抓取组件初始化失败: {e}"));
    let concurrency = config.concurrency.clamp(1, total);

    // 批42b P2-5：并行检验下 FLOW_SCOPE 串读的可观测告警（登记项 B42-C2）。
    // 单槽 scope 不只是「按空值降级」——A 的 @put 可能落进 B 的 scope，B 随后
    // @get 会读到 A 的值。仅在并行度 >1 且至少两个源可能使用流程会话变量时
    // 输出一次，避免对普通检验刷屏。
    if concurrency > 1 {
        let flow_sensitive: Vec<&str> = parts
            .iter()
            .filter(|part| source_uses_flow_variables(&part.source))
            .map(|part| part.source.book_source_url.as_str())
            .collect();
        if flow_sensitive.len() >= 2 {
            let message = format!(
                "书源检验并行度={concurrency}，其中 {} 个源使用流程会话变量（@put/@get/java.put）；\
                 legado-js FLOW_SCOPE 为进程级单槽，跨源变量可能互相串读（A 的 @put 可能写进 B 的 scope，\
                 登记项 B42-C2）: {}",
                flow_sensitive.len(),
                flow_sensitive.join(", ")
            );
            tracing::warn!("{message}");
            // 服务端未安装 tracing subscriber 时 warn 不可见，补 stderr 便于取证
            eprintln!("[书源检验] {message}");
        }
    }

    let queue = Arc::new(StdMutex::new(parts.into_iter()));
    let mut workers = tokio::task::JoinSet::new();
    for _ in 0..concurrency {
        let worker_state = Arc::clone(&state);
        let worker_token = token.clone();
        let worker_config = config.clone();
        let worker_deps = deps.clone();
        let worker_queue = Arc::clone(&queue);
        workers.spawn(async move {
            loop {
                // 取消检查：stop 后不再领取新源（在途请求由任务中止兜底）
                if worker_state.source_check.is_cancelled(&worker_token) {
                    break;
                }
                let next = {
                    let mut guard = worker_queue.lock().unwrap_or_else(|e| e.into_inner());
                    guard.next()
                };
                let Some(part) = next else {
                    break;
                };
                check_one_source(
                    &worker_state,
                    &worker_token,
                    part,
                    &worker_config,
                    &worker_deps,
                )
                .await;
            }
        });
    }
    while let Some(result) = workers.join_next().await {
        if let Err(e) = result {
            tracing::warn!("书源检验工作线程异常退出: {e}");
        }
    }
    // 会话释放交给 SessionGuard（P2-3：panic 展开也能清理）
}

/// 单源检验执行（快照复核 → 超时校验 → 写回）
async fn check_one_source(
    state: &Arc<AppState>,
    token: &str,
    part: SelectedSource,
    config: &CheckConfig,
    deps: &Result<legado_fetcher::deps::FetcherDeps, String>,
) {
    if state.source_check.is_cancelled(token) {
        return;
    }
    let url = part.source.book_source_url.clone();
    // 校验前快照复核（对齐 CheckSourceService：源/状态变更则结果不写回）
    let snapshot = {
        let db = state.db.lock().await;
        let source = BookSourceRepository::new(db.connection())
            .find_by_url(&url)
            .ok()
            .flatten();
        let stored_state = BookSourceCheckStateRepository::new(db.connection())
            .find_by_url(&url)
            .ok()
            .flatten();
        match (source, stored_state) {
            (Some(source), Some(stored_state)) => Some((source, stored_state)),
            _ => None,
        }
    };
    let Some((current, stored_state)) = snapshot else {
        return;
    };
    if current.last_update_time != part.source.last_update_time
        || stored_state.revision != part.state.revision
    {
        return;
    }

    let started = Instant::now();
    let outcome = match tokio::time::timeout(
        Duration::from_millis(config.timeout_ms),
        check_source(&current, config, deps),
    )
    .await
    {
        Ok(outcome) => outcome,
        Err(_) => CheckOutcome::failed("校验超时"),
    };
    let elapsed_ms = started.elapsed().as_millis() as i64;
    write_back_check_result(
        state,
        token,
        &url,
        &part.state.revision,
        &outcome,
        elapsed_ms,
        config,
    )
    .await;
}

/// 写回单源检验结果（对齐 `CheckSourceService.onEach` 的 detail/respondTime）
///
/// 批42b P2-1：**取消检查放在写回入口**。`stop` 的 AbortHandle 只能在 await
/// 点打断任务，若检查恰在 stop 前后返回（超时/请求完成），没有显式检查时
/// 结果仍会以 FAILED/UNCHECKABLE 覆盖「停止后保持 NEEDS_CHECK」语义。写回
/// 前再判一次会话令牌，已停止/已更换则直接丢弃本次结果。
async fn write_back_check_result(
    state: &Arc<AppState>,
    token: &str,
    url: &str,
    revision: &str,
    outcome: &CheckOutcome,
    elapsed_ms: i64,
    config: &CheckConfig,
) {
    if state.source_check.is_cancelled(token) {
        tracing::debug!("书源 {url} 检验会话已停止，丢弃在途结果（{outcome:?}）");
        return;
    }
    let detail = compose_detail(outcome, config.w_source_comment);
    // P3-1：对齐 `Debug.getRespondTime(..., status != FAILED)`——UNCHECKABLE
    // 也算成功、按实际耗时；仅 FAILED 叠加超时基数
    let respond_time = if outcome.status == check_status::FAILED {
        config.timeout_ms as i64 + elapsed_ms
    } else {
        elapsed_ms
    };

    let db = state.db.lock().await;
    let state_repo = BookSourceCheckStateRepository::new(db.connection());
    match state_repo.finish_check(url, revision, outcome.status, &detail, now_millis()) {
        Ok(true) => {
            if let Err(e) =
                BookSourceRepository::new(db.connection()).update_respond_time(url, respond_time)
            {
                tracing::warn!("更新书源 {url} 响应时间失败: {e}");
            }
        }
        Ok(false) => {
            tracing::debug!("书源 {url} 检验结果未写回：已变更或已删除");
        }
        Err(e) => tracing::warn!("写回书源 {url} 检验结果失败: {e}"),
    }
}

/// 单源检验（对齐 `CheckSourceService.doCheckSource` 的可达子集）
///
/// 检查项顺序与原版一致：源地址可访问性（TCP）→ 搜索 → 搜索书详情/目录/正文
/// → 发现 → 发现书详情/目录/正文 → 失效分组汇总。任一「非失效分组」异常
/// 立即判 FAILED（对齐原版异常上抛语义）；目录/正文为空记为失效分组，继续
/// 执行后续检查项后再统一汇总。
///
/// `deps` 为会话级复用的抓取依赖（P3-3）；初始化失败按本次校验失败返回。
async fn check_source(
    source: &BookSource,
    config: &CheckConfig,
    deps: &Result<legado_fetcher::deps::FetcherDeps, String>,
) -> CheckOutcome {
    let mut invalid_groups: Vec<String> = Vec::new();

    // 源地址可访问性（对齐原版 checkDomain 分支）：非 http(s) → UNCHECKABLE；
    // http(s) 且开启探测时做 TCP 连接（1.6s 总预算 / 500ms 单地址），
    // 不可达 → FAILED「域名失效」
    let mut domain_unchecked = false;
    if config.check_domain {
        match parse_check_source_endpoint(&source.book_source_url) {
            None => domain_unchecked = true,
            Some((host, port)) => {
                if !is_domain_reachable(&host, port).await {
                    invalid_groups.push("域名失效".to_string());
                    return CheckOutcome::failed_with_groups("源地址不可访问", invalid_groups);
                }
            }
        }
    }

    let source_json = match serde_json::to_string(source) {
        Ok(json) => json,
        Err(e) => return fail_check(format!("源序列化失败: {e}"), &invalid_groups),
    };

    let mut searched_book: Option<WebSearchResult> = None;
    if config.check_search {
        if !source.is_js_source()
            && source
                .search_url
                .as_deref()
                .map(str::trim)
                .unwrap_or("")
                .is_empty()
        {
            return fail_check("搜索链接规则为空", &invalid_groups);
        }
        let deps = match deps {
            Ok(deps) => deps,
            Err(e) => return fail_check(e.clone(), &invalid_groups),
        };
        let keyword = effective_keyword(source, &config.keyword);
        match legado_fetcher::web_book::webbook_search(deps.clone(), &source_json, &keyword, 1)
            .await
        {
            Err(e) => return fail_check(e.to_string(), &invalid_groups),
            Ok(raw) => match serde_json::from_str::<Vec<WebSearchResult>>(&raw) {
                Err(e) => return fail_check(format!("搜索结果解析失败: {e}"), &invalid_groups),
                Ok(results) if results.is_empty() => invalid_groups.push("搜索失效".to_string()),
                Ok(mut results) => searched_book = Some(results.remove(0)),
            },
        }
    }

    // 搜索书详情/目录/正文（原版在发现校验之前执行；空目录/空正文只记分组）
    if let Some(book) = searched_book.as_ref() {
        let deps = match deps {
            Ok(deps) => deps,
            Err(e) => return fail_check(e.clone(), &invalid_groups),
        };
        match check_book(source, book, config, deps, CheckFlow::Search).await {
            Ok(()) => {}
            Err(CheckBookError::Group(group)) => invalid_groups.push(group),
            Err(CheckBookError::Failed(message)) => {
                return fail_check(message, &invalid_groups);
            }
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
        let setup_script = deps
            .as_ref()
            .ok()
            .and_then(|deps| deps.setup_script_for(source));
        match first_explore_category_url(
            source.explore_url.as_deref().unwrap_or(""),
            source,
            setup_script,
        ) {
            // 无可用分类 URL：上游抛「发现规则为空」→ 失效分组
            Err(ExploreRuleError::Empty) => invalid_groups.push("发现规则为空".to_string()),
            // 求值异常：上游异常上抛 → FAILED（detail 区分「求值失败」）
            Err(ExploreRuleError::Eval(message)) => {
                return fail_check(format!("发现规则求值失败: {message}"), &invalid_groups);
            }
            // 宿主未启用 JS 引擎：能力缺口而非源缺陷，跳过发现校验（登记差异）。
            // 服务端未安装 tracing subscriber 时 debug 不可见 → warn + stderr。
            Err(ExploreRuleError::Unavailable(message)) => {
                tracing::warn!(
                    "书源 {} 的 JS 发现规则跳过求值（{message}；非 quickjs 边界）",
                    source.book_source_url
                );
                eprintln!(
                    "[书源检验] 跳过 JS 发现规则（{}）：{message}（非 quickjs 构建，不计入失效）",
                    source.book_source_url
                );
            }
            Ok(category_url) => {
                let deps = match deps {
                    Ok(deps) => deps,
                    Err(e) => return fail_check(e.clone(), &invalid_groups),
                };
                match legado_fetcher::web_book::webbook_explore_first_book(
                    deps.clone(),
                    &source_json,
                    &category_url,
                    1,
                )
                .await
                {
                    Err(e) => {
                        return fail_check(format!("发现页请求失败: {e}"), &invalid_groups);
                    }
                    Ok(None) => invalid_groups.push("发现失效".to_string()),
                    Ok(Some(book)) => {
                        match check_book(source, &book, config, deps, CheckFlow::Discovery).await {
                            Ok(()) => {}
                            Err(CheckBookError::Group(group)) => invalid_groups.push(group),
                            Err(CheckBookError::Failed(message)) => {
                                return fail_check(message, &invalid_groups);
                            }
                        }
                    }
                }
            }
        }
    }

    if !invalid_groups.is_empty() {
        return CheckOutcome::failed_with_groups(invalid_groups.join(", "), invalid_groups);
    }

    if domain_unchecked {
        return CheckOutcome::uncheckable();
    }
    CheckOutcome::passed()
}

/// 硬失败早退并保留已累计的失效分组（批42b P2-2）
///
/// 修复前各早退点直接构造 `CheckOutcome::failed`，会把此前已判定的失效分组
/// （如「搜索失效」）丢掉：搜索空 + 发现求值抛错时 detail 只剩后者。
fn fail_check(message: impl Into<String>, invalid_groups: &[String]) -> CheckOutcome {
    CheckOutcome::failed_with_groups(message, invalid_groups.to_vec())
}

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

/// 详情/目录/正文校验的失败类型
#[derive(Debug, Clone, PartialEq, Eq)]
enum CheckBookError {
    /// 失效分组（原版 ContentEmptyException / TocEmptyException，继续后续检查）
    Group(String),
    /// 其他异常（原版直接上抛 → FAILED）
    Failed(String),
}

/// 搜索/发现结果的详情/目录/正文校验（对齐 `CheckSourceService.checkBook`）
async fn check_book(
    source: &BookSource,
    book: &WebSearchResult,
    config: &CheckConfig,
    deps: &legado_fetcher::deps::FetcherDeps,
    flow: CheckFlow,
) -> Result<(), CheckBookError> {
    if !config.check_info {
        return Ok(());
    }
    let source_json = serde_json::to_string(source)
        .map_err(|e| CheckBookError::Failed(format!("源序列化失败: {e}")))?;

    // 搜索结果不含 tocUrl → 与原版「tocUrl 为空则取详情」一致，恒取详情
    let info_raw =
        legado_fetcher::web_book::webbook_info(deps.clone(), &source_json, &book.book_url)
            .await
            .map_err(|e| CheckBookError::Failed(format!("详情页解析失败: {e}")))?;
    let info: WebBookInfo = serde_json::from_str(&info_raw)
        .map_err(|e| CheckBookError::Failed(format!("详情结果解析失败: {e}")))?;

    if !config.check_category || source.book_source_type == book_source_type::FILE {
        return Ok(());
    }
    let chapters_raw = legado_fetcher::web_book::webbook_chapters(
        deps.clone(),
        &source_json,
        &info.book_url,
        &info.toc_url,
        &info.name,
    )
    .await
    .map_err(|e| CheckBookError::Failed(format!("目录解析失败: {e}")))?;
    let chapters: Vec<WebChapter> = serde_json::from_str(&chapters_raw)
        .map_err(|e| CheckBookError::Failed(format!("目录结果解析失败: {e}")))?;
    let label = flow.book_type_label();
    let chapter = select_check_chapter(&chapters)
        .ok_or_else(|| CheckBookError::Group(format!("{label}目录失效")))?;

    if !config.check_content {
        return Ok(());
    }
    let chapter_json = serde_json::to_string(chapter)
        .map_err(|e| CheckBookError::Failed(format!("章节序列化失败: {e}")))?;
    let content =
        legado_fetcher::web_book::webbook_content(deps.clone(), &source_json, &chapter_json)
            .await
            .map_err(|e| CheckBookError::Failed(format!("正文解析失败: {e}")))?;
    if content.trim().is_empty() {
        return Err(CheckBookError::Group(format!("{label}正文失效")));
    }
    Ok(())
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
    ///
    /// 仅 `not(quickjs)` 构建构造；quickjs 构建保留变体以统一匹配分支。
    /// 非 quickjs 边界（批42b P3-7）：只影响 `@js:` / `<js>` 形态的 exploreUrl
    /// 求值——纯文本 `分类::URL` 与 JSON 分类数组不经过 JS，两种构建行为一致；
    /// 遇到本变体时调用方跳过该源的发现项（不判 FAILED、不计失效分组），并
    /// 以 warn + stderr 留下可观测记录。
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

/// 将 exploreUrl 解析为可分类的规则字符串（对齐 ffi `resolve_explore_rule_str`）
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
        prelude.push_str(&legado_fetcher::js_adapter::sanitize_js_lib_for_quickjs(
            js_lib,
        ));
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
        // 与 ffi `eval_explore_js` 同款非严格包装：Rhino 裸调用函数 this=全局，
        // QuickJS `ctx.eval` 严格模式下 this=undefined（书山等聚合源依赖）
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

/// 未启用 quickjs：`@js:` / `<js>` 发现规则无法求值
///
/// 这是宿主能力缺口而非源缺陷：返回 [`ExploreRuleError::Unavailable`] 由
/// 调用方跳过发现校验（否则默认构建会把全部 JS 发现源误判 FAILED）。
///
/// 非 quickjs 边界（批42b P3-7）：该分支只在 exploreUrl 以 `@js:` / `<js>`
/// 开头时命中；纯文本分类与 JSON 分类数组仍走 [`parse_explore_url`] 正常
/// 解析，不受构建特性影响。
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
///
/// 先经 tokio 异步解析地址（多 A/AAAA 记录逐个尝试，对齐 Java
/// `Socket.connect(InetSocketAddress)` 的地址列表语义）。批42b P3-5：单地址
/// 连接限 [`DOMAIN_PROBE_PER_ADDRESS_TIMEOUT`]（500ms），避免首个地址慢连接
/// 吃掉全部预算；整体仍受 [`DOMAIN_PROBE_TIMEOUT`]（1.6s）约束。
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

/// 目录首章选择（对齐 `CheckSourceChapterSelection.kt:11-25`）
///
/// 原版先 `filterNot { it.isVolume && it.url.startsWith(it.title) }` 再取首章：
/// 目录解析把空 URL 的卷章头合成为 `{title}{index}`（对齐
/// `BookChapterList.kt:263-264`），这类条目不是正文页，直接 `first()` 会拿合成
/// URL 去抓正文 → 假失败。`nextChapterUrl` 仅用于上游正文分页，Rust 正文接口
/// 不需要，故只返回首个可读章。
fn select_check_chapter(chapters: &[WebChapter]) -> Option<&WebChapter> {
    chapters
        .iter()
        .find(|chapter| !(chapter.is_volume && chapter.url.starts_with(&chapter.title)))
}

/// 有效搜索关键词（对齐 `BookSource.getCheckKeyword`）
///
/// 原版 `isNotBlank()` 只做判定、**返回原串**（不做 trim）；P3-4 起同步该口径。
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

/// 失败详情拼接（对齐 CheckSourceService.onEach 的 detail 组合）
///
/// 原版：`失效分组 | message | // Error: 本次异常`，过滤空串、去重、
/// `" | "` 连接；`PASSED` 恒为空串。
///
/// 第三段来源（批30b P1-1 修正）：上游 `doCheckSource` 起始
/// `removeErrorComment()` 剥离历史 `// Error:` 块，失败时
/// `addErrorComment(本次异常)` 把 `// Error: {本次 message}` 前置，detail 再取
/// 其首行——所以第三段**恒为本次失败消息**，与库内注释无关。这里直接由
/// `outcome.message` 去「校验失败:」前缀生成：无注释源也有第三段、带历史错误
/// 的源不会显示旧文案。`UNCHECKABLE` 没有失败异常（上游不调用
/// `addErrorComment`），第三段不出现。
fn compose_detail(outcome: &CheckOutcome, w_source_comment: bool) -> String {
    if outcome.status == check_status::PASSED {
        return String::new();
    }
    let mut parts: Vec<String> = Vec::new();
    if !outcome.invalid_groups.is_empty() {
        parts.push(outcome.invalid_groups.join(", "));
    }
    if !outcome.message.is_empty() {
        parts.push(outcome.message.clone());
    }
    if w_source_comment && outcome.status == check_status::FAILED {
        let message = outcome
            .message
            .strip_prefix("校验失败:")
            .unwrap_or(&outcome.message);
        parts.push(format!("// Error: {message}"));
    }
    let mut distinct: Vec<String> = Vec::new();
    for part in parts {
        if !part.is_empty() && !distinct.contains(&part) {
            distinct.push(part);
        }
    }
    distinct.join(" | ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compose_detail_passed_is_empty() {
        assert_eq!(compose_detail(&CheckOutcome::passed(), true), "");
    }

    #[test]
    fn test_compose_detail_matches_upstream_join() {
        let outcome =
            CheckOutcome::failed_with_groups("校验失败:搜索失效", vec!["搜索失效".to_string()]);
        assert_eq!(
            compose_detail(&outcome, true),
            "搜索失效 | 校验失败:搜索失效 | // Error: 搜索失效"
        );
        assert_eq!(
            compose_detail(&outcome, false),
            "搜索失效 | 校验失败:搜索失效"
        );
    }

    #[test]
    fn test_compose_detail_dedupes() {
        let outcome = CheckOutcome::failed_with_groups("校验失败:搜索失效", vec![]);
        assert_eq!(
            compose_detail(&outcome, true),
            "校验失败:搜索失效 | // Error: 搜索失效"
        );
    }

    /// P1-1 回归：第三段恒为本次失败消息（去「校验失败:」前缀）
    ///
    /// 上游 `doCheckSource` 起始 `removeErrorComment()` 剥离历史错误块，失败时
    /// `addErrorComment(本次异常)` 前置，detail 取其首行；因此第三段不能取库内
    /// 历史注释（修复前带历史错误的源会显示旧文案、无注释源恒缺第三段）。
    #[test]
    fn test_compose_detail_failed_uses_current_message() {
        let outcome = CheckOutcome::failed("正文为空");
        assert_eq!(
            compose_detail(&outcome, true),
            "校验失败:正文为空 | // Error: 正文为空"
        );
    }

    /// P1-1 回归：UNCHECKABLE 无失败异常，不取库内注释
    #[test]
    fn test_compose_detail_uncheckable_has_no_comment_part() {
        assert_eq!(
            compose_detail(&CheckOutcome::uncheckable(), true),
            "无法校验:源地址不是http链接"
        );
    }

    /// P1-1 回归：无历史注释的失败源也必须有第三段（修复前恒缺）
    #[test]
    fn test_compose_detail_failed_without_stored_comment_still_has_error_part() {
        let outcome = CheckOutcome::failed("搜索链接规则为空");
        assert_eq!(
            compose_detail(&outcome, true),
            "校验失败:搜索链接规则为空 | // Error: 搜索链接规则为空"
        );
    }

    #[test]
    fn test_effective_keyword() {
        let mut source = BookSource::default();
        assert_eq!(effective_keyword(&source, "我的"), "我的");
        source.rule_search = Some(legado_core::models::SearchRule {
            check_key_word: Some("  自定义  ".to_string()),
            ..Default::default()
        });
        assert_eq!(
            effective_keyword(&source, "我的"),
            "  自定义  ",
            "对齐原版 getCheckKeyword：isNotBlank 只判定、原串返回（不 trim）"
        );
        source.rule_search = Some(legado_core::models::SearchRule {
            check_key_word: Some("http://x".to_string()),
            ..Default::default()
        });
        assert_eq!(effective_keyword(&source, "我的"), "我的");
        source.rule_search = Some(legado_core::models::SearchRule {
            check_key_word: Some("   ".to_string()),
            ..Default::default()
        });
        assert_eq!(
            effective_keyword(&source, "我的"),
            "我的",
            "空白串回退默认值"
        );
    }

    /// P3-4：关键词进程级粘滞（对齐原版全局 `CheckSource.keyword`）
    #[test]
    fn test_session_manager_keyword_sticky() {
        let manager = SourceCheckManager::default();
        assert_eq!(manager.keyword(), "我的");
        manager.set_keyword("自定义");
        assert_eq!(manager.keyword(), "自定义");
        // 会话开关不影响粘滞值
        let (token, _) = manager.try_start().expect("首次应成功");
        manager.finish(&token);
        assert_eq!(manager.keyword(), "自定义");
    }

    /// P2-3：会话守卫在正常 drop 与 panic 展开时都释放会话
    #[test]
    fn test_session_guard_releases_on_drop() {
        let manager = Arc::new(SourceCheckManager::default());
        let (token, _) = manager.try_start().expect("首次应成功");
        {
            let _guard = SessionGuard {
                manager: Arc::clone(&manager),
                token: token.clone(),
            };
            assert_eq!(manager.current_token().as_deref(), Some(token.as_str()));
        }
        assert!(
            manager.current_token().is_none(),
            "guard drop 应释放会话（任务正常结束）"
        );
    }

    /// P2-3：任务 panic 时守卫仍释放会话，不会永久占用检验通道
    #[test]
    fn test_session_guard_releases_on_panic() {
        let manager = Arc::new(SourceCheckManager::default());
        let (token, _) = manager.try_start().expect("首次应成功");
        let panic_manager = Arc::clone(&manager);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = SessionGuard {
                manager: panic_manager,
                token,
            };
            panic!("模拟后台任务 panic");
        }));
        assert!(result.is_err(), "闭包应 panic");
        assert!(
            manager.current_token().is_none(),
            "panic 展开也必须释放会话（修复前永久占用）"
        );
    }

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

    /// P1-2 回归：空 URL 卷章头（合成为 `{title}{index}`）不得当正文章抓取
    ///
    /// 上游 `selectCheckSourceChapter` 先过滤
    /// `isVolume && url.startsWith(title)` 再取首章；修复前直接 `first()` 会拿
    /// 合成 URL 请求正文 → 假 FAILED。
    #[test]
    fn test_select_check_chapter_skips_volume_header() {
        let chapters = vec![
            web_chapter(0, "第一卷 开端", "第一卷 开端0", true),
            web_chapter(1, "第一章", "https://a.example.com/1", false),
            web_chapter(2, "第二章", "https://a.example.com/2", false),
        ];
        let chapter = select_check_chapter(&chapters).expect("应选到正文章");
        assert_eq!(chapter.title, "第一章");
        assert_eq!(chapter.url, "https://a.example.com/1");
    }

    /// 卷章 URL 不以标题开头（真实链接）时上游不过滤，仍按首章处理
    #[test]
    fn test_select_check_chapter_keeps_volume_with_real_url() {
        let chapters = vec![web_chapter(0, "卷", "https://a.example.com/vol", true)];
        assert_eq!(
            select_check_chapter(&chapters).map(|c| c.url.as_str()),
            Some("https://a.example.com/vol")
        );
    }

    /// 全部为卷章头时等价原版 `TocEmptyException`（由调用方转「目录为空」）
    #[test]
    fn test_select_check_chapter_none_when_only_volume_headers() {
        let chapters = vec![web_chapter(0, "第一卷", "第一卷0", true)];
        assert!(select_check_chapter(&chapters).is_none());
        assert!(select_check_chapter(&[]).is_none());
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
        // 非 http(s) / 无主机 / 非法地址 → None（上游 parseCheckSourceEndpoint）
        assert_eq!(parse_check_source_endpoint("ftp://a.example.com"), None);
        assert_eq!(parse_check_source_endpoint("a.example.com"), None);
        assert_eq!(parse_check_source_endpoint(""), None);
    }

    /// 并发数规范化：显式配置夹逼 1~32，缺省按 CPU 夹逼 4~8
    #[test]
    fn test_normalize_check_concurrency() {
        assert_eq!(
            normalize_check_concurrency(Some(0)),
            default_check_concurrency()
        );
        assert_eq!(normalize_check_concurrency(Some(2)), 2);
        assert_eq!(normalize_check_concurrency(Some(6)), 6);
        assert_eq!(
            normalize_check_concurrency(Some(999)),
            CHECK_CONCURRENCY_HARD_MAX
        );
        let fallback = default_check_concurrency();
        assert!((CHECK_CONCURRENCY_MIN..=CHECK_CONCURRENCY_MAX).contains(&fallback));
        assert_eq!(normalize_check_concurrency(None), fallback);
    }

    /// 发现分类解析：取首个非空 URL；分组标题/空 URL 跳过
    #[test]
    fn test_first_explore_category_url() {
        let source = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            ..BookSource::default()
        };
        assert_eq!(
            first_explore_category_url(
                "分组\n&&玄幻::https://a.example.com/xh\n都市::https://a.example.com/ds",
                &source,
                None
            )
            .unwrap(),
            "https://a.example.com/xh"
        );
        // JSON 数组
        assert_eq!(
            first_explore_category_url(
                r#"[{"title":"玄幻","url":"https://a.example.com/xh"}]"#,
                &source,
                None
            )
            .unwrap(),
            "https://a.example.com/xh"
        );
        // 只有分组标题 → 规则为空
        assert_eq!(
            first_explore_category_url("玄幻\n都市", &source, None),
            Err(ExploreRuleError::Empty)
        );
        // 空 URL 分组 + 有效分类
        assert_eq!(
            first_explore_category_url("分组::\n玄幻::https://a.example.com/xh", &source, None)
                .unwrap(),
            "https://a.example.com/xh"
        );
        // 分类 JSON 损坏 → 求值失败（不得把 ERROR 原文当 URL 抓取）
        // 批42b P3-10：JSON 形态判定需首尾括号，损坏样本保留闭合符
        assert!(matches!(
            first_explore_category_url("[{\"title\":}]", &source, None),
            Err(ExploreRuleError::Eval(_))
        ));
    }

    /// 非 quickjs 构建：JS 发现规则按「宿主能力缺失」上报（调用方跳过校验）
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn test_explore_js_rule_unavailable_without_quickjs() {
        let source = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            ..BookSource::default()
        };
        assert!(matches!(
            first_explore_category_url("@js:'[{\"title\":\"x\",\"url\":\"u\"}]'", &source, None),
            Err(ExploreRuleError::Unavailable(_))
        ));
    }

    /// quickjs 构建：`@js:` / `<js>` 发现规则真实求值；脚本异常 → 求值失败
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_explore_js_rule_evaluates_with_quickjs() {
        let source = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            ..BookSource::default()
        };
        let js = "JSON.stringify([{title:'玄幻',url:'https://a.example.com/xh'}])";
        assert_eq!(
            first_explore_category_url(&format!("@js:{js}"), &source, None).unwrap(),
            "https://a.example.com/xh"
        );
        assert_eq!(
            first_explore_category_url(&format!("<js>{js}</js>"), &source, None).unwrap(),
            "https://a.example.com/xh"
        );
        // 脚本抛错 → 求值失败（不得误判「规则为空」）
        assert!(matches!(
            first_explore_category_url("@js:throw new Error('boom')", &source, None),
            Err(ExploreRuleError::Eval(message)) if message.contains("boom")
        ));
    }

    #[test]
    fn test_parse_bool_defaults() {
        assert!(parse_bool(Some("true".to_string()), false));
        assert!(parse_bool(Some("1".to_string()), false));
        assert!(!parse_bool(Some("false".to_string()), true));
        assert!(!parse_bool(Some("0".to_string()), true));
        assert!(parse_bool(None, true));
        assert!(!parse_bool(Some("weird".to_string()), false));
    }

    #[test]
    fn test_session_manager_single_session_and_stop() {
        let manager = SourceCheckManager::default();
        assert!(manager.current_token().is_none());
        let (token, _) = manager.try_start().expect("首次应成功");
        assert_eq!(manager.current_token().as_deref(), Some(token.as_str()));
        assert!(manager.try_start().is_none(), "单会话约束");
        assert!(!manager.is_cancelled(&token));
        assert!(manager.stop(&token));
        assert!(manager.is_cancelled(&token));
        assert!(manager.current_token().is_none());
        assert!(!manager.stop(&token), "重复停止不匹配");
        let (second, _) = manager.try_start().expect("停止后可再开");
        assert_ne!(second, token);
        // 自然结束清理
        manager.finish(&second);
        assert!(manager.current_token().is_none());
    }

    /// 批42b P2-2：硬失败早退必须携带已累计的失效分组
    ///
    /// 场景：搜索已判「搜索失效」后，发现规则求值抛错（原版异常上抛 →
    /// FAILED）。修复前早退直接 `failed(...)`，detail 首段丢失「搜索失效」。
    #[test]
    fn test_fail_check_keeps_accumulated_groups() {
        let outcome = fail_check("发现规则求值失败: boom", &["搜索失效".to_string()]);
        assert_eq!(outcome.status, check_status::FAILED);
        assert_eq!(outcome.invalid_groups, vec!["搜索失效".to_string()]);
        assert_eq!(
            outcome.message, "校验失败:发现规则求值失败: boom",
            "硬失败消息仍带「校验失败:」前缀"
        );
        assert_eq!(
            compose_detail(&outcome, true),
            "搜索失效 | 校验失败:发现规则求值失败: boom | // Error: 发现规则求值失败: boom",
            "detail 同时包含已判分组与本次失败消息"
        );
    }

    /// `failed_with_groups` 对已带前缀的消息不重复加前缀
    #[test]
    fn test_failed_with_groups_prefix_is_idempotent() {
        let outcome = CheckOutcome::failed_with_groups(
            "校验失败:源地址不可访问",
            vec!["域名失效".to_string()],
        );
        assert_eq!(outcome.message, "校验失败:源地址不可访问");
        assert_eq!(
            compose_detail(&outcome, true),
            "域名失效 | 校验失败:源地址不可访问 | // Error: 源地址不可访问"
        );
    }

    /// 批42b P2-5：流程会话变量使用识别（并行串读告警的触发条件）
    #[test]
    fn test_source_uses_flow_variables() {
        let plain = BookSource {
            book_source_url: "https://plain.example.com".to_string(),
            ..BookSource::default()
        };
        assert!(!source_uses_flow_variables(&plain));

        let mut put_source = plain.clone();
        put_source.rule_search = Some(legado_core::models::SearchRule {
            book_list: Some("@put:{kind:小说}@css:.book".to_string()),
            ..Default::default()
        });
        assert!(source_uses_flow_variables(&put_source));

        let mut get_source = plain.clone();
        get_source.rule_content = Some(legado_core::models::ContentRule {
            content: Some("@get:{kind}@css:#content@text".to_string()),
            ..Default::default()
        });
        assert!(source_uses_flow_variables(&get_source));

        // mainJs 非空 → JS 源恒视为可能使用会话变量
        let mut js_source = plain.clone();
        js_source.main_js = Some("function search() { return '[]' }".to_string());
        assert!(source_uses_flow_variables(&js_source));
    }

    /// 批42b P2-1：会话停止后写回入口必须丢弃在途结果
    ///
    /// 端到端用例（`source_check_api_test.rs`）验证 stop 后的状态；取消与
    /// 写回之间的调度窗口无法稳定制造，故守卫本身在这里做直接覆盖：
    /// 同一份源 + revision，取消状态下调用不得落库，活跃会话下必须落库
    /// （对照组证明测试具备区分力）。
    #[tokio::test]
    async fn test_write_back_skipped_when_session_cancelled() {
        use legado_core::download_manager::DownloadManager;
        use tokio::sync::Mutex;

        let db = legado_db::init_in_memory_database().expect("内存库");
        let state = Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(1)),
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
        });
        let url = "https://cancel.example.com";
        let source = BookSource {
            book_source_url: url.to_string(),
            book_source_name: "取消写回源".to_string(),
            ..BookSource::default()
        };
        let revision = {
            let db = state.db.lock().await;
            BookSourceRepository::new(db.connection())
                .insert_with_check_state(&source)
                .expect("种源");
            BookSourceCheckStateRepository::new(db.connection())
                .find_by_url(url)
                .expect("查状态")
                .expect("状态存在")
                .revision
        };
        let config = CheckConfig::default();
        let outcome = CheckOutcome::failed("校验超时");

        // 1) 会话已停止 → 丢弃
        let (token, _) = state.source_check.try_start().expect("开始会话");
        assert!(state.source_check.stop(&token));
        write_back_check_result(&state, &token, url, &revision, &outcome, 10, &config).await;
        let (status, detail) = {
            let db = state.db.lock().await;
            let state = BookSourceCheckStateRepository::new(db.connection())
                .find_by_url(url)
                .expect("查状态")
                .expect("状态存在");
            (state.status, state.detail)
        };
        assert_eq!(status, check_status::NEEDS_CHECK, "取消后不得写回");
        assert_eq!(detail, "");

        // 2) 活跃会话 → 正常写回（对照）
        let (token, _) = state.source_check.try_start().expect("重新开始会话");
        write_back_check_result(&state, &token, url, &revision, &outcome, 10, &config).await;
        let (status, detail) = {
            let db = state.db.lock().await;
            let state = BookSourceCheckStateRepository::new(db.connection())
                .find_by_url(url)
                .expect("查状态")
                .expect("状态存在");
            (state.status, state.detail)
        };
        assert_eq!(status, check_status::FAILED, "活跃会话应写回");
        assert!(detail.starts_with("校验失败:校验超时"), "detail={detail}");
    }
}
