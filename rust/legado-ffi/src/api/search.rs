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
use legado_core::search_engine::{MultiSourceSearcher, SearchConfig};
use legado_core::source_matcher::SearchCandidate;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::read_record_repository::decode_read_record_authors;
use legado_db::ReadRecordRepository;
use legado_net::LegadoClient;
use legado_parser::{AnalyzeRule, AnalyzeUrl, RequestMethod};

use crate::api::source as source_api;
use crate::runtime;

/// 全局搜索取消标志
static SEARCH_CANCELLED: AtomicBool = AtomicBool::new(false);

/// 多源搜索并发上限
///
/// 对齐原版 `SearchModel` 固定线程池语义：
/// `min(AppConfig.threadCount 默认 32, AppConst.MAX_THREAD 9)` = 9。
/// 避免数百书源无限制并发 spawn 导致 socket/连接池耗尽、整体长时间阻塞。
pub(crate) const SEARCH_CONCURRENCY: usize = 9;

/// 单源搜索超时（对齐原版 `SearchModel` `withTimeout(30000)`）
pub(crate) const SEARCH_SOURCE_TIMEOUT: Duration = Duration::from_secs(30);

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
        match search_single_source(&self.client, source, query).await {
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

    // 限流并发 + 单源超时 + 异常隔离（对齐原版 SearchModel 线程池语义），
    // 逐源完成后累积结果；失败源跳过不阻断整体。
    let keyword_owned = keyword.to_string();
    let mut results = runtime::block_on(async {
        let client = crate::http_state::shared_client();
        let mut all_results: Vec<SearchResult> = Vec::new();
        drive_source_batches(
            sources,
            SEARCH_CONCURRENCY,
            SEARCH_SOURCE_TIMEOUT,
            move |source: BookSource| {
                let client = client.clone();
                let keyword = keyword_owned.clone();
                async move { search_single_source(&client, &source, &keyword).await }
            },
            |outcome| {
                if let Ok(mut items) = outcome.result {
                    all_results.append(&mut items);
                }
                Ok(())
            },
        )
        .await;
        Ok::<_, LegadoError>(all_results)
    })?;

    // 搜索完成后批量附加阅读记录标识（一次性构建内存索引，O(1) 查找，
    // 对齐上游 ReadRecordIndex 思路；search_cover 复用本函数但不关心该字段）
    let index = ReadRecordIndex::load();
    annotate_results(&mut results, &index);

    Ok(results)
}

/// 多源并行搜索（同步包装）
///
/// `query` — 搜索关键词
/// `source_urls_json` — JSON 数组，指定搜索的书源 URL 列表；为空则搜索所有启用的书源
///
/// 返回 JSON 字符串格式的搜索结果数组。
pub fn multi_source_search(query: &str, source_urls_json: &str) -> LegadoResult<String> {
    // 重置取消标志
    SEARCH_CANCELLED.store(false, Ordering::SeqCst);

    let sources = load_search_sources(source_urls_json)?;
    if sources.is_empty() {
        return Ok("[]".to_string());
    }

    let config = SearchConfig {
        query: query.to_string(),
        timeout_secs: 10,
        max_results_per_source: 20,
    };

    let results = runtime::block_on(async {
        let client = crate::http_state::shared_client();

        let searcher = MultiSourceSearcher::new(WebSourceSearcher::new(client));
        let cancel = Arc::new(AtomicBool::new(false));
        // 桥接全局取消标志
        let cancel_inner = Arc::clone(&cancel);
        let _monitor = tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                if SEARCH_CANCELLED.load(Ordering::SeqCst) {
                    cancel_inner.store(true, Ordering::SeqCst);
                    break;
                }
            }
        });
        Ok::<_, LegadoError>(searcher.search(config, sources, cancel).await)
    })?;

    // 批量附加阅读记录标识后序列化（不修改 core 的 SearchResult 结构，
    // 通过加法式 DTO 扩展输出 JSON）
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
                relevance_score: c.relevance_score,
                has_read_record: has_record,
                read_record_author: record_author,
            }
        })
        .collect();

    serde_json::to_string(&annotated).map_err(LegadoError::Serialization)
}

/// 取消正在进行的搜索
pub fn cancel_search() {
    SEARCH_CANCELLED.store(true, Ordering::SeqCst);
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
pub async fn run_multi_stream<F>(query: String, source_urls_json: String, mut on_batch: F)
where
    F: FnMut(String) -> Result<(), String>,
{
    // 重置取消标志
    SEARCH_CANCELLED.store(false, Ordering::SeqCst);

    // 书源加载失败时以空流结束（Dart 侧表现为无结果）
    let sources = load_search_sources(&source_urls_json).unwrap_or_default();
    if sources.is_empty() {
        return;
    }

    let client = crate::http_state::shared_client();

    // 一次性构建阅读记录索引，逐批附加标识（对齐 ReadRecordIndex 思路）
    let read_record_index = ReadRecordIndex::load();

    drive_source_batches(
        sources,
        SEARCH_CONCURRENCY,
        SEARCH_SOURCE_TIMEOUT,
        move |source: BookSource| {
            let client = client.clone();
            let query = query.clone();
            async move { search_single_source(&client, &source, &query).await }
        },
        |outcome| {
            let (mut books, error) = match outcome.result {
                Ok(list) => (list, None),
                Err(e) => (Vec::new(), Some(e.to_string())),
            };

            // 批次推送前附加阅读记录标识
            annotate_results(&mut books, &read_record_index);

            let batch = SearchSourceBatch {
                source_index: outcome.index,
                source_url: outcome.source_url,
                source_name: outcome.source_name,
                books: books.into_iter().map(result_to_search_book).collect(),
                error,
                finished_count: outcome.finished_count,
                total_count: outcome.total_count,
                is_last: outcome.is_last,
            };

            let json = serde_json::to_string(&batch).map_err(|e| e.to_string())?;
            // sink 关闭（Err）时提前终止
            on_batch(json)
        },
    )
    .await;
}

/// 单源搜索完成结果（驱动器回调载荷）
pub(crate) struct SourceBatchOutcome {
    /// 书源在请求列表中的索引
    pub index: usize,
    pub source_url: String,
    pub source_name: String,
    /// 该源搜索结果（失败/超时/panic 均为 Err，不阻断其他源）
    pub result: LegadoResult<Vec<SearchResult>>,
    pub finished_count: usize,
    pub total_count: usize,
    pub is_last: bool,
}

/// 多源并发搜索驱动器（严格对齐原版 `SearchModel` 语义）
///
/// - **限流并发**：信号量将同时进行的单源搜索限制为 `concurrency`
///   （对应原版固定线程池 `min(threadCount, MAX_THREAD)`）；
/// - **单源超时**：每源包裹 `per_source_timeout`（对应原版 `withTimeout(30000)`）；
/// - **异常隔离**：单源 Err/超时/任务 panic 均转为错误结果批次，
///   不中断整体（对应原版 `mapParallelSafe` 单源异常不外溢）；
/// - **渐进回调**：每完成一个书源调用一次 `on_source`（附 finished/total 进度），
///   返回 `Err` 时提前终止（如 sink 已关闭）；
/// - **取消**：循环内检查全局 `SEARCH_CANCELLED`。
pub(crate) async fn drive_source_batches<F, Fut, G>(
    sources: Vec<BookSource>,
    concurrency: usize,
    per_source_timeout: Duration,
    search_one: F,
    mut on_source: G,
) where
    F: Fn(BookSource) -> Fut + Send + Sync + 'static,
    Fut: std::future::Future<Output = LegadoResult<Vec<SearchResult>>> + Send + 'static,
    G: FnMut(SourceBatchOutcome) -> Result<(), String>,
{
    use futures::FutureExt;
    use std::panic::AssertUnwindSafe;

    let total = sources.len();
    if total == 0 {
        return;
    }
    let semaphore = Arc::new(tokio::sync::Semaphore::new(concurrency.max(1)));
    let search_one = Arc::new(search_one);

    let mut tasks = Vec::with_capacity(total);
    for (index, source) in sources.into_iter().enumerate() {
        let semaphore = Arc::clone(&semaphore);
        let search_one = Arc::clone(&search_one);
        tasks.push(tokio::spawn(async move {
            let source_url = source.book_source_url.clone();
            let source_name = source.book_source_name.clone();
            // 限流并发：获取许可后才真正发起搜索（等价原版线程池排队）
            let permit = match semaphore.acquire_owned().await {
                Ok(p) => p,
                Err(_) => {
                    return (
                        index,
                        source_url,
                        source_name,
                        Err(LegadoError::Network("并发信号量已关闭".into())),
                    )
                }
            };
            // 单源超时 + panic 隔离（catch_unwind 保证单源崩溃不传染）
            let outcome = tokio::time::timeout(
                per_source_timeout,
                AssertUnwindSafe(search_one(source)).catch_unwind(),
            )
            .await;
            drop(permit);
            let result = match outcome {
                Ok(Ok(res)) => res,
                Ok(Err(_panic)) => {
                    Err(LegadoError::Network("单源搜索异常（已隔离）".into()))
                }
                Err(_) => Err(LegadoError::Network(format!(
                    "搜索超时（{}s）",
                    per_source_timeout.as_secs()
                ))),
            };
            (index, source_url, source_name, result)
        }));
    }

    let mut set = futures::stream::FuturesUnordered::from_iter(tasks);
    let mut finished: usize = 0;
    while let Some(joined) = set.next().await {
        finished += 1;
        if SEARCH_CANCELLED.load(Ordering::SeqCst) {
            break;
        }
        // 任务级 JoinError 兑底隔离（正常路径已被 catch_unwind 覆盖）
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
            break;
        }
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
        time: 0,
        variable: None,
        origin_order: 0,
        chapter_word_count_text: None,
        chapter_word_count: -1,
        respond_time: -1,
        // 阅读记录标识（由 api::search 批量附加后透传）
        has_read_record: r.has_read_record,
        read_record_author: r.read_record_author,
    }
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
            authors
                .entry(record.book_name)
                .or_default()
                .extend(decoded);
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
pub(crate) async fn search_single_source(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchResult>> {
    // JS 书源分派
    if source.is_js_source() {
        return search_js_source(source, keyword).await;
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
    let analyze_url = tokio::task::spawn_blocking(move || {
        crate::js_executor::build_search_url(&template, &key, 1, &build_base)
    })
    .await
    .map_err(|e| LegadoError::Internal(format!("搜索 URL 构建任务异常: {e}")))?;

    // 3. 合并请求头：书源全局 header + AnalyzeUrl 提取的 header
    let mut headers = parse_header_option(source.header.as_deref()).unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    // 4. 发送 HTTP 请求
    let response = match analyze_url.method() {
        RequestMethod::Post => {
            let body = analyze_url.body().unwrap_or("");
            client.post(analyze_url.url(), body, headers_opt).await?
        }
        _ => client.get(analyze_url.url(), headers_opt).await?,
    };

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "搜索请求失败: HTTP {}",
            response.status
        )));
    }

    // 5. 使用 AnalyzeRule 解析搜索结果（同步解析同样移入阻塞线程，
    //    灾难性正则/超大页面不会阻塞 runtime，单源超时可中断）
    let body = response.body;
    let final_url = response.url;
    let source_clone = source.clone();
    tokio::task::spawn_blocking(move || parse_search_response(&body, &final_url, &source_clone))
        .await
        .map_err(|e| LegadoError::Internal(format!("搜索解析任务异常: {e}")))?
}

/// 构建搜索 URL
///
/// 处理 `{key}`、`{{key}}`、`searchKey` 等关键词占位符与 `{{JS表达式}}`
/// 模板（如 `{{encodeURIComponent(key)}}`、`{{page > 1 ? '/' + page : ''}}`），
/// 然后通过 AnalyzeUrl 解析 URL 选项（method/headers/body 等）。
/// 统一委托 [`crate::js_executor::build_search_url`]，与调试/搜索路径共用同一模板渲染语义。
fn build_search_url(template: &str, keyword: &str, source: &BookSource) -> AnalyzeUrl {
    crate::js_executor::build_search_url(template, keyword, 1, &source.book_source_url)
}

/// 解析搜索响应（HTML 或 JSON）
///
/// 使用书源的 `rule_search` 规则解析响应体为结构化搜索结果。
fn parse_search_response(
    body: &str,
    base_url: &str,
    source: &BookSource,
) -> LegadoResult<Vec<SearchResult>> {
    let rule_search = match source.rule_search.as_ref() {
        Some(r) => r,
        None => return Ok(Vec::new()),
    };

    // 创建顶层 AnalyzeRule（quickjs 启用时注入 JS 执行器，使 @js: 搜索规则生效）
    let analyzer = crate::js_executor::construct_analyzer(
        body.to_string(),
        base_url.to_string(),
        &source.book_source_url,
    );

    // 获取书籍列表元素
    let book_list_rule = rule_search.book_list.as_deref().unwrap_or("");
    let elements = if book_list_rule.is_empty() {
        // 无 bookList 规则：尝试将整个响应作为单条结果解析
        vec![body.to_string()]
    } else {
        analyzer.get_elements(book_list_rule).unwrap_or_default()
    };

    if elements.is_empty() {
        return Ok(Vec::new());
    }

    // 对每个元素解析各字段
    let mut results = Vec::new();
    for element_html in &elements {
        let item_analyzer = crate::js_executor::construct_analyzer(
            element_html.clone(),
            base_url.to_string(),
            &source.book_source_url,
        );

        // 提取书名（必填，无书名则跳过）
        let book_name = eval_field_string(&item_analyzer, rule_search.name.as_deref());
        if book_name.is_empty() {
            continue;
        }

        // 提取作者
        let author = eval_field_string(&item_analyzer, rule_search.author.as_deref());

        // 提取分类（部分失败不致整条丢弃，对齐原版逐字段 try/catch 语义）
        let kind = eval_field_optional(&item_analyzer, rule_search.kind.as_deref());

        // 提取字数并格式化（对齐原版 wordCountFormat）
        let word_count =
            word_count_format(&eval_field_string(&item_analyzer, rule_search.word_count.as_deref()));

        // 书籍详情页 URL
        let raw_book_url = eval_field_string(&item_analyzer, rule_search.book_url.as_deref());
        let book_url = resolve_url(&raw_book_url, base_url);

        // 提取封面 URL
        let raw_cover = eval_field_string(&item_analyzer, rule_search.cover_url.as_deref());
        let cover_url = if raw_cover.is_empty() {
            None
        } else {
            Some(resolve_url(&raw_cover, base_url))
        };

        // 提取简介
        let intro = eval_field_optional(&item_analyzer, rule_search.intro.as_deref());

        // 提取最新章节
        let latest_chapter =
            eval_field_optional(&item_analyzer, rule_search.last_chapter.as_deref());

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
            // 阅读记录标识由搜索完成后统一批量附加（见 annotate_results）
            has_read_record: false,
            read_record_author: None,
        });
    }

    Ok(results)
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
fn word_count_format(raw: &str) -> Option<String> {
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

/// 从 AnalyzeRule 中获取字段值（无结果返回空串）
///
/// 对标原版 `AnalyzeRule.getString(sourceRule)`：规则支持 Kotlin SourceRule 的
/// `##replaceRegex##replacement` 替换语法（复用 web_book::eval_rule_string）。
fn eval_field_string(analyzer: &AnalyzeRule, rule: Option<&str>) -> String {
    match rule {
        Some(r) if !r.is_empty() => {
            super::web_book::eval_rule_string(analyzer, r).unwrap_or_default()
        }
        _ => String::new(),
    }
}

/// 从 AnalyzeRule 中获取字段（返回 Option<String>），支持 `##` 替换语法
fn eval_field_optional(analyzer: &AnalyzeRule, rule: Option<&str>) -> Option<String> {
    let val = eval_field_string(analyzer, rule);
    if val.is_empty() {
        None
    } else {
        Some(val)
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

/// JS 书源搜索（通过 JsSourceBookOrchestrator 执行）
///
/// 使用 spawn_blocking 将 JS 执行移出 tokio worker 线程，
/// 避免 JS 宿主函数内部 block_on 导致嵌套 runtime 死锁（R1）。
async fn search_js_source(
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchResult>> {
    let source_clone = source.clone();
    let key = keyword.to_string();

    let values = tokio::task::spawn_blocking(move || {
        let orchestrator = crate::api::web_book::build_js_orchestrator(&source_clone)?;
        let mut orch = orchestrator.ok_or_else(|| {
            LegadoError::Internal("JS 书源缺少 mainJs".into())
        })?;
        orch.search(&source_clone, &key, 1)
    })
    .await
    .map_err(|e| LegadoError::Internal(format!("JS 搜索任务异常: {e}")))?
    ?;

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
                book_url: Some(
                    "@XPath:.//*[contains(@class, 'bookname')]/a/@href".to_string(),
                ),
                intro: Some(
                    "@XPath:.//*[contains(@class, 'update')]//text()##简介：".to_string(),
                ),
                last_chapter: Some(
                    "@XPath:.//*[contains(@class, 'cat')]//a/text()".to_string(),
                ),
                ..SearchRule::default()
            }),
            ..BookSource::default()
        };

        let results =
            parse_search_response(html, "https://www.sto66.com/search/99.html", &source)
                .unwrap();

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
        assert_eq!(results[0].latest_chapter, Some("第353章 大结局".to_string()));
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
                        latest_chapter: None,
                        intro: None,
                        cover_url: None,
                        kind: None,
                        word_count: None,
                        book_type: book_type::TEXT,
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
            search_one,
            move |o| {
                let (n, err) = match o.result {
                    Ok(ref b) => (Some(b.len()), None),
                    Err(ref e) => (None, Some(e.to_string())),
                };
                outcomes_c
                    .lock()
                    .unwrap()
                    .push((o.source_url, n, err, o.finished_count, o.total_count));
                Ok(())
            },
        )
        .await;

        let got = outcomes.lock().unwrap();
        assert_eq!(got.len(), 5, "每个书源都应产出一个批次（含失败/超时/panic）");
        // 成功源结果全部保留
        let ok_books: usize = got.iter().filter_map(|(_, n, _, _, _)| *n).sum();
        assert_eq!(ok_books, 2, "两个成功源各 1 本书应全部保留");
        // 失败/超时/panic 均有错误信息且不阻断其他源
        assert!(
            got.iter()
                .any(|(u, _, e, _, _)| u.contains("fail") && e.is_some())
        );
        assert!(got.iter().any(|(u, _, e, _, _)| u.contains("slow")
            && e.as_deref().is_some_and(|m| m.contains("超时"))));
        assert!(
            got.iter()
                .any(|(u, _, e, _, _)| u.contains("panic") && e.is_some())
        );
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

    // ─── 测试 fix32: 无匹配/字段完整/多媒体识别 ───────────────────────

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
            parse_search_response(body, "https://www.example.com/search?q=zzz", &source)
                .unwrap();
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

    /// bookType 判定对齐原版 `BookSource.getBookType()`
    #[test]
    fn test_book_type_of_source_mapping() {
        assert_eq!(book_type_of_source(0), book_type::TEXT);
        assert_eq!(book_type_of_source(1), book_type::AUDIO);
        assert_eq!(book_type_of_source(2), book_type::IMAGE);
        assert_eq!(book_type_of_source(3), book_type::TEXT | book_type::WEB_FILE);
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
            |_source| async {
                // 模拟修复后实现：同步长计算移入阻塞线程（await 点可中断）
                tokio::task::spawn_blocking(|| {
                    std::thread::sleep(Duration::from_millis(3000));
                    Ok(Vec::new())
                })
                .await
                .map_err(|e| LegadoError::Internal(e.to_string()))?
            },
            |outcome| {
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
            has_read_record: false,
            read_record_author: None,
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
            has_read_record: false,
            read_record_author: None,
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
}
