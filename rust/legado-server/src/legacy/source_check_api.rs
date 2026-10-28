//! 原版书源检验状态与检验会话端点（批30，4 条）
//!
//! 原版依据（upstream）：
//!
//! | 端点 | 原版实现 | 令牌 | 备注 |
//! |---|---|---|---|
//! | GET `/getBookSourcesForManagement?urls=` | `BookSourceCheckController.sources`（:22-43） | 无（前端仍会带） | 返回 `{sources, states}`；`urls` 为 JSON 字符串数组，缺省全量；坏 JSON →「书源地址参数无效」 |
//! | GET `/getBookSourceCheckStates` | `BookSourceCheckController.states`（:15-20） | 无 | 返回 `{states, sessionToken}`（无进行中会话时 `sessionToken: null`） |
//! | POST `/startBookSourceCheck` | `BookSourceCheckController.start`（:48-85） | **有**（`PROTECTED_SOURCE_WRITE_ROUTES`） | 请求 `{sources:[BookSource], keyword}`；返回 `{sessionToken, sourceRevisions}`；校验提交源与库内 `checkContent()` 一致；单会话 |
//! | POST `/stopBookSourceCheck` | `BookSourceCheckController.stop`（:87-96） | **有** | 请求 `{sessionToken}`；会话不匹配 →「检验会话已结束或已更换」；成功 `data=""` |
//!
//! 状态机（对齐 `BookSourceCheckState.kt` / `BookSourceDao.kt` / `CheckSourceService.kt`）：
//! 1. 书源保存（新增/规则变更）→ 状态重建为 `NEEDS_CHECK`，生成新
//!    `revision` + `sourceRevision`；仅改启用/排序等不影响规则的字段时保留状态
//!    （见 [`legado_db::BookSourceRepository::insert_with_check_state`] /
//!    [`legado_db::BookSourceRepository::update_with_check_state`]）；
//! 2. `start`：校验提交源与库内内容一致后，单会话排队，逐源把状态重置为
//!    `NEEDS_CHECK`（新 `revision`、保留 `sourceRevision`），服务端后台逐源检验；
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
//! 1. **发现页检验未接入**：原版 `CheckSource.checkDiscovery` 用发现规则引擎
//!    抓取首个分类；Rust 轨发现规则引擎在服务端尚不可达（`ws/original.rs` 同款
//!    降级登记），本实现跳过发现校验——只有发现规则坏、搜索/详情/目录/正文
//!    全好的源会被判 `PASSED`；
//! 2. **并发模型**：原版按 `AppConfig.threadCount` 并行校验；本实现逐源串行
//!    （单会话、可停止语义不变，避免 sqlite 单连接多任务写竞争）；
//! 3. **校验配置来源**：原版读 SharedPreferences（`CheckSource.timeout` 等）；
//!    Rust 侧无对应 UI，改读 caches 表 `config:checkSourceTimeout` /
//!    `config:wSourceComment` / `config:checkDomain` / `config:checkSearch` /
//!    `config:checkDiscovery` / `config:checkInfo` / `config:checkCategory` /
//!    `config:checkContent`，缺键取原版默认值（180s / true / false / 五个 true）；
//! 4. **调试通道互斥**：原版 `Debug.tryStartCheckSession` 与书源/RSS 调试共用
//!    通道；Rust 侧 WS 调试会话独立，本实现只保证「检验单会话」，
//!    不能阻止同时发起 WS 调试（登记）；
//! 5. `getBookSourcesForManagement` 的 `sources` 顺序按 `customOrder` 升序、
//!    `states` 按 `bookSourceUrl` 升序（原版无显式排序，属稳定化增强）；
//! 6. 不重建 `book_sources_part` 视图（Rust 无消费方，见 `schema.rs` v115 注）；
//! 7. **失败分组细节**：原版按失败类型维护「域名失效/js失效/网站失效/校验超时/
//!    搜索失效」等分组，并把分组名拼进 `detail` 首段；本实现只保留「搜索失效」
//!    与超时/错误消息（原版分组本就只用于 detail 组合、不落库），网络/JS 类失败
//!    的 detail 会比原版少一个分组前缀；
//! 8. **源地址可访问性**：原版 `checkDomain=true` 时做 TCP 连接探测并可能加
//!    「域名失效」分组；本实现只保留「非 http(s) → UNCHECKABLE」判定，不做 TCP
//!    探测（搜索请求会自然暴露不可达），默认 `checkDomain=false` 与原版一致。

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

/// 校验超时上限（毫秒）：防 caches 被写入超大值导致单源长期占用
const MAX_CHECK_TIMEOUT_MS: u64 = 600_000;

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
    /// 是否校验发现（Rust 侧引擎不可达，见模块登记 1）
    pub check_discovery: bool,
    /// 是否校验详情
    pub check_info: bool,
    /// 是否校验目录
    pub check_category: bool,
    /// 是否校验正文
    pub check_content: bool,
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
    process_token: String,
    next_session_id: AtomicU64,
}

impl Default for SourceCheckManager {
    fn default() -> Self {
        Self {
            inner: StdMutex::new(None),
            process_token: uuid::Uuid::new_v4().to_string(),
            next_session_id: AtomicU64::new(0),
        }
    }
}

impl SourceCheckManager {
    fn lock(&self) -> std::sync::MutexGuard<'_, Option<ActiveCheck>> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
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
pub async fn get_book_sources_for_management(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSourcesForManagement";
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
            None => (
                source_repo.find_all().unwrap_or_default(),
                state_repo.find_all().unwrap_or_default(),
            ),
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
pub async fn get_book_source_check_states(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getBookSourceCheckStates";
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
    if let Some(keyword) = request.keyword.as_deref().map(str::trim) {
        if !keyword.is_empty() {
            config.keyword = keyword.to_string();
        }
    }

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

    fn failed(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            status: check_status::FAILED,
            message: if message.starts_with("校验失败:") {
                message
            } else {
                format!("校验失败:{message}")
            },
            invalid_groups: Vec::new(),
        }
    }

    fn failed_with_groups(message: impl Into<String>, groups: Vec<String>) -> Self {
        Self {
            status: check_status::FAILED,
            message: message.into(),
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

/// 后台检验会话：逐源执行，每源完成立即写回（对齐 CheckSourceService）
async fn run_check_session(
    state: Arc<AppState>,
    token: String,
    parts: Vec<SelectedSource>,
    config: CheckConfig,
) {
    for part in parts {
        if state.source_check.is_cancelled(&token) {
            break;
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
            continue;
        };
        if current.last_update_time != part.source.last_update_time
            || stored_state.revision != part.state.revision
        {
            continue;
        }

        let started = Instant::now();
        let outcome = match tokio::time::timeout(
            Duration::from_millis(config.timeout_ms),
            check_source(&state, &current, &config),
        )
        .await
        {
            Ok(outcome) => outcome,
            Err(_) => CheckOutcome::failed("校验超时"),
        };
        let elapsed_ms = started.elapsed().as_millis() as i64;
        let detail = compose_detail(&current, &outcome, config.w_source_comment);
        let respond_time = if outcome.status == check_status::PASSED {
            elapsed_ms
        } else {
            config.timeout_ms as i64 + elapsed_ms
        };

        {
            let db = state.db.lock().await;
            let state_repo = BookSourceCheckStateRepository::new(db.connection());
            match state_repo.finish_check(
                &url,
                &part.state.revision,
                outcome.status,
                &detail,
                now_millis(),
            ) {
                Ok(true) => {
                    if let Err(e) = BookSourceRepository::new(db.connection())
                        .update_respond_time(&url, respond_time)
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
    }
    state.source_check.finish(&token);
}

/// 单源检验（对齐 `CheckSourceService.doCheckSource` 的可达子集）
async fn check_source(
    state: &Arc<AppState>,
    source: &BookSource,
    config: &CheckConfig,
) -> CheckOutcome {
    let mut invalid_groups: Vec<String> = Vec::new();

    // 源地址可访问性：原版在此处做 TCP 探测；本实现只保留「非 http 地址 →
    // UNCHECKABLE」判定，网络可达性交给后续搜索请求自然暴露（登记差异）
    let domain_unchecked = config.check_domain && !is_http_url(&source.book_source_url);

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
            return CheckOutcome::failed("搜索链接规则为空");
        }
        let source_json = match serde_json::to_string(source) {
            Ok(json) => json,
            Err(e) => return CheckOutcome::failed(format!("源序列化失败: {e}")),
        };
        let deps = match server_deps(state) {
            Ok(deps) => deps,
            Err(e) => return CheckOutcome::failed(format!("抓取组件初始化失败: {e}")),
        };
        let keyword = effective_keyword(source, &config.keyword);
        match legado_fetcher::web_book::webbook_search(deps, &source_json, &keyword, 1).await {
            Err(e) => return CheckOutcome::failed(e.to_string()),
            Ok(raw) => match serde_json::from_str::<Vec<WebSearchResult>>(&raw) {
                Err(e) => return CheckOutcome::failed(format!("搜索结果解析失败: {e}")),
                Ok(results) if results.is_empty() => invalid_groups.push("搜索失效".to_string()),
                Ok(mut results) => searched_book = Some(results.remove(0)),
            },
        }
    }

    // 发现校验：服务端发现规则引擎尚不可达（模块登记 1），仅日志后跳过
    if config.check_discovery
        && source
            .explore_url
            .as_deref()
            .map(str::trim)
            .is_some_and(|url| !url.is_empty())
    {
        tracing::debug!(
            "书源 {} 含发现规则，服务端未接入发现引擎，本次跳过发现校验",
            source.book_source_url
        );
    }

    if !invalid_groups.is_empty() {
        return CheckOutcome::failed_with_groups(
            format!("校验失败:{}", invalid_groups.join(", ")),
            invalid_groups,
        );
    }

    if let Some(book) = searched_book {
        if let Err(message) = check_book(state, source, &book, config).await {
            return CheckOutcome::failed(message);
        }
    }

    if domain_unchecked {
        return CheckOutcome::uncheckable();
    }
    CheckOutcome::passed()
}

/// 搜索结果的详情/目录/正文校验（对齐 `CheckSourceService.checkBook`）
async fn check_book(
    state: &Arc<AppState>,
    source: &BookSource,
    search: &WebSearchResult,
    config: &CheckConfig,
) -> Result<(), String> {
    if !config.check_info {
        return Ok(());
    }
    let deps = server_deps(state).map_err(|e| format!("抓取组件初始化失败: {e}"))?;
    let source_json = serde_json::to_string(source).map_err(|e| format!("源序列化失败: {e}"))?;

    // 搜索结果不含 tocUrl → 与原版「tocUrl 为空则取详情」一致，恒取详情
    let info_raw =
        legado_fetcher::web_book::webbook_info(deps.clone(), &source_json, &search.book_url)
            .await
            .map_err(|e| format!("详情页解析失败: {e}"))?;
    let info: WebBookInfo =
        serde_json::from_str(&info_raw).map_err(|e| format!("详情结果解析失败: {e}"))?;

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
    .map_err(|e| format!("目录解析失败: {e}"))?;
    let chapters: Vec<WebChapter> =
        serde_json::from_str(&chapters_raw).map_err(|e| format!("目录结果解析失败: {e}"))?;
    let chapter = chapters.first().ok_or_else(|| "目录为空".to_string())?;

    if !config.check_content {
        return Ok(());
    }
    let chapter_json =
        serde_json::to_string(chapter).map_err(|e| format!("章节序列化失败: {e}"))?;
    let content = legado_fetcher::web_book::webbook_content(deps, &source_json, &chapter_json)
        .await
        .map_err(|e| format!("正文解析失败: {e}"))?;
    if content.trim().is_empty() {
        return Err("正文为空".to_string());
    }
    Ok(())
}

/// 有效搜索关键词（对齐 `BookSource.getCheckKeyword`）
fn effective_keyword(source: &BookSource, default: &str) -> String {
    if let Some(keyword) = source
        .rule_search
        .as_ref()
        .and_then(|rule| rule.check_key_word.as_deref())
    {
        let keyword = keyword.trim();
        if !keyword.is_empty()
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

/// 是否为可校验的 http(s) 地址（对齐 `parseCheckSourceEndpoint` 的 OkHttp 判定）
fn is_http_url(url: &str) -> bool {
    let raw = url.split('#').next().unwrap_or("");
    match url::Url::parse(raw) {
        Ok(parsed) => {
            matches!(parsed.scheme(), "http" | "https")
                && parsed.host_str().is_some_and(|host| !host.is_empty())
        }
        Err(_) => false,
    }
}

/// 失败详情拼接（对齐 CheckSourceService.onEach 的 detail 组合）
///
/// 原版：`invalidGroups | message | 注释中 // Error: 首行`，过滤空串、去重、
/// `" | "` 连接；`PASSED` 恒为空串。
fn compose_detail(source: &BookSource, outcome: &CheckOutcome, w_source_comment: bool) -> String {
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
    if w_source_comment {
        if let Some(line) = source
            .book_source_comment
            .as_deref()
            .unwrap_or("")
            .lines()
            .find(|line| line.starts_with("// Error: "))
        {
            parts.push(line.to_string());
        }
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
    use legado_core::models::BookSource;

    fn source_with_comment(comment: &str) -> BookSource {
        BookSource {
            book_source_url: "https://a.example.com".to_string(),
            book_source_comment: Some(comment.to_string()),
            ..BookSource::default()
        }
    }

    #[test]
    fn test_compose_detail_passed_is_empty() {
        let source = source_with_comment("// Error: old");
        assert_eq!(compose_detail(&source, &CheckOutcome::passed(), true), "");
    }

    #[test]
    fn test_compose_detail_matches_upstream_join() {
        let source = source_with_comment("说明\n// Error: 网站失效\n尾注");
        let outcome =
            CheckOutcome::failed_with_groups("校验失败:搜索失效", vec!["搜索失效".to_string()]);
        assert_eq!(
            compose_detail(&source, &outcome, true),
            "搜索失效 | 校验失败:搜索失效 | // Error: 网站失效"
        );
        assert_eq!(
            compose_detail(&source, &outcome, false),
            "搜索失效 | 校验失败:搜索失效"
        );
    }

    #[test]
    fn test_compose_detail_dedupes() {
        let source = source_with_comment("");
        let outcome = CheckOutcome::failed_with_groups("校验失败:搜索失效", vec![]);
        assert_eq!(compose_detail(&source, &outcome, true), "校验失败:搜索失效");
    }

    #[test]
    fn test_effective_keyword() {
        let mut source = BookSource::default();
        assert_eq!(effective_keyword(&source, "我的"), "我的");
        source.rule_search = Some(legado_core::models::SearchRule {
            check_key_word: Some("  自定义  ".to_string()),
            ..Default::default()
        });
        assert_eq!(effective_keyword(&source, "我的"), "自定义");
        source.rule_search = Some(legado_core::models::SearchRule {
            check_key_word: Some("http://x".to_string()),
            ..Default::default()
        });
        assert_eq!(effective_keyword(&source, "我的"), "我的");
    }

    #[test]
    fn test_is_http_url() {
        assert!(is_http_url("https://a.example.com"));
        assert!(is_http_url("http://a.example.com/path#frag"));
        assert!(!is_http_url("ftp://a.example.com"));
        assert!(!is_http_url("a.example.com"));
        assert!(!is_http_url(""));
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
}
