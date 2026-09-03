//! 搜索 API
//!
//! 提供跨书源并行搜索能力，通过 legado-net 发起 HTTP 请求，
//! 使用 legado-parser 的 AnalyzeUrl + AnalyzeRule 解析搜索结果。

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use futures::StreamExt;

use legado_core::models::{BookSource, SearchBook as CoreSearchBook};
use legado_core::source_matcher::SearchCandidate;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::read_record_repository::decode_read_record_authors;
use legado_db::ReadRecordRepository;
use legado_net::LegadoClient;
use legado_parser::{AnalyzeUrl, RequestMethod};

use crate::api::source as source_api;
use crate::runtime;

/// 搜索会话级取消/暂停令牌（P0-3：由全局静态改为会话级，隔离重叠搜索）
///
/// 每次搜索创建独立会话；旧搜索的在飞任务持有自己的令牌引用，新搜索启动
/// 不再重置旧会话的取消状态 —— 消除「旧搜索残留」（此前全局 `SEARCH_CANCELLED`
/// 被新搜索重置，导致已取消搜索的在飞任务复活并污染后续搜索）。
#[derive(Debug)]
pub(crate) struct SearchSession {
    /// 取消标志：停止 / 页面销毁 / sink 关闭 / 新搜索取代均置位以终止本会话
    pub cancel: Arc<AtomicBool>,
    /// 暂停标志（软挂起：仅拦未派发书源，已派发任务继续完成）
    /// 对齐原版 `SearchModel` workingState 门控语义（批次B G-B-04）。
    pub paused: Arc<AtomicBool>,
}

impl SearchSession {
    fn new() -> Self {
        Self {
            cancel: Arc::new(AtomicBool::new(false)),
            paused: Arc::new(AtomicBool::new(false)),
        }
    }
}

/// 当前活跃搜索会话（供无参 FFI `cancel_search`/`pause_search`/`resume_search` 定位）
///
/// 新搜索启动时取代并取消上一会话；`std::sync::Mutex` 仅短暂持有、不跨 await。
static CURRENT_SEARCH_SESSION: std::sync::Mutex<Option<Arc<SearchSession>>> =
    std::sync::Mutex::new(None);

/// 注册当前会话：先取消上一会话（若存在且不同），再置为本会话（新搜索取代旧搜索）
fn register_current_session(session: &Arc<SearchSession>) {
    let mut guard = CURRENT_SEARCH_SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(prev) = guard.as_ref() {
        if !Arc::ptr_eq(prev, session) {
            prev.cancel.store(true, Ordering::SeqCst); // 新搜索取代 → 终止旧会话，防残留
        }
    }
    *guard = Some(Arc::clone(session));
}

/// 取当前会话（无参 FFI 定位目标）
fn current_session() -> Option<Arc<SearchSession>> {
    CURRENT_SEARCH_SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

/// 判断给定会话是否仍为当前会话（Arc::ptr_eq；供取消/持久化前复检，防旧会话残留写入）
fn is_current_session(session: &Arc<SearchSession>) -> bool {
    matches!(CURRENT_SEARCH_SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner()).as_ref(), Some(cur) if Arc::ptr_eq(cur, session))
}

/// 若当前会话仍是给定会话则清除（防 A 的清理误清已启动的 B；三入口所有退出路径调用）
fn clear_current_session_if_same(session: &Arc<SearchSession>) {
    let mut guard = CURRENT_SEARCH_SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(cur) = guard.as_ref() {
        if Arc::ptr_eq(cur, session) {
            *guard = None;
        }
    }
}

/// 多源搜索并发上限
///
/// 对齐原版 `SearchModel` **有效并发**语义：`mapParallelSafe(AppConfig.threadCount)`，
/// threadCount 默认 32（用户可配置）。原版的固定线程池 `min(threadCount, MAX_THREAD=9)`
/// 只限制执行协程的线程数——OkHttp 异步 I/O 等待响应时不占线程，故真实并发搜索数
/// = threadCount（32），而非线程池大小。2026-08-25 实测对比（快速组 219/236 源）：
/// 原版 ~100s 收敛 vs 本引擎 335–352s，根因即并发数差异。
pub(crate) const SEARCH_CONCURRENCY: usize = 32;

/// 单源搜索超时（对齐原版 `SearchModel` `withTimeout(30000)`）
pub(crate) const SEARCH_SOURCE_TIMEOUT: Duration = Duration::from_secs(30);

// 注：曾试验「CPU 阶段限流 9 并发」信号量（对齐原版 MAX_THREAD=9）——B8 实测对超时
// 零改善（ok=49/128 超时），根因实为规则编译正则逐次重建 + 列表字段重复解析
// （2026-08-27 探针定位，已修），限流遂撤销：单源 CPU 工作降至毫秒级后无争用必要。

/// 搜索结果项
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 书籍名称
    pub book_name: String,
    /// 作者
    pub author: String,
    /// 详情页 URL
    pub book_url: String,
    /// 最新章节
    pub latest_chapter: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 分类标签（对齐原版 ruleSearch.kind 解析，逗号分隔多标签）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 字数展示文本（对齐原版 ruleSearch.wordCount + `wordCountFormat`）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    /// BookType 位标志（对齐原版 `bookSource.getBookType()`，源级多媒体类型）
    #[serde(default)]
    pub book_type: i32,
    /// 书源手动排序编号（对齐原版 BookList.kt:215 originOrder = customOrder；[P0-2 S4] 此前 DTO 转换恒写 0）
    #[serde(default, rename = "originOrder")]
    pub origin_order: i32,
    /// 是否有阅读记录（对齐上游 `SearchViewModel.hasReadRecord`，
    /// 加法式字段：无记录时恒为 false）
    #[serde(default, rename = "hasReadRecord")]
    pub has_read_record: bool,
    /// 阅读记录中的作者信息（仅在有阅读记录时附加，
    /// 多作者以顿号连接；无记录时缺省）
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "readRecordAuthor"
    )]
    pub read_record_author: Option<String>,
    /// 规则变量 JSON（换源 T5，2026-09-03）：搜索元素级解析期间 `@put`/
    /// `putVariable` 级联导出，随候选进入换源（对齐原版 SearchBook.toBook
    /// 复制 variable 语义，SearchBook.kt:134）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
}

// ─── WebSourceSearcher ────────────────────────────────────────────────────────

/// 真实的网络书源搜索器
///
/// 使用 AnalyzeUrl 构建请求、LegadoClient 发送请求、AnalyzeRule 解析结果。
/// 实现 `SourceSearcher` trait 以接入 `MultiSourceSearcher` 并行框架。
pub struct WebSourceSearcher {
    client: LegadoClient,
}

impl WebSourceSearcher {
    pub fn new(client: LegadoClient) -> Self {
        Self { client }
    }
}

impl legado_core::SourceSearcher for WebSourceSearcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        max_results: usize,
    ) -> Vec<SearchCandidate> {
        let precision = crate::api::config_api::get_config("precisionSearch")
            .map(|v| v == "true")
            .unwrap_or(false);
        match search_single_source(&self.client, source, query, 1, precision).await {
            Ok(results) => results
                .into_iter()
                .take(max_results)
                .map(|r| SearchCandidate {
                    source_url: r.source_url,
                    source_name: r.source_name,
                    book_url: r.book_url,
                    book_name: r.book_name,
                    author: r.author,
                    latest_chapter: r.latest_chapter,
                    word_count: r.word_count,
                    chapter_word_count_text: None,
                    chapter_word_count: -1,
                    respond_time: -1,
                    origin_order: source.custom_order,
                    book_score: 0,
                    variable: r.variable,
                })
                .collect(),
            Err(_) => Vec::new(),
        }
    }
}

// ─── 公共 API ─────────────────────────────────────────────────────────────────

/// 搜索书籍（同步包装，内部使用 tokio runtime 执行异步 HTTP 请求）
///
/// `keyword` — 搜索关键词
/// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
pub fn search_books(keyword: &str, source_urls_json: &str) -> LegadoResult<Vec<SearchResult>> {
    // 获取待搜索的书源
    let sources = load_search_sources(source_urls_json)?;
    if sources.is_empty() {
        return Ok(Vec::new());
    }
    let precision = crate::api::config_api::get_config("precisionSearch")
        .map(|v| v == "true")
        .unwrap_or(false);

    // 限流并发 + 单源超时 + 异常隔离（对齐原版 SearchModel 线程池语义），
    // 逐源完成后累积结果；失败源跳过不阻断整体。
    let keyword_owned = keyword.to_string();
    // P0-3：为本次搜索创建独立会话（取代并取消上一会话），不再重置全局标志
    let session = Arc::new(SearchSession::new());
    register_current_session(&session);
    let mut results = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        let mut all_results: Vec<SearchResult> = Vec::new();
        // 7.4：on_source 复检用（会话身份）
        let session_cb = Arc::clone(&session);
        drive_source_batches(
            sources,
            SEARCH_CONCURRENCY,
            SEARCH_SOURCE_TIMEOUT,
            &session.cancel,
            &session.paused,
            move |source: BookSource| {
                let client = client.clone();
                let keyword = keyword_owned.clone();
                async move { search_single_source(&client, &source, &keyword, 1, precision).await }
            },
            |outcome| {
                // 7.4：累积前复检会话未取消且仍为当前（防旧会话批次进入累积）
                if session_cb.cancel.load(Ordering::SeqCst) || !is_current_session(&session_cb) {
                    return Ok(());
                }
                if let Ok(mut items) = outcome.result {
                    all_results.append(&mut items);
                }
                Ok(())
            },
        )
        .await;
        Ok::<_, LegadoError>(all_results)
    })?;

    // 7.5：drive 返回后先清理当前会话（若仍为本会话）
    clear_current_session_if_same(&session);
    // 7.4：持久化前复检——若已取消则丢弃累积结果，不落库（防旧搜索残留污染 searchBooks）
    if session.cancel.load(Ordering::SeqCst) {
        return Ok(Vec::new());
    }

    // 搜索完成后批量附加阅读记录标识（一次性构建内存索引，O(1) 查找，
    // 对齐上游 ReadRecordIndex 思路；search_cover 复用本函数但不关心该字段）
    let index = ReadRecordIndex::load();
    annotate_results(&mut results, &index);

    // 一次性搜索同样落库（对齐 SearchModel.insert），供换源复用
    let core_books: Vec<_> = results.iter().cloned().map(result_to_search_book).collect();
    persist_search_books(&core_books);

    Ok(results)
}

/// 精确搜索（对齐原版 `WebBook.preciseSearchAwait` / `preciseSearch`）
///
/// 在指定（或全部启用）书源中以书名为关键词搜索，返回**首个**
/// `name` 完全相等且（`author` 为空或 `author` 完全相等）的命中，
/// 序列化为 SearchBook camelCase JSON。未命中返回错误。
pub fn precise_search(name: &str, author: &str, source_urls_json: &str) -> LegadoResult<String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(LegadoError::Parser("精确搜索书名不能为空".into()));
    }
    let author = author.trim();
    let sources = load_search_sources(source_urls_json)?;
    if sources.is_empty() {
        return Err(LegadoError::Network("没有可用书源".into()));
    }

    let name_owned = name.to_string();
    let author_owned = author.to_string();

    // 按书源顺序检索，命中即停（对齐 preciseSearch 串行 + shouldBreak）
    let hit = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        for source in sources {
            let items = match search_single_source(&client, &source, &name_owned, 1, false).await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!(
                        "[precise_search] 书源 {} 失败（跳过）: {e}",
                        source.book_source_name
                    );
                    continue;
                }
            };
            for item in items {
                if item.book_name != name_owned {
                    continue;
                }
                if author_owned.is_empty() || item.author == author_owned {
                    return Ok::<_, LegadoError>(Some(item));
                }
            }
        }
        Ok(None)
    })?;

    match hit {
        Some(r) => {
            let sb = result_to_search_book(r);
            Ok(serde_json::to_string(&sb)?)
        }
        None => Err(LegadoError::Network(format!(
            "未搜索到 {name}({author}) 书籍"
        ))),
    }
}

/// 多源并行搜索（同步包装）
///
/// `query` — 搜索关键词
/// `source_urls_json` — JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
///
/// 返回 JSON 字符串格式的搜索结果数组。
pub fn multi_source_search(query: &str, source_urls_json: &str) -> LegadoResult<String> {
    // P0-3：为本次搜索创建独立会话（取代并取消上一会话），不再重置全局标志
    let session = Arc::new(SearchSession::new());
    register_current_session(&session);

    let sources = load_search_sources(source_urls_json)?;
    if sources.is_empty() {
        clear_current_session_if_same(&session); // 7.5：空源早退亦清理会话
        return Ok("[]".to_string());
    }
    let precision = crate::api::config_api::get_config("precisionSearch")
        .map(|v| v == "true")
        .unwrap_or(false);

    // 委托统一单源执行器（drive_source_batches + search_single_source），与
    // search_books / run_multi_stream 共享同一并发/超时/解析语义：有界并发
    // SEARCH_CONCURRENCY、每源 SEARCH_SOURCE_TIMEOUT(30s)、无截断。原
    // MultiSourceSearcher/WebSourceSearcher 独立驱动器的 10s 全局超时、20 条
    // 截断与跨源去重/相关性排序已移除——聚合排序下沉至 Flutter，对齐原版
    // SearchModel「Rust 出原始单源结果、UI 按 mergeItems 聚合」。
    let query_owned = query.to_string();
    let results: Vec<SearchResult> = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        let mut all_results: Vec<SearchResult> = Vec::new();
        // 7.4：on_source 复检用（会话身份）
        let session_cb = Arc::clone(&session);
        drive_source_batches(
            sources,
            SEARCH_CONCURRENCY,
            SEARCH_SOURCE_TIMEOUT,
            &session.cancel,
            &session.paused,
            move |source: BookSource| {
                let client = client.clone();
                let query = query_owned.clone();
                async move { search_single_source(&client, &source, &query, 1, precision).await }
            },
            |outcome| {
                // 7.4：累积前复检会话未取消且仍为当前（防旧会话批次进入累积）
                if session_cb.cancel.load(Ordering::SeqCst) || !is_current_session(&session_cb) {
                    return Ok(());
                }
                if let Ok(mut items) = outcome.result {
                    all_results.append(&mut items);
                }
                Ok(())
            },
        )
        .await;
        Ok::<_, LegadoError>(all_results)
    })?;

    // 7.5：drive 返回后先清理当前会话（若仍为本会话）
    clear_current_session_if_same(&session);
    // 7.4：已取消则丢弃累积结果（一次性入口语义，防旧搜索残留）
    if session.cancel.load(Ordering::SeqCst) {
        return Ok("[]".to_string());
    }

    // [审计 D3 | SearchModel.insert] 一次性入口同样落库 searchBooks，供换源
    // getDbSearchBooks 复用（search_books 已有同款；当前 UI 只用流式主路径，
    // 此处对齐原版"两入口均落库"语义，防后续调用方换源 DB 缓存偏少）
    let core_books: Vec<_> = results.iter().cloned().map(result_to_search_book).collect();
    persist_search_books(&core_books);

    // 批量附加阅读记录标识后序列化（不修改 core 的 SearchResult 结构，通过加法式
    // DTO 扩展输出 JSON）。统一执行器不做跨源去重/相关性排序（聚合下沉至 Flutter），
    // 故 relevance_score 恒为 0。
    let index = ReadRecordIndex::load();
    let annotated: Vec<AnnotatedCandidate> = results
        .into_iter()
        .map(|c| {
            let (has_record, record_author) = index.lookup(&c.book_name, &c.author);
            AnnotatedCandidate {
                book_name: c.book_name,
                author: c.author,
                cover_url: c.cover_url,
                intro: c.intro,
                latest_chapter: c.latest_chapter,
                source_url: c.source_url,
                source_name: c.source_name,
                book_url: c.book_url,
                relevance_score: 0.0,
                has_read_record: has_record,
                read_record_author: record_author,
                variable: c.variable,
            }
        })
        .collect();

    serde_json::to_string(&annotated).map_err(LegadoError::Serialization)
}

/// 取消正在进行的搜索（P0-3：作用于当前会话，不再全局污染后续搜索）
pub fn cancel_search() {
    if let Some(s) = current_session() {
        s.cancel.store(true, Ordering::SeqCst);
    }
}

/// 暂停正在进行的流式搜索（软挂起，批次B G-B-04；作用于当前会话）
///
/// 仅拦截尚未派发单源任务的书源；已派发任务继续完成。
/// 状态/进度全部保留，可经 [`resume_search`] 恢复。
pub fn pause_search() {
    if let Some(s) = current_session() {
        s.paused.store(true, Ordering::SeqCst);
    }
}

/// 恢复已暂停的流式搜索（批次B G-B-04；作用于当前会话）
pub fn resume_search() {
    if let Some(s) = current_session() {
        s.paused.store(false, Ordering::SeqCst);
    }
}

// ─── 封面搜索 ──────────────────────────────────────────────────────────────────

/// 封面候选项
///
/// 用于 `change_cover_screen` 网络封面搜索（API_CONTRACT.md §3 需求 3）。
/// 字段对齐 Dart 侧 `CoverCandidate` freezed 模型（snake_case）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoverCandidate {
    /// 封面图片地址（必需）
    pub url: String,
    /// 图片宽度（像素，未知填 0）
    pub width: i32,
    /// 图片高度（像素，未知填 0）
    pub height: i32,
}

/// 搜索书籍封面候选列表
///
/// 复用现有书源搜索能力（方案 A）：以书名为关键词搜索所有启用的书源，
/// 从搜索结果中提取 `cover_url` 字段作为封面候选，过滤空值并去重。
///
/// `book_name` — 书籍名称（搜索关键词）
///
/// 返回去重后的封面候选列表；无候选时返回空列表（非异常）。
/// `width` / `height` 暂设为 0（搜索结果无法提供图片尺寸，UI 侧可接受）。
pub fn search_cover(book_name: &str) -> LegadoResult<Vec<CoverCandidate>> {
    // 复用多书源搜索（搜索所有启用的书源）
    let results = search_books(book_name, "")?;
    Ok(extract_cover_candidates(results))
}

/// 从搜索结果中提取封面候选（过滤空值 + 去重，保持首次出现顺序）
fn extract_cover_candidates(results: Vec<SearchResult>) -> Vec<CoverCandidate> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut candidates: Vec<CoverCandidate> = Vec::new();
    for item in results {
        if let Some(url) = item.cover_url {
            if !url.is_empty() && seen.insert(url.clone()) {
                candidates.push(CoverCandidate {
                    url,
                    width: 0,
                    height: 0,
                });
            }
        }
    }
    candidates
}

// ─── 渐进式（流式）搜索 ────────────────────────────────────────────────────────

/// 单个书源的搜索结果批次
///
/// 用于渐进式搜索：每完成一个书源即推送一个批次，UI 侧可逐源渲染，
/// 无需等待最慢的书源。批次以 JSON 字符串形式跨 FFI 传递。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchSourceBatch {
    /// 书源在请求列表中的索引（从 0 开始）
    pub source_index: usize,
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 该书源命中的书籍列表（原版 `SearchBook` camelCase 序列化契约，
    /// 与 Dart 侧 `SearchBook.fromJson` 字段一一对应）
    pub books: Vec<CoreSearchBook>,
    /// 该书源搜索失败时的错误信息（成功为 None）
    pub error: Option<String>,
    /// 当前已完成（已推送批次）的书源数量
    pub finished_count: usize,
    /// 本次搜索的书源总数
    pub total_count: usize,
    /// 是否为最后一个批次（finished_count == total_count 时为 true）
    pub is_last: bool,
    /// 是否还有下一页可加载（累积值：任一已推送批次非空即 true，
    /// 对齐原版 SearchModel `hasMore = hasMore || items.isNotEmpty()`；批次B G-B-02）
    #[serde(default)]
    pub has_more: bool,
}

/// 多源渐进式（流式）搜索驱动器
///
/// 与 [`multi_source_search`] 不同：本函数不等待全部书源完成，而是
/// **每完成一个书源即调用一次 `on_batch`**（传入该源批次的 JSON 字符串），
/// 实现渐进式返回。
///
/// `query` — 搜索关键词
/// `source_urls_json` — JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
/// `on_batch` — 每个书源完成时的回调；返回 `Err` 时提前终止（如 sink 已关闭）。
///
/// 配合 `cancel_search()` 可提前中止。供 flutter_rust_bridge 的 `StreamSink`
/// 绑定使用（在 ffi.rs 中将 `on_batch` 接到 `sink.add`）。
pub async fn run_multi_stream<F>(
    query: String,
    source_urls_json: String,
    page: i32,
    mut on_batch: F,
) where
    F: FnMut(String) -> Result<(), String>,
{
    // P0-3：为本次搜索创建独立会话（取代并取消上一会话），不再重置全局标志
    let session = Arc::new(SearchSession::new());
    register_current_session(&session);

    // 书源加载失败时以空流结束（Dart 侧表现为无结果）
    let sources = load_search_sources(&source_urls_json).unwrap_or_default();
    if sources.is_empty() {
        clear_current_session_if_same(&session); // 7.5：空源早退亦清理会话
        return;
    }

    let client = match crate::http_state::shared_client() {
        Ok(c) => c,
        Err(e) => {
            log::error!("流式搜索：共享 HTTP 客户端初始化失败: {e}");
            clear_current_session_if_same(&session); // 7.5：HTTP 失败早退亦清理会话
            return;
        }
    };

    // 一次性构建阅读记录索引，逐批附加标识（对齐 ReadRecordIndex 思路）
    let read_record_index = ReadRecordIndex::load();

    // hasMore 累积（批次B G-B-02）：任一已推送批次非空 → true
    // 对齐原版 SearchModel `hasMore = hasMore || items.isNotEmpty()` 语义
    let mut has_more_acc = false;
    // 7.4：on_source 复检用（会话身份），避免旧会话批次进入持久化/流
    let session_cb = Arc::clone(&session);
    let precision = crate::api::config_api::get_config("precisionSearch")
        .map(|v| v == "true")
        .unwrap_or(false);

    drive_source_batches(
        sources,
        SEARCH_CONCURRENCY,
        SEARCH_SOURCE_TIMEOUT,
        &session.cancel,
        &session.paused,
        move |source: BookSource| {
            let client = client.clone();
            let query = query.clone();
            // 页码透传（批次B G-B-01）：同关键词翻页递增、新关键词重置为 1
            async move { search_single_source(&client, &source, &query, page, precision).await }
        },
        |outcome| {
            // 7.4：序列化/持久化/sink.add 前复检会话未取消且仍为当前（防旧会话残留写入）
            if session_cb.cancel.load(Ordering::SeqCst) || !is_current_session(&session_cb) {
                return Ok(()); // 本会话已被取消或取代 → 丢弃该批次，不持久化、不推流
            }
            let (mut books, error) = match outcome.result {
                Ok(list) => (list, None),
                Err(e) => (Vec::new(), Some(e.to_string())),
            };

            // 批次推送前附加阅读记录标识
            annotate_results(&mut books, &read_record_index);

            // 对齐原版 SearchModel：逐源 insert searchBooks，供换源 getDbSearchBooks 复用
            let core_books: Vec<_> = books.iter().cloned().map(result_to_search_book).collect();
            persist_search_books(&core_books);

            // hasMore 累积（原版语义：非空批次的 OR；失败/空批次不贡献）
            if !books.is_empty() {
                has_more_acc = true;
            }

            let batch = SearchSourceBatch {
                source_index: outcome.index,
                source_url: outcome.source_url,
                source_name: outcome.source_name,
                books: core_books,
                error,
                finished_count: outcome.finished_count,
                total_count: outcome.total_count,
                is_last: outcome.is_last,
                has_more: has_more_acc,
            };

            let json = serde_json::to_string(&batch).map_err(|e| e.to_string())?;
            // sink 关闭（Err）时提前终止
            on_batch(json)
        },
    )
    .await;
    // 7.5：drive 返回后清理当前会话（若仍为本会话；A 被 B 取代时不误清 B）
    clear_current_session_if_same(&session);
}

/// 单源搜索完成结果（驱动器回调载荷）
///
/// `T` — 单源搜索输出元素类型：search.rs 用 `SearchResult`；换源流式驱动器
/// （source_switch.rs T6）复用同一派发/超时/取消门控机制，以 `SearchCandidate` 为元素。
pub(crate) struct SourceBatchOutcome<T> {
    /// 书源在请求列表中的索引
    pub index: usize,
    pub source_url: String,
    pub source_name: String,
    /// 该源搜索结果（失败/超时/panic 均为 Err，不阻断其他源）
    pub result: LegadoResult<Vec<T>>,
    pub finished_count: usize,
    pub total_count: usize,
    pub is_last: bool,
}

/// 驱动一批书源搜索：受控在飞任务、单源超时、取消/暂停会话级门控。
///
/// - **隔离**：单源失败/panic 不影响其他源（各自 catch_unwind）。
/// - **并发（P0-3 复审 7.2）**：`sources` 作为待派发队列，任意时刻最多 `concurrency` 个在飞任务；
///   每有一个完成才派发下一个。不再「每源一个 tokio::spawn + semaphore 排队」——那会让大书源包
///   预创建与源数等量的排队任务，且取消时丢弃 FuturesUnordered 只是分离（detach）而非中止它们。
/// - **取消 / sink 关闭 / 会话替换**：显式 abort_all 并 drain 已启动 handle，确保在飞任务被终止、
///   其结果绝不进入流 / 状态 / 落库。
/// - **暂停**：门控发生在派发下一个源之前（调度层），未请求源不占用任何并发许可；已派发任务继续
///   完成（软挂起，对齐原版 SearchModel workingState 调度前门控）。
/// - **超时**：单源搜索超过 `per_source_timeout` 判为超时错误。
// 取消等待——取消标志置位后立即返回（轮询 50ms），
// 用于 select! 中断阻塞的 set.next()，使取消/会话替换能及时唤醒收集循环并 abort 在飞任务。
async fn wait_cancelled(cancel: &Arc<AtomicBool>) {
    loop {
        if cancel.load(Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

pub(crate) async fn drive_source_batches<F, Fut, T, G>(
    sources: Vec<BookSource>,
    concurrency: usize,
    per_source_timeout: Duration,
    cancel: &Arc<AtomicBool>,
    paused: &Arc<AtomicBool>,
    search_one: F,
    mut on_source: G,
) where
    F: Fn(BookSource) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = LegadoResult<Vec<T>>> + Send + 'static,
    T: Send + 'static,
    G: FnMut(SourceBatchOutcome<T>) -> Result<(), String>,
{
    use futures::FutureExt;
    use std::panic::AssertUnwindSafe;

    let total = sources.len();
    if total == 0 {
        return;
    }

    // 待派发队列（index, source）；在飞任务数 ≤ concurrency
    let mut queue: std::collections::VecDeque<(usize, BookSource)> =
        sources.into_iter().enumerate().collect();
    let mut set = futures::stream::FuturesUnordered::new();
    // 保留每个在飞任务的 AbortHandle，取消 / sink 关闭时显式 abort_all + drain
    let mut aborts: Vec<tokio::task::AbortHandle> = Vec::new();

    let search_one = Arc::new(search_one);
    let concurrency = concurrency.max(1);

    let mut finished: usize = 0;
    'collect: loop {
        // 派发至多 concurrency 个在飞任务；暂停门控在派发前（不占许可）
        while set.len() < concurrency && !queue.is_empty() {
            if cancel.load(Ordering::SeqCst) {
                break 'collect;
            }
            if paused.load(Ordering::SeqCst) {
                // 调度层等待恢复或取消（未持有并发许可，对齐原版 workingState 门控位置）
                loop {
                    if cancel.load(Ordering::SeqCst) || !paused.load(Ordering::SeqCst) {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                if cancel.load(Ordering::SeqCst) {
                    break 'collect;
                }
            }

            let (index, source) = queue.pop_front().unwrap();
            let search_one = Arc::clone(&search_one);
            let cancel = Arc::clone(cancel);
            let handle = tokio::spawn(async move {
                let source_url = source.book_source_url.clone();
                let source_name = source.book_source_name.clone();

                // 派发前防御性取消检查（会话级；派发层已门控，此处兜底）
                if cancel.load(Ordering::SeqCst) {
                    return (
                        index,
                        source_url,
                        source_name,
                        Err(LegadoError::Network("搜索已取消".into())),
                    );
                }

                let outcome = tokio::time::timeout(
                    per_source_timeout,
                    AssertUnwindSafe(search_one(source)).catch_unwind(),
                )
                .await;

                let result = match outcome {
                    Ok(Ok(r)) => r,
                    Ok(Err(p)) => Err(LegadoError::Network(format!(
                        "单源搜索崩溃: {:?}（已隔离，不影响其他源）",
                        p
                    ))),
                    Err(_elapsed) => Err(LegadoError::Network(format!(
                        "搜索超时（{}s）",
                        per_source_timeout.as_secs()
                    ))),
                };

                (index, source_url, source_name, result)
            });
            aborts.push(handle.abort_handle());
            set.push(handle);
        }

        if set.is_empty() {
            break 'collect;
        }

        // 按完成顺序取下一个结果；与取消竞争 —— 取消置位后立即唤醒并 abort 在飞任务，
        // 不再等待最快下一个自然完成（否则在飞请求最长可能持续至单源超时）。
        let joined = tokio::select! {
            j = set.next() => match j {
                Some(j) => j,
                None => break 'collect,
            },
            _ = wait_cancelled(cancel) => break 'collect,
        };
        // P0-3 复审 7.2：取消 / sink 关闭后不再把在飞结果交付 on_source（防旧会话残留）
        if cancel.load(Ordering::SeqCst) {
            break 'collect;
        }
        finished += 1;
        let (index, source_url, source_name, result) = match joined {
            Ok(v) => v,
            Err(e) => (
                0,
                String::new(),
                String::new(),
                Err(LegadoError::Network(format!("搜索任务异常: {e}"))),
            ),
        };

        let outcome = SourceBatchOutcome {
            index,
            source_url,
            source_name,
            result,
            finished_count: finished,
            total_count: total,
            is_last: finished >= total,
        };

        if on_source(outcome).is_err() {
            // sink 关闭 → 置位会话取消，停止收集（下方统一 abort_all + drain）
            cancel.store(true, Ordering::SeqCst);
            break 'collect;
        }
    }

    // 取消 / sink 关闭 / 正常结束：显式 abort_all + drain 已启动 handle（P0-3 复审 7.2）
    for ah in &aborts {
        ah.abort();
    }
    while set.next().await.is_some() {
        // drain：丢弃剩余在飞任务的结果，绝不进入流 / 状态 / 落库
    }
}

/// 搜索结果 → 原版 `SearchBook` camelCase 序列化结构
///
/// 契约对齐 Dart 侧 `SearchBook.fromJson`（name/originName/bookUrl/…），
/// 供 searchBooks 一次性返回与渐进批次共用同一序列化契约。
pub(crate) fn result_to_search_book(r: SearchResult) -> CoreSearchBook {
    CoreSearchBook {
        book_url: r.book_url,
        origin: r.source_url,
        origin_name: r.source_name,
        book_type: r.book_type,
        name: r.book_name,
        author: r.author,
        kind: r.kind,
        cover_url: r.cover_url,
        intro: r.intro,
        word_count: r.word_count,
        latest_chapter_title: r.latest_chapter,
        toc_url: String::new(),
        time: chrono_now_ms(),
        // [T5] 搜索期级联变量随 SearchBook 落库（换源读库路径复用）
        variable: r.variable,
        // [P0-2 S4] 透传真实书源排序（原恒写 0，违反数据契约约束 #4）
        origin_order: r.origin_order,
        chapter_word_count_text: None,
        chapter_word_count: -1,
        respond_time: -1,
        book_score: 0,
        // 阅读记录标识（由 api::search 批量附加后透传）
        has_read_record: r.has_read_record,
        read_record_author: r.read_record_author,
    }
}

/// 将搜索命中写入 searchBooks（对齐原版 `appDb.searchBookDao.insert`）
///
/// 失败静默（单条 FK/锁冲突不阻断搜索主流程）；DB 未初始化时跳过。
fn persist_search_books(books: &[CoreSearchBook]) {
    if books.is_empty() || !crate::db_state::is_initialized() {
        return;
    }
    let _ = crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        let _ = repo.insert_all(books);
        Ok(())
    });
}

fn chrono_now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ─── 阅读记录标识（对齐上游 ReadRecordIndex，#424）─────────────────────

/// 阅读记录内存索引（对齐上游 Kotlin `ReadRecordIndex`）
///
/// 一次性从 readRecord 表加载全量记录构建 `书名 -> 作者集合` 映射，
/// 搜索结果逐本 O(1) 查找，避免每本书一次 DB 查询。
///
/// 匹配语义对齐上游 `ReadRecordIndex.contains`：
/// 阅读记录以书名为准，作者仅作辅助 —— 任意一方作者为空时
/// 退化为按书名判断；两侧作者都非空时需存在交集才算读过。
struct ReadRecordIndex {
    /// 书名 -> 阅读记录中的作者列表（旧记录/无作者时为空列表）
    authors: HashMap<String, Vec<String>>,
}

impl ReadRecordIndex {
    /// 从当前数据库加载全量阅读记录构建索引
    ///
    /// 数据库未初始化或查询失败时降级为空索引（不影响搜索主流程）。
    fn load() -> Self {
        let records = crate::db_state::with_database(|db| {
            ReadRecordRepository::new(db.connection()).find_all()
        })
        .unwrap_or_default();
        Self::of(records)
    }

    /// 由记录列表构建索引（对齐上游 `ReadRecordIndex.of`）
    ///
    /// 注意：上游 `ReadRecordAuthors.decode` 对空白 author 返回 {""}，
    /// 索引中保留空串占位以表达「旧记录无作者 → 按书名命中任意作者」；
    /// Rust 侧解码返回空列表时需补上空串占位保持等价。
    fn of(records: Vec<legado_db::repository::read_record_repository::ReadRecord>) -> Self {
        let mut authors: HashMap<String, Vec<String>> = HashMap::new();
        for record in records {
            let mut decoded = decode_read_record_authors(&record.author);
            if decoded.is_empty() {
                decoded.push(String::new());
            }
            authors.entry(record.book_name).or_default().extend(decoded);
        }
        Self { authors }
    }

    /// 查询书籍是否有阅读记录（对齐上游 `ReadRecordIndex.contains`）
    fn contains(&self, name: &str, author: &str) -> bool {
        let Some(record_authors) = self.authors.get(name) else {
            return false;
        };
        let author = author.trim();
        if author.is_empty() {
            return true;
        }
        record_authors
            .iter()
            .any(|a| a.trim().is_empty() || a == author)
    }

    /// 查询并返回（是否有记录, 记录中的作者展示串）
    ///
    /// 作者展示串仅在有记录时返回：多作者以顿号连接，
    /// 记录无作者信息时为 None。
    fn lookup(&self, name: &str, author: &str) -> (bool, Option<String>) {
        if !self.contains(name, author) {
            return (false, None);
        }
        let display = self
            .authors
            .get(name)
            .map(|list| {
                list.iter()
                    .filter(|a| !a.trim().is_empty())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("、")
            })
            .filter(|s| !s.is_empty());
        (true, display)
    }
}

/// 批量为搜索结果附加阅读记录标识（原地修改）
fn annotate_results(results: &mut [SearchResult], index: &ReadRecordIndex) {
    for item in results.iter_mut() {
        let (has_record, record_author) = index.lookup(&item.book_name, &item.author);
        item.has_read_record = has_record;
        item.read_record_author = record_author;
    }
}

/// 附加阅读记录标识后的多源搜索输出 DTO
///
/// 字段为 `legado_core::search_engine::SearchResult` 的加法式超集：
/// 不修改 core 结构，仅在输出 JSON 中额外携带
/// `hasReadRecord` / `readRecordAuthor`（Dart 侧 jsonDecode 兼容）。
#[derive(Debug, Clone, Serialize, Deserialize)]
struct AnnotatedCandidate {
    /// 书籍名称
    pub book_name: String,
    /// 作者
    pub author: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 最新章节
    pub latest_chapter: Option<String>,
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 书籍详情页 URL
    pub book_url: String,
    /// 相关性评分
    pub relevance_score: f64,
    /// 是否有阅读记录
    #[serde(default, rename = "hasReadRecord")]
    pub has_read_record: bool,
    /// 阅读记录中的作者信息（无记录时缺省）
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "readRecordAuthor"
    )]
    pub read_record_author: Option<String>,
    /// 规则变量 JSON（换源 T5 透传，additive）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
}

// ─── 内部实现 ─────────────────────────────────────────────────────────────────

/// 加载待搜索的书源列表
///
/// `source_urls_json` 为空字符串或空数组（`[]`）均表示「搜索所有启用的书源」；
/// Dart 侧无筛选条件时传 `'[]'`，与原版「未选分组/书源即搜全部」语义对齐。
/// 留项#12（Task #131）：提升为 pub(crate) 供 source_switch 换源搜索复用同一过滤语义。
pub(crate) fn load_search_sources(source_urls_json: &str) -> LegadoResult<Vec<BookSource>> {
    if source_urls_json.is_empty() {
        // 使用所有启用的书源
        return source_api::list_enabled_sources();
    }
    let urls: Vec<String> = serde_json::from_str(source_urls_json)
        .map_err(|e| LegadoError::Ffi(format!("书源 URL 列表解析失败: {e}")))?;
    if urls.is_empty() {
        // 空数组同样表示搜全部（兼容 Dart 侧默认值 '[]'）
        return source_api::list_enabled_sources();
    }
    // 从数据库逐个加载（简化实现）
    let all = source_api::list_enabled_sources()?;
    let filtered: Vec<BookSource> = all
        .into_iter()
        .filter(|s| urls.contains(&s.book_source_url))
        .collect();
    Ok(filtered)
}

/// 对单个书源执行搜索（异步）
///
/// 完整链路：AnalyzeUrl 构建请求 → LegadoClient 发送 → AnalyzeRule 解析结果
/// JS 书源走 JsSourceBookOrchestrator 路径（R1: spawn_blocking 避免嵌套 runtime 死锁）
///
/// Task #16 P1：改为 `pub(crate)` 供换源场景（source_switch.rs）复用，
/// 使换源候选拿到真实的详情页 book_url（而非搜索结果页 URL）。
/// 换源单源搜索超时（对齐原版 ChangeBookSourceViewModel `withTimeout(60000)`）
pub(crate) const SWITCH_SOURCE_TIMEOUT: Duration = Duration::from_secs(60);

pub(crate) async fn search_single_source(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
    page: i32,
    precision: bool,
) -> LegadoResult<Vec<SearchResult>> {
    // G4：书源 concurrentRate 固定窗口节流（对齐 Kotlin ConcurrentRateLimiter）
    crate::api::source_rate_limit::acquire_source_rate_limit(source).await;

    // 阶段计时诊断（LEGADO_SEARCH_PHASE_TIMING=1）：定位单源 30s 超时挂起阶段
    let phase_on = std::env::var("LEGADO_SEARCH_PHASE_TIMING").is_ok();
    let t_phase = std::time::Instant::now();
    // JS 书源分派
    if source.is_js_source() {
        let mut results = search_js_source(source, keyword, page).await?;
        // [审计 D4 | WebBook.kt:47 + JsSourceBook.kt:29-37] 原版把 precision
        // filter 传入 JsSourceBook.searchAwait，JS 源结果同样受三字段"或"
        // 语义约束，不得绕过
        results.retain(|r| {
            precision_filter_match(
                precision,
                keyword,
                &r.book_name,
                &r.author,
                r.kind.as_deref(),
            )
        });
        return Ok(results);
    }

    // 1. 获取搜索 URL 模板
    let search_url_template = source
        .search_url
        .as_ref()
        .ok_or_else(|| LegadoError::Parser("书源未配置 searchUrl".into()))?;

    if search_url_template.is_empty() {
        return Err(LegadoError::Parser("书源 searchUrl 为空".into()));
    }

    // 2. 使用 AnalyzeUrl 构建请求（同步且可能执行 {{JS}} 表达式；
    //    移入阻塞线程：恶意/超长同步计算不会占住 tokio worker，
    //    保证单源超时能在 await 点生效，避免整体挂起）
    let template = search_url_template.clone();
    let key = keyword.to_string();
    let build_base = source.book_source_url.clone();
    let source_lib = source.js_lib.clone();
    // 书源上下文 setup：搜索模板 `{{source.getKey()}}` 等依赖 source/cookie
    // 绑定（爱下电子等源）——对齐原版 AnalyzeUrl.kt evalJS source 绑定
    let search_setup = crate::api::source_js_bindings::book_source_js_setup_script(source).ok();
    let analyze_url = tokio::task::spawn_blocking(move || {
        crate::js_executor::build_search_url_with_setup(
            &template,
            &key,
            // 页码透传（批次B G-B-01）：原硬编码 page=1，现由调用方传入
            page,
            &build_base,
            source_lib.as_deref(),
            search_setup,
        )
    })
    .await
    .map_err(|e| LegadoError::Internal(format!("搜索 URL 构建任务异常: {e}")))?;
    if phase_on {
        eprintln!(
            "[phase] url_build={}ms src={}",
            t_phase.elapsed().as_millis(),
            source.book_source_url
        );
    }
    if analyze_url.url().starts_with("legado-js-error://") {
        return Err(LegadoError::Internal(format!(
            "searchUrl JS 求值失败: {}",
            analyze_url.url()
        )));
    }

    // 3. 合并请求头：书源全局 header + AnalyzeUrl 提取的 header
    let mut headers = parse_header_option(source.header.as_deref()).unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    // [UI-fix 2026-08-10 | Reasonix] 对齐原版 BaseSource.kt:202-204 +
    // AppConfig.userAgent：书源未配置 UA 时补充 Chrome UA（默认 Legado/1.0
    // 会被反爬站点识别为非浏览器而拒绝/返回空列表）
    ensure_default_user_agent(&mut headers);
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    // 4. 发送 HTTP 请求
    // charset=gbk 等：原始字节 + 指定编码解码，避免书名乱码导致精确匹配失败。— Reasonix
    // [S0-E | AnalyzeUrl.kt:499-534] 对齐原版：不校验 HTTP 状态码，
    // 非 2xx 响应体仍进入解析（通常得空列表），仅日志留痕。
    let (body, final_url, resp_code) = if analyze_url.needs_charset_decode() {
        let raw = match analyze_url.method() {
            RequestMethod::Post => {
                client
                    .post_raw(analyze_url.url(), analyze_url.request_body(), headers_opt)
                    .await?
            }
            _ => client.get_raw(analyze_url.url(), headers_opt).await?,
        };
        if !(200..300).contains(&raw.status) {
            eprintln!(
                "[search] 非 2xx HTTP {} url={}",
                raw.status,
                analyze_url.url()
            );
        }
        let decoded = AnalyzeUrl::decode_response_bytes(&raw.body, analyze_url.charset());
        (decoded, raw.url, raw.status)
    } else {
        let response = match analyze_url.method() {
            RequestMethod::Post => {
                let body = analyze_url.request_body();
                client.post(analyze_url.url(), body, headers_opt).await?
            }
            _ => client.get(analyze_url.url(), headers_opt).await?,
        };
        if !response.is_success() {
            eprintln!(
                "[search] 非 2xx HTTP {} url={}",
                response.status,
                analyze_url.url()
            );
        }
        (response.body, response.url, response.status)
    };
    if phase_on {
        eprintln!(
            "[phase] http={}ms src={}",
            t_phase.elapsed().as_millis(),
            source.book_source_url
        );
    }

    // [S0-E | WebBook.kt:74-98] loginCheckJs：成功响应先 eval；未登录 →
    // errResponse(500) 二次 eval；仍需登录 → LoginRequired 上抛（原版错误吞吐：
    //   单源失败静默不中断其他源）。JS 环境不兼容降级放行（与 web_book 路径一致）。
    crate::api::web_book::RealBookSourceFetcher::execute_login_check(
        source, &body, &final_url, resp_code,
    )?;
    // 5. 使用 AnalyzeRule 解析搜索结果（同步解析同样移入阻塞线程，
    //    灾难性正则/超大页面不会阻塞 runtime，单源超时可中断）
    let source_clone = source.clone();
    let keyword_owned = keyword.to_string();
    let parsed = tokio::task::spawn_blocking(move || {
        parse_search_response_ex(&body, &final_url, &source_clone, precision, &keyword_owned)
    })
    .await
    .map_err(|e| LegadoError::Internal(format!("搜索解析任务异常: {e}")))?;
    if phase_on {
        eprintln!(
            "[phase] total={}ms src={}",
            t_phase.elapsed().as_millis(),
            source.book_source_url
        );
    }
    parsed
}

/// 构建搜索 URL
///
/// 处理 `{key}`、`{{key}}`、`searchKey` 等关键词占位符与 `{{JS表达式}}`
/// 模板（如 `{{encodeURIComponent(key)}}`、`{{page > 1 ? '/' + page : ''}}`），
/// 然后通过 AnalyzeUrl 解析 URL 选项（method/headers/body 等）。
/// 统一委托 [`crate::js_executor::build_search_url`]，与调试/搜索路径共用同一模板渲染语义。
#[cfg(test)]
fn build_search_url(template: &str, keyword: &str, source: &BookSource) -> AnalyzeUrl {
    crate::js_executor::build_search_url(template, keyword, 1, &source.book_source_url)
}

#[allow(dead_code)]
/// 解析搜索响应（HTML 或 JSON）
///
/// 使用书源的 `rule_search` 规则解析响应体为结构化搜索结果。
/// [P3-6 阶段三] 测试/默认入口:precision 关闭(全通过)
fn parse_search_response(
    body: &str,
    base_url: &str,
    source: &BookSource,
) -> LegadoResult<Vec<SearchResult>> {
    parse_search_response_ex(body, base_url, source, false, "")
}

/// [P3-6 阶段三 | SearchModel.kt:106-113 + BookList.kt:236-238] 带 precision filter 的解析:
/// precision 开启时,解析期逐条按 name/author/kind contains(key) 过滤(对齐原版
/// SearchModel 传入 WebBook 的 filter 闭包与 getSearchItem/getInfoItem 的调用点)。
fn parse_search_response_ex(
    body: &str,
    base_url: &str,
    source: &BookSource,
    precision: bool,
    key: &str,
) -> LegadoResult<Vec<SearchResult>> {
    // [S0-E | BookList.kt:62-81] bookUrlPattern 详情页直连（原版在列表解析前判定，
    // baseUrl = 重定向后最终 URL 整串全匹配）：命中则按详情页规则解析单条结果。
    let has_pattern = source
        .book_url_pattern
        .as_deref()
        .is_some_and(|p| !p.trim().is_empty());
    if has_pattern
        && crate::api::web_book::matches_book_url_pattern(
            source.book_url_pattern.as_deref().unwrap_or(""),
            base_url,
        )
    {
        let info = crate::api::web_book::RealBookSourceFetcher::parse_book_info_from_body(
            source,
            body.to_string(),
            base_url,
            base_url,
            true,
            "",
            "",
        );
        return Ok(if info.name.is_empty() {
            vec![]
        } else {
            let item = web_info_to_search_result(info, source);
            // [P3-6 阶段三 | BookList.kt:184-190] getInfoItem 同样受 filter 约束
            if !precision_filter_match(
                precision,
                key,
                &item.book_name,
                &item.author,
                item.kind.as_deref(),
            ) {
                return Ok(vec![]);
            }
            vec![item]
        });
    }

    // [S0-E | BookList.kt:84-96] ruleSearch 缺失 → 空规则（bookList 空 → getElements
    // 得空集合 → 走下方空列表回退），不再提前返回、也不再把整个响应体当单条元素。
    let default_rule_search = legado_core::models::rule::SearchRule::default();
    let rule_search = source.rule_search.as_ref().unwrap_or(&default_rule_search);

    // 创建顶层 AnalyzeRule（quickjs 启用时注入 JS 执行器，使 @js: 搜索规则生效；
    // 2026-08-10 起同时注入书源 jsLib，模板引用的 Reload/getHosts 等库函数可用）
    // [P0-2 S1 | BookList.kt AnalyzeRule(ruleData, bookSource)] 追加书源上下文 setup
    // （source/cookie 绑定 + BookSource 方法），使搜索规则中 `{{source.getKey()}}`、
    // jsLib 函数 `let { source, cookie } = this` 等依赖生效——对齐发现页已用的
    // construct_analyzer_with_source_context（此前搜索主路径仅注入 jsLib，无 setup）。
    let setup_script = crate::api::source_js_bindings::book_source_js_setup_script(source).ok();
    let analyzer = crate::js_executor::construct_analyzer_with_source_context(
        body.to_string(),
        base_url.to_string(),
        &source.book_source_url,
        source.js_lib.as_deref(),
        setup_script.clone(),
    );

    // 获取书籍列表元素
    // [P0-2 S2 | BookList.kt:90-96] 剥离 bookList 规则的 `+`/`-` 前缀：
    // `-` 表示最终结果逆序（reverse），`+` 本版本仅去前缀、无额外行为。
    let (book_list_rule, reverse) =
        split_book_list_prefix(rule_search.book_list.as_deref().unwrap_or(""));
    let elements = if book_list_rule.is_empty() {
        // [S0-E] 对齐原版 getElements("")：空规则得空集合（随后走空列表回退）
        Vec::new()
    } else {
        analyzer.get_elements(&book_list_rule).unwrap_or_default()
    };

    if elements.is_empty() {
        // [S0-E | BookList.kt:100-108] 空列表详情回退：原版双条件 —— 列表为空
        // 且未配置 bookUrlPattern 才回退；pattern 已配置但不命中 → 直接返回空。
        if has_pattern {
            return Ok(Vec::new());
        }
        let info = crate::api::web_book::RealBookSourceFetcher::parse_book_info_from_body(
            source,
            body.to_string(),
            base_url,
            base_url,
            true,
            "",
            "",
        );
        return Ok(if info.name.is_empty() {
            vec![]
        } else {
            let item = web_info_to_search_result(info, source);
            // [P3-6 阶段三 | BookList.kt:184-190] getInfoItem 同样受 filter 约束
            if !precision_filter_match(
                precision,
                key,
                &item.book_name,
                &item.author,
                item.kind.as_deref(),
            ) {
                return Ok(vec![]);
            }
            vec![item]
        });
    }

    // 对每个元素解析各字段
    let mut results = Vec::new();
    for element_html in &elements {
        // 列表元素按结构化对象写入（JSON 元素 → result 注入为对象，
        // `result.source` 等属性访问；HTML 元素自动回退字符串）
        // — DeepSeek Harness + Bridge
        // [P0-2 S1] 与顶层一致：注入书源上下文 setup（source/cookie），使元素级 JS 规则可用
        let mut item_analyzer = crate::js_executor::construct_analyzer_with_source_context(
            String::new(),
            base_url.to_string(),
            &source.book_source_url,
            source.js_lib.as_deref(),
            setup_script.clone(),
        );
        item_analyzer.set_element_content(element_html.clone());

        // 批量字段提取：纯 CSS 规则共享一次 HTML 解析（搜索速度修复 2026-08-18，
        // 此前每字段各自全量 parse → yeudusk 35s 超时）；语义与逐字段 get_string
        // 完全一致。索引序：0 name / 1 author / 2 kind / 3 word_count /
        // 4 book_url / 5 cover / 6 intro / 7 last_chapter。
        let field_rules: Vec<&str> = vec![
            rule_search.name.as_deref().unwrap_or(""),
            rule_search.author.as_deref().unwrap_or(""),
            rule_search.kind.as_deref().unwrap_or(""),
            rule_search.word_count.as_deref().unwrap_or(""),
            rule_search.book_url.as_deref().unwrap_or(""),
            rule_search.cover_url.as_deref().unwrap_or(""),
            rule_search.intro.as_deref().unwrap_or(""),
            rule_search.last_chapter.as_deref().unwrap_or(""),
        ];
        let fields = item_analyzer.get_strings_batch(field_rules);
        let fields_str: Vec<String> = fields.into_iter().map(|r| r.unwrap_or_default()).collect();
        let field_str = |i: usize| -> String { fields_str.get(i).cloned().unwrap_or_default() };

        // 提取书名（必填，无书名则跳过）；清洗对齐原版 BookHelp.formatBookName
        let book_name = legado_core::book_help::format_book_name(&field_str(0));
        if book_name.is_empty() {
            continue;
        }

        // 提取作者（清洗对齐原版 BookHelp.formatBookAuthor）
        let author = legado_core::book_help::format_book_author(&field_str(1));

        // 提取分类（部分失败不致整条丢弃，对齐原版逐字段 try/catch 语义）。
        // 多标签按原版 BookList.kt:230 `getStringList(ruleKind)?.joinToString(",")` 用逗号分隔：
        // 批量路径 css_vec_to_string 已把多匹配以 \n 连接，此处将 \n 换为 ,（等价于 joinToString(",")，
        // 复用共享 CSS 解析、零额外 parse，不回退 2026-08-18 搜索提速）。
        let kind = if field_str(2).is_empty() {
            None
        } else {
            Some(field_str(2).replace('\n', ","))
        };

        // [P3-6 阶段三 | BookList.kt:236-238] precision filter:原版在 getSearchItem
        // 中以 (name, author, kind) 调用 filter,不命中即丢弃该条(precision 关闭时全通过)。
        if !precision_filter_match(precision, key, &book_name, &author, kind.as_deref()) {
            continue;
        }

        // 提取字数并格式化（对齐原版 wordCountFormat）
        let word_count = word_count_format(&field_str(3));

        // 书籍详情页 URL
        let raw_book_url = field_str(4);
        // [UI-fix 2026-08-10 | Reasonix] 对齐原版 BookList.kt:282-284 +
        // AnalyzeRule.kt:369-375：bookUrl 规则解析为空时回退书源主页
        // （bookSourceUrl），避免 book_url 为空导致结果条目无法打开
        // [S0-E | BookList.kt:281-284] bookUrl 规则为空时回退 baseUrl（最终搜索页
        // URL，重定向后），而非书源主页 —— 对齐原版 getSearchItem 回退语义。
        let book_url = if raw_book_url.is_empty() {
            base_url.to_string()
        } else {
            resolve_url(&raw_book_url, base_url)
        };

        // 提取封面 URL
        let raw_cover = field_str(5);
        let cover_url = if raw_cover.is_empty() {
            None
        } else {
            Some(resolve_url(&raw_cover, base_url))
        };

        // 提取简介（对齐原版 BookList.kt:260 `HtmlFormatter.formatIntro`：块级标签→换行、
        // 删注释与其他标签（含 img）、折叠空白；与正文 format_keep_img 保留 img 区分）
        let intro = if field_str(6).is_empty() {
            None
        } else {
            Some(legado_core::html_formatter::format_intro(&field_str(6)))
        };

        // 提取最新章节
        let latest_chapter = if field_str(7).is_empty() {
            None
        } else {
            Some(field_str(7))
        };

        // [T5 | SearchBook.kt:134] 元素级 @put/putVariable 级联导出（字段规则
        // 求值完成后统一收集，随候选进入换源；对齐原版 SearchModel 落库语义）
        let variable = item_analyzer.export_variables_json();

        results.push(SearchResult {
            source_url: source.book_source_url.clone(),
            source_name: source.book_source_name.clone(),
            book_name,
            author,
            book_url,
            latest_chapter,
            intro,
            cover_url,
            kind,
            word_count,
            book_type: book_type_of_source(source.book_source_type),
            // [P0-2 S4 | BookList.kt:215] originOrder = source.customOrder（真实书源排序，非默认 0）
            origin_order: source.custom_order,
            // 阅读记录标识由搜索完成后统一批量附加（见 annotate_results）
            has_read_record: false,
            read_record_author: None,
            variable,
        });
    }

    // [P0-2 S2 | BookList.kt:142-147] 去重（LinkedHashSet 语义，保留首次出现）后按
    // `-` 前缀逆序。键 = 书源 + 书名 + bookUrl：同源同详情页视为重复，不同书名不误伤。
    let mut results = dedup_search_results_keep_first(results);
    if reverse {
        results.reverse();
    }

    Ok(results)
}

/// [P3-6 阶段三 | SearchModel.kt:106-113] 原版 precision filter 谓词:
/// `!precision || name.contains(key) || author.contains(key) || kind?.contains(key) == true`
fn precision_filter_match(
    precision: bool,
    key: &str,
    name: &str,
    author: &str,
    kind: Option<&str>,
) -> bool {
    !precision
        || name.contains(key)
        || author.contains(key)
        || kind.map(|k| k.contains(key)).unwrap_or(false)
}

/// [S0-E] 详情页解析结果 → 搜索项（bookUrlPattern 直连 / 空列表回退共用，
/// 对齐原版 `Book.getInfoItem` 产出 SearchBook 的字段映射）
fn web_info_to_search_result(
    info: legado_core::web_book::WebBookInfo,
    source: &BookSource,
) -> SearchResult {
    SearchResult {
        source_url: source.book_source_url.clone(),
        source_name: source.book_source_name.clone(),
        book_name: info.name,
        author: info.author,
        book_url: info.book_url,
        latest_chapter: info.last_chapter,
        intro: info.intro,
        cover_url: info.cover_url,
        kind: info.kind,
        word_count: info.word_count,
        // 原版 getInfoItem 带入 bookSource.getBookType()（BookList.kt:173）
        book_type: book_type_of_source(source.book_source_type),
        origin_order: source.custom_order,
        has_read_record: false,
        read_record_author: None,
        variable: info.variable,
    }
}

/// [P0-2 S2 | BookList.kt:90-96] 拆分 bookList 规则的 `+`/`-` 前缀。
/// `-`：最终结果逆序（reverse=true），规则体去前缀；`+`：本版本仅去前缀、无额外行为。
/// 返回 (清洗后的规则, reverse 标志)。原版在 getElements 前剥离、dedup 后按 reverse 反转。
fn split_book_list_prefix(rule: &str) -> (String, bool) {
    if let Some(rest) = rule.strip_prefix('-') {
        return (rest.to_string(), true);
    }
    if let Some(rest) = rule.strip_prefix('+') {
        return (rest.to_string(), false);
    }
    (rule.to_string(), false)
}

/// [S0-E | BookList.kt:142-144 + SearchBook.kt:65] 按书籍标识去重（原版 LinkedHashSet<SearchBook> 语义，保留首次出现）
/// 语义，保留首次出现）。键 = 书源 + 书名 + bookUrl：同源同详情页视为重复；不同书名不误伤。
fn dedup_search_results_keep_first(items: Vec<SearchResult>) -> Vec<SearchResult> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(items.len());
    for it in items {
        // [S0-E | SearchBook.kt:65 + BookList.kt:142-144] 去重键 = bookUrl 单键
        //（原版 LinkedHashSet<SearchBook>，equals 仅比较 bookUrl；单源内 origin 恒定）
        let key = it.book_url.clone();
        if seen.insert(key) {
            out.push(it);
        }
    }
    out
}

#[cfg(test)]
mod p0_2_s2_tests {
    use super::*;

    fn mk_result(source: &str, name: &str, book_url: &str) -> SearchResult {
        SearchResult {
            source_url: source.to_string(),
            source_name: "src".into(),
            book_name: name.to_string(),
            author: String::new(),
            book_url: book_url.to_string(),
            latest_chapter: None,
            intro: None,
            cover_url: None,
            kind: None,
            word_count: None,
            book_type: 0,
            origin_order: 0,
            has_read_record: false,
            read_record_author: None,
            variable: None,
        }
    }

    #[test]
    fn test_split_book_list_prefix_minus_reverses() {
        let (rule, reverse) = split_book_list_prefix("-.bookbox");
        assert_eq!(rule, ".bookbox");
        assert!(reverse);
    }

    #[test]
    fn test_split_book_list_prefix_plus_strips_only() {
        let (rule, reverse) = split_book_list_prefix("+.bookbox");
        assert_eq!(rule, ".bookbox");
        assert!(!reverse);
    }

    #[test]
    fn test_split_book_list_prefix_no_prefix_unchanged() {
        let (rule, reverse) = split_book_list_prefix(".bookbox");
        assert_eq!(rule, ".bookbox");
        assert!(!reverse);
    }

    #[test]
    fn test_dedup_keeps_first_occurrence() {
        let items = vec![
            mk_result("s1", "A", "u1"),
            mk_result("s1", "A", "u1"), // 重复（同 bookUrl）
            mk_result("s1", "B", "u2"),
            mk_result("s2", "A", "u1"), // [S0-E] 原版 SearchBook.equals 仅比较 bookUrl
                                        //（SearchBook.kt:65）→ 同 bookUrl 不同源亦去重
        ];
        let d = dedup_search_results_keep_first(items);
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].book_name, "A");
        assert_eq!(d[1].book_name, "B");
    }

    #[test]
    fn test_dedup_preserves_order_and_empty() {
        let items = vec![
            mk_result("s", "X", "u1"),
            mk_result("s", "Y", "u2"),
            mk_result("s", "Z", "u3"),
        ];
        let d = dedup_search_results_keep_first(items);
        assert_eq!(
            d.iter().map(|r| r.book_name.clone()).collect::<Vec<_>>(),
            vec!["X".to_string(), "Y".to_string(), "Z".to_string()]
        );
        assert_eq!(dedup_search_results_keep_first(Vec::new()).len(), 0);
    }
}

/// [S0-E] 主搜索路径原版语义收敛测试：bookUrlPattern 直连 / 空列表详情回退 /
/// bookUrl 空回退 / bookUrl 单键去重 / loginCheckJs（quickjs）
#[cfg(test)]
mod s0e_tests {
    use super::*;
    // 仅 quickjs 门控测试使用（默认 cargo test 无该 feature，不门控会报未使用导入）
    #[cfg(feature = "quickjs")]
    use crate::api::web_book::RealBookSourceFetcher;
    use legado_core::models::rule::{BookInfoRule, SearchRule};

    fn mk_source(
        book_url: &str,
        pattern: Option<&str>,
        login_js: Option<&str>,
        rule_search: Option<SearchRule>,
    ) -> BookSource {
        BookSource {
            book_source_url: book_url.to_string(),
            book_source_name: "S0E-源".to_string(),
            book_url_pattern: pattern.map(|p| p.to_string()),
            login_check_js: login_js.map(|p| p.to_string()),
            rule_search,
            rule_book_info: Some(BookInfoRule {
                name: Some(".title".to_string()),
                author: Some(".author".to_string()),
                ..Default::default()
            }),
            ..BookSource::default()
        }
    }

    fn list_rules(book_list: &str) -> Option<SearchRule> {
        Some(SearchRule {
            book_list: Some(book_list.to_string()),
            name: Some(".name".to_string()),
            author: Some(".author".to_string()),
            book_url: Some("a@href".to_string()),
            ..Default::default()
        })
    }

    fn mk(source_url: &str, name: &str, book_url: &str) -> SearchResult {
        SearchResult {
            source_url: source_url.to_string(),
            source_name: "S0E-源".to_string(),
            book_name: name.to_string(),
            author: String::new(),
            book_url: book_url.to_string(),
            latest_chapter: None,
            intro: None,
            cover_url: None,
            kind: None,
            word_count: None,
            book_type: 0,
            origin_order: 0,
            has_read_record: false,
            read_record_author: None,
            variable: None,
        }
    }

    const LIST_BODY: &str = r#"<html><body>
        <div class="book-item"><a class="name" href="/book/1">列表书A</a><span class="author">作者A</span></div>
        </body></html>"#;
    const DETAIL_BODY: &str = r#"<html><body>
        <div class="title">直连书名</div><div class="author">直连作者</div>
        </body></html>"#;

    /// BookList.kt:62-81：搜索 URL 命中 bookUrlPattern → 详情页直连单条
    #[test]
    fn test_s0e_pattern_direct_hit_parses_detail() {
        let source = mk_source(
            "https://ex.com",
            Some(r#"^https://ex\.com/book/\d+$"#),
            None,
            list_rules(".book-item"),
        );
        let results =
            parse_search_response(DETAIL_BODY, "https://ex.com/book/123", &source).unwrap();
        assert_eq!(results.len(), 1, "命中 pattern 应按详情解析出单条");
        assert_eq!(results[0].book_name, "直连书名");
        assert_eq!(results[0].book_url, "https://ex.com/book/123");
        assert_eq!(results[0].author, "直连作者");
    }

    /// BookList.kt:62-81：pattern 存在但不命中 → 继续走列表解析
    #[test]
    fn test_s0e_pattern_miss_continues_list_parse() {
        let source = mk_source(
            "https://ex.com",
            Some(r#"^https://ex\.com/book/\d+$"#),
            None,
            list_rules(".book-item"),
        );
        let results =
            parse_search_response(LIST_BODY, "https://ex.com/search?kw=x", &source).unwrap();
        assert_eq!(results.len(), 1, "pattern 不命中应正常走列表解析");
        assert_eq!(results[0].book_name, "列表书A");
    }

    /// BookList.kt:100-108：列表空且未配置 pattern → 按详情页规则回退一次
    #[test]
    fn test_s0e_empty_list_falls_back_to_detail() {
        let source = mk_source("https://ex.com", None, None, list_rules(".none"));
        let results = parse_search_response(DETAIL_BODY, "https://ex.com/s", &source).unwrap();
        assert_eq!(results.len(), 1, "空列表应回退详情解析");
        assert_eq!(results[0].book_name, "直连书名");
        assert_eq!(
            results[0].book_url, "https://ex.com/s",
            "回退 bookUrl=baseUrl"
        );
    }

    /// BookList.kt:100-108：pattern 已配置但不命中且列表空 → 不回退、返回空
    #[test]
    fn test_s0e_empty_list_with_pattern_no_fallback() {
        let source = mk_source(
            "https://ex.com",
            Some(r#"^https://ex\.com/book/\d+$"#),
            None,
            list_rules(".none"),
        );
        let results =
            parse_search_response(LIST_BODY, "https://ex.com/search?kw=x", &source).unwrap();
        assert!(results.is_empty(), "pattern 不命中且列表空 → 直接空结果");
    }

    /// SearchBook.kt:65：去重键 = bookUrl 单键（同名同 URL 不重复、同 URL 不同名也去重）
    #[test]
    fn test_s0e_dedup_key_is_book_url_only() {
        let items = vec![
            mk("s1", "甲", "https://ex.com/b/1"),
            mk("s1", "乙", "https://ex.com/b/1"), // 同 URL 不同名 → 去重
        ];
        let d = dedup_search_results_keep_first(items);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].book_name, "甲", "保留首次出现");
    }

    /// WebBook.kt:74-98：loginCheckJs 通过（quickjs）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_s0e_login_check_pass() {
        let source = mk_source("https://ex.com", None, Some("result.code() == 200"), None);
        RealBookSourceFetcher::execute_login_check(&source, "ok", "https://ex.com/s", 200)
            .expect("code 200 应通过");
    }

    /// WebBook.kt:88-90：首检未登录 + errResponse 二次 eval 仍未登录 → LoginRequired
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_s0e_login_check_required() {
        let source = mk_source("https://ex.com", None, Some("false"), None);
        let err = RealBookSourceFetcher::execute_login_check(&source, "b", "https://ex.com/s", 200)
            .expect_err("false 应判定未登录");
        assert!(matches!(err, LegadoError::LoginRequired(_)));
    }

    /// WebBook.kt:91-97：errResponse 路径 JS「自动登录」恢复 → 放行
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_s0e_login_check_err_path_recovers() {
        let source = mk_source(
            "https://ex.com",
            None,
            Some("result.code() == 200 ? 'false' : 'ok'"),
            None,
        );
        RealBookSourceFetcher::execute_login_check(&source, "b", "https://ex.com/s", 200)
            .expect("errResponse 二次 eval 返回非 false 应放行");
    }
}

/// BookType 位标志（对齐原版 `io.legado.app.constant.BookType`）
pub(crate) mod book_type {
    /// 4 视频
    pub const VIDEO: i32 = 0b100;
    /// 8 文本
    pub const TEXT: i32 = 0b1000;
    /// 32 音频
    pub const AUDIO: i32 = 0b100000;
    /// 64 图片（漫画）
    pub const IMAGE: i32 = 0b1000000;
    /// 128 只提供下载服务的网站
    pub const WEB_FILE: i32 = 0b10000000;
}

/// 书源类型 → BookType（对齐原版 `BookSource.getBookType()`：
/// file→text|webFile、image→image、audio→audio、video→video、其余→text）
pub(crate) fn book_type_of_source(source_type: i32) -> i32 {
    use legado_core::models::book_source_type as st;
    match source_type {
        st::FILE => book_type::TEXT | book_type::WEB_FILE,
        st::IMAGE => book_type::IMAGE,
        st::AUDIO => book_type::AUDIO,
        st::VIDEO => book_type::VIDEO,
        _ => book_type::TEXT,
    }
}

/// 字数格式化（对齐原版 `StringUtils.wordCountFormat(String)`：
/// 纯数字 >10000 → 「x.x万字」；>0 → 「n字」；非数字原样；空/<=0 → None）
///
/// `pub(crate)`：explore 链路复用（发现页修复 A7）。— DeepSeek Harness + Bridge
pub(crate) fn word_count_format(raw: &str) -> Option<String> {
    let t = raw.trim();
    if t.is_empty() {
        return None;
    }
    match t.parse::<i64>() {
        Ok(n) if n > 10000 => {
            let v = n as f64 / 10000.0;
            let scaled = (v * 10.0).round();
            let s = if scaled % 10.0 == 0.0 {
                format!("{}", scaled as i64 / 10)
            } else {
                format!("{:.1}", scaled / 10.0)
            };
            Some(format!("{s}万字"))
        }
        Ok(n) if n > 0 => Some(format!("{n}字")),
        Ok(_) => None,
        Err(_) => Some(t.to_string()),
    }
}

/// 解析 URL（将相对路径转为绝对路径）
fn resolve_url(url: &str, base_url: &str) -> String {
    if url.is_empty() {
        return String::new();
    }
    // 已是绝对 URL
    if url.starts_with("http://") || url.starts_with("https://") {
        return url.to_string();
    }
    // 协议相对
    if url.starts_with("//") {
        if let Some(pos) = base_url.find("://") {
            return format!("{}:{}", &base_url[..pos], url);
        }
        return format!("https:{}", url);
    }
    // 绝对路径
    if url.starts_with('/') {
        if let Some(pos) = base_url.find("://") {
            if let Some(slash_pos) = base_url[pos + 3..].find('/') {
                let domain = &base_url[..pos + 3 + slash_pos];
                return format!("{}{}", domain, url);
            }
        }
        return format!("{}{}", base_url.trim_end_matches('/'), url);
    }
    // 相对路径
    if let Some(pos) = base_url.rfind('/') {
        format!("{}/{}", &base_url[..pos], url)
    } else {
        format!("{}/{}", base_url, url)
    }
}

/// 解析 JSON 格式的请求头字符串
fn parse_header_option(header_str: Option<&str>) -> Option<HashMap<String, String>> {
    header_str.and_then(|s| serde_json::from_str(s).ok())
}

/// 请求头缺少 User-Agent 时补充 Chrome UA
///
/// [UI-fix 2026-08-10 | Reasonix] 对齐原版 BaseSource.kt:202-204 + AppConfig.userAgent：
/// 默认 UA（Legado/1.0）会被反爬站点识别为非浏览器而拒绝/返回空列表。
/// 书源 header 已配置 UA（任意大小写键名）时不覆盖。
fn ensure_default_user_agent(headers: &mut HashMap<String, String>) {
    if !headers.keys().any(|k| k.eq_ignore_ascii_case("user-agent")) {
        headers.insert(
            "User-Agent".to_string(),
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                .to_string(),
        );
    }
}

/// JS 书源搜索（通过 JsSourceBookOrchestrator 执行）
///
/// 使用 spawn_blocking 将 JS 执行移出 tokio worker 线程，
/// 避免 JS 宿主函数内部 block_on 导致嵌套 runtime 死锁（R1）。
async fn search_js_source(
    source: &BookSource,
    keyword: &str,
    page: i32,
) -> LegadoResult<Vec<SearchResult>> {
    let source_clone = source.clone();
    let key = keyword.to_string();

    let values = tokio::task::spawn_blocking(move || {
        let orchestrator = crate::api::web_book::build_js_orchestrator(&source_clone)?;
        let mut orch =
            orchestrator.ok_or_else(|| LegadoError::Internal("JS 书源缺少 mainJs".into()))?;
        // 页码透传（批次B G-B-01）：原硬编码 page=1，现由调用方传入
        orch.search(&source_clone, &key, page)
    })
    .await
    .map_err(|e| LegadoError::Internal(format!("JS 搜索任务异常: {e}")))??;

    // 将 serde_json::Value 转换为 SearchResult
    let results = values
        .into_iter()
        .filter_map(|v| {
            let book_name = v.get("name")?.as_str()?.to_string();
            let book_url = v.get("bookUrl")?.as_str()?.to_string();
            if book_name.is_empty() || book_url.is_empty() {
                return None;
            }
            Some(SearchResult {
                source_url: source.book_source_url.clone(),
                source_name: source.book_source_name.clone(),
                book_name,
                author: v
                    .get("author")
                    .and_then(|a| a.as_str())
                    .unwrap_or_default()
                    .to_string(),
                book_url,
                latest_chapter: v
                    .get("latestChapter")
                    .or_else(|| v.get("lastChapter"))
                    .and_then(|l| l.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                intro: v
                    .get("intro")
                    .and_then(|i| i.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                cover_url: v
                    .get("coverUrl")
                    .and_then(|c| c.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                kind: v
                    .get("kind")
                    .and_then(|k| k.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string()),
                word_count: v
                    .get("wordCount")
                    .and_then(|w| w.as_str())
                    .and_then(word_count_format),
                book_type: book_type_of_source(source.book_source_type),
                // [P0-2 S4 | BookList.kt:215] originOrder = source.customOrder（真实书源排序，非默认 0）
                origin_order: source.custom_order,
                // [T5] JS 源返回 JSON 可携带 variable（JS 源搜索期变量）
                variable: v
                    .get("variable")
                    .and_then(|x| x.as_str())
                    .filter(|x| !x.is_empty())
                    .map(|x| x.to_string()),
                // 阅读记录标识由搜索完成后统一批量附加（见 annotate_results）
                has_read_record: false,
                read_record_author: None,
            })
        })
        .collect();

    Ok(results)
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::SearchRule;
    use legado_core::SourceSearcher;
    use legado_net::LegadoClientConfig;

    /// 构造带搜索规则的书源
    fn make_source_with_rules(
        book_list: &str,
        name: &str,
        author: &str,
        book_url: &str,
        cover_url: &str,
        intro: &str,
        last_chapter: &str,
    ) -> BookSource {
        BookSource {
            book_source_url: "https://www.example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://www.example.com/search?q={key}".to_string()),
            rule_search: Some(SearchRule {
                book_list: Some(book_list.to_string()),
                name: Some(name.to_string()),
                author: Some(author.to_string()),
                book_url: Some(book_url.to_string()),
                cover_url: Some(cover_url.to_string()),
                intro: Some(intro.to_string()),
                last_chapter: Some(last_chapter.to_string()),
                ..SearchRule::default()
            }),
            ..BookSource::default()
        }
    }

    // ─── 测试 1: HTML 搜索结果解析 ────────────────────────────────────────────

    #[test]
    fn test_parse_origin_order_from_custom_order() {
        // [P0-2 S4 | BookList.kt:215] originOrder 必须来自 source.customOrder（非默认 0）
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/book/1">斗破苍穹</a>
                <span class="author">天蚕土豆</span>
            </div>
        </body></html>"#;
        let mut source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );
        source.custom_order = 7;
        let results =
            parse_search_response(html, "https://www.example.com/search?q=test", &source).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].origin_order, 7);
    }

    #[test]
    fn test_result_to_search_book_preserves_origin_order() {
        // [P0-2 S4] DTO 转换必须透传真实 originOrder（原恒写 0）
        let r = SearchResult {
            source_url: "https://s.example.com".into(),
            source_name: "src".into(),
            book_name: "book".into(),
            author: "a".into(),
            book_url: "https://s.example.com/b/1".into(),
            latest_chapter: None,
            intro: None,
            cover_url: None,
            kind: None,
            word_count: None,
            book_type: 0,
            origin_order: 5,
            has_read_record: false,
            read_record_author: None,
            variable: None,
        };
        let core = result_to_search_book(r);
        assert_eq!(core.origin_order, 5);
    }

    #[test]
    fn test_parse_html_search_results() {
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/book/1">斗破苍穹</a>
                <span class="author">天蚕土豆</span>
                <img class="cover" src="/covers/1.jpg" />
                <p class="intro">这里是简介</p>
                <span class="last">第100章 大结局</span>
            </div>
            <div class="book-item">
                <a class="name" href="/book/2">凡人修仙传</a>
                <span class="author">忘语</span>
                <img class="cover" src="/covers/2.jpg" />
                <p class="intro">修仙之路</p>
                <span class="last">第200章 飞升</span>
            </div>
        </body></html>"#;

        let source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );

        let results =
            parse_search_response(html, "https://www.example.com/search?q=test", &source).unwrap();

        assert_eq!(results.len(), 2);

        // 验证第一条结果
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert_eq!(results[0].author, "天蚕土豆");
        assert_eq!(results[0].book_url, "https://www.example.com/book/1");
        assert_eq!(
            results[0].cover_url,
            Some("https://www.example.com/covers/1.jpg".to_string())
        );
        assert_eq!(results[0].intro, Some("这里是简介".to_string()));
        assert_eq!(
            results[0].latest_chapter,
            Some("第100章 大结局".to_string())
        );
        assert_eq!(results[0].source_url, "https://www.example.com");
        assert_eq!(results[0].source_name, "测试书源");

        // 验证第二条结果
        assert_eq!(results[1].book_name, "凡人修仙传");
        assert_eq!(results[1].author, "忘语");
        assert_eq!(results[1].book_url, "https://www.example.com/book/2");
    }

    /// 搜索解析须清洗书名/作者（对齐 BookList + BookHelp），否则 mergeItems 聚合键分裂
    #[test]
    fn test_parse_search_formats_name_author() {
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/book/1">斗破苍穹 作者天蚕土豆</a>
                <span class="author">作者：天蚕土豆</span>
            </div>
            <div class="book-item">
                <a class="name" href="/book/2">斗破苍穹</a>
                <span class="author">天蚕土豆 著</span>
            </div>
        </body></html>"#;

        let source = make_source_with_rules(
            ".book-item",
            ".name@text",
            ".author@text",
            "a@href",
            "img@src",
            ".intro@text",
            ".latest@text",
        );

        let results =
            parse_search_response(html, "https://www.example.com/search?q=test", &source).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert_eq!(results[0].author, "天蚕土豆");
        assert_eq!(results[1].book_name, "斗破苍穹");
        assert_eq!(results[1].author, "天蚕土豆");
    }

    // ─── 测试 1.1: bookUrl 规则为空时回退 baseUrl（对齐原版 BookList.kt）───

    #[test]
    fn test_parse_html_book_url_empty_falls_back_to_base() {
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name">斗破苍穹</a>
                <span class="author">天蚕土豆</span>
            </div>
        </body></html>"#;
        // bookUrl 规则指向不存在的属性 → 解析为空串
        let source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".missing-attr@href",
            "",
            "",
            "",
        );

        let results =
            parse_search_response(html, "https://www.example.com/search?q=test", &source).unwrap();

        assert_eq!(results.len(), 1);
        // [S0-E] 空 bookUrl 回退 baseUrl（=传入的最终搜索页 URL，BookList.kt:281-284）
        assert_eq!(results[0].book_url, "https://www.example.com/search?q=test");
    }

    // ─── 测试 1.2: 请求头缺 UA 时补充 Chrome UA ───────────────────────────────

    #[test]
    fn test_ensure_default_user_agent_adds_when_missing() {
        let mut headers = HashMap::new();
        headers.insert("Referer".to_string(), "https://www.example.com".to_string());
        ensure_default_user_agent(&mut headers);
        assert!(headers
            .get("User-Agent")
            .unwrap()
            .starts_with("Mozilla/5.0"));
    }

    #[test]
    fn test_ensure_default_user_agent_keeps_source_ua() {
        // 书源 header 已配置 UA（含小写键名）时不覆盖
        let mut headers = HashMap::new();
        headers.insert("user-agent".to_string(), "CustomMobile/1.0".to_string());
        ensure_default_user_agent(&mut headers);
        assert_eq!(headers.get("user-agent").unwrap(), "CustomMobile/1.0");
        assert!(headers.keys().all(|k| k != "User-Agent"));
    }

    // ─── 测试 1.5: sto66 真实响应体复现（XPath bookList + ## 替换）───────────

    /// Task #30 复现：sto66.com 搜索页（真实结构：无引号属性、未闭合 meta/link、
    /// 内嵌脚本），ruleSearch 为 XPath 规则且带 `##` 替换后缀。
    /// 修复前：严格 XML 解析失败→bookList 0 条；修复后：应解析出 >0 条。
    #[test]
    fn test_parse_sto66_real_response_xpath() {
        // 真实响应体片段（取自 https://www.sto66.com/search/99.html，保留致 XML 解析失败的特征）
        let html = "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"zh-CN\">\
            <head><title>搜索:99-思绪阅读</title>\
            <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>\
            <meta name=\"viewport\" content=\"width=device-width\">\
            <link rel=\"icon\" href=\"/sto/images/app-icon72x72.png\">\
            <script src=\"/sto/js/default.js\" type=\"text/javascript\"></script>\
            </head><body>\
            <div class=header-left><a href=\"/\" class=\"logo\">思绪阅读</a></div>\
            <div class=\"bookbox\"><div class=\"p10\"><span class=\"num\">1</span>\
            <div class=\"bookinfo\"><h2 class=\"bookname\">\
            <a href=\"/book/26zvJv0kmLb9N2oyvORpxn.html\">重案1990</a></h2>\
            <div class=\"author\">作者：高山流水</div>\
            <div class=\"author\">字数：125.6万</div>\
            <div class=\"cat\"><span>现代都市</span>\
            <a href=\"/chapter/26zvJv0kmLb9N2oyvORpxn/2FqUlMjy8jQylEJA0rygGF.html\">第353章 大结局</a></div>\
            <div class=\"update\"><span>简介：</span>重回1990年的刑侦故事</div>\
            </div><div class=\"delbutton\">\
            <a class=\"del_but\" href=\"/book/26zvJv0kmLb9N2oyvORpxn.html\">阅读</a>\
            </div></div></div>\
            <div class=\"bookbox\"><div class=\"p10\"><span class=\"num\">2</span>\
            <div class=\"bookinfo\"><h2 class=\"bookname\">\
            <a href=\"/book/63c1MuMNVQJEGWKNltSyG8.html\">全能魔女1994</a></h2>\
            <div class=\"author\">作者：云中鹤</div>\
            <div class=\"author\">字数：411.5万</div>\
            <div class=\"cat\"><span>现代都市</span>\
            <a href=\"/chapter/63c1MuMNVQJEGWKNltSyG8/6nthAhzx8ioLiPhVN4roWq.html\">第一章 重生</a></div>\
            <div class=\"update\"><span>简介：</span>魔女重生的故事</div>\
            </div><div class=\"delbutton\">\
            <a class=\"del_but\" href=\"/book/63c1MuMNVQJEGWKNltSyG8.html\">阅读</a>\
            </div></div></div>\
            <div class=\"clear\"></div>\
            <div class=\"pages\"><div class=\"pagelink\">\
            <em id=\"pagestats\">1/6</em><a href=\"/search/99/2.html\">2</a>\
            </div></div></body></html>";

        // sto66 真实 ruleSearch（设备 DB 抓取）
        let source = BookSource {
            book_source_url: "https://www.sto66.com".to_string(),
            book_source_name: "思绪阅读".to_string(),
            rule_search: Some(SearchRule {
                book_list: Some("//*[contains(@class, 'bookbox')]".to_string()),
                name: Some("@XPath:.//*[contains(@class, 'bookname')]/a/text()".to_string()),
                author: Some(
                    "@XPath:.//*[contains(@class, 'author')][1]/text()##作者：".to_string(),
                ),
                book_url: Some("@XPath:.//*[contains(@class, 'bookname')]/a/@href".to_string()),
                intro: Some("@XPath:.//*[contains(@class, 'update')]//text()##简介：".to_string()),
                last_chapter: Some("@XPath:.//*[contains(@class, 'cat')]//a/text()".to_string()),
                ..SearchRule::default()
            }),
            ..BookSource::default()
        };

        let results =
            parse_search_response(html, "https://www.sto66.com/search/99.html", &source).unwrap();

        assert!(
            results.len() >= 2,
            "bookList 应解析出 ≥2 条，实际 {} 条",
            results.len()
        );
        assert_eq!(results[0].book_name, "重案1990");
        // ## 替换：作者前缀应被剔除
        assert_eq!(results[0].author, "高山流水");
        // 相对 URL 绝对化
        assert_eq!(
            results[0].book_url,
            "https://www.sto66.com/book/26zvJv0kmLb9N2oyvORpxn.html"
        );
        assert_eq!(
            results[0].latest_chapter,
            Some("第353章 大结局".to_string())
        );
        // ## 替换：简介前缀应被剔除（//text() 多节点按原版以换行连接，trim 后比较）
        assert_eq!(
            results[0].intro.as_deref().map(str::trim),
            Some("重回1990年的刑侦故事")
        );
        assert_eq!(results[1].book_name, "全能魔女1994");
        assert_eq!(results[1].author, "云中鹤");
    }

    // ─── 测试 1.6: 多源并发驱动器（异常隔离 + 限流 + 超时）───────────────

    /// Task #31：多源并发搜索语义——部分源成功/部分源失败/超时/panic 时，
    /// 成功源结果全部保留、失败源不阻断、并发数不超过上限。
    #[tokio::test]
    async fn test_drive_source_batches_isolation_concurrency_timeout() {
        use std::sync::atomic::AtomicUsize;

        let active = Arc::new(AtomicUsize::new(0));
        let max_active = Arc::new(AtomicUsize::new(0));

        let sources: Vec<BookSource> = ["ok1", "ok2", "fail", "slow", "panic"]
            .into_iter()
            .map(|u| BookSource {
                book_source_url: format!("https://{u}.example.com"),
                book_source_name: format!("源{u}"),
                ..BookSource::default()
            })
            .collect();

        let active_c = Arc::clone(&active);
        let max_c = Arc::clone(&max_active);
        let search_one = move |source: BookSource| {
            let active = Arc::clone(&active_c);
            let max_active = Arc::clone(&max_c);
            async move {
                let cur = active.fetch_add(1, Ordering::SeqCst) + 1;
                max_active.fetch_max(cur, Ordering::SeqCst);
                let url = source.book_source_url.clone();
                let name = source.book_source_name.clone();
                let result = if url.contains("slow") {
                    // 超过单源超时（500ms）→ 应被驱动器判为超时错误
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    Ok(Vec::new())
                } else if url.contains("panic") {
                    panic!("故意 panic：验证单源崩溃隔离");
                } else if url.contains("fail") {
                    Err(LegadoError::Network("故意失败".into()))
                } else {
                    Ok(vec![SearchResult {
                        source_url: url.clone(),
                        source_name: name.clone(),
                        book_name: format!("书{name}"),
                        author: "作者".into(),
                        book_url: format!("{url}/book/1"),
                        variable: None,
                        latest_chapter: None,
                        intro: None,
                        cover_url: None,
                        kind: None,
                        word_count: None,
                        book_type: book_type::TEXT,
                        origin_order: 0,
                        has_read_record: false,
                        read_record_author: None,
                    }])
                };
                // 持有并发窗口一小段时间，使最大并发观测可靠
                tokio::time::sleep(Duration::from_millis(50)).await;
                active.fetch_sub(1, Ordering::SeqCst);
                result
            }
        };

        let outcomes = Arc::new(std::sync::Mutex::new(Vec::new()));
        let outcomes_c = Arc::clone(&outcomes);
        drive_source_batches(
            sources,
            2,
            Duration::from_millis(500),
            &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            search_one,
            move |o| {
                let (n, err) = match o.result {
                    Ok(ref b) => (Some(b.len()), None),
                    Err(ref e) => (None, Some(e.to_string())),
                };
                outcomes_c.lock().unwrap().push((
                    o.source_url,
                    n,
                    err,
                    o.finished_count,
                    o.total_count,
                ));
                Ok(())
            },
        )
        .await;

        let got = outcomes.lock().unwrap();
        assert_eq!(
            got.len(),
            5,
            "每个书源都应产出一个批次（含失败/超时/panic）"
        );
        // 成功源结果全部保留
        let ok_books: usize = got.iter().filter_map(|(_, n, _, _, _)| *n).sum();
        assert_eq!(ok_books, 2, "两个成功源各 1 本书应全部保留");
        // 失败/超时/panic 均有错误信息且不阻断其他源
        assert!(got
            .iter()
            .any(|(u, _, e, _, _)| u.contains("fail") && e.is_some()));
        assert!(got.iter().any(|(u, _, e, _, _)| u.contains("slow")
            && e.as_deref().is_some_and(|m| m.contains("超时"))));
        assert!(got
            .iter()
            .any(|(u, _, e, _, _)| u.contains("panic") && e.is_some()));
        // 进度 total 正确且存在收尾批次（finished == total）
        assert!(got.iter().all(|(_, _, _, _, t)| *t == 5));
        assert!(got.iter().any(|(_, _, _, f, t)| f == t));
        // 并发上限：最大同时在跑的单源搜索不超过 2
        assert!(
            max_active.load(Ordering::SeqCst) <= 2,
            "最大并发 {} 超过上限 2",
            max_active.load(Ordering::SeqCst)
        );
    }
    // ─── P0-3 真实重叠压力测试（复审 7.3）：A 运行中被取代 → A 中止（排队源不发请求、
    //     在飞结果不交付 on_source），B 干净执行。取消标志直接置位模拟「register(B) 取消 A」，
    //     避免触碰全局 CURRENT_SEARCH_SESSION（与并发测试隔离）──
    #[tokio::test]
    async fn test_search_overlap_a_replaced_by_b() {
        use std::sync::atomic::AtomicUsize;

        // A：concurrency=2 → 前 2 源在飞（sleep 阻塞），后 3 源排队
        let a_started = Arc::new(AtomicUsize::new(0)); // A 已发起请求的源数
        let a_delivered = Arc::new(AtomicUsize::new(0)); // A on_source 交付次数（取消后应为 0）
        let session_a = Arc::new(SearchSession::new());

        let search_one_a = {
            let c = Arc::clone(&a_started);
            move |_s: BookSource| {
                let cc = Arc::clone(&c);
                async move {
                    cc.fetch_add(1, Ordering::SeqCst);
                    // 模拟「在飞」：阻塞一段时间（被 abort 前不会自行结束）
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    Ok(Vec::new())
                }
            }
        };
        let sources_a: Vec<BookSource> = (1..=5)
            .map(|i| BookSource {
                book_source_url: format!("https://a{i}.example.com"),
                ..BookSource::default()
            })
            .collect();

        // 在独立任务中运行 A（与 B 真正并发）；on_source 记录交付次数
        let a_delivered_c = Arc::clone(&a_delivered);
        let sa = Arc::clone(&session_a); // 移入闭包的克隆；session_a 保留用于后续置位取消
        let drive_a = tokio::spawn(async move {
            drive_source_batches(
                sources_a,
                2,
                Duration::from_secs(30),
                &sa.cancel,
                &sa.paused,
                search_one_a,
                |_o: SourceBatchOutcome<SearchResult>| {
                    a_delivered_c.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                },
            )
            .await;
        });

        // 等 A 有 2 个在飞（前 2 源已派发，后 3 源排队）
        for _ in 0..400 {
            if a_started.load(Ordering::SeqCst) >= 2 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(
            a_started.load(Ordering::SeqCst),
            2,
            "A 应有 2 个在飞源（concurrency=2）"
        );

        // B：独立会话、未取消，与 A 并发运行；同时置位 A 的取消标志（模拟 register(B) 取消 A，
        // 覆盖显式停止 / 页面销毁入口——二者均置 cancel 标志）
        let b_started = Arc::new(AtomicUsize::new(0));
        let session_b = Arc::new(SearchSession::new());
        let search_one_b = {
            let c = Arc::clone(&b_started);
            move |_s: BookSource| {
                let cc = Arc::clone(&c);
                async move {
                    cc.fetch_add(1, Ordering::SeqCst);
                    Ok(Vec::new())
                }
            }
        };
        let sources_b: Vec<BookSource> = (1..=5)
            .map(|i| BookSource {
                book_source_url: format!("https://b{i}.example.com"),
                ..BookSource::default()
            })
            .collect();

        session_a.cancel.store(true, Ordering::SeqCst); // 模拟 B 取代 A → 取消 A
        let drive_b = tokio::spawn(async move {
            drive_source_batches(
                sources_b,
                32,
                Duration::from_secs(30),
                &session_b.cancel,
                &session_b.paused,
                search_one_b,
                // T 由 on_source 闭包标注固定（泛型驱动器推断需要）
                |_o: SourceBatchOutcome<SearchResult>| Ok(()),
            )
            .await;
        });

        let _ = drive_a.await; // A：检测取消 → abort_all + drain（约 300ms）
        let _ = drive_b.await; // B：全部执行

        // A：排队源（后 3 个）从不发请求 → a_started 恒为 2
        assert_eq!(
            a_started.load(Ordering::SeqCst),
            2,
            "A 的排队源在取消后不应发起任何请求"
        );
        // A：在飞结果不交付 on_source（取消后 break，未交付任何批次）→ 不进流/状态/落库
        assert_eq!(
            a_delivered.load(Ordering::SeqCst),
            0,
            "A 取消后在飞结果不应进入 on_source/流"
        );
        // B：全新会话 → 全部执行，不受 A 影响（会话隔离）
        assert_eq!(
            b_started.load(Ordering::SeqCst),
            5,
            "B 应全部执行（会话隔离，A 未污染 B）"
        );
    }

    // ─── 取消即时唤醒（P0-3 强化）：取消置位时收集循环正阻塞在 set.next()，
    //     必须立即 abort 在飞任务并返回，而不昏等待最快下一个自然完成。
    #[tokio::test]
    async fn test_drive_cancel_wakes_blocked_collect_promptly() {
        use std::sync::atomic::AtomicUsize;

        // 在飞任务永不自行完成：阻塞在 Notify 上（模拟长连接）
        let started = Arc::new(AtomicUsize::new(0));
        let gate = Arc::new(tokio::sync::Notify::new());
        let search_one = {
            let g = Arc::clone(&gate);
            let c = Arc::clone(&started);
            move |_s: BookSource| {
                let g = Arc::clone(&g);
                let cc = Arc::clone(&c);
                async move {
                    cc.fetch_add(1, Ordering::SeqCst);
                    g.notified().await; // 测试中永不放开
                    Ok(Vec::new())
                }
            }
        };
        let session = Arc::new(SearchSession::new());
        let delivered = Arc::new(AtomicUsize::new(0));
        let delivered_c = Arc::clone(&delivered);
        let sc = Arc::clone(&session);
        let sources: Vec<BookSource> = (1..=4)
            .map(|i| BookSource {
                book_source_url: format!("https://x{i}.example.com"),
                ..BookSource::default()
            })
            .collect();
        let drive = tokio::spawn(async move {
            drive_source_batches(
                sources,
                2,
                Duration::from_secs(30),
                &sc.cancel,
                &sc.paused,
                search_one,
                |_o: SourceBatchOutcome<SearchResult>| {
                    delivered_c.fetch_add(1, Ordering::SeqCst);
                    Ok(())
                },
            )
            .await;
        });

        // 等 2 个在飞（concurrency=2，后 2 源排队）
        for _ in 0..400 {
            if started.load(Ordering::SeqCst) >= 2 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(started.load(Ordering::SeqCst), 2, "应有 2 个在飞源");

        session.cancel.store(true, Ordering::SeqCst);
        // 取消必须即时（≤600ms）唤醒收集循环；在飞任务永不自然完成，
        // 若旧实现（等 set.next()）则永远超时。
        tokio::time::timeout(Duration::from_millis(600), drive)
            .await
            .expect("取消应即时中止收集循环")
            .expect("drive 不应 panic");
        assert_eq!(
            delivered.load(Ordering::SeqCst),
            0,
            "取消后不应交付任何批次"
        );
        // 被 abort 的任务 future 已 drop，通知无人接收也应安全
        gate.notify_waiters();
    }

    // ─── P0-3 sink 关闭入口（复审 7.3）：on_source 返回 Err → 驱动器中止剩余源、abort 在飞 ──
    #[tokio::test]
    async fn test_drive_source_batches_sink_err_aborts_remaining() {
        use std::sync::atomic::AtomicUsize;

        let started = Arc::new(AtomicUsize::new(0));
        let search_one = {
            let c = Arc::clone(&started);
            move |_s: BookSource| {
                let cc = Arc::clone(&c);
                async move {
                    cc.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(200)).await; // 在飞阻塞
                    Ok(Vec::new())
                }
            }
        };
        let sources: Vec<BookSource> = (1..=6)
            .map(|i| BookSource {
                book_source_url: format!("https://s{i}.example.com"),
                ..BookSource::default()
            })
            .collect();

        let cancel = Arc::new(AtomicBool::new(false));
        let paused = Arc::new(AtomicBool::new(false));
        let delivered = Arc::new(AtomicUsize::new(0));
        let delivered_c = Arc::clone(&delivered);

        drive_source_batches(
            sources,
            2, // concurrency=2 → 前 2 源在飞，后 4 源排队
            Duration::from_secs(30),
            &cancel,
            &paused,
            search_one,
            move |_o: SourceBatchOutcome<SearchResult>| {
                delivered_c.fetch_add(1, Ordering::SeqCst);
                Err("sink 已关闭".into()) // 第 1 个批次交付后立即 sink 关闭
            },
        )
        .await;

        // sink 在第 1 批次后关闭 → cancel 置位，剩余源中止、在飞 abort
        assert!(cancel.load(Ordering::SeqCst), "sink 关闭应置位会话取消");
        assert_eq!(
            delivered.load(Ordering::SeqCst),
            1,
            "只交付了 1 个批次即 sink 关闭"
        );
        // 只有前 2 源在飞（已派发）；后 4 排队源中止，不执行
        assert_eq!(
            started.load(Ordering::SeqCst),
            2,
            "sink 关闭后剩余排队源应中止（只执行了 2 个在飞源）"
        );
    }

    // ─── P0-3 会话注册与清理安全（复审 7.5）：register(B) 取消 A；A 的清理不误清 B ──
    //     触碰全局 CURRENT_SEARCH_SESSION → 用 TEST_SESSION_LOCK 串行化，避免与其他此类测试并发
    static TEST_SESSION_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[tokio::test]
    async fn test_session_registration_and_cleanup_safety() {
        let _lock = TEST_SESSION_LOCK.lock().unwrap();

        // A → B：注册 B 应取消 A，且当前会话变为 B
        let a = Arc::new(SearchSession::new());
        register_current_session(&a);
        assert!(is_current_session(&a), "注册后 A 应为当前会话");

        let b = Arc::new(SearchSession::new());
        register_current_session(&b);
        assert!(
            a.cancel.load(Ordering::SeqCst),
            "注册 B 应取消 A（新搜索取代）"
        );
        assert!(is_current_session(&b), "当前会话应为 B");
        assert!(
            !is_current_session(&a),
            "A 不再是当前会话（7.4：A 的 on_source 复检将 early-return，不落库）"
        );

        // A 的清理不应误清已启动的 B（Arc::ptr_eq 保护；复审 7.5）
        clear_current_session_if_same(&a);
        assert!(is_current_session(&b), "A 的清理不应清除 B");

        // B 的清理应清除自身
        clear_current_session_if_same(&b);
        assert!(!is_current_session(&b), "B 的清理应清除当前会话");
    }

    // ─── 测试 2: JSON 搜索结果解析 ────────────────────────────────────────────

    #[test]
    fn test_parse_json_search_results() {
        let json = r#"{
            "data": [
                {
                    "title": "三体",
                    "writer": "刘慈欣",
                    "url": "https://api.example.com/book/3",
                    "cover": "https://cdn.example.com/cover3.jpg",
                    "desc": "地球往事三部曲",
                    "lastCh": "第30章"
                },
                {
                    "title": "黑暗森林",
                    "writer": "刘慈欣",
                    "url": "https://api.example.com/book/4",
                    "cover": "https://cdn.example.com/cover4.jpg",
                    "desc": "面壁计划",
                    "lastCh": "第25章"
                }
            ]
        }"#;

        let source = make_source_with_rules(
            "@json:$.data[*]",
            "@json:$.title",
            "@json:$.writer",
            "@json:$.url",
            "@json:$.cover",
            "@json:$.desc",
            "@json:$.lastCh",
        );

        let results =
            parse_search_response(json, "https://api.example.com/search", &source).unwrap();

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "三体");
        assert_eq!(results[0].author, "刘慈欣");
        assert_eq!(results[0].book_url, "https://api.example.com/book/3");
        assert_eq!(
            results[0].cover_url,
            Some("https://cdn.example.com/cover3.jpg".to_string())
        );
        assert_eq!(results[0].intro, Some("地球往事三部曲".to_string()));
        assert_eq!(results[1].book_name, "黑暗森林");
    }

    // ─── 测试 3: 空结果和无规则处理 ───────────────────────────────────────────

    #[test]
    fn test_parse_empty_response() {
        let html = r#"<html><body><p>没有找到相关书籍</p></body></html>"#;

        let source =
            make_source_with_rules(".book-item", ".name", ".author", ".name@href", "", "", "");

        let results =
            parse_search_response(html, "https://www.example.com/search", &source).unwrap();

        assert!(results.is_empty());
    }

    #[test]
    fn test_parse_no_rule_search_returns_empty() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            book_source_name: "无规则源".to_string(),
            rule_search: None,
            ..BookSource::default()
        };

        let results =
            parse_search_response("<html></html>", "https://www.example.com", &source).unwrap();

        assert!(results.is_empty());
    }

    // ─── 测试 4: URL 解析（相对/绝对/协议相对）────────────────────────────────

    #[test]
    fn test_resolve_url_variants() {
        let base = "https://www.example.com/search/page";

        // 绝对 URL 不变
        assert_eq!(
            resolve_url("https://other.com/book/1", base),
            "https://other.com/book/1"
        );

        // 协议相对
        assert_eq!(
            resolve_url("//cdn.example.com/cover.jpg", base),
            "https://cdn.example.com/cover.jpg"
        );

        // 绝对路径
        assert_eq!(
            resolve_url("/book/1", base),
            "https://www.example.com/book/1"
        );

        // 相对路径
        assert_eq!(
            resolve_url("detail.html", base),
            "https://www.example.com/search/detail.html"
        );

        // 空 URL
        assert_eq!(resolve_url("", base), "");
    }

    // ─── 测试 5: build_search_url 关键词替换 ──────────────────────────────────

    #[test]
    fn test_build_search_url_key_replacement() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            ..BookSource::default()
        };

        // {key} 替换
        let url = build_search_url(
            "https://www.example.com/search?q={key}",
            "斗破苍穹",
            &source,
        );
        assert!(url.url().contains("斗破苍穹") || url.url().contains("%E6%96%97"));

        // {{key}} 替换
        let url2 = build_search_url("https://www.example.com/search?q={{key}}", "三体", &source);
        assert!(url2.url().contains("三体") || url2.url().contains("%E4%B8%89"));

        // searchKey 替换
        let url3 = build_search_url(
            "https://www.example.com/search?q=searchKey",
            "rust",
            &source,
        );
        assert!(url3.url().contains("rust"));
    }

    // ─── 测试 6: POST 方法检测 ────────────────────────────────────────────────

    #[test]
    fn test_build_search_url_post_method() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            ..BookSource::default()
        };

        let url = build_search_url(
            r#"https://www.example.com/api,{"method":"POST","body":"keyword={key}"}"#,
            "测试",
            &source,
        );
        assert_eq!(url.method(), &RequestMethod::Post);
        assert!(url.body().unwrap_or("").contains("测试"));
    }

    // ─── 测试 7: WebSourceSearcher 错误容错 ───────────────────────────────────

    #[tokio::test]
    async fn test_web_source_searcher_no_search_url() {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        let searcher = WebSourceSearcher::new(client);

        // 无 searchUrl 的书源应返回空列表（不 panic）
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "无搜索源".to_string(),
            search_url: None,
            ..BookSource::default()
        };

        let results = searcher.search(&source, "测试", 10).await;
        assert!(results.is_empty());
    }

    // ─── 测试 8: 无书名时跳过该条目 ──────────────────────────────────────────

    #[test]
    fn test_parse_skips_items_without_name() {
        let html = r#"<html><body>
            <div class="book-item">
                <span class="author">无名氏</span>
            </div>
            <div class="book-item">
                <a class="name" href="/book/9">有书名</a>
                <span class="author">作者A</span>
            </div>
        </body></html>"#;

        let source =
            make_source_with_rules(".book-item", ".name", ".author", ".name@href", "", "", "");

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        // 第一条无书名被跳过，只剩第二条
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_name, "有书名");
    }

    // ─── T6: CSS 提取 + @js: 链求值 bookUrl（对齐原版 splitSourceRule）───
    #[test]
    fn test_parse_search_book_url_css_js_chain() {
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/novel/42">书名</a>
                <span class="author">作者</span>
            </div>
        </body></html>"#;

        let source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            // 先取 href，再经 JS 拼接绝对路径（黑岩等 JS 链书源形态）
            r#".name@href@js:'https://www.example.com'+result"#,
            "",
            "",
            "",
        );

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        #[cfg(feature = "quickjs")]
        {
            assert_eq!(results.len(), 1);
            assert_eq!(
                results[0].book_url, "https://www.example.com/novel/42",
                "CSS@js 链应产出非空绝对 bookUrl"
            );
            assert!(!results[0].book_url.is_empty());
        }

        #[cfg(not(feature = "quickjs"))]
        {
            // 无 quickjs：链中 JS 段降级，bookUrl 空则回退书源主页
            assert_eq!(results.len(), 1);
            assert_eq!(results[0].book_url, "https://www.example.com");
        }
    }

    // ─── 测试 9: @js: 搜索规则注入（quickjs 启用时生效，否则降级）───────────────

    #[test]
    fn test_parse_search_js_rule() {
        let html = r#"<html><body>
            <div class="book-item"><span class="author">作者</span></div>
        </body></html>"#;

        // name / book_url 规则使用 @js:：quickjs 启用时返回固定值，未启用时降级为空
        let source = make_source_with_rules(
            ".book-item",
            "@js:'JS注入书名'",
            ".author",
            "@js:'https://www.example.com/book/js'",
            "",
            "",
            "",
        );

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        #[cfg(feature = "quickjs")]
        {
            assert_eq!(results.len(), 1, "quickjs 启用时 @js: 规则应被执行");
            assert_eq!(results[0].book_name, "JS注入书名");
            assert_eq!(results[0].book_url, "https://www.example.com/book/js");
        }

        #[cfg(not(feature = "quickjs"))]
        {
            // 未启用 quickjs：@js: 规则降级为空，书名为空该条目被跳过
            assert!(results.is_empty(), "未启用 quickjs 时 @js: 规则应降级为空");
        }
    }

    /// P0-2 S1：搜索主路径须建立 source/cookie JS 上下文（对齐原版 AnalyzeRule(ruleData, bookSource)）。
    /// name 规则 `@js:String(source.getKey())` 引用书源上下文——此前搜索仅注入 jsLib（无 setup），
    /// `source is not defined` ReferenceError → 字段降级为空；现经 construct_analyzer_with_source_context
    /// 注入 setup，source.getKey() = bookSourceUrl（对齐 BaseSource.getKey()）。
    #[test]
    fn test_parse_search_source_context_available() {
        let html = r#"<html><body>
            <div class="book-item"><span class="author">作者</span></div>
        </body></html>"#;

        let mut source = make_source_with_rules(
            ".book-item",
            "@js:String(source.getKey())",
            ".author",
            "",
            "",
            "",
            "",
        );
        // bookSourceUrl 即 source.getKey() 返回值（对齐原版 BaseSource.getKey()）
        source.book_source_url = "https://src.example.com".to_string();

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        #[cfg(feature = "quickjs")]
        {
            assert_eq!(
                results.len(),
                1,
                "quickjs：source 上下文应可用，@js: 规则执行"
            );
            assert_eq!(results[0].book_name, "https://src.example.com");
        }

        #[cfg(not(feature = "quickjs"))]
        {
            // 未启用 quickjs：@js: 规则降级为空 → 书名为空该条目被跳过
            assert!(results.is_empty());
        }
    }

    // ─── 测试 fix32: 无匹配/字段完整/多媒体识别 ──────────────

    /// 无匹配：bookList 匹配为空 → 记 0 条 success（非 error、不挂起，对齐原版空列表语义）
    #[test]
    fn test_parse_no_match_is_zero_success() {
        let source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );
        let body = "<html><body><p>没有找到相关书籍</p></body></html>";
        let results =
            parse_search_response(body, "https://www.example.com/search?q=zzz", &source).unwrap();
        assert!(results.is_empty(), "无匹配应记 0 条而非 error");
    }

    /// 字段完整性：kind/wordCount/cover 绝对化/bookType；部分字段缺失不致整条丢弃
    #[test]
    fn test_parse_fields_complete_and_partial_failure_isolated() {
        let mut source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );
        if let Some(r) = source.rule_search.as_mut() {
            r.kind = Some(".kind".into());
            r.word_count = Some(".wc".into());
        }
        // image（漫画）源 → BookType.image
        source.book_source_type = 2;
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/b/1">漫画书</a>
                <span class="author">作者</span>
                <img class="cover" src="/c/1.jpg" />
                <span class="kind">漫画,热血</span>
                <span class="wc">123456</span>
            </div>
            <div class="book-item">
                <a class="name" href="/b/2">缺字段书</a>
                <span class="author">乙</span>
            </div>
        </body></html>"#;

        let results =
            parse_search_response(html, "https://www.example.com/search", &source).unwrap();
        assert_eq!(results.len(), 2);
        let first = &results[0];
        assert_eq!(first.kind.as_deref(), Some("漫画,热血"));
        assert_eq!(first.word_count.as_deref(), Some("12.3万字"));
        // cover 相对路径绝对化（对齐原版 NetworkUtils.getAbsoluteURL）
        assert_eq!(
            first.cover_url.as_deref(),
            Some("https://www.example.com/c/1.jpg")
        );
        assert_eq!(first.book_type, book_type::IMAGE);
        // 第二条缺 cover/kind/wordCount 仍保留（只剔空 name/url）
        let second = &results[1];
        assert_eq!(second.book_name, "缺字段书");
        assert!(second.cover_url.is_none());
        assert!(second.kind.is_none());
        assert!(second.word_count.is_none());
        assert_eq!(second.book_type, book_type::IMAGE);
    }

    /// kind 多标签：多个匹配元素按原版 `getStringList().joinToString(",")` 用逗号分隔（BookList.kt:230）
    #[test]
    fn test_parse_kind_multi_match_joined_with_comma() {
        let mut source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );
        if let Some(r) = source.rule_search.as_mut() {
            r.kind = Some(".kind".into());
        }
        // 单个 book-item 内含 3 个 .kind 元素 → kind 规则多匹配
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/b/1">书A</a>
                <span class="author">作者</span>
                <span class="kind">科幻</span>
                <span class="kind">都市</span>
                <span class="kind">玄幻</span>
            </div>
        </body></html>"#;
        let results =
            parse_search_response(html, "https://www.example.com/search", &source).unwrap();
        assert_eq!(results.len(), 1);
        // 3 个 kind 元素 → 原版 joinToString(",") → 逗号分隔（而非 \n）
        assert_eq!(results[0].kind.as_deref(), Some("科幻,都市,玄幻"));
    }

    /// bookType 判定对齐原版 `BookSource.getBookType()`
    #[test]
    fn test_book_type_of_source_mapping() {
        assert_eq!(book_type_of_source(0), book_type::TEXT);
        assert_eq!(book_type_of_source(1), book_type::AUDIO);
        assert_eq!(book_type_of_source(2), book_type::IMAGE);
        assert_eq!(
            book_type_of_source(3),
            book_type::TEXT | book_type::WEB_FILE
        );
        assert_eq!(book_type_of_source(4), book_type::VIDEO);
    }

    /// wordCountFormat 对齐原版 StringUtils.wordCountFormat
    #[test]
    fn test_word_count_format_aligns_original() {
        assert_eq!(word_count_format("123456").as_deref(), Some("12.3万字"));
        assert_eq!(word_count_format("20000").as_deref(), Some("2万字"));
        assert_eq!(word_count_format("5000").as_deref(), Some("5000字"));
        assert_eq!(word_count_format(""), None);
        assert_eq!(word_count_format("0"), None);
        assert_eq!(word_count_format("连载中").as_deref(), Some("连载中"));
    }

    /// 回归：单源超时对阻塞型同步计算生效，整体不挂起
    ///
    /// 实机缺陷回归：同步解析占住 tokio worker 时 `tokio::time::timeout`
    /// 无法触发，信号量排队导致整体挂起（691/692 卡死）。
    /// 修复后同步长计算在阻塞线程执行（spawn_blocking），超时在 await 点生效：
    /// 超时源记错误批次、整体立即完成，不等阻塞任务。
    #[tokio::test]
    async fn test_drive_timeout_effective_for_blocking_parse() {
        use std::time::Duration;
        let sources = vec![make_source_with_rules(".b", ".n", ".a", ".u", "", "", "")];
        let mut batch_errors = Vec::new();
        let started = std::time::Instant::now();
        super::drive_source_batches(
            sources,
            1,
            Duration::from_millis(300),
            &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            |_source| async {
                // 模拟修复后实现：同步长计算移入阻塞线程（await 点可中断）
                tokio::task::spawn_blocking(|| {
                    std::thread::sleep(Duration::from_millis(3000));
                    Ok(Vec::new())
                })
                .await
                .map_err(|e| LegadoError::Internal(e.to_string()))?
            },
            |outcome: SourceBatchOutcome<SearchResult>| {
                batch_errors.push(outcome.result.is_err());
                Ok(())
            },
        )
        .await;
        assert_eq!(batch_errors.len(), 1, "超时源仍应推送一个批次");
        assert!(batch_errors[0], "超时源应记错误批次而非挂起");
        assert!(
            started.elapsed() < Duration::from_millis(1500),
            "整体应在超时后立即完成，不等阻塞任务"
        );
    }

    // ─── 测试 10: 封面候选提取（过滤空值 + 去重）────────────────────────────

    /// 构造带指定封面的 SearchResult
    fn make_result_with_cover(cover: Option<&str>) -> SearchResult {
        SearchResult {
            source_url: "https://www.example.com".to_string(),
            source_name: "测试书源".to_string(),
            book_name: "测试书籍".to_string(),
            author: "作者".to_string(),
            book_url: "https://www.example.com/book/1".to_string(),
            latest_chapter: None,
            intro: None,
            cover_url: cover.map(|s| s.to_string()),
            kind: None,
            word_count: None,
            book_type: book_type::TEXT,
            origin_order: 0,
            has_read_record: false,
            read_record_author: None,
            variable: None,
        }
    }

    #[test]
    fn test_extract_cover_candidates_dedup_and_filter() {
        let results = vec![
            make_result_with_cover(Some("https://cdn.example.com/a.jpg")),
            make_result_with_cover(Some("https://cdn.example.com/b.jpg")),
            // 重复 URL 应被去重
            make_result_with_cover(Some("https://cdn.example.com/a.jpg")),
            // 空封面应被过滤
            make_result_with_cover(None),
            // 空字符串封面应被过滤
            make_result_with_cover(Some("")),
            make_result_with_cover(Some("https://cdn.example.com/c.jpg")),
        ];

        let candidates = extract_cover_candidates(results);

        // 去重 + 过滤后仅剩 3 个，且保持首次出现顺序
        assert_eq!(candidates.len(), 3);
        assert_eq!(candidates[0].url, "https://cdn.example.com/a.jpg");
        assert_eq!(candidates[1].url, "https://cdn.example.com/b.jpg");
        assert_eq!(candidates[2].url, "https://cdn.example.com/c.jpg");
        // width / height 均为 0
        assert!(candidates.iter().all(|c| c.width == 0 && c.height == 0));
    }

    #[test]
    fn test_extract_cover_candidates_empty_input() {
        let candidates = extract_cover_candidates(Vec::new());
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_cover_candidate_serialize() {
        let candidate = CoverCandidate {
            url: "https://cdn.example.com/x.jpg".to_string(),
            width: 0,
            height: 0,
        };
        let json = serde_json::to_string(&candidate).unwrap();
        // 字段名为 snake_case，对齐 Dart CoverCandidate 模型
        assert!(json.contains("\"url\""));
        assert!(json.contains("\"width\""));
        assert!(json.contains("\"height\""));
        assert!(json.contains("https://cdn.example.com/x.jpg"));
    }

    /// 回归：`load_search_sources("[]")` 应视为搜全部（Dart 侧无筛选默认传 '[]'）
    #[test]
    fn test_load_search_sources_empty_array_means_all() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");

        let from_empty_array = load_search_sources("[]").expect("空数组解析失败");
        let from_empty_str = load_search_sources("").expect("空串解析失败");
        assert!(
            !from_empty_array.is_empty(),
            "空数组 '[]' 应表示搜索全部启用书源"
        );
        assert_eq!(from_empty_array.len(), from_empty_str.len());
    }

    /// E2E 诊断测试（需网络，默认忽略）：
    /// 导入 yckceo 7631 书源并执行真实搜索，用于区分
    /// 「集成测试框架缺陷」与「Rust 搜索链路问题」。
    /// 运行：cargo test -p legado-ffi e2e_yckceo -- --ignored --nocapture
    #[test]
    #[ignore]
    fn test_e2e_yckceo_search_network() {
        let _db_guard = crate::db_state::ensure_test_db();

        // cwd 为 rust/legado-ffi，书源夹具位于 tests/fixtures/
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        let imported = crate::api::source::import_sources(&json).expect("导入书源失败");
        eprintln!("[E2E] 导入书源数量: {imported}");

        match search_books("都市", "") {
            Ok(results) => {
                eprintln!("[E2E] 搜索结果数量: {}", results.len());
                for r in results.iter().take(5) {
                    eprintln!(
                        "[E2E] - 《{}》 作者:{} 源:{} url:{}",
                        r.book_name, r.author, r.source_name, r.book_url
                    );
                }
            }
            Err(e) => eprintln!("[E2E] 搜索失败: {e:?}"),
        }
    }

    /// E2E 诊断：搜索 → 刷新目录 → 获取正文，定位阅读链路断点。
    /// 运行：cargo test -p legado-ffi e2e_read_chain --features quickjs -- --ignored --nocapture
    #[test]
    #[ignore]
    fn test_e2e_yckceo_read_chain_network() {
        let _db_guard = crate::db_state::ensure_test_db();

        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");

        let results = search_books("都市", "").expect("搜索失败");
        assert!(!results.is_empty(), "搜索无结果");
        // 优先选《都市逍遥邪医》，否则取首条
        let target = results
            .iter()
            .find(|r| r.book_name.contains("都市逍遥邪医"))
            .unwrap_or(&results[0]);
        eprintln!(
            "[E2E-READ] 目标: 《{}》 url={} origin={}",
            target.book_name, target.book_url, target.source_url
        );

        match crate::api::reader::refresh_toc(&target.book_url, &target.source_url) {
            Ok(resp) => {
                eprintln!("[E2E-READ] 目录章节数: {}", resp.total);
                for c in resp.chapters.iter().take(3) {
                    eprintln!("[E2E-READ] - {} url={}", c.title, c.url);
                }
                if let Some(first) = resp.chapters.first() {
                    match crate::api::reader::fetch_chapter_content(
                        &target.book_url,
                        &first.url,
                        &target.source_url,
                    ) {
                        Ok(content) => eprintln!(
                            "[E2E-READ] 正文长度: {} 前80字: {}",
                            content.len(),
                            content.chars().take(80).collect::<String>()
                        ),
                        Err(e) => eprintln!("[E2E-READ] 正文获取失败: {e:?}"),
                    }
                }
            }
            Err(e) => eprintln!("[E2E-READ] 目录获取失败: {e:?}"),
        }
    }

    // ─── 测试 11: 阅读记录标识（对齐上游 ReadRecordIndex，#424）────────────

    use legado_db::repository::read_record_repository::ReadRecord;

    /// 构造 ReadRecord 测试数据（device_id/last_read 为 v101 新增字段，取默认值）
    fn make_record(book_name: &str, author: &str) -> ReadRecord {
        ReadRecord {
            book_name: book_name.to_string(),
            author: author.to_string(),
            read_time: 0,
            ..Default::default()
        }
    }

    /// 构造最简 SearchResult 测试数据
    fn make_result(book_name: &str, author: &str) -> SearchResult {
        SearchResult {
            source_url: "https://s.example.com".into(),
            source_name: "源".into(),
            book_name: book_name.into(),
            author: author.into(),
            book_url: "https://s.example.com/b/1".into(),
            latest_chapter: None,
            intro: None,
            cover_url: None,
            kind: None,
            word_count: None,
            book_type: book_type::TEXT,
            origin_order: 0,
            has_read_record: false,
            read_record_author: None,
            variable: None,
        }
    }

    /// 索引匹配语义（对齐上游 ReadRecordIndex.contains 的四种分支）
    #[test]
    fn test_read_record_index_match_semantics() {
        let index = ReadRecordIndex::of(vec![
            make_record("剑来", "烽火戏诸侯"),
            make_record("旧记录书", ""),
        ]);

        // 书名+作者完全匹配
        assert!(index.contains("剑来", "烽火戏诸侯"));
        // 书名命中但作者不符 → 不算读过
        assert!(!index.contains("剑来", "某同名作者"));
        // 搜索结果无作者 → 退化为按书名判断
        assert!(index.contains("剑来", ""));
        // 记录无作者（旧记录）→ 任意作者都算命中
        assert!(index.contains("旧记录书", "任何作者"));
        // 无记录
        assert!(!index.contains("不存在", ""));
    }

    /// 多作者集合编码（\u{1E}authors: 前缀）解码后逐作者匹配
    #[test]
    fn test_read_record_index_multi_author_encoded() {
        let encoded = format!("\u{1E}authors:[\"作者A\",\"作者B\"]");
        let index = ReadRecordIndex::of(vec![make_record("同名书", &encoded)]);

        assert!(index.contains("同名书", "作者A"));
        assert!(index.contains("同名书", "作者B"));
        assert!(!index.contains("同名书", "作者C"));
        // lookup 返回记录侧全部作者（顿号连接）
        let (has, author) = index.lookup("同名书", "作者B");
        assert!(has);
        assert_eq!(author.as_deref(), Some("作者A、作者B"));
    }

    /// 无记录时字段缺省：hasReadRecord=false，readRecordAuthor 缺省
    #[test]
    fn test_read_record_annotation_absent() {
        let index = ReadRecordIndex::of(Vec::new());
        let mut results = vec![make_result("任意书", "任意作者")];

        annotate_results(&mut results, &index);
        assert!(!results[0].has_read_record);
        assert!(results[0].read_record_author.is_none());

        // 序列化：hasReadRecord 恒输出，readRecordAuthor 缺省时不出现
        let json = serde_json::to_string(&results[0]).unwrap();
        assert!(json.contains("\"hasReadRecord\":false"));
        assert!(!json.contains("readRecordAuthor"));
    }

    /// 端到端：DB 存在阅读记录时，搜索结果被批量附加标识
    #[test]
    fn test_read_record_annotation_with_db() {
        let _db_guard = crate::db_state::ensure_test_db();
        crate::db_state::with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.insert_with_author("标识测试书A", "作者甲", 100)?;
            repo.upsert("标识测试书B", 200)?; // 旧式记录，无作者
            Ok(())
        })
        .expect("写入测试阅读记录失败");

        let index = ReadRecordIndex::load();
        let mut results = vec![
            make_result("标识测试书A", "作者甲"),
            make_result("标识测试书B", "书源给的作者"),
            make_result("无记录书", ""),
        ];

        annotate_results(&mut results, &index);

        // 有记录 + 作者匹配
        assert!(results[0].has_read_record);
        assert_eq!(results[0].read_record_author.as_deref(), Some("作者甲"));
        // 旧式无作者记录 → 按书名命中，无作者展示串
        assert!(results[1].has_read_record);
        assert!(results[1].read_record_author.is_none());
        // 无记录
        assert!(!results[2].has_read_record);

        // 序列化字段名契约（camelCase）
        let json = serde_json::to_string(&results[0]).unwrap();
        assert!(json.contains("\"hasReadRecord\":true"));
        assert!(json.contains("\"readRecordAuthor\":\"作者甲\""));

        // 清理测试记录，避免污染共享测试库
        crate::db_state::with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.delete_by_book_name("标识测试书A")?;
            repo.delete_by_book_name("标识测试书B")?;
            Ok(())
        })
        .expect("清理测试阅读记录失败");
    }

    /// 批量查询性能：大量记录 + 大量结果，一次建索引后 O(1) 查找
    #[test]
    fn test_read_record_index_batch_lookup() {
        // 5000 条记录 + 2000 条搜索结果
        let records: Vec<ReadRecord> = (0..5000)
            .map(|i| make_record(&format!("批量书{i}"), &format!("作者{i}")))
            .collect();
        let index = ReadRecordIndex::of(records);

        let mut results: Vec<SearchResult> = (0..2000)
            .map(|i| make_result(&format!("批量书{}", i * 2), &format!("作者{}", i * 2)))
            .collect();

        let start = std::time::Instant::now();
        annotate_results(&mut results, &index);
        let elapsed = start.elapsed();

        assert!(results.iter().all(|r| r.has_read_record));
        // 2000 次 O(1) 查找应远低于每本一次 DB 查询的开销
        assert!(
            elapsed < std::time::Duration::from_secs(1),
            "批量查找耗时异常: {elapsed:?}"
        );
    }

    /// 设备导出的神漫画/Nhentai/51：search→toc 网络探针
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network + tmp_debug fixtures"]
    fn probe_manga_sources_from_tmp_debug() {
        let _db = crate::db_state::ensure_test_db();
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tmp_debug");
        for (file, kw) in [
            ("src_51.json", "一人之下"),
            ("src_shen.json", "一人之下"),
            ("src_nhentai.json", "姐姐"),
            ("src_kuaikan.json", "一人之下"),
            ("src_cola.json", "一人之下"),
        ] {
            let path = root.join(file);
            if !path.exists() {
                println!("skip missing {file}");
                continue;
            }
            let raw = std::fs::read_to_string(&path).unwrap();
            let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(n != 0));
                    }
                }
            }
            let src: legado_core::models::BookSource = serde_json::from_value(v).unwrap();
            println!("\n==== {} ====", src.book_source_name);
            let arr = serde_json::json!([src]).to_string();
            crate::api::source::import_sources(&arr).unwrap();
            let urls = format!(r#"["{}"]"#, src.book_source_url);
            match search_books(kw, &urls) {
                Ok(list) => {
                    println!("SEARCH n={}", list.len());
                    if let Some(b) = list.first() {
                        println!("  {} {}", b.book_name, b.book_url);
                        match crate::api::reader::refresh_toc(&b.book_url, &b.source_url) {
                            Ok(toc) => {
                                println!("  TOC n={}", toc.chapters.len());
                                if let Some(ch) = toc.chapters.first() {
                                    match crate::api::reader::get_chapter_content_full(
                                        &b.book_url,
                                        ch.index,
                                    ) {
                                        Ok(c) => println!("  CONTENT len={}", c.len()),
                                        Err(e) => println!("  CONTENT err={e}"),
                                    }
                                }
                            }
                            Err(e) => println!("  TOC err={e}"),
                        }
                    }
                }
                Err(e) => println!("SEARCH err={e}"),
            }
        }
    }
    /// 批量图片源搜索/目录探针（网络，ignore）
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network + tmp_debug/sources.json"]
    fn probe_all_image_sources_batch() {
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/sources.json");
        let raw = std::fs::read_to_string(&path).expect("sources.json");
        let mut data: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let mut img = Vec::new();
        for v in &mut data {
            if v.get("bookSourceType").and_then(|x| x.as_i64()) != Some(2) {
                continue;
            }
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(n != 0));
                    }
                }
            }
            img.push(v.clone());
        }
        println!("IMAGE_SOURCES={}", img.len());
        let mut ok_search = 0usize;
        let mut fail_search = 0usize;
        let mut err_counter: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        let mut ok_names = Vec::new();
        let mut fail_samples = Vec::new();
        for (i, v) in img.iter().enumerate() {
            let src: legado_core::models::BookSource = match serde_json::from_value(v.clone()) {
                Ok(s) => s,
                Err(e) => {
                    fail_search += 1;
                    *err_counter.entry(format!("deserialize:{e}")).or_default() += 1;
                    continue;
                }
            };
            let name = src.book_source_name.clone();
            let url = src.book_source_url.clone();
            let arr = serde_json::json!([src]).to_string();
            let _ = crate::api::source::import_sources(&arr);
            let urls = format!(r#"["{url}"]"#);
            match search_books("一人之下", &urls) {
                Ok(list) if !list.is_empty() => {
                    ok_search += 1;
                    ok_names.push(format!("{name} n={}", list.len()));
                    let b = &list[0];
                    match crate::api::reader::refresh_toc(&b.book_url, &b.source_url) {
                        Ok(toc) => println!(
                            "OK_SEARCH+TOC\t{name}\tsearch={}\ttoc={}",
                            list.len(),
                            toc.chapters.len()
                        ),
                        Err(e) => {
                            let es = e.to_string();
                            println!(
                                "OK_SEARCH+TOC_FAIL\t{name}\tsearch={}\terr={es}",
                                list.len()
                            );
                            *err_counter.entry(format!("toc:{es}")).or_default() += 1;
                        }
                    }
                }
                Ok(_) => {
                    fail_search += 1;
                    *err_counter.entry("search:empty".into()).or_default() += 1;
                    if fail_samples.len() < 25 {
                        fail_samples.push(format!("{name}\tempty"));
                    }
                    println!("FAIL_SEARCH\t{name}\tempty");
                }
                Err(e) => {
                    fail_search += 1;
                    let es = e.to_string();
                    let key = if es.contains("ReferenceError") {
                        format!("js:{}", es.chars().take(80).collect::<String>())
                    } else if es.contains("timeout") || es.contains("Timeout") {
                        "http:timeout".into()
                    } else if es.contains("404") {
                        "http:404".into()
                    } else if es.contains("connect")
                        || es.contains("dns")
                        || es.contains("TLS")
                        || es.contains("ssl")
                    {
                        "http:network".into()
                    } else {
                        format!("other:{}", es.chars().take(60).collect::<String>())
                    };
                    *err_counter.entry(key).or_default() += 1;
                    if fail_samples.len() < 25 {
                        fail_samples.push(format!("{name}\t{es}"));
                    }
                    println!("FAIL_SEARCH\t{name}\t{es}");
                }
            }
            if i % 10 == 0 {
                eprintln!("progress {}/{}", i + 1, img.len());
            }
        }
        println!("\n==== SUMMARY ====");
        println!(
            "ok_search={ok_search} fail_search={fail_search} total={}",
            img.len()
        );
        println!("ok_names={ok_names:?}");
        println!("top_errors:");
        let mut errs: Vec<_> = err_counter.into_iter().collect();
        errs.sort_by(|a, b| b.1.cmp(&a.1));
        for (k, c) in errs.iter().take(30) {
            println!("  {c}\t{k}");
        }
        println!("fail_samples:");
        for s in fail_samples {
            println!("  {s}");
        }
    }

    /// 抽样：原版有、重构常空的漫画源
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "e2e network probe"]
    fn probe_missing_manga_sources() {
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/e2e_5558/probe_missing_srcs.json");
        let raw = std::fs::read_to_string(&path).expect("probe_missing_srcs.json");
        let list: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let _ = crate::api::source::import_sources(&raw);
        let kw = "一人之下";
        for v in &list {
            let name = v
                .get("bookSourceName")
                .and_then(|x| x.as_str())
                .unwrap_or("?");
            let url = v
                .get("bookSourceUrl")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            let urls_json = serde_json::to_string(&vec![url]).unwrap();
            match search_books(kw, &urls_json) {
                Ok(hits) => {
                    let exact: Vec<_> = hits.iter().filter(|r| r.book_name.contains(kw)).collect();
                    println!(
                        "OK\t{name}\tn={}\texact={}\tfirst={}",
                        hits.len(),
                        exact.len(),
                        hits.first().map(|r| r.book_name.as_str()).unwrap_or("-")
                    );
                }
                Err(e) => println!("ERR\t{name}\t{e}"),
            }
        }
    }

    /// 快速书源（普通小说）分组搜索探针 — 对照原版缺口
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "e2e network probe"]
    fn probe_fast_group_novel_search() {
        use std::collections::BTreeMap;
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/sources.json");
        let raw = std::fs::read_to_string(&path).expect("sources.json");
        let mut data: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let mut fast = Vec::new();
        for v in &mut data {
            let group = v
                .get("bookSourceGroup")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            let ty = v
                .get("bookSourceType")
                .and_then(|x| x.as_i64())
                .unwrap_or(0);
            // 快速书源且文本源（type=0）
            if !group
                .split(|c| ",;，；".contains(c))
                .any(|p| p.trim() == "快速书源")
            {
                continue;
            }
            if ty != 0 {
                continue;
            }
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(n != 0));
                    }
                }
            }
            fast.push(v.clone());
        }
        println!("FAST_GROUP_TYPE0_SOURCES={}", fast.len());
        let _ =
            crate::api::source::import_sources(&serde_json::Value::Array(fast.clone()).to_string());
        let urls: Vec<String> = fast
            .iter()
            .filter_map(|v| {
                v.get("bookSourceUrl")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .collect();
        let urls_json = serde_json::to_string(&urls).unwrap();
        let kw = "斗破苍穹";
        println!("SEARCH_KW={kw} URLS={}", urls.len());
        match search_books(kw, &urls_json) {
            Ok(list) => {
                let exact: Vec<_> = list.iter().filter(|r| r.book_name.contains(kw)).collect();
                let mut by_origin: BTreeMap<String, usize> = BTreeMap::new();
                let mut by_origin_exact: BTreeMap<String, usize> = BTreeMap::new();
                for r in &list {
                    *by_origin
                        .entry(format!("{}|{}", r.source_name, r.source_url))
                        .or_default() += 1;
                }
                for r in &exact {
                    *by_origin_exact
                        .entry(format!("{}|{}", r.source_name, r.source_url))
                        .or_default() += 1;
                }
                println!("TOTAL_HITS={}", list.len());
                println!("ORIGINS_WITH_HITS={}", by_origin.len());
                println!("EXACT_TITLE_HITS={}", exact.len());
                println!("EXACT_ORIGINS_WITH_HITS={}", by_origin_exact.len());
                // 聚合口径：精确书名下不同 origin 数 ≈ 原版顶条徽标
                for (k, n) in by_origin_exact.iter().take(40) {
                    println!("EXACT_ORIGIN\t{n}\t{k}");
                }
                // 抽样前几条书名
                for r in exact.iter().take(15) {
                    println!(
                        "EXACT_SAMPLE\t{}\t{}\t{}",
                        r.source_name, r.book_name, r.author
                    );
                }
            }
            Err(e) => println!("SEARCH_ERR={e}"),
        }
    }

    /// 快速书源 type=0 逐源失败原因分布（斗破苍穹）
    ///
    /// 对齐 systematic-debugging：先统计 empty/JS/HTTP/timeout/解析等，
    /// 再找引擎级整批失败模式。— Reasonix
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "e2e network probe"]
    fn probe_fast_group_novel_fail_classify() {
        use std::collections::BTreeMap;
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/sources.json");
        let raw = std::fs::read_to_string(&path).expect("sources.json");
        let mut data: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let mut fast = Vec::new();
        for v in &mut data {
            let group = v
                .get("bookSourceGroup")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            let ty = v
                .get("bookSourceType")
                .and_then(|x| x.as_i64())
                .unwrap_or(0);
            if !group
                .split(|c| ",;，；".contains(c))
                .any(|p| p.trim() == "快速书源")
            {
                continue;
            }
            if ty != 0 {
                continue;
            }
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(n != 0));
                    }
                }
            }
            fast.push(v.clone());
        }
        println!("FAST_GROUP_TYPE0_SOURCES={}", fast.len());
        let kw = "斗破苍穹";
        let mut ok = 0usize;
        let mut exact_origins = 0usize;
        let mut err_counter: BTreeMap<String, usize> = BTreeMap::new();
        let mut fail_samples: Vec<String> = Vec::new();
        let client = crate::http_state::shared_client().unwrap();
        for (i, v) in fast.iter().enumerate() {
            let src: BookSource = match serde_json::from_value(v.clone()) {
                Ok(s) => s,
                Err(e) => {
                    *err_counter.entry(format!("deserialize:{}", e)).or_default() += 1;
                    continue;
                }
            };
            let name = src.book_source_name.clone();
            let search_url = src.search_url.clone().unwrap_or_default();
            let outcome = crate::runtime::block_on(async {
                tokio::time::timeout(
                    SEARCH_SOURCE_TIMEOUT,
                    search_single_source(&client, &src, kw, 1, false),
                )
                .await
            });
            match outcome {
                Ok(Ok(list)) if !list.is_empty() => {
                    ok += 1;
                    if list.iter().any(|r| r.book_name.contains(kw)) {
                        exact_origins += 1;
                    }
                    let empty_url = list.iter().filter(|r| r.book_url.is_empty()).count();
                    if empty_url > 0 {
                        *err_counter.entry("warn:bookUrl_empty".into()).or_default() += 1;
                    }
                    println!(
                        "OK\t{name}\tn={}\texact={}\tempty_url={empty_url}",
                        list.len(),
                        list.iter().filter(|r| r.book_name.contains(kw)).count()
                    );
                }
                Ok(Ok(_)) => {
                    *err_counter.entry("empty".into()).or_default() += 1;
                    // 附加 searchUrl 形态特征，便于找引擎级模式
                    let feat = if search_url.is_empty() {
                        "no_searchUrl"
                    } else if search_url.starts_with('/') || !search_url.contains("://") {
                        "relative_url"
                    } else if search_url.contains("<js>") || search_url.contains("@js:") {
                        "js_block"
                    } else if search_url.contains("{{") {
                        "mustache"
                    } else {
                        "literal"
                    };
                    *err_counter.entry(format!("empty:{feat}")).or_default() += 1;
                    let bl = src
                        .rule_search
                        .as_ref()
                        .and_then(|r| r.book_list.clone())
                        .unwrap_or_default();
                    if bl.starts_with("class.") {
                        *err_counter
                            .entry("empty:bookList_class.".into())
                            .or_default() += 1;
                    } else if bl.contains("@js:") || bl.contains("<js>") {
                        *err_counter.entry("empty:bookList_js".into()).or_default() += 1;
                    } else if bl.starts_with("$.") || bl.starts_with("$[") {
                        *err_counter.entry("empty:bookList_json".into()).or_default() += 1;
                    }
                    if fail_samples.len() < 40 {
                        fail_samples.push(format!(
                            "{name}\tempty\tfeat={feat}\tbookList={}",
                            bl.chars().take(60).collect::<String>()
                        ));
                    }
                    println!("FAIL\t{name}\tempty\tfeat={feat}");
                }
                Ok(Err(e)) => {
                    let es = e.to_string();
                    let key = classify_search_err(&es);
                    *err_counter.entry(key.clone()).or_default() += 1;
                    if fail_samples.len() < 40 {
                        fail_samples.push(format!("{name}\t{es}"));
                    }
                    println!("FAIL\t{name}\t{key}\t{es}");
                }
                Err(_) => {
                    *err_counter.entry("timeout".into()).or_default() += 1;
                    println!("FAIL\t{name}\ttimeout");
                }
            }
            if (i + 1) % 20 == 0 {
                eprintln!("progress {}/{}", i + 1, fast.len());
            }
        }
        println!("\n==== SUMMARY ====");
        println!("ok={ok} exact_origins={exact_origins} total={}", fast.len());
        println!("top_errors:");
        let mut errs: Vec<_> = err_counter.into_iter().collect();
        errs.sort_by(|a, b| b.1.cmp(&a.1));
        for (k, c) in errs {
            println!("  {c}\t{k}");
        }
        println!("fail_samples:");
        for s in fail_samples {
            println!("  {s}");
        }
    }

    fn classify_search_err(es: &str) -> String {
        if es.contains("ReferenceError")
            || es.contains("TypeError")
            || es.contains("SyntaxError")
            || es.contains("JS engine")
            || es.contains("jsLib")
            || es.contains("is not defined")
        {
            format!("js:{}", es.chars().take(80).collect::<String>())
        } else if es.contains("timeout") || es.contains("Timeout") || es.contains("timed out") {
            "http:timeout".into()
        } else if es.contains("404") {
            "http:404".into()
        } else if es.contains("403") {
            "http:403".into()
        } else if es.contains("HTTP ") {
            format!("http:status:{}", es.chars().take(40).collect::<String>())
        } else if es.contains("connect")
            || es.contains("dns")
            || es.contains("DNS")
            || es.contains("TLS")
            || es.contains("ssl")
            || es.contains("certificate")
            || es.contains("resolve")
        {
            "http:network".into()
        } else if es.contains("searchUrl") {
            "parse:searchUrl".into()
        } else if es.contains("解析") || es.contains("Parser") || es.contains("selector") {
            format!("parse:{}", es.chars().take(60).collect::<String>())
        } else {
            format!("other:{}", es.chars().take(60).collect::<String>())
        }
    }

    /// GBK charset 书源搜索探针（验证请求编码修复）— Reasonix
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "e2e network probe"]
    fn probe_gbk_charset_novel_search() {
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/e2e_5558/probe_gbk_srcs.json");
        let raw = std::fs::read_to_string(&path).expect("probe_gbk_srcs.json");
        let list: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        println!("GBK_SOURCES={}", list.len());
        let kw = "斗破苍穹";
        let client = crate::http_state::shared_client().unwrap();
        let mut ok = 0usize;
        let mut exact = 0usize;
        for v in &list {
            let src: BookSource = match serde_json::from_value(v.clone()) {
                Ok(s) => s,
                Err(e) => {
                    println!("DESER_ERR\t{e}");
                    continue;
                }
            };
            let name = src.book_source_name.clone();
            // 打印实际请求 URL，确认 GBK 百分号编码
            if let Some(ref tpl) = src.search_url {
                let au = crate::js_executor::build_search_url_with_lib(
                    tpl,
                    kw,
                    1,
                    &src.book_source_url,
                    src.js_lib.as_deref(),
                );
                println!("URL\t{name}\tcharset={:?}\t{}", au.charset(), au.url());
                if au.method() == &RequestMethod::Post {
                    println!("BODY\t{name}\t{}", au.request_body());
                }
            }
            let outcome = crate::runtime::block_on(async {
                tokio::time::timeout(
                    SEARCH_SOURCE_TIMEOUT,
                    search_single_source(&client, &src, kw, 1, false),
                )
                .await
            });
            match outcome {
                Ok(Ok(hits)) if !hits.is_empty() => {
                    ok += 1;
                    let ex = hits.iter().filter(|r| r.book_name.contains(kw)).count();
                    if ex > 0 {
                        exact += 1;
                    }
                    println!(
                        "OK\t{name}\tn={}\texact={ex}\tfirst={}",
                        hits.len(),
                        hits[0].book_name
                    );
                }
                Ok(Ok(_)) => println!("EMPTY\t{name}"),
                Ok(Err(e)) => println!("ERR\t{name}\t{e}"),
                Err(_) => println!("TIMEOUT\t{name}"),
            }
        }
        println!("SUMMARY ok={ok} exact={exact} total={}", list.len());
    }

    /// 漫画书源分组端到端搜索探针（与模拟器验收同关键词）
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "e2e network probe"]
    fn probe_manga_group_e2e_search() {
        use std::collections::BTreeMap;
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/sources.json");
        let raw = std::fs::read_to_string(&path).expect("sources.json");
        let mut data: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let mut manga = Vec::new();
        for v in &mut data {
            let group = v
                .get("bookSourceGroup")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            if !group.contains("漫画书源") {
                continue;
            }
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(n != 0));
                    }
                }
            }
            manga.push(v.clone());
        }
        println!("MANGA_GROUP_SOURCES={}", manga.len());
        let _ = crate::api::source::import_sources(
            &serde_json::Value::Array(manga.clone()).to_string(),
        );
        let urls: Vec<String> = manga
            .iter()
            .filter_map(|v| {
                v.get("bookSourceUrl")
                    .and_then(|x| x.as_str())
                    .map(|s| s.to_string())
            })
            .collect();
        let urls_json = serde_json::to_string(&urls).unwrap();
        let kw = "一人之下";
        println!("SEARCH_KW={kw} URLS={}", urls.len());
        match search_books(kw, &urls_json) {
            Ok(list) => {
                // 与原版聚合对比：仅统计书名含关键词的命中（排除作者误匹配等噪声）
                let exact: Vec<_> = list.iter().filter(|r| r.book_name.contains(kw)).collect();
                let mut by_origin: BTreeMap<String, usize> = BTreeMap::new();
                let mut by_origin_exact: BTreeMap<String, usize> = BTreeMap::new();
                for r in &list {
                    *by_origin
                        .entry(format!("{}|{}", r.source_name, r.source_url))
                        .or_default() += 1;
                }
                for r in &exact {
                    *by_origin_exact
                        .entry(format!("{}|{}", r.source_name, r.source_url))
                        .or_default() += 1;
                }
                println!("TOTAL_HITS={}", list.len());
                println!("ORIGINS_WITH_HITS={}", by_origin.len());
                println!("EXACT_TITLE_HITS={}", exact.len());
                println!("EXACT_ORIGINS_WITH_HITS={}", by_origin_exact.len());
                for (k, n) in &by_origin_exact {
                    println!("EXACT_ORIGIN\t{n}\t{k}");
                }
                for key in ["51", "神漫", "快看"] {
                    let b = match exact.iter().find(|r| r.source_name.contains(key)) {
                        Some(r) => *r,
                        None => match list.iter().find(|r| r.source_name.contains(key)) {
                            Some(r) => r,
                            None => {
                                println!("TOC_SKIP\t{key}\tno search hit");
                                continue;
                            }
                        },
                    };
                    let exact_hit = b.book_name.contains(kw);
                    match crate::api::reader::refresh_toc(&b.book_url, &b.source_url) {
                        Ok(toc) => println!(
                            "TOC_OK\t{}\tchapters={}\tbook={}\texact_title={}",
                            b.source_name,
                            toc.chapters.len(),
                            b.book_name,
                            exact_hit
                        ),
                        Err(e) => println!(
                            "TOC_FAIL\t{}\texact_title={}\t{e}",
                            b.source_name, exact_hit
                        ),
                    }
                }
            }
            Err(e) => println!("SEARCH_ERR={e}"),
        }
    }

    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network"]
    fn probe_51_toc_detail() {
        let _db = crate::db_state::ensure_test_db();
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tmp_debug/src_51.json");
        let raw = std::fs::read_to_string(&path).unwrap();
        let mut v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        if let Some(obj) = v.as_object_mut() {
            for k in [
                "enabled",
                "enabledExplore",
                "enabledCookieJar",
                "eventListener",
                "customButton",
            ] {
                if let Some(n) = obj.get(k).and_then(|x| x.as_i64()) {
                    obj.insert(k.to_string(), serde_json::json!(n != 0));
                }
            }
        }
        let src: legado_core::models::BookSource = serde_json::from_value(v).unwrap();
        crate::api::source::import_sources(&serde_json::json!([src.clone()]).to_string()).unwrap();
        let urls = format!(r#"["{}"]"#, src.book_source_url);
        let list = search_books("一人之下", &urls).expect("search");
        println!("search n={}", list.len());
        let b = list.first().expect("hit");
        println!("book={} url={}", b.book_name, b.book_url);
        let engine = crate::api::web_book::build_engine().expect("build_engine");
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        match rt.block_on(engine.get_chapters(&src, &b.book_url)) {
            Ok(chs) => {
                println!("engine_toc n={}", chs.len());
                for c in chs.iter().take(3) {
                    println!("  {} -> {}", c.title, c.url);
                }
            }
            Err(e) => println!("engine_toc err={e}"),
        }
        match crate::api::reader::refresh_toc(&b.book_url, &b.source_url) {
            Ok(t) => println!("refresh_toc n={}", t.chapters.len()),
            Err(e) => println!("refresh_toc err={e}"),
        }
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn offline_51_chapter_list_from_saved_html() {
        let html = std::fs::read_to_string(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/comic_2122.html"),
        )
        .expect("html");
        let rule = concat!(
            "<js>\n",
            "const scripts = Array.from(java.getElement(\"script\")).filter(e => String(e).includes('目录'));\n",
            "const c = scripts[0];\n",
            "d = c\n",
            "  ? JSON.parse(c.html()).itemListElement.map(e => ({ title: e.name, url: e.url }))\n",
            "  : [{ title: book.name, url: java.getString(\".btn-read@href\", src) }];\n",
            "JSON.stringify(d);\n",
            "</js>\n",
            "$[*]",
        );
        let analyzer = crate::js_executor::construct_analyzer_with_js_lib(
            html.clone(),
            "https://51acgs.com/comic/2122".into(),
            "https://51acgs.com",
            None,
        )
        .with_js_binding("book", r#"{"name":"下半身第一主義3"}"#);
        match analyzer.get_elements(rule) {
            Ok(els) => {
                println!("elements n={}", els.len());
                for (i, e) in els.iter().take(5).enumerate() {
                    println!("  [{}] {}", i, &e[..e.len().min(200)]);
                }
                assert!(!els.is_empty(), "expected fallback chapter");
            }
            Err(e) => panic!("get_elements err: {e}"),
        }
        let name = crate::js_executor::construct_analyzer_with_js_lib(
            html,
            "https://51acgs.com/comic/2122".into(),
            "https://51acgs.com",
            None,
        )
        .get_string(".comic-content@.text-primary@text")
        .unwrap_or_default();
        println!("book_name_rule=>{name:?}");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network"]
    fn probe_relative_search_urls() {
        let _db = crate::db_state::ensure_test_db();
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tmp_debug");
        let raw = std::fs::read_to_string(root.join("sources.json")).unwrap();
        let mut data: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        let want = [
            "漫蛙",
            "拷贝漫画",
            "包子漫画（优+）",
            "爱看漫画",
            "神漫画",
            "51漫画",
        ];
        for v in &mut data {
            let n = v
                .get("bookSourceName")
                .and_then(|x| x.as_str())
                .unwrap_or("");
            if !want.contains(&n) {
                continue;
            }
            if let Some(obj) = v.as_object_mut() {
                for k in [
                    "enabled",
                    "enabledExplore",
                    "enabledCookieJar",
                    "eventListener",
                    "customButton",
                ] {
                    if let Some(num) = obj.get(k).and_then(|x| x.as_i64()) {
                        obj.insert(k.to_string(), serde_json::json!(num != 0));
                    }
                }
            }
            let src: legado_core::models::BookSource = serde_json::from_value(v.clone()).unwrap();
            let _ =
                crate::api::source::import_sources(&serde_json::json!([src.clone()]).to_string());
            let urls = format!(r#"["{}"]"#, src.book_source_url);
            match search_books("一人之下", &urls) {
                Ok(list) => println!(
                    "REL\t{}\tn={}\turl={}",
                    src.book_source_name,
                    list.len(),
                    src.search_url.as_deref().unwrap_or("")
                ),
                Err(e) => println!("REL\t{}\terr={e}", src.book_source_name),
            }
        }
    }
}

/// [P3-6 阶段三] precision filter(解析期逐条过滤)测试
#[cfg(test)]
mod p3f_tests {
    use super::*;
    use legado_core::models::rule::SearchRule;

    fn parse_with(precision: bool, key: &str) -> Vec<SearchResult> {
        let html = r#"<html><body>
            <div class="book-item"><a class="name" href="/b/1">斗破苍穹</a><span class="author">天蚕土豆</span><span class="kind">玄幻</span></div>
            <div class="book-item"><a class="name" href="/b/2">凡人修仙传</a><span class="author">忘语</span><span class="kind">仙侠</span></div>
        </body></html>"#;
        let source = BookSource {
            book_source_url: "https://p3f.example.com".to_string(),
            book_source_name: "P3F-源".to_string(),
            rule_search: Some(SearchRule {
                book_list: Some(".book-item".to_string()),
                name: Some(".name".to_string()),
                author: Some(".author".to_string()),
                kind: Some(".kind".to_string()),
                book_url: Some(".name@href".to_string()),
                ..Default::default()
            }),
            ..BookSource::default()
        };
        parse_search_response_ex(
            html,
            "https://p3f.example.com/s?kw=x",
            &source,
            precision,
            key,
        )
        .unwrap()
    }

    /// SearchModel.kt:106-113:precision 开启 → 仅保留 name/author/kind contains(key) 的条目
    #[test]
    fn test_p3f_precision_filters_non_matching() {
        let results = parse_with(true, "斗破");
        assert_eq!(results.len(), 1, "仅保留 name 含关键词的条目");
        assert_eq!(results[0].book_name, "斗破苍穹");
    }

    #[test]
    fn test_p3f_precision_off_keeps_all() {
        let results = parse_with(false, "斗破");
        assert_eq!(results.len(), 2, "precision 关闭全通过");
    }

    /// author 或 kind 命中同样保留(原版 filter 三字段或语义)
    #[test]
    fn test_p3f_precision_author_match_kept() {
        let results = parse_with(true, "忘语");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_name, "凡人修仙传");
    }

    #[test]
    fn test_p3f_precision_kind_match_kept() {
        let results = parse_with(true, "仙侠");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_name, "凡人修仙传");
    }

    /// 无任何字段命中 → 全部丢弃
    #[test]
    fn test_p3f_precision_no_match_drops_all() {
        let results = parse_with(true, "雪中悍刀行");
        assert!(results.is_empty());
    }
}

// ─── [审计 D4 | WebBook.kt:47] JS 书源 precision filter 回归测试 ─────────────
//
// mainJs 静态返回两本书（仅书名含关键词的条目命中），无需网络：
// precision=true 时 JS 源结果同样受三字段"或"语义约束，不得绕过。
#[cfg(all(test, feature = "quickjs"))]
mod d4_js_precision_tests {
    use super::*;
    use legado_net::LegadoClientConfig;

    #[tokio::test]
    async fn test_search_single_source_js_precision_filter() {
        let src = BookSource {
            book_source_url: "http://js.test/source".to_string(),
            book_source_name: "JS测试源".to_string(),
            main_js: Some(
                "function search(key, page){ return JSON.stringify([\
                 {name:'斗破苍穹', author:'天蚕土豆', kind:'玄幻', bookUrl:'http://js.test/1'},\
                 {name:'遮天', author:'辰东', kind:'玄幻', bookUrl:'http://js.test/2'}]); }"
                    .to_string(),
            ),
            ..BookSource::default()
        };
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();

        // precision=true：书2（遮天/辰东/玄幻 均不含"斗破"）应被过滤
        let on = search_single_source(&client, &src, "斗破", 1, true)
            .await
            .unwrap();
        assert_eq!(on.len(), 1, "precision=true 应过滤 JS 源未命中条目");
        assert_eq!(on[0].book_name, "斗破苍穹");

        // precision=false：两条全通过
        let off = search_single_source(&client, &src, "斗破", 1, false)
            .await
            .unwrap();
        assert_eq!(off.len(), 2);
    }
}
