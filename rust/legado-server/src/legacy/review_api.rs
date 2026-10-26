//! 原版 `ReviewController` 段评端点（B4 段评 legacy 6 条）
//!
//! 原版依据（upstream `api/controller/ReviewController.kt` + `web/HttpServer.kt`）：
//! - GET `/getReviewSummary`（:181-220）、`/getReviewDetail`（:222-329）、
//!   `/getReviewReplies`（:331-398）：requireContext（url/index/书籍/章节/书源）
//!   → JS 书源走 `JsSourceReview`（我方 [`legado_js`] 编排器同型入口）、规则书源走
//!   `AnalyzeUrl` 抓取 + `ReviewRuleParser` 解析（我方 `legado_parser`
//!   `parse_summary_with`/`parse_detail_page_with`/`parse_reply_page_with` 同一实现）；
//! - POST `/openLegacyReview`（:400-436，令牌保护）：`{url,index,src}` →
//!   click 脚本白名单（`getDP(a,b)`/`getZP(a)`）→ 源 JS 环境执行（`java.showBrowser`
//!   拦截为页面载荷）→ 会话登记（16 槽 / 2h TTL）→ `{id,nonce}`；
//! - POST `/runLegacyReview`（:438-456，令牌保护）：`{id,script}`（≤64KiB）→
//!   会话复检（书源未变更）→ 脚本求值 → HEIF 图片代理重写；
//! - GET `/legacyReviewPage`（HttpServer.kt:115-120/:280-324）：`id+nonce` 取回
//!   注入桥接脚本的 HTML（CSP sandbox + frame-ancestors）。
//!
//! 引擎链落点（B4 调查结论，全可达）：`legado-parser`（AnalyzeUrl/review_rule_parser）、
//! `legado-fetcher`（client 注入面 / `apply_cookie_jar_marker` / JS 执行器适配）、
//! `legado-js`（JS 书源编排器 / QuickJS 宿主 API `java.showBrowser` →
//! `ui_action_queue`，收集容器按每次求值隔离——审查批4 P2-3：并发
//! `/openLegacyReview`、`/runLegacyReview` 与 App 侧 FFI 求值互不串流，
//! 对齐原版每次求值新建 `LegacyReviewJsExtensions` 局部回调的生命周期）。
//! 与 ffi `review_api.rs` 为同一解析/抓取语义（单实现原则，
//! 仅宿主差异：ffi 用进程共享客户端，server 用 `server_deps` cookie 持久化客户端）。
//!
//! 登记差异：
//! - 详情分页游标：原版 `LruCache(64)`（LRU 淘汰），我方为容量 64 的
//!   「最久未使用时间戳淘汰」实现，访问即刷新时间戳，语义等价；
//! - JS 书源 `/getReviewReplies`：走 `legado-js` 编排器 `get_review_replies`
//!   （对齐原版 `JsSourceReview.getReviewRepliesAwait`：参数
//!   chapter/book/paraIndex/paraData/reviewId/page，返回 `items` 扁平化回复
//!   列表；函数缺失或返回 null → 空页 `{items:[],hasMore:false}`）；
//!   `hasMore` 对齐原版 `ReviewController.kt:331-345` 的 `items.isNotEmpty()`；
//! - `openLegacyReview` 脚本执行环境：原版 Rhino `RssJsExtensions`（`java` 绑定
//!   仅暴露 showBrowser 等 RSS 扩展），我方 QuickJS 宿主 API 的 `java` 命名空间
//!   为全集（showBrowser 行为一致：载荷返回 + ui_action_queue 收集）；书源
//!   `jsLib`/setup/mainJs 预载后求值，`book`/`chapter` 以 JS 对象绑定（字段名
//!   同 Kotlin 实体）；求值超时 120s（对齐桥接脚本 `run()` 的 120s 客户端
//!   超时；原版无显式上限）；
//! - `runLegacyReview` 求值环境：原版 `AnalyzeRule.evalJS` 另绑定
//!   `source`/`cookie`/`cache`/`baseUrl` 等；我方仅保证 `book`/`chapter`/
//!   `result`（脚本常用面），其余按 QuickJS 宿主 API 既有面提供（登记）；
//! - 非 quickjs 构建下 JS 书源路径/legacy 脚本求值返回引擎占位错误（与既有
//!   非 quickjs 构建行为一致）；
//! - 段评抓取请求的 HTTP 日志由 `legado-net` 统一采集点写入
//!   `legacy/http_log.rs` 存储（批11 起全量接线；本链**不再手工记录**，避免
//!   双记录。开关真源 `config:recordHttpLog`，经 FFI `setHttpLogRecording` 或
//!   服务启动回填写入 `legado_net::http_log` 运行期开关）；
//! - 抓取非 2xx 直接回错误 `HTTP {status} for {url}`（沿用 ffi review_api
//!   同款判定）；原版 OkHttp 不因状态码抛错，会把错误页交给解析器（登记）；
//! - POST 请求体解析失败文案为「数据格式错误: {serde 错误}」；原版透传
//!   Gson 异常 localizedMessage（无固定文案，登记）。

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderName, HeaderValue};
use axum::response::Response;
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};

use legado_core::models::{Book, BookChapter, BookSource};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::BookSourceRepository;
use legado_parser::review_rule_parser::{
    parse_detail_page_with, parse_reply_page_with, parse_summary_with, ReviewDetailItem,
};
use legado_parser::{AnalyzeUrl, RequestMethod};

use crate::handlers::web_book::server_deps;
use crate::state::AppState;

use super::source_api::{load_js_source_api_config, token_error_response};
use super::{origin_of, to_response, ReturnData};

/// 会话 TTL：2 小时（ReviewController.kt:705 `LEGACY_REVIEW_SESSION_TTL`）
const LEGACY_REVIEW_SESSION_TTL_MS: i64 = 2 * 60 * 60 * 1000;
/// legacy 脚本长度上限：64 KiB（ReviewController.kt:706 `MAX_LEGACY_REVIEW_SCRIPT`）
const MAX_LEGACY_REVIEW_SCRIPT: usize = 64 * 1024;
/// 详情分页游标容量（对齐 `detailCursors = LruCache(64)`）
const DETAIL_CURSOR_CAPACITY: usize = 64;
/// legacy 会话容量（对齐 `legacyReviewSessions = LruCache(16)`）
const LEGACY_SESSION_CAPACITY: usize = 16;
/// legacy 脚本求值超时（对齐桥接脚本 `run()` 的 120s 客户端超时，见模块注释）
#[cfg(feature = "quickjs")]
const LEGACY_REVIEW_EVAL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// serde_json 值 → QuickJS 绑定值（对象/数组递归；数字优先 i64）
#[cfg(feature = "quickjs")]
fn json_to_js_value(value: &serde_json::Value) -> legado_js::JsValue {
    use legado_js::JsValue;
    match value {
        serde_json::Value::Null => JsValue::Null,
        serde_json::Value::Bool(b) => JsValue::Bool(*b),
        serde_json::Value::Number(n) => n
            .as_i64()
            .map(JsValue::Int)
            .or_else(|| n.as_f64().map(JsValue::Number))
            .unwrap_or(JsValue::Null),
        serde_json::Value::String(s) => JsValue::String(s.clone()),
        serde_json::Value::Array(items) => {
            JsValue::Array(items.iter().map(json_to_js_value).collect())
        }
        serde_json::Value::Object(map) => JsValue::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), json_to_js_value(v)))
                .collect(),
        ),
    }
}

/// 会话/游标页载荷（openLegacyReview 拦截到的 showBrowser 页面）
#[derive(Debug, Clone, Default)]
pub struct LegacyBrowserPage {
    pub url: String,
    pub html: Option<String>,
    pub preload_js: Option<String>,
}

/// 详情分页游标值（对齐 `DetailCursor(context, page, url)`）
#[derive(Debug, Clone)]
pub struct DetailCursorState {
    pub book_url: String,
    pub chapter_index: i32,
    pub source_key: String,
    pub rule_hash: u64,
    pub paragraph_index: i32,
    pub paragraph_data: String,
    pub page: i32,
    pub url: String,
    /// LRU 时间戳（访问/写入时刷新）
    pub last_used: u64,
}

/// legacy 会话值（对齐 `LegacyReviewSession`）
#[derive(Debug, Clone)]
pub struct LegacyReviewSession {
    pub book_url: String,
    pub chapter_index: i32,
    pub source_key: String,
    pub nonce: String,
    pub page_url: String,
    pub page_html: String,
    pub preload_js: String,
    pub frame_origin: Option<String>,
    /// 过期时刻（Unix 毫秒）
    pub expires_at: i64,
}

/// 段评 legacy 共享状态（挂在 [`AppState`]，对齐 ReviewController 的两个
/// LruCache 成员；进程内有效，重启即失效——与原版内存态一致）
#[derive(Debug, Default)]
pub struct LegacyReviewShared {
    pub detail_cursors: HashMap<String, DetailCursorState>,
    pub legacy_sessions: HashMap<String, LegacyReviewSession>,
    lru_counter: u64,
}

impl LegacyReviewShared {
    /// 游标写入（容量满时淘汰最久未使用项）
    pub fn put_cursor(&mut self, id: String, mut state: DetailCursorState) {
        self.lru_counter += 1;
        state.last_used = self.lru_counter;
        if self.detail_cursors.len() >= DETAIL_CURSOR_CAPACITY
            && !self.detail_cursors.contains_key(&id)
        {
            if let Some(oldest) = self
                .detail_cursors
                .iter()
                .min_by_key(|(_, v)| v.last_used)
                .map(|(k, _)| k.clone())
            {
                self.detail_cursors.remove(&oldest);
            }
        }
        self.detail_cursors.insert(id, state);
    }

    /// 游标读取（命中刷新 LRU 时间戳）
    pub fn get_cursor(&mut self, id: &str) -> Option<DetailCursorState> {
        if let Some(state) = self.detail_cursors.get_mut(id) {
            self.lru_counter += 1;
            state.last_used = self.lru_counter;
            return Some(state.clone());
        }
        None
    }

    /// 会话写入（容量满时淘汰最久未使用项；此处以写入序近似——会话无读侧
    /// 刷新语义，对齐 LruCache put 淘汰）
    pub fn put_session(&mut self, id: String, session: LegacyReviewSession) {
        if self.legacy_sessions.len() >= LEGACY_SESSION_CAPACITY
            && !self.legacy_sessions.contains_key(&id)
        {
            // 淘汰最早过期者（写入时序即过期时序）
            if let Some(oldest) = self
                .legacy_sessions
                .iter()
                .min_by_key(|(_, v)| v.expires_at)
                .map(|(k, _)| k.clone())
            {
                self.legacy_sessions.remove(&oldest);
            }
        }
        self.legacy_sessions.insert(id, session);
    }

    /// 会话读取（过期即删，对齐 `getLegacyReviewSession`）
    pub fn get_session(&mut self, id: &str) -> Option<LegacyReviewSession> {
        let now = now_millis();
        let expired = self
            .legacy_sessions
            .get(id)
            .map(|s| s.expires_at <= now)
            .unwrap_or(false);
        if expired {
            self.legacy_sessions.remove(id);
            return None;
        }
        self.legacy_sessions.get(id).cloned()
    }
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 上下文（对齐 `ReviewContext(book, chapter, source)`）
struct ReviewContext {
    book: Book,
    chapter: BookChapter,
    source: Option<BookSource>,
}

// ─── 参数校验（对齐 requireParameter / requireInt / requireParagraphIndex） ──

fn require_parameter<'a>(
    params: &'a HashMap<String, String>,
    name: &str,
) -> Result<&'a str, String> {
    params
        .get(name)
        .map(|s| s.as_str())
        .ok_or_else(|| format!("参数 {name} 不能为空"))
}

fn require_int(params: &HashMap<String, String>, name: &str, minimum: i32) -> Result<i32, String> {
    let raw = require_parameter(params, name)?;
    let value: i32 = raw.parse().map_err(|_| format!("参数 {name} 无效"))?;
    if value < minimum {
        return Err(format!("参数 {name} 无效"));
    }
    Ok(value)
}

/// paraIndex 合法域：-1（本章热评）或 > 0（ReviewController.kt:685-691）
fn require_paragraph_index(params: &HashMap<String, String>) -> Result<i32, String> {
    let raw = require_parameter(params, "paraIndex")?;
    let value: i32 = raw.parse().map_err(|_| "参数 paraIndex 无效".to_string())?;
    if value == -1 || value > 0 {
        Ok(value)
    } else {
        Err("参数 paraIndex 无效".to_string())
    }
}

/// 上下文解析（对齐 `requireContext(parameters)` / `requireContext(url, index)`）
async fn require_context(
    state: &Arc<AppState>,
    book_url: &str,
    chapter_index: i32,
) -> Result<ReviewContext, String> {
    if book_url.trim().is_empty() {
        return Err("参数 url 不能为空".to_string());
    }
    if chapter_index < 0 {
        return Err("参数 index 无效".to_string());
    }
    let db = state.db.lock().await;
    let book = BookRepository::new(db.connection())
        .find_by_url(book_url)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未找到书籍".to_string())?;
    let chapter = BookChapterRepository::new(db.connection())
        .find_by_book_url_and_index(book_url, chapter_index)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "未找到章节".to_string())?;
    let source = BookSourceRepository::new(db.connection())
        .find_by_url(&book.origin)
        .map_err(|e| e.to_string())?;
    Ok(ReviewContext {
        book,
        chapter,
        source,
    })
}

/// GET 查询参数上下文：url 必填非空 + index 必填 int ≥ 0
async fn require_context_from_query(
    state: &Arc<AppState>,
    params: &HashMap<String, String>,
) -> Result<ReviewContext, String> {
    require_parameter(params, "url")?; // 缺参 → 参数 url 不能为空
    let book_url = params.get("url").cloned().unwrap_or_default();
    if book_url.trim().is_empty() {
        return Err("参数 url 不能为空".to_string());
    }
    let index = require_int(params, "index", 0)?;
    require_context(state, &book_url, index).await
}

// ─── 抓取链（AnalyzeUrl + server_deps 客户端 + HTTP 日志采集） ───────────────

/// 合并请求头：书源全局 header + AnalyzeUrl 解析头 + CookieJar 门控标记
/// （对齐 ffi `review_api.rs` 与 `web_book.rs` 同款合并次序）
fn merged_request_headers(
    source: &BookSource,
    analyze_url: &AnalyzeUrl,
) -> HashMap<String, String> {
    let source_headers: HashMap<String, String> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok())
        .unwrap_or_default();
    let mut headers = source_headers;
    headers.extend(analyze_url.headers().clone());
    legado_fetcher::web_book::apply_cookie_jar_marker(&mut headers, source);
    headers
}

/// 段评抓取：URL 规则 → AnalyzeUrl 解析 → 绝对化 → 请求 → （日志采集）→ 响应体
///
/// 返回 `(响应体, baseUrl)`；baseUrl 取重定向后的最终 URL（对齐
/// `analyzeUrl.url` 语义 + ffi base_url 回退）。
async fn fetch_review_body(
    state: &Arc<AppState>,
    source: &BookSource,
    url_rule: &str,
    variables: &HashMap<String, String>,
    page: i32,
    chapter_url: &str,
    stage: &str,
) -> Result<(String, String), String> {
    let analyze_url = AnalyzeUrl::parse(url_rule, variables, page).map_err(|e| e.to_string())?;
    let raw = analyze_url.url().to_string();
    if raw.is_empty() {
        return Err(format!("解析后段评{stage}URL 为空"));
    }
    let final_url = if chapter_url.trim().is_empty() {
        raw
    } else {
        AnalyzeUrl::get_absolute_url(chapter_url, &raw)
    };

    let headers = merged_request_headers(source, &analyze_url);
    let method = analyze_url.method().clone();
    let post_body = analyze_url.request_body().to_string();

    let deps = server_deps(state).map_err(|e| e.to_string())?;
    let client = &deps.client;
    // HTTP 日志由 legado-net 统一采集点（LegadoClient 出口）写入同一 ring，
    // 本链不再手工 record_*，避免双记录（单实现原则）；开关见模块注释。

    let outcome = match method {
        RequestMethod::Post => {
            client
                .post(&final_url, &post_body, Some(headers.clone()))
                .await
        }
        _ => client.get(&final_url, Some(headers.clone())).await,
    };

    match outcome {
        Ok(resp) => {
            if !resp.is_success() {
                return Err(format!("HTTP {} for {}", resp.status, final_url));
            }
            let base_url = if resp.url.is_empty() {
                final_url
            } else {
                resp.url.clone()
            };
            Ok((resp.body, base_url))
        }
        Err(e) => Err(format!("请求段评{stage}失败: {e}")),
    }
}

/// 段评规则 JS 执行器（`@js:` 规则求值；与 ffi `construct_analyzer` 同构：
/// 仅绑书源 tag、无 jsLib——同一解析语义）
fn review_rule_executor(source: &BookSource) -> Option<Arc<dyn legado_parser::JsExecutor>> {
    let analyzer = legado_fetcher::js_adapter::construct_analyzer_with_js_lib(
        String::new(),
        String::new(),
        &source.book_source_url,
        None,
    );
    analyzer.js_executor()
}

/// 规则哈希（对齐 Kotlin `rule.hashCode()` 的游标失效语义：规则内容变则游标失效）
fn rule_hash(rule: &legado_core::models::ReviewRule) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let serialized = serde_json::to_string(rule).unwrap_or_default();
    let mut hasher = DefaultHasher::new();
    serialized.hash(&mut hasher);
    hasher.finish()
}

/// JS 书源编排器（spawn_blocking 包裹同步 JS 求值，对齐 ffi webbook 模式）
async fn with_js_orchestrator<T, F>(source: &BookSource, task: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(
            &mut legado_js::js_source::js_source_book::JsSourceBookOrchestrator,
        ) -> legado_core::LegadoResult<T>
        + Send
        + 'static,
{
    let mut orchestrator = legado_fetcher::web_book::build_js_orchestrator(source)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "JS 书源 mainJs 为空，无法加载段评".to_string())?;
    tokio::task::spawn_blocking(move || task(&mut orchestrator))
        .await
        .map_err(|e| format!("JS 段评任务异常: {e}"))?
        .map_err(|e| e.to_string())
}

/// js_source_review 条目 → parser ReviewDetailItem（对齐 ffi `convert_js_review_items`
/// 单实现语义：JS 书源 content 内容协议已由 `legado-js` 按原版
/// `JsSourceReview.parseDetailItem` 解析，此处逐字段透传）
fn convert_js_review_items(
    items: Vec<legado_js::js_source::js_source_review::ReviewDetailItem>,
) -> Vec<ReviewDetailItem> {
    items
        .into_iter()
        .map(|it| ReviewDetailItem {
            id: it.id,
            avatar: it.avatar,
            name: it.name,
            reply_to_name: it.reply_to_name,
            badges: it.badges,
            content: Some(it.content),
            image_url: it.image_url,
            audio_url: it.audio_url,
            time: it.time,
            like_count: it.like_count,
            reply_count: it.reply_count,
            replies: convert_js_review_items(it.replies),
        })
        .collect()
}

// ─── ReviewPage 序列化（对齐 Kotlin @Keep ReviewPage：nextCursor null 省略） ──

fn review_page_value(
    items: Vec<ReviewDetailItem>,
    next_cursor: Option<String>,
    has_more: bool,
) -> Value {
    let mut map = serde_json::Map::new();
    map.insert(
        "items".to_string(),
        serde_json::to_value(&items).unwrap_or(Value::Array(Vec::new())),
    );
    if let Some(cursor) = next_cursor {
        map.insert("nextCursor".to_string(), Value::String(cursor));
    }
    map.insert("hasMore".to_string(), Value::Bool(has_more));
    Value::Object(map)
}

fn empty_summary() -> Value {
    json!({"counts": {}, "keys": {}})
}

fn summary_result_value(result: legado_parser::review_rule_parser::ReviewSummaryResult) -> Value {
    let counts: serde_json::Map<String, Value> = result
        .counts
        .into_iter()
        .map(|(k, v)| (k.to_string(), json!(v)))
        .collect();
    let keys: serde_json::Map<String, Value> = result
        .keys
        .into_iter()
        .map(|(k, v)| (k.to_string(), json!(v)))
        .collect();
    json!({"counts": counts, "keys": keys})
}

// ─── GET /getReviewSummary ──────────────────────────────────────────────────

/// GET `/getReviewSummary?url=&index=`（ReviewController.getSummary，:181-220）
///
/// 规则缺失/未启用/摘要规则不完整/书源缺失 → **空摘要成功响应**（非异常）。
pub async fn get_review_summary(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getReviewSummary";
    let outcome: Result<Value, String> = async {
        let context = require_context_from_query(&state, &params).await?;
        let Some(source) = context.source else {
            return Ok(empty_summary());
        };
        if source.is_js_source() {
            let book = context.book.clone();
            let chapter = context.chapter.clone();
            let summary =
                with_js_orchestrator(&source, move |o| o.get_review_summary(&book, &chapter))
                    .await?;
            return Ok(summary_result_value(
                legado_parser::review_rule_parser::ReviewSummaryResult {
                    counts: summary.counts.into_iter().collect(),
                    keys: summary.keys.into_iter().collect(),
                },
            ));
        }

        let Some(rule) = source.rule_review.as_ref() else {
            return Ok(empty_summary());
        };
        let summary_url = rule
            .review_summary_url
            .as_deref()
            .unwrap_or("")
            .trim()
            .to_string();
        let incomplete = !rule.enabled
            || summary_url.is_empty()
            || rule
                .summary_list_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
            || rule
                .summary_paragraph_index_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
            || rule
                .summary_count_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty();
        if incomplete {
            return Ok(empty_summary());
        }

        let chapter_url = context.chapter.url.clone();
        let (body, base_url) = fetch_review_body(
            &state,
            &source,
            &summary_url,
            &HashMap::new(),
            1,
            &chapter_url,
            "摘要",
        )
        .await?;
        let parsed = parse_summary_with(&body, rule, &base_url, review_rule_executor(&source))
            .map(summary_result_value)
            .unwrap_or_else(empty_summary);
        Ok(parsed)
    }
    .await;
    let rd = match outcome {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getReviewDetail ───────────────────────────────────────────────────

/// GET `/getReviewDetail?url=&index=&paraIndex=&paraData=&page=&cursor=`
/// （ReviewController.getDetail，:222-329）
pub async fn get_review_detail(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getReviewDetail";
    let outcome: Result<Value, String> = async {
        let context = require_context_from_query(&state, &params).await?;
        let source = context
            .source
            .as_ref()
            .ok_or_else(|| "未找到书源".to_string())?;
        let paragraph_index = require_paragraph_index(&params)?;
        let paragraph_data = params
            .get("paraData")
            .cloned()
            .unwrap_or_else(|| paragraph_index.to_string());
        let page = require_int(&params, "page", 1)?;

        if source.is_js_source() {
            if params
                .get("cursor")
                .map(|c| !c.trim().is_empty())
                .unwrap_or(false)
            {
                return Err("JavaScript 段评不使用分页游标".to_string());
            }
            let book = context.book.clone();
            let chapter = context.chapter.clone();
            let page_data = with_js_orchestrator(&source.clone(), move |o| {
                o.get_review_detail(&book, &chapter, paragraph_index, &paragraph_data, page)
            })
            .await?;
            let has_more = !page_data.items.is_empty()
                && page_data
                    .next_page_url
                    .as_deref()
                    .map(|s| !s.trim().is_empty())
                    .unwrap_or(false);
            return Ok(review_page_value(
                convert_js_review_items(page_data.items),
                None,
                has_more,
            ));
        }

        let rule = source
            .rule_review
            .as_ref()
            .ok_or_else(|| "段评规则未配置".to_string())?;
        if !rule.enabled {
            return Err("段评规则未启用".to_string());
        }
        if rule
            .detail_list_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty()
            || rule
                .detail_content_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
        {
            return Err("段评详情规则不完整".to_string());
        }
        let first_page_url = rule
            .review_detail_url
            .as_deref()
            .unwrap_or("")
            .trim()
            .to_string();
        if first_page_url.is_empty() {
            return Err("段评详情地址未配置".to_string());
        }
        let next_page_rule = rule
            .review_detail_next_page_url
            .as_deref()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());

        let context_hash = rule_hash(rule);
        let cursor = params
            .get("cursor")
            .map(|c| c.trim().to_string())
            .filter(|c| !c.is_empty());
        let detail_url = {
            // 游标表操作段（同步 Mutex，临界区无 await）
            let mut shared = state
                .legacy_review
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            if page == 1 {
                if cursor.is_some() {
                    return Err("首段评页不能使用分页游标".to_string());
                }
                first_page_url.clone()
            } else if next_page_rule.is_none() {
                return Err("当前段评规则没有更多页".to_string());
            } else {
                let state_cursor = cursor
                    .as_deref()
                    .and_then(|c| shared.get_cursor(c))
                    .ok_or_else(|| "段评分页面游标无效或已过期".to_string())?;
                let context_matches = state_cursor.book_url == context.book.book_url
                    && state_cursor.chapter_index == context.chapter.index
                    && state_cursor.source_key == source.book_source_url
                    && state_cursor.rule_hash == context_hash
                    && state_cursor.paragraph_index == paragraph_index
                    && state_cursor.paragraph_data == paragraph_data;
                if !context_matches || state_cursor.page != page {
                    return Err("段评分页面游标无效或已过期".to_string());
                }
                state_cursor.url.clone()
            }
        };

        let mut variables = HashMap::new();
        variables.insert("paraIndex".to_string(), paragraph_index.to_string());
        variables.insert("paraData".to_string(), paragraph_data.clone());
        variables.insert("page".to_string(), page.to_string());
        let chapter_url = context.chapter.url.clone();
        let (body, base_url) = fetch_review_body(
            &state,
            source,
            &detail_url,
            &variables,
            page,
            &chapter_url,
            "详情",
        )
        .await?;
        let result = parse_detail_page_with(
            &body,
            rule,
            next_page_rule.as_deref(),
            &base_url,
            review_rule_executor(source),
        );

        let next_cursor = result
            .next_page_url
            .clone()
            .filter(|_| !result.items.is_empty())
            .filter(|u| !u.trim().is_empty())
            .map(|next_url| {
                let id = uuid::Uuid::new_v4().to_string();
                let mut shared = state
                    .legacy_review
                    .lock()
                    .unwrap_or_else(|p| p.into_inner());
                shared.put_cursor(
                    id.clone(),
                    DetailCursorState {
                        book_url: context.book.book_url.clone(),
                        chapter_index: context.chapter.index,
                        source_key: source.book_source_url.clone(),
                        rule_hash: context_hash,
                        paragraph_index,
                        paragraph_data: paragraph_data.clone(),
                        page: page + 1,
                        url: next_url,
                        last_used: 0,
                    },
                );
                id
            });
        let has_more = !result.items.is_empty() && next_cursor.is_some();
        Ok(review_page_value(result.items, next_cursor, has_more))
    }
    .await;
    let rd = match outcome {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /getReviewReplies ──────────────────────────────────────────────────

/// GET `/getReviewReplies?url=&index=&paraIndex=&paraData=&reviewId=&page=`
/// （ReviewController.getReplies，:331-398）；规则/回复规则缺失 → 空页成功响应
pub async fn get_review_replies(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/getReviewReplies";
    let outcome: Result<Value, String> = async {
        let context = require_context_from_query(&state, &params).await?;
        let Some(source) = context.source.clone() else {
            return Ok(review_page_value(Vec::new(), None, false));
        };
        if source.is_js_source() {
            // JS 书源：原版走 `JsSourceReview.getReviewRepliesAwait`（可选函数
            // `getReviewReplies`，缺失/返回 null 时为空页）；我方由 legado-js
            // 编排器 `get_review_replies` 同型实现。参数校验顺序与原版一致。
            let paragraph_index = require_paragraph_index(&params)?;
            let paragraph_data = params
                .get("paraData")
                .cloned()
                .unwrap_or_else(|| paragraph_index.to_string());
            let review_id = require_parameter(&params, "reviewId")?.to_string();
            if review_id.trim().is_empty() {
                return Err("参数 reviewId 不能为空".to_string());
            }
            let page = require_int(&params, "page", 1)?;
            let book = context.book.clone();
            let chapter = context.chapter.clone();
            let items = with_js_orchestrator(&source, move |o| {
                o.get_review_replies(
                    &book,
                    &chapter,
                    paragraph_index,
                    &paragraph_data,
                    &review_id,
                    page,
                )
            })
            .await?;
            // 对齐原版 ReviewController.kt:331-345：hasMore = items.isNotEmpty()
            let has_more = !items.is_empty();
            return Ok(review_page_value(
                convert_js_review_items(items),
                None,
                has_more,
            ));
        }

        let Some(rule) = source.rule_review.clone() else {
            return Ok(review_page_value(Vec::new(), None, false));
        };
        let reply_url = rule
            .review_quote_url
            .as_deref()
            .unwrap_or("")
            .trim()
            .to_string();
        if reply_url.is_empty() {
            return Ok(review_page_value(Vec::new(), None, false));
        }
        if !rule.enabled
            || rule
                .reply_list_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
            || rule
                .reply_content_rule
                .as_deref()
                .unwrap_or("")
                .trim()
                .is_empty()
        {
            return Ok(review_page_value(Vec::new(), None, false));
        }
        let paragraph_index = require_paragraph_index(&params)?;
        let paragraph_data = params
            .get("paraData")
            .cloned()
            .unwrap_or_else(|| paragraph_index.to_string());
        let review_id = require_parameter(&params, "reviewId")?;
        if review_id.trim().is_empty() {
            return Err("参数 reviewId 不能为空".to_string());
        }
        let page = require_int(&params, "page", 1)?;

        let mut variables = HashMap::new();
        variables.insert("paraIndex".to_string(), paragraph_index.to_string());
        variables.insert("paraData".to_string(), paragraph_data);
        variables.insert("reviewId".to_string(), review_id.to_string());
        variables.insert("page".to_string(), page.to_string());
        let chapter_url = context.chapter.url.clone();
        let (body, base_url) = fetch_review_body(
            &state,
            &source,
            &reply_url,
            &variables,
            page,
            &chapter_url,
            "回复",
        )
        .await?;
        if body.trim().is_empty() {
            return Err("段评回复内容为空".to_string());
        }
        let items = parse_reply_page_with(&body, &rule, &base_url, review_rule_executor(&source))
            .map_err(|e| e.to_string())?;
        let has_more = !items.is_empty();
        Ok(review_page_value(items, None, has_more))
    }
    .await;
    let rd = match outcome {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── legacy 会话：openLegacyReview / runLegacyReview / legacyReviewPage ─────

#[derive(Debug, Deserialize)]
struct LegacyReviewOpenRequest {
    #[serde(default)]
    url: String,
    /// 原版默认 -1（ReviewController.kt:127）：缺省时 `requireContext`
    /// 以「参数 index 无效」拒绝，而非落到第 0 章
    #[serde(default = "default_legacy_review_index")]
    index: i32,
    #[serde(default)]
    src: String,
}

fn default_legacy_review_index() -> i32 {
    -1
}

#[derive(Debug, Deserialize)]
struct LegacyReviewRunRequest {
    #[serde(default)]
    id: String,
    #[serde(default)]
    script: String,
}

/// click 脚本白名单（ReviewController.kt:30-32 `legacyReviewClickPattern`）
fn legacy_review_click_matches(click: &str) -> bool {
    Regex::new(r"^(?:getDP\(\s*\d+\s*,\s*\d+\s*\)|getZP\(\s*\d+\s*\))$")
        .map(|re| re.is_match(click))
        .unwrap_or(false)
}

/// `AnalyzeUrl.paramPattern`（HttpServer 侧同款 `\s*,\s*(?=\{)`）提取 click 脚本
/// （ReviewController.kt:78-87 `parseLegacyReviewClickScript`）
///
/// Rust regex crate 不支持前瞻断言 → 改用 `\s*,\s*\{` 匹配并定位 `{` 起点，
/// 与 Kotlin `matcher.end()` 后 JSON 解析语义等价。
fn parse_legacy_review_click_script(src: &str) -> Option<String> {
    let pattern = Regex::new(r"\s*,\s*\{").ok()?;
    let matcher = pattern.find(src)?;
    let json_start = matcher.start() + matcher.as_str().rfind('{')?;
    let parsed: Value = serde_json::from_str(&src[json_start..]).ok()?;
    let click = parsed.get("click")?.as_str()?.trim().to_string();
    if legacy_review_click_matches(&click) {
        Some(click)
    } else {
        None
    }
}

/// HEIF 图片 URL 形态（ReviewController.kt:33 `legacyHeifUrlPattern`）
fn legacy_heif_url_matches(url: &str) -> bool {
    Regex::new(r"(?i)^https?://.*\.(?:heic|heif)(?:[?#].*|$)")
        .map(|re| re.is_match(url))
        .unwrap_or(false)
}

fn encode_legacy_review_query(value: &str) -> String {
    urlencoding::encode(value).into_owned()
}

fn escape_html_attribute(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// HEIF 图片代理重写（ReviewController.kt:39-52 `rewriteLegacyReviewImages`）
///
/// Rust regex crate 不支持反向引用 → 以「双引号/单引号」两个分支匹配属性值
/// （`(?:["]([^"]*)["]|[']([^']*)['])`），保留原引号形态，语义与 Kotlin
/// `(["'])(.*?)\2` 等价。
fn rewrite_legacy_review_images(html: &str, book_url: &str) -> String {
    let tag_pattern = Regex::new(r"(?is)<img\b[^>]*>").expect("img 标签正则编译失败");
    let attr_pattern =
        Regex::new(r#"(?i)(\b(?:src|data-src|data-original)\s*=\s*)(?:"([^"]*)"|'([^']*)')"#)
            .expect("img 属性正则编译失败");
    tag_pattern
        .replace_all(html, |caps: &regex::Captures| {
            let tag = &caps[0];
            attr_pattern
                .replace_all(tag, |attr_caps: &regex::Captures| {
                    let (raw, quote) = match (attr_caps.get(2), attr_caps.get(3)) {
                        (Some(v), _) => (v.as_str(), "\""),
                        (_, Some(v)) => (v.as_str(), "'"),
                        _ => return attr_caps[0].to_string(),
                    };
                    if !legacy_heif_url_matches(raw) {
                        return attr_caps[0].to_string();
                    }
                    let proxy = format!(
                        "/image?path={}&url={}&width=2048",
                        encode_legacy_review_query(raw),
                        encode_legacy_review_query(book_url)
                    );
                    format!(
                        "{}{}{}{}",
                        &attr_caps[1],
                        quote,
                        escape_html_attribute(&proxy),
                        quote
                    )
                })
                .into_owned()
        })
        .into_owned()
}

/// 结果重写（ReviewController.kt:54-67 `rewriteLegacyReviewResult`：JSON 对象含
/// 字符串 `html` 键时只重写该键，否则整串按 HTML 重写）
fn rewrite_legacy_review_result(result: &str, book_url: &str) -> String {
    match serde_json::from_str::<Value>(result) {
        Ok(Value::Object(mut json)) => {
            let rewritten = json
                .get("html")
                .and_then(|h| h.as_str())
                .map(|html| rewrite_legacy_review_images(html, book_url));
            if let Some(html) = rewritten {
                json.insert("html".to_string(), Value::String(html));
                return serde_json::to_string(&json).unwrap_or_else(|_| result.to_string());
            }
            rewrite_legacy_review_images(result, book_url)
        }
        _ => rewrite_legacy_review_images(result, book_url),
    }
}

/// legacy 脚本求值（对齐 `executeLegacyReviewScript` / `runLegacyReview` 的
/// `runScriptWithContext` 求值语义）
///
/// 求值环境：jsLib → 书源上下文 setup → mainJs → 目标脚本；绑定
/// `book` / `chapter` / `result`（`java` 为 QuickJS 宿主 API 全集，含
/// `showBrowser` → `ui_action_queue` 桥）。
#[cfg(feature = "quickjs")]
fn eval_legacy_review_script(
    source: &BookSource,
    setup_script: Option<String>,
    script: &str,
    book: &Book,
    chapter: &BookChapter,
    result: Option<&str>,
) -> Result<(String, Option<LegacyBrowserPage>), String> {
    use legado_js::engine::JsEngine;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::JsValue;

    let engine = legado_js::QuickJsEngine::new(SandboxConfig {
        max_execution_time: LEGACY_REVIEW_EVAL_TIMEOUT,
        allow_script_run: true,
        ..SandboxConfig::default()
    })
    .map_err(|e| e.to_string())?;

    // jsLib / setup / mainJs 预载（对齐源 JS 环境装配次序）
    if let Some(js_lib) = source.js_lib.as_deref() {
        if !js_lib.trim().is_empty() {
            engine.eval(js_lib).map_err(|e| e.to_string())?;
        }
    }
    if let Some(setup) = setup_script.as_deref() {
        if !setup.trim().is_empty() {
            engine.eval(setup).map_err(|e| e.to_string())?;
        }
    }
    if let Some(main_js) = source.main_js.as_deref() {
        if !main_js.trim().is_empty() {
            engine.eval(main_js).map_err(|e| e.to_string())?;
        }
    }

    let book_json = serde_json::to_value(book).map_err(|e| e.to_string())?;
    let chapter_json = serde_json::to_value(chapter).map_err(|e| e.to_string())?;
    // 对齐原版 Rhino 绑定：book/chapter 以对象暴露（脚本常态 `book.name` /
    // `chapter.title`），result 恒绑定（无值时 null，避免 ReferenceError）
    let bindings: Vec<(&str, JsValue)> = vec![
        ("book", json_to_js_value(&book_json)),
        ("chapter", json_to_js_value(&chapter_json)),
        (
            "result",
            result
                .map(|r| JsValue::String(r.to_string()))
                .unwrap_or(JsValue::Null),
        ),
    ];

    // 审查批4 P2-3：每次 legacy 脚本求值一个独立收集容器——HTTP 服务并发处理
    // `/openLegacyReview`、`/runLegacyReview`（以及与 App 侧 FFI 求值并发）互不
    // 串流；对齐原版每次求值新建 `LegacyReviewJsExtensions(source, onShowBrowser)`
    // 的局部回调生命周期（ReviewController.kt:471-487）。
    let (eval, collected) = legado_js::host_api::ui_action_queue::with_collect(|| {
        engine.eval_with_bindings(script, &bindings)
    });
    let actions = collected.actions;
    let output = eval.map_err(|e| e.to_string())?;

    // showBrowser 拦截：取最后一次 openBrowser 载荷（对齐 onShowBrowser 回调
    // 覆写语义 browserPage = it）
    let browser_page = actions
        .iter()
        .rfind(|a| a.get("action").and_then(|v| v.as_str()) == Some("openBrowser"))
        .map(|a| LegacyBrowserPage {
            url: a
                .get("url")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
            html: a
                .get("html")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            preload_js: a
                .get("preloadJs")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
        });
    Ok((output, browser_page))
}

/// 非 quickjs 构建：引擎占位错误（与既有非 quickjs 行为一致）
#[cfg(not(feature = "quickjs"))]
fn eval_legacy_review_script(
    _source: &BookSource,
    _setup_script: Option<String>,
    _script: &str,
    _book: &Book,
    _chapter: &BookChapter,
    _result: Option<&str>,
) -> Result<(String, Option<LegacyBrowserPage>), String> {
    Err("QuickJS engine not enabled. Build with --features quickjs".to_string())
}

/// POST `/openLegacyReview`（ReviewController.openLegacyReview，:400-436；令牌保护）
pub async fn open_legacy_review(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: String,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/openLegacyReview";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let outcome: Result<Value, String> = async {
        let request: LegacyReviewOpenRequest =
            serde_json::from_str(&body).map_err(|e| format!("数据格式错误: {e}"))?;
        let context = require_context(&state, &request.url, request.index).await?;
        let source = context
            .source
            .clone()
            .ok_or_else(|| "未找到书源".to_string())?;
        let click = parse_legacy_review_click_script(&request.src)
            .ok_or_else(|| "不是受支持的旧段评或章评链接".to_string())?;

        let setup_script = server_deps(&state)
            .ok()
            .and_then(|deps| deps.setup_script_for(&source));
        // JS 求值为同步阻塞 → spawn_blocking（对齐 runLegacyReview / MCP eval_js）
        let source_for_task = source.clone();
        let book = context.book.clone();
        let chapter = context.chapter.clone();
        let src = request.src.clone();
        let (output, browser_page) = tokio::task::spawn_blocking(move || {
            eval_legacy_review_script(
                &source_for_task,
                setup_script,
                &click,
                &book,
                &chapter,
                Some(&src),
            )
        })
        .await
        .map_err(|e| format!("旧评论脚本任务异常: {e}"))??;
        let page = browser_page.ok_or_else(|| "旧评论脚本未返回页面".to_string())?;
        let page_html = page
            .html
            .clone()
            .filter(|h| !h.trim().is_empty())
            .ok_or_else(|| "旧评论页面内容为空".to_string())?;
        let _ = output;

        let id = uuid::Uuid::new_v4().to_string();
        let nonce = uuid::Uuid::new_v4().to_string();
        let mut shared = state
            .legacy_review
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        shared.put_session(
            id.clone(),
            LegacyReviewSession {
                book_url: context.book.book_url.clone(),
                chapter_index: context.chapter.index,
                source_key: source.book_source_url.clone(),
                nonce: nonce.clone(),
                page_url: page.url.clone(),
                page_html: rewrite_legacy_review_images(&page_html, &context.book.book_url),
                preload_js: page.preload_js.unwrap_or_default(),
                frame_origin: origin.clone(),
                expires_at: now_millis() + LEGACY_REVIEW_SESSION_TTL_MS,
            },
        );
        drop(shared);
        Ok(json!({"id": id, "nonce": nonce}))
    }
    .await;
    let rd = match outcome {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, uri, origin.as_deref())
}

/// POST `/runLegacyReview`（ReviewController.runLegacyReview，:438-456；令牌保护）
pub async fn run_legacy_review(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: String,
) -> Response {
    let origin = origin_of(&headers);
    let uri = "/runLegacyReview";
    let config = load_js_source_api_config(&state).await;
    if !config.has_valid_token(&headers) {
        return token_error_response(uri, origin.as_deref());
    }
    let outcome: Result<Value, String> = async {
        let request: LegacyReviewRunRequest =
            serde_json::from_str(&body).map_err(|e| format!("数据格式错误: {e}"))?;
        if request.script.trim().is_empty()
            || request.script.encode_utf16().count() > MAX_LEGACY_REVIEW_SCRIPT
        {
            // 对齐 Kotlin `String.length`（UTF-16 code unit 计数）
            return Err("旧评论脚本为空或过长".to_string());
        }
        let session = {
            let mut shared = state
                .legacy_review
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            shared.get_session(&request.id)
        }
        .ok_or_else(|| "旧评论会话无效或已过期".to_string())?;

        let context = require_context(&state, &session.book_url, session.chapter_index).await?;
        let source = context
            .source
            .clone()
            .ok_or_else(|| "未找到书源".to_string())?;
        if source.book_source_url != session.source_key {
            return Err("书源已变更，请重新打开评论".to_string());
        }

        let setup_script = server_deps(&state)
            .ok()
            .and_then(|deps| deps.setup_script_for(&source));
        // JS 求值为同步阻塞 → spawn_blocking（对齐 MCP eval_js 模式）
        let source_for_task = source.clone();
        let book = context.book.clone();
        let chapter = context.chapter.clone();
        let script = request.script.clone();
        let (output, _) = tokio::task::spawn_blocking(move || {
            eval_legacy_review_script(
                &source_for_task,
                setup_script,
                &script,
                &book,
                &chapter,
                None,
            )
        })
        .await
        .map_err(|e| format!("旧评论脚本任务异常: {e}"))??;
        let result = if output.is_empty() || output == "null" || output == "undefined" {
            return Err("旧评论脚本未返回结果".to_string());
        } else {
            output
        };
        Ok(Value::String(rewrite_legacy_review_result(
            &result,
            &session.book_url,
        )))
    }
    .await;
    let rd = match outcome {
        Ok(value) => ReturnData::success(value),
        Err(msg) => ReturnData::error(msg),
    };
    to_response(&rd, uri, origin.as_deref())
}

// ─── GET /legacyReviewPage（HTML 响应，非 ReturnData） ──────────────────────

/// 资源策略（HttpServer.kt:239-245 `LEGACY_REVIEW_RESOURCE_POLICY`）
const LEGACY_REVIEW_RESOURCE_POLICY: &str = "default-src 'none'; \
script-src 'unsafe-inline' 'unsafe-eval'; \
style-src 'unsafe-inline'; img-src http: https: data: blob:; \
media-src http: https: data: blob:; font-src http: https: data:; \
connect-src 'none'; object-src 'none'; base-uri http: https:; \
form-action 'none'";

/// frame-ancestors 推导（HttpServer.kt:312-324 `allowedFrameAncestor`）
///
/// 逐条对齐 `java.net.URI` 校验：scheme 仅 http/https、rawAuthority 非空、
/// rawUserInfo 为空、rawPath/rawQuery/rawFragment 均不存在（注意 `http://h/`
/// 的 rawPath 为 `/` 非空 → 原版回 `'self'`）；URI 解析失败（非法端口/主机）
/// 同样回 `'self'`。合法时原样返回 `scheme://authority`。
fn allowed_frame_ancestor(origin: Option<&str>) -> String {
    let Some(origin) = origin else {
        return "'self'".to_string();
    };
    let Some((scheme, rest)) = origin.split_once("://") else {
        return "'self'".to_string();
    };
    if !matches!(scheme, "http" | "https") {
        return "'self'".to_string();
    }
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    if authority.is_empty() || rest.len() != authority.len() {
        return "'self'".to_string();
    }
    // 交给 url 解析器做 URI 合法性校验（非法端口/主机/用户信息 → 'self'）
    let Ok(uri) = url::Url::parse(&format!("{scheme}://{authority}")) else {
        return "'self'".to_string();
    };
    if !uri.username().is_empty() || uri.password().is_some() {
        return "'self'".to_string();
    }
    format!("{scheme}://{authority}")
}

/// 桥接脚本注入（ReviewController.kt:501-646 `injectLegacyReviewBridge` 的
/// 忠实移植；nonce/bookUrl/preloadJs 经 JSON 转义后内插，`<` 转 `\u003c`）
fn inject_legacy_review_bridge(
    nonce: &str,
    book_url: &str,
    page_url: &str,
    page_html: &str,
    preload_js: &str,
) -> String {
    let nonce_json = serde_json::to_string(nonce).unwrap_or_else(|_| "\"\"".to_string());
    let book_url_json = serde_json::to_string(book_url)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('<', "\\u003c");
    let preload_json = serde_json::to_string(preload_js)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('<', "\\u003c");
    let bridge = format!(
        r#"<script>
(() => {{
  const nativeSetInterval = window.setInterval.bind(window);
  window.setInterval = (callback, delay, ...args) =>
    nativeSetInterval(callback, Math.max(100, Number(delay) || 0), ...args);
  const nonce = {nonce_json};
  const bookUrl = {book_url_json};
  const heifPattern = /\.(?:heic|heif)(?:[?#]|$)/i;
  const isProxyImageUrl = raw => {{
    try {{
      const target = new URL(String(raw || ''), window.location.href);
      return target.pathname === '/image' &&
        target.searchParams.has('path') && target.searchParams.has('url');
    }} catch (_) {{
      return false;
    }}
  }};
  const proxyImageUrl = raw => {{
    const value = String(raw || '');
    if (isProxyImageUrl(value) || !/^https?:/i.test(value) || !heifPattern.test(value)) {{
      return value;
    }}
    try {{
      const target = new URL('/image', window.location.href);
      target.searchParams.set('path', value);
      target.searchParams.set('url', bookUrl);
      target.searchParams.set('width', '2048');
      return target.toString();
    }} catch (_) {{
      return value;
    }}
  }};
  const rewriteImage = image => {{
    if (!(image instanceof HTMLImageElement)) return;
    const dataOriginal = image.getAttribute('data-original') ||
      image.getAttribute('data-src') || '';
    const current = image.getAttribute('src') || '';
    const storedOriginal = image.getAttribute('data-legado-original-src') || '';
    const raw = storedOriginal ||
      (heifPattern.test(dataOriginal) ? dataOriginal :
        heifPattern.test(current) ? current : dataOriginal || current);
    const proxied = proxyImageUrl(raw);
    if (proxied === raw) return;
    if (!storedOriginal) image.setAttribute('data-legado-original-src', raw);
    if (image.getAttribute('data-original') !== proxied)
      image.setAttribute('data-original', proxied);
    if (current !== proxied) image.setAttribute('src', proxied);
  }};
  const rewriteImages = root => {{
    if (!root) return;
    rewriteImage(root);
    root.querySelectorAll?.('img').forEach(rewriteImage);
  }};
  const observeImages = () => {{
    const root = document.documentElement;
    if (!root) {{
      document.addEventListener('DOMContentLoaded', observeImages, {{once: true}});
      return;
    }}
    rewriteImages(document);
    new MutationObserver(records => records.forEach(record => {{
      record.addedNodes.forEach(node => rewriteImages(node));
      if (record.type === 'attributes') rewriteImage(record.target);
    }})).observe(root, {{
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'data-src', 'data-original']
    }});
  }};
  observeImages();
  const finishLoading = () =>
    document.getElementById('loading')?.classList.add('hidden');
  const showError = error => {{
    const message = String(error || '评论加载失败');
    finishLoading();
    const viewer = document.getElementById('viewer');
    if (viewer) viewer.textContent = message;
    return new Error(message);
  }};
  window.run = async function(code) {{
    return new Promise((resolve, reject) => {{
      const channel = new MessageChannel();
      const timeout = window.setTimeout(() => {{
        reject(showError('评论加载超时'));
        channel.port1.close();
      }}, 120000);
      channel.port1.onmessage = event => {{
        window.clearTimeout(timeout);
        if (event.data?.error || event.data?.result == null) {{
          reject(showError(event.data?.error));
        }} else {{
          finishLoading();
          resolve(String(event.data.result));
        }}
        channel.port1.close();
      }};
      channel.port1.onmessageerror = () => {{
        window.clearTimeout(timeout);
        reject(showError('评论响应解析失败'));
        channel.port1.close();
      }};
      window.parent.postMessage({{
        type: 'legado-legacy-review-run',
        nonce,
        script: String(code)
      }}, '*', [channel.port2]);
    }});
  }};
  document.addEventListener('click', event => {{
    const image = event.target;
    if (!(image instanceof HTMLImageElement)) return;
    const src = image.currentSrc || image.src;
    if (!src) return;
    window.parent.postMessage({{
      type: 'legado-legacy-review-image',
      nonce,
      src
    }}, '*');
  }}, true);
  window.java = {{ upConfig() {{}} }};
  const preload = {preload_json};
  if (preload) (0, eval)(preload);
}});
</script>"#
    );
    let base = if page_url.trim().is_empty() {
        String::new()
    } else {
        format!("<base href=\"{}\">", escape_html_attribute(page_url))
    };
    let injection = format!("{base}{bridge}");
    // 注意：必须用 `to_ascii_lowercase`——`to_lowercase` 会在部分非 ASCII 字符
    // （如 U+0130 `İ` → `i` + 组合点）上改变 UTF-8 字节长度，用其 find 结果去
    // 切原串会落在非字符边界而 panic；`<head` 全为 ASCII，二者判定等价。
    let head_index = page_html.to_ascii_lowercase().find("<head");
    if let Some(head_index) = head_index {
        if let Some(head_end) = page_html[head_index..].find('>') {
            let end = head_index + head_end + 1;
            return format!("{}{}{}", &page_html[..end], injection, &page_html[end..]);
        }
    }
    format!("{injection}{page_html}")
}

/// meta CSP 注入（HttpServer.kt:284-291 `legacyReviewPageResponse` 的
/// protectedHtml 包装）
fn inject_meta_csp(html: &str) -> String {
    let meta = format!(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"{LEGACY_REVIEW_RESOURCE_POLICY}\">"
    );
    let lower = html.to_ascii_lowercase();
    let Some(head_index) = lower.find("<head") else {
        return format!("{meta}{html}");
    };
    let Some(head_end_rel) = html[head_index..].find('>') else {
        return format!("{meta}{html}");
    };
    let head_end = head_index + head_end_rel + 1;
    format!("{}{}{}", &html[..head_end], meta, &html[head_end..])
}

/// GET `/legacyReviewPage?id=&nonce=`（HttpServer.kt:115-120/:280-310）
///
/// 命中 → 200 `text/html; charset=utf-8`（注入桥接 + meta CSP）；未命中/过期/
/// nonce 不符 → 404 text/plain「旧评论会话无效或已过期」。
pub async fn legacy_review_page(
    State(state): State<Arc<AppState>>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
) -> Response {
    let origin = origin_of(&headers);

    let id = params.get("id").map(|s| s.trim()).filter(|s| !s.is_empty());
    let nonce = params
        .get("nonce")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());
    let page = match (id, nonce) {
        (Some(id), Some(nonce)) => {
            let mut shared = state
                .legacy_review
                .lock()
                .unwrap_or_else(|p| p.into_inner());
            shared
                .get_session(id)
                .filter(|s| s.nonce == nonce)
                .map(|s| {
                    let html = inject_legacy_review_bridge(
                        &s.nonce,
                        &s.book_url,
                        &s.page_url,
                        &s.page_html,
                        &s.preload_js,
                    );
                    (html, s.frame_origin)
                })
        }
        _ => None,
    };

    let (mut resp, frame_origin) = match page {
        Some((html, frame_origin)) => {
            let protected = inject_meta_csp(&html);
            let resp = Response::builder()
                .status(axum::http::StatusCode::OK)
                .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
                .body(axum::body::Body::from(protected))
                .expect("legacyReviewPage 响应构建失败");
            (resp, frame_origin)
        }
        None => {
            let resp = Response::builder()
                .status(axum::http::StatusCode::NOT_FOUND)
                .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(axum::body::Body::from("旧评论会话无效或已过期"))
                .expect("legacyReviewPage 404 构建失败");
            (resp, None)
        }
    };
    // 对齐原版 `apply { addWebHeaders + Cache-Control + Referrer-Policy + CSP }`：
    // 404 亦带全套头（page 为 null → frame-ancestors 'self'）
    resp.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    resp.headers_mut().insert(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    resp.headers_mut().insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_str(&format!(
            "sandbox allow-scripts allow-modals; {LEGACY_REVIEW_RESOURCE_POLICY}; frame-ancestors {}",
            allowed_frame_ancestor(frame_origin.as_deref())
        ))
        .unwrap_or(HeaderValue::from_static("sandbox")),
    );
    super::web_headers_for_legacy_page(&mut resp, origin.as_deref());
    resp
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── frame-ancestors（对齐 java.net.URI 校验） ─────────────────────────

    #[test]
    fn test_allowed_frame_ancestor_matches_uri_semantics() {
        assert_eq!(allowed_frame_ancestor(None), "'self'");
        assert_eq!(
            allowed_frame_ancestor(Some("http://127.0.0.1:1122")),
            "http://127.0.0.1:1122"
        );
        assert_eq!(
            allowed_frame_ancestor(Some("https://web.example.com")),
            "https://web.example.com"
        );
        // 带路径（含仅 "/"）/查询/片段 → 'self'（Java rawPath 非空）
        assert_eq!(allowed_frame_ancestor(Some("http://h/")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://h/a")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://h?a=1")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://h#f")), "'self'");
        // scheme 非 http(s) / 用户信息 / 非法端口 / 空 authority → 'self'
        assert_eq!(allowed_frame_ancestor(Some("ftp://h")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://u:p@h")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://h:notaport")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("http://")), "'self'");
        assert_eq!(allowed_frame_ancestor(Some("not-an-origin")), "'self'");
        // 大写 scheme 与原版严格比较一致 → 'self'
        assert_eq!(allowed_frame_ancestor(Some("HTTP://h")), "'self'");
    }

    // ─── HEIF 图片代理重写 / HTML 属性转义 ────────────────────────────────

    #[test]
    fn test_rewrite_legacy_review_images_heif_only() {
        let html = r#"<img src="https://a.com/x.heic?q=1"><img src="https://a.com/y.jpg"><img data-src="https://a.com/z.heif">"#;
        let out = rewrite_legacy_review_images(html, "https://src.example.com/book/1");
        assert!(out.contains("/image?path=https%3A%2F%2Fa.com%2Fx.heic%3Fq%3D1"));
        // 属性值整串经 escapeHtmlAttribute → `&` 转 `&amp;`（对齐原版）
        assert!(out.contains("&amp;url=https%3A%2F%2Fsrc.example.com%2Fbook%2F1&amp;width=2048"));
        assert!(
            out.contains(r#"<img src="https://a.com/y.jpg">"#),
            "非 heif 不改写"
        );
        assert!(out.contains("data-src=\"/image?path="), "data-src 亦改写");
    }

    #[test]
    fn test_rewrite_legacy_review_result_object_html_key() {
        let result = r#"{"html":"<img src=\"https://a.com/1.heic\">","ok":true}"#;
        let out = rewrite_legacy_review_result(result, "book");
        let parsed: Value = serde_json::from_str(&out).unwrap();
        let html = parsed["html"].as_str().unwrap();
        assert!(html.contains("/image?path="), "对象 html 键应改写：{out}");
        assert_eq!(parsed["ok"], Value::Bool(true), "其他键保留");

        // 非对象 → 整串按 HTML 改写
        let out = rewrite_legacy_review_result("<img src='https://a.com/1.heic'>", "book");
        assert!(out.contains("/image?path="), "整串 HTML 应改写：{out}");
    }

    // ─── click 脚本白名单 / src 解析 ─────────────────────────────────────

    #[test]
    fn test_parse_legacy_review_click_script_whitelist() {
        // 原版 src 形如 `...函数调用...,{"click":"getDP(1,2)"}`（paramPattern
        // 取 `,{` 之后的 JSON 对象）
        assert_eq!(
            parse_legacy_review_click_script(r#"clickCb(), {"click":" getDP( 1 , 2 ) "}"#)
                .as_deref(),
            Some("getDP( 1 , 2 )")
        );
        assert_eq!(
            parse_legacy_review_click_script(r#"cb(),{"click":"getZP(3)"}"#).as_deref(),
            Some("getZP(3)")
        );
        // 非白名单 / JSON 非法 / 缺键 / 无 `,{` 分隔 → None
        assert!(parse_legacy_review_click_script(r#"cb(),{"click":"alert(1)"}"#).is_none());
        assert!(parse_legacy_review_click_script("not-a-json").is_none());
        assert!(parse_legacy_review_click_script(r#"cb(),{"other":"getDP(1,2)"}"#).is_none());
        assert!(parse_legacy_review_click_script(r#"{"click":"getDP(1,2)"}"#).is_none());
    }

    // ─── meta CSP 注入 ───────────────────────────────────────────────────

    #[test]
    fn test_inject_meta_csp_inserts_after_head_open() {
        let html = "<html><head><title>t</title></head><body></body></html>";
        let out = inject_meta_csp(html);
        let head_end = out.find("<head>").unwrap() + "<head>".len();
        assert!(
            out[head_end..].starts_with("<meta http-equiv=\"Content-Security-Policy\""),
            "meta 应紧跟 <head>：{out}"
        );
        let no_head = inject_meta_csp("<div>x</div>");
        assert!(no_head.starts_with("<meta http-equiv=\"Content-Security-Policy\""));
    }

    // ─── 会话槽 / TTL / 游标容量 ─────────────────────────────────────────

    fn session(expires_at: i64) -> LegacyReviewSession {
        LegacyReviewSession {
            book_url: "book".into(),
            chapter_index: 0,
            source_key: "src".into(),
            nonce: "n".into(),
            page_url: String::new(),
            page_html: "<html></html>".into(),
            preload_js: String::new(),
            frame_origin: None,
            expires_at,
        }
    }

    #[test]
    fn test_session_expiry_and_capacity() {
        let mut shared = LegacyReviewShared::default();
        let now = now_millis();
        // 过期会话读取即删除
        shared.put_session("old".into(), session(now - 1));
        assert!(shared.get_session("old").is_none());
        assert!(shared.legacy_sessions.is_empty());

        // 容量 16：第 17 个写入淘汰最早过期者
        for i in 0..LEGACY_SESSION_CAPACITY {
            shared.put_session(format!("s{i}"), session(now + 1000 + i as i64));
        }
        assert_eq!(shared.legacy_sessions.len(), LEGACY_SESSION_CAPACITY);
        shared.put_session("new".into(), session(now + 999_999));
        assert_eq!(shared.legacy_sessions.len(), LEGACY_SESSION_CAPACITY);
        assert!(
            !shared.legacy_sessions.contains_key("s0"),
            "最早过期者应被淘汰"
        );
        assert!(shared.legacy_sessions.contains_key("new"));
    }

    #[test]
    fn test_detail_cursor_capacity_and_lru_refresh() {
        let mut shared = LegacyReviewShared::default();
        let cursor = |url: &str| DetailCursorState {
            book_url: "book".into(),
            chapter_index: 0,
            source_key: "src".into(),
            rule_hash: 1,
            paragraph_index: 1,
            paragraph_data: "1".into(),
            page: 2,
            url: url.into(),
            last_used: 0,
        };
        for i in 0..DETAIL_CURSOR_CAPACITY {
            shared.put_cursor(format!("c{i}"), cursor("u"));
        }
        assert_eq!(shared.detail_cursors.len(), DETAIL_CURSOR_CAPACITY);
        // 访问 c0 刷新时间戳后写入第 65 个 → 淘汰 c1（最久未使用）
        assert_eq!(
            shared.get_cursor("c0").map(|c| c.url),
            Some("u".to_string())
        );
        shared.put_cursor("c-new".into(), cursor("u2"));
        assert_eq!(shared.detail_cursors.len(), DETAIL_CURSOR_CAPACITY);
        assert!(
            shared.detail_cursors.contains_key("c0"),
            "刚访问过不应被淘汰"
        );
        assert!(
            !shared.detail_cursors.contains_key("c1"),
            "最久未使用者应被淘汰"
        );
        assert!(shared.detail_cursors.contains_key("c-new"));
    }

    // ─── P1-1：JS 书源条目转换透传 replyToName（及内容协议其余字段） ────────

    #[test]
    fn test_convert_js_review_items_passthrough_protocol_fields() {
        let json = r#"{
            "items": [
                {"id": "c1", "name": "用户A",
                 "content": "{\"text\":\"回复内容\",\"replyToName\":\"楼主\",\"img\":\"/i.png\",\"time\":\"昨天\",\"likeCount\":3,\"replyCount\":1}",
                 "replies": [
                    {"id": "r1", "name": "用户B",
                     "content": "{\"text\":\"同意\",\"replyToName\":\"用户A\"}"}
                 ]}
            ]
        }"#;
        let page = legado_js::js_source::js_source_review::JsSourceReview::parse_detail_page(
            json,
            "http://example.com",
        )
        .unwrap();
        let converted = convert_js_review_items(page.items);
        assert_eq!(converted.len(), 1);
        assert_eq!(converted[0].content.as_deref(), Some("回复内容"));
        assert_eq!(converted[0].reply_to_name.as_deref(), Some("楼主"));
        assert_eq!(
            converted[0].image_url.as_deref(),
            Some("http://example.com/i.png")
        );
        assert_eq!(converted[0].time.as_deref(), Some("昨天"));
        assert_eq!(converted[0].like_count, Some(3));
        assert_eq!(converted[0].reply_count, Some(1));
        assert_eq!(converted[0].replies.len(), 1);
        assert_eq!(
            converted[0].replies[0].reply_to_name.as_deref(),
            Some("用户A")
        );
        // 序列化键名与原版 GSON camelCase 契约一致
        let value = serde_json::to_value(&converted[0]).unwrap();
        assert_eq!(value["replyToName"], "楼主");
    }

    // ─── P2：`to_lowercase` 字节下标切串 panic 回归（含 `İ`） ──────────────

    /// `İ`（U+0130）小写展开为 `i` + 组合点（2 字节 → 3 字节），
    /// 旧 `to_lowercase().find("<head")` 的字节下标会落到原串非字符边界。
    #[test]
    fn test_inject_bridge_handles_dotless_capital_i() {
        // 7 个 İ（小写侧多出 7 字节）后接 <head> 与多字节字符：
        // 旧实现下标 21 落在 `中` 的 UTF-8 中间（panic）；新实现无 panic 且位置正确。
        let page_html = format!("{}<head>中</head>", "İ".repeat(7));
        let out = inject_legacy_review_bridge("n", "book", "", &page_html, "");
        assert!(
            out.starts_with(&format!("{}<head><script>", "İ".repeat(7))),
            "桥接脚本应紧跟 <head> 注入：{out}"
        );
        // meta CSP 注入同一路径
        let out = inject_meta_csp(&page_html);
        assert!(
            out.starts_with(&format!("{}<head><meta http-equiv", "İ".repeat(7))),
            "meta 应紧跟 <head> 注入：{out}"
        );
    }
}
