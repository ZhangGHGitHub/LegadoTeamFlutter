//! 换源 API
//!
//! 提供搜索可替换书源和切换书籍来源的功能。
//! 复用 legado-net 的 HTTP 客户端和 legado-core 的 SourceMatcher 评分逻辑。

use serde::{Deserialize, Serialize};

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};

use futures::stream::{self, StreamExt};

use legado_core::models::{Book, BookChapter, BookSource};
use legado_core::source_matcher::{SearchCandidate, SourceMatch, SourceMatcher};
use legado_core::web_book::{BookSourceFetcher, WebBookInfo, WebChapter};
use legado_core::{LegadoError, LegadoResult};
use legado_net::LegadoClient;

use crate::runtime;

/// 换源搜索高级选项（对齐 AppConfig changeSourceLoad* 三开关）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SwitchSearchOptions {
    #[serde(default, rename = "loadInfo")]
    pub load_info: bool,
    #[serde(default, rename = "loadToc")]
    pub load_toc: bool,
    #[serde(default, rename = "loadWordCount")]
    pub load_word_count: bool,
    /// 强制网络重搜（对齐原版换源「刷新列表」/startSearch；默认 false 优先复用 searchBooks）
    #[serde(default, rename = "forceRefresh")]
    pub force_refresh: bool,
}

impl SwitchSearchOptions {
    fn needs_enrichment(&self) -> bool {
        self.load_info || self.load_toc || self.load_word_count
    }
}

// ─── 换源预拉缓存 + 应用取消代数（2026-09-24 加法式，对齐上游
//     ChangeBookSourceViewModel 的 tocMap/bookMap 与 changeSourceCancelable
//     语义，解决「换源感知等待」：搜索期预拉详情+目录，选中即命中免抓取） ───

/// 预拉缓存条目：详情 info + 目录 chapters。
///
/// 上游拆两个 map（`tocMap` 仅存目录、`bookMap` 存书且恒写入）；这里合并为
/// 单条目：命中路径以 info（变量合并/字段更新）+ chapters（直接落库）共同
/// 替代 apply 链的 2a/2b 网络抓取。`info` 为 None（预拉期详情补抓失败）时
/// 命中降级为「缓存目录 + 详情现场补抓」的部分命中。
#[derive(Clone)]
struct SwitchPrefetchEntry {
    info: Option<WebBookInfo>,
    chapters: Vec<WebChapter>,
}

/// 预拉缓存体：条目表 + 已缓存目录总章数。
///
/// 总章数上限对齐上游 `tocMapChapterCount < 30000` 守卫（超限跳过缓存写入、
/// 仅影响命中收益，不影响候选展示；防超大目录预拉撑爆内存）。
struct SwitchPrefetchCache {
    entries: HashMap<String, SwitchPrefetchEntry>,
    chapter_count: usize,
}

// HashMap::new() 非 const → 外层 LazyLock 惰性初始化（Rust 1.80+ 稳定）
static SWITCH_PREFETCH_CACHE: LazyLock<Mutex<SwitchPrefetchCache>> = LazyLock::new(|| {
    Mutex::new(SwitchPrefetchCache {
        entries: HashMap::new(),
        chapter_count: 0,
    })
});

/// 预拉缓存总章数上限（上游 `tocMapChapterCount < 30000`，L399-403）
const PREFETCH_CACHE_MAX_CHAPTERS: usize = 30_000;

/// 缓存键：`source_url + '\0' + book_url`。
///
/// 对齐上游 `BookExtensions.primaryStr()`（BookExtensions.kt L266-268：
/// `origin + bookUrl` 两键直接拼接）；`\0` 分隔符防止源 URL/书 URL 不同
/// 长度时的边界歧义（如 `srcA`+`bc.com` 与 `srcAb`+`c.com` 同串）。
fn prefetch_cache_key(source_url: &str, book_url: &str) -> String {
    format!("{source_url}\u{0}{book_url}")
}

/// 清空预拉缓存。
///
/// 对应上游 `startSearch()` 入口清 `tocMap`/`bookMap`/`tocMapChapterCount`
/// （ChangeBookSourceViewModel.kt L279-281）：新一轮搜索会话开始时作废旧
/// 会话预拉，防选中读到上一会话的陈旧目录。
pub fn prefetch_cache_clear() {
    if let Ok(mut guard) = SWITCH_PREFETCH_CACHE.lock() {
        guard.entries.clear();
        guard.chapter_count = 0;
    }
}

/// 写入预拉缓存（总章数上限守卫：超限跳过写入，仅 log，不影响候选展示）。
fn prefetch_cache_insert(
    source_url: &str,
    book_url: &str,
    info: Option<WebBookInfo>,
    chapters: Vec<WebChapter>,
) {
    let key = prefetch_cache_key(source_url, book_url);
    let Ok(mut guard) = SWITCH_PREFETCH_CACHE.lock() else {
        return;
    };
    if guard.chapter_count + chapters.len() > PREFETCH_CACHE_MAX_CHAPTERS {
        log::debug!(
            "换源预拉缓存跳过：总章数 {}+{} 超上限 {}（对齐上游 tocMapChapterCount 守卫）",
            guard.chapter_count,
            chapters.len(),
            PREFETCH_CACHE_MAX_CHAPTERS
        );
        return;
    }
    guard.chapter_count += chapters.len();
    guard
        .entries
        .insert(key, SwitchPrefetchEntry { info, chapters });
}

/// 读取预拉缓存（命中返回条目克隆；未命中/加锁失败返回 None）。
fn prefetch_cache_get(source_url: &str, book_url: &str) -> Option<SwitchPrefetchEntry> {
    let key = prefetch_cache_key(source_url, book_url);
    SWITCH_PREFETCH_CACHE
        .lock()
        .ok()
        .and_then(|guard| guard.entries.get(&key).cloned())
}

// ─── 换源（预拉缓存版）应用取消代数（对齐上游 changeSourceCancelable /
//     cancelChangeSource，L692-721） ───

/// 应用取消代数：[`cancel_switch_apply`] +1；apply 前事务前比对，取消后
/// 不提交（DB 零变更）。同时 bump 既有 TOC 刷新代数，使在途 nextTocUrl
/// 分页链在下一页边界中止（复用 web_book.rs 既有 epoch 机制，不改签名）。
static SWITCH_APPLY_EPOCH: AtomicU64 = AtomicU64::new(0);

/// 取消进行中的换源（预拉缓存版）应用（FFI `source_switch_apply_cancel`，
/// 加法式；上游 `cancelChangeSource()` L715-721 的 FFI 化）
pub fn cancel_switch_apply() {
    SWITCH_APPLY_EPOCH.fetch_add(1, Ordering::SeqCst);
    super::web_book::bump_toc_fetch_epoch();
}

/// 增强预拉有界并发上限（保守值，论证见 [`enrich_switch_candidates_async`]
/// 文档：上游 threadCount=32 作用于「逐源搜索+增强」整链，我方搜索期已
/// 32 并发，增强期为重型目录抓取集中突发，取 8 防连接池饱和）。
const ENRICH_CONCURRENCY: usize = 8;

/// 换源搜索响应
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceSwitchResponse {
    /// 原始书籍名称
    pub book_name: String,
    /// 原始作者
    pub author: String,
    /// 匹配到的候选列表（按评分降序）
    pub matches: Vec<SourceMatch>,
}

/// 搜索可替换的书源
///
/// `book_name` — 当前书籍名称
/// `author` — 当前作者
/// `source_urls_json` — 可选 JSON 数组，指定搜索的书源 URL 列表；
/// 空串/空数组/缺省=搜索所有启用源（留项#12/Task #131，语义与
/// `search_books` 的 `source_urls_json` 一致，复用 `search::load_search_sources`）。
/// `options_json` — 可选 JSON 对象 `{loadInfo,loadToc,loadWordCount}`；
/// 空串/缺省时回退读取 config 同名键（对齐 AppConfig）。
///
/// 在指定（或全部启用）的书源中搜索，返回按匹配度排序的候选列表。
pub fn search_alternative_sources(
    book_name: &str,
    author: &str,
    source_urls_json: &str,
    options_json: &str,
) -> LegadoResult<SourceSwitchResponse> {
    let options = resolve_switch_options(options_json);

    // 对齐上游 startSearch() 入口清空 tocMap/bookMap（L279-281）：新一轮
    // 搜索会话作废旧会话预拉，防选中读到陈旧目录
    prefetch_cache_clear();

    // 对齐原版 ChangeBookSourceViewModel.searchDataFlow：
    // 先 getDbSearchBooks；非空则直接展示，仅空列表或强制刷新才全量搜索。
    if !options.force_refresh {
        if let Some(matches) = try_load_change_source_from_db(book_name, author, &options) {
            return Ok(SourceSwitchResponse {
                book_name: book_name.to_string(),
                author: author.to_string(),
                matches,
            });
        }
    } else {
        // 强制刷新：清掉该书旧 searchBooks，避免与新结果混杂
        clear_search_books_for_change(book_name, author);
    }

    let sources = resolve_switch_sources(source_urls_json)?;
    if sources.is_empty() {
        return Ok(SourceSwitchResponse {
            book_name: book_name.to_string(),
            author: author.to_string(),
            matches: Vec::new(),
        });
    }

    // 并行搜索（对齐 SearchModel.mapParallelSafe：限流并发 + 单源超时 60s）
    let book_name_for_search = book_name.to_string();
    let sources_for_search = sources.clone();
    let candidates = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;

        let mut all_candidates: Vec<SearchCandidate> = Vec::new();
        let outcomes: Vec<_> = stream::iter(sources_for_search)
            .map(|source| {
                let client = client.clone();
                let keyword = book_name_for_search.clone();
                async move {
                    let url = source.book_source_url.clone();
                    let result = tokio::time::timeout(
                        crate::api::search::SWITCH_SOURCE_TIMEOUT,
                        search_for_switch(&client, &source, &keyword),
                    )
                    .await;
                    (url, result)
                }
            })
            .buffer_unordered(crate::api::search::SEARCH_CONCURRENCY)
            .collect()
            .await;

        for (_url, joined) in outcomes {
            if let Ok(Ok(mut items)) = joined {
                all_candidates.append(&mut items);
            }
        }
        Ok::<_, LegadoError>(all_candidates)
    })?;

    // Task #25：对齐原版 ChangeBookSourceViewModel L266-270 的换源硬过滤：
    // 只保留同名书（fName == name），可选「校验作者」开关（原版
    // AppConfig.changeSourceCheckAuthor，键名一致）。此前仅打分排序不过滤，
    // match_score 为 0 的毫不相关错书仍全部进入换源列表（Task #25 现象）。
    // config 读取失败按关闭处理（不误伤同名过滤主语义）。
    let check_author = crate::api::config_api::get_config("changeSourceCheckAuthor")
        .map(|v| v.trim() == "true")
        .unwrap_or(false);
    let candidates = SourceMatcher::filter_for_change(candidates, book_name, author, check_author);

    let candidates = if options.needs_enrichment() {
        enrich_switch_candidates(&sources, candidates, &options)?
    } else {
        candidates
    };

    // 使用 SourceMatcher 评分排序（loadWordCount 开启时用字数 comparator）
    let matches = SourceMatcher::rank_candidates_with_options(
        candidates,
        book_name,
        author,
        options.load_word_count,
    );

    persist_switch_matches(&matches);

    Ok(SourceSwitchResponse {
        book_name: book_name.to_string(),
        author: author.to_string(),
        matches,
    })
}

/// 换源搜索流批次事件（契约 §2.4 `searchSourceStream`）
///
/// `matches` 为**当前已过滤评分候选的全量快照**——Rust 侧维持过滤/排序，UI 仅替换展示；
/// 单源失败经 `error` 字段承载，不中断流。
#[derive(Debug, Clone, Serialize)]
pub struct ChangeSourceBatch {
    /// 刚完成书源的索引（0-based；DB 复用 / enrich 终批为 0）
    pub source_index: usize,
    pub source_url: String,
    pub source_name: String,
    /// 该源搜索失败时的错误信息（成功为 None）
    pub error: Option<String>,
    /// 已完成书源数量
    pub finished_count: usize,
    /// 本次搜索书源总数
    pub total_count: usize,
    /// 是否为最后一个批次（finished_count == total_count）
    pub is_last: bool,
    /// 当前已过滤评分候选全量快照（同名过滤(+可选作者校验) + 评分排序）
    pub matches: Vec<SourceMatch>,
}

/// 推送一个换源流批次事件；返回 `Err`（sink 关闭）时由调用方决定终止
fn push_change_source_batch(
    on_batch: &mut impl FnMut(String) -> Result<(), String>,
    batch: ChangeSourceBatch,
) -> Result<(), String> {
    let json = serde_json::to_string(&batch).map_err(|e| e.to_string())?;
    on_batch(json)
}

/// 换源搜索流式驱动器（T6 / 契约 §2.4 `searchSourceStream`）
///
/// 每完成一个书源推送一批次事件（`on_batch` 接收批次 JSON 字符串）：
/// - `matches` = 累积候选经同名过滤(+可选作者校验)与评分排序后的**全量快照**——
///   逐源增量过滤 ≡ 批量过滤（[`SourceMatcher::filter_for_change`] 为元素级判定）；
/// - 进度由 `finished_count`/`total_count` 承载；单源失败推带 `error` 字段的批次，不中断流；
/// - DB 复用路径（forceRefresh=false 且 searchBooks 有数据）推单批即结束，无网络请求；
/// - 全部书源完成后：enrich 开启时执行流内后置增强（详情/目录/试读字数）并再推一批
///   enriched+重排快照——**不阻塞首批到达**（所有搜索批次已先行推送）；
///   最终候选落库 searchBooks（对齐原版 searchSuccess → insert）。
///
/// `on_batch` 返回 `Err`（sink 关闭 / 流取消）→ 驱动器置位取消并 abort 在飞任务，结束流。
pub async fn run_change_source_stream<F>(
    book_name: String,
    author: String,
    source_urls_json: String,
    options_json: String,
    mut on_batch: F,
) where
    F: FnMut(String) -> Result<(), String>,
{
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    let options = resolve_switch_options(&options_json);

    // 对齐上游 startSearch() 入口清空 tocMap/bookMap（L279-281）：新一轮
    // 搜索会话作废旧会话预拉，防选中读到陈旧目录
    prefetch_cache_clear();

    // 对齐原版 ChangeBookSourceViewModel.searchDataFlow：先 getDbSearchBooks，
    // 非空直接展示（单批推送即结束）；仅空列表或强制刷新才全量搜索
    if !options.force_refresh {
        if let Some(matches) = try_load_change_source_from_db(&book_name, &author, &options) {
            // 早期批次：sink 关闭无在飞任务可 abort，忽略推送结果
            let _ = push_change_source_batch(
                &mut on_batch,
                ChangeSourceBatch {
                    source_index: 0,
                    source_url: String::new(),
                    source_name: String::new(),
                    error: None,
                    finished_count: 1,
                    total_count: 1,
                    is_last: true,
                    matches,
                },
            );
            return;
        }
    } else {
        // 强制刷新：清掉该书旧 searchBooks，避免与新结果混杂
        clear_search_books_for_change(&book_name, &author);
    }

    let sources = match resolve_switch_sources(&source_urls_json) {
        Ok(s) => s,
        Err(e) => {
            let _ = push_change_source_batch(
                &mut on_batch,
                ChangeSourceBatch {
                    source_index: 0,
                    source_url: String::new(),
                    source_name: String::new(),
                    error: Some(e.to_string()),
                    finished_count: 0,
                    total_count: 0,
                    is_last: true,
                    matches: Vec::new(),
                },
            );
            return;
        }
    };

    if sources.is_empty() {
        let _ = push_change_source_batch(
            &mut on_batch,
            ChangeSourceBatch {
                source_index: 0,
                source_url: String::new(),
                source_name: String::new(),
                error: None,
                finished_count: 0,
                total_count: 0,
                is_last: true,
                matches: Vec::new(),
            },
        );
        return;
    }

    let client = match crate::http_state::shared_client() {
        Ok(c) => c,
        Err(e) => {
            let _ = push_change_source_batch(
                &mut on_batch,
                ChangeSourceBatch {
                    source_index: 0,
                    source_url: String::new(),
                    source_name: String::new(),
                    error: Some(e.to_string()),
                    finished_count: 0,
                    total_count: sources.len(),
                    is_last: true,
                    matches: Vec::new(),
                },
            );
            return;
        }
    };

    // 与批量路径同口径：原版 AppConfig.changeSourceCheckAuthor（读取失败按关闭）
    let check_author = crate::api::config_api::get_config("changeSourceCheckAuthor")
        .map(|v| v.trim() == "true")
        .unwrap_or(false);

    // 会话级门控标志：sink 关闭 → 驱动器置位取消并 abort 在飞任务（复用 P0-3 驱动机制）
    let cancel = Arc::new(AtomicBool::new(false));
    let paused = Arc::new(AtomicBool::new(false));

    // 累积过滤后候选（逐源增量过滤 ≡ 批量过滤，元素级判定）
    let mut accumulated: Vec<SearchCandidate> = Vec::new();

    // search_one 闭包为 move（'static），需预克隆；on_source 闭包借用 book_name/author/options
    let client_for_search = client.clone();
    let book_name_for_search = book_name.clone();

    crate::api::search::drive_source_batches(
        sources.clone(),
        crate::api::search::SEARCH_CONCURRENCY,
        crate::api::search::SWITCH_SOURCE_TIMEOUT,
        &cancel,
        &paused,
        move |source: BookSource| {
            let client = client_for_search.clone();
            let keyword = book_name_for_search.clone();
            async move { search_for_switch(&client, &source, &keyword).await }
        },
        |outcome| {
            // 该源候选增量过滤（同名 + 可选作者校验）并累积
            if let Ok(items) = &outcome.result {
                accumulated.extend(SourceMatcher::filter_for_change(
                    items.clone(),
                    &book_name,
                    &author,
                    check_author,
                ));
            }
            // 重排快照：当前已过滤评分候选全量集
            let matches = SourceMatcher::rank_candidates_with_options(
                accumulated.clone(),
                &book_name,
                &author,
                options.load_word_count,
            );
            // sink 关闭（Err）→ 传播给驱动器，置位取消并 abort 在飞任务
            push_change_source_batch(
                &mut on_batch,
                ChangeSourceBatch {
                    source_index: outcome.index,
                    source_url: outcome.source_url,
                    source_name: outcome.source_name,
                    error: outcome.result.err().map(|e| e.to_string()),
                    finished_count: outcome.finished_count,
                    total_count: outcome.total_count,
                    is_last: outcome.is_last,
                    matches,
                },
            )
        },
    )
    .await;

    // 流内后置增强（不阻塞首批到达——所有搜索批次已先行推送）：
    // enrich 开启时对累积候选执行详情/目录/试读字数，再推最终重排快照
    let enriched = if options.needs_enrichment() {
        enrich_switch_candidates_async(
            &sources,
            accumulated,
            &options,
            super::web_book::RealBookSourceFetcher::new,
        )
        .await
        .unwrap_or_default()
    } else {
        accumulated
    };

    let final_matches = SourceMatcher::rank_candidates_with_options(
        enriched,
        &book_name,
        &author,
        options.load_word_count,
    );

    // 终批仅在 enrich 开启时推送（enriched+重排快照）；未开启时最后一搜索批次即最终态
    if options.needs_enrichment() {
        let total = sources.len();
        // 终批推送失败（sink 已关闭）不影响最终候选落库
        let _ = push_change_source_batch(
            &mut on_batch,
            ChangeSourceBatch {
                source_index: 0,
                source_url: String::new(),
                source_name: String::new(),
                error: None,
                finished_count: total,
                total_count: total,
                is_last: true,
                matches: final_matches.clone(),
            },
        );
    }

    // 最终候选落库 searchBooks（对齐原版 searchSuccess → insert；供下次读库路径复用）
    persist_switch_matches(&final_matches);
}

/// 从 searchBooks 表加载换源候选（对齐 getDbSearchBooks）
///
/// 有结果时返回 Some；无结果/DB 未初始化/读失败返回 None（回退网络搜索）。
fn try_load_change_source_from_db(
    book_name: &str,
    author: &str,
    options: &SwitchSearchOptions,
) -> Option<Vec<SourceMatch>> {
    if !crate::db_state::is_initialized() {
        return None;
    }
    let check_author = crate::api::config_api::get_config("changeSourceCheckAuthor")
        .map(|v| v.trim() == "true")
        .unwrap_or(false);
    let search_group = crate::api::config_api::get_config("searchGroup")
        .unwrap_or_default()
        .trim()
        .to_string();
    let author_filter = if check_author {
        legado_core::book_help::format_book_author(author)
    } else {
        String::new()
    };
    // [审计 D6 | ChangeBookSourceViewModel.kt:603-625] 原版 getDbSearchBooks 以
    // 原样 book.name 查询（不做归一化）；库内书名在解析期已经 formatBookName，
    // 查询参数不再二次归一化
    log::info!(
        "换源读库: name={} author_filter={} searchGroup={}",
        book_name,
        author_filter,
        search_group
    );

    let books = crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        repo.change_source_by_group(book_name, &author_filter, &search_group)
    })
    .ok()?;

    if books.is_empty() {
        return None;
    }

    let candidates: Vec<SearchCandidate> = books
        .into_iter()
        .map(|b| SearchCandidate {
            source_url: b.origin,
            source_name: b.origin_name,
            book_url: b.book_url,
            book_name: b.name,
            author: b.author,
            latest_chapter: b.latest_chapter_title,
            word_count: b.word_count,
            chapter_word_count_text: b.chapter_word_count_text,
            chapter_word_count: b.chapter_word_count,
            respond_time: b.respond_time,
            origin_order: b.origin_order,
            book_score: b.book_score,
            // [T5] 读库路径：searchBooks 行的搜索期级联变量
            variable: b.variable,
        })
        .collect();

    // 读库路径不再二次过滤（SQL 已按名/作者/分组筛过）；直接评分排序
    let matches = SourceMatcher::rank_candidates_with_options(
        candidates,
        book_name,
        author,
        options.load_word_count,
    );
    if matches.is_empty() {
        None
    } else {
        Some(matches)
    }
}

fn clear_search_books_for_change(book_name: &str, author: &str) {
    if !crate::db_state::is_initialized() {
        return;
    }
    let check_author = crate::api::config_api::get_config("changeSourceCheckAuthor")
        .map(|v| v.trim() == "true")
        .unwrap_or(false);
    let author_filter = if check_author {
        legado_core::book_help::format_book_author(author)
    } else {
        String::new()
    };
    let normalized_name = legado_core::book_help::format_book_name(book_name);
    let _ = crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        let _ = repo.clear_by_name_author(&normalized_name, &author_filter);
        Ok(())
    });
}

/// 切换到新书源
///
/// `book_url` — 当前书籍的 bookUrl（稳定主键，换源后保持不变）
/// `new_source_url` — 新书源的 URL
/// `new_book_url` — 新书源中该书籍的详情页 URL
///
/// 返回更新后的书籍信息（JSON）。
///
/// Task #16 P0（方案 A，对齐 Android 原版）：**bookUrl 作为稳定主键，换源时不
/// 变更 bookUrl**。仅更新书源相关字段（origin/originName/tocUrl），随后清除该
/// bookUrl 下的旧章节与旧缓存正文，并用 new_book_url 从新源重新抓取目录、以
/// 稳定的原 bookUrl 落库。避免旧实现「先改 book_url 再按新值 update」命中 0 行
/// 回退 insert 导致的僵尸记录与章节孤儿；同时清缓存避免跨源正文串本。
/// 切换到新书源
///
/// `book_url` — 当前书籍的 bookUrl（稳定主键，换源后保持不变）
/// `new_source_url` — 新书源的 URL
/// `new_book_url` — 新书源中该书籍的详情页 URL
///
/// 返回更新后的书籍信息（JSON）。
///
/// Task #16 P0（方案 A，对齐 Android 原版）：**bookUrl 作为稳定主键，换源时不
/// 变更 bookUrl**。仅更新书源相关字段（origin/originName/tocUrl），随后清除该
/// bookUrl 下的旧章节与旧缓存正文，并用 new_book_url 从新源重新抓取目录、以
/// 稳定的原 bookUrl 落库。避免旧实现「先改 book_url 再按新值 update」命中 0 行
/// 回退 insert 导致的僵尸记录与章节孤儿；同时清缓存避免跨源正文串本。
pub fn switch_book_source(
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    let fetcher = super::web_book::RealBookSourceFetcher::new()?;
    switch_book_source_with(&fetcher, book_url, new_source_url, new_book_url)
}

/// [T5] 变量合并：候选搜索期变量（searchBooks 行）为先，详情页导出变量
/// 后写入者优先（对齐原版 AnalyzeRule.putVariable 同名键覆盖语义）。
/// 两侧均空/均非 JSON 对象 → None。
pub(crate) fn merge_variables(initial: Option<&str>, detail: Option<&str>) -> Option<String> {
    let mut map = serde_json::Map::new();
    for (label, src) in [("initial", initial), ("detail", detail)] {
        let _ = label;
        if let Some(s) = src.map(str::trim).filter(|v| !v.is_empty()) {
            if let Ok(serde_json::Value::Object(m)) = serde_json::from_str::<serde_json::Value>(s) {
                for (k, v) in m {
                    map.insert(k, v);
                }
            }
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(serde_json::Value::Object(map).to_string())
    }
}

/// [P2-15 剩项②] 陈旧 overlay 让位：换源合并点上，对本进程 JS 写路径
/// 残留 overlay（`super::web_book::book_var_overlay_map` 返回的键域，即
/// `bookVar::{bookUrl}::` 持久裸层键）参与 [`merge_variables`] 合并后
/// 的结果做保守修正——**仅**这些键在满足全部条件时用 DB 值覆盖：
///
/// 1. 键 ∈ overlay 键域（`overlay_keys`）——本进程 JS `book.putVariable`
///    写路径的残留值（`GLOBAL_VARIABLES` 进程级黏性：换源/换书不清，
///    见 P2-15 剩项① 的收窄说明）；
/// 2. 键 ∉ 候选搜索行变量（`candidate_variable`）——候选 ⊕ 详情是 T5
///    换源意图内的新鲜合并链，候选携带的键绝不让位（T5 候选优先不变）；
/// 3. DB `books.variable`（`db_variable`）已有该键的值——DB 为持久权威
///    值（用户编辑 / 既有落库），比进程级残留 overlay「更新」。
///
/// 其余一律不动：非 overlay 键（详情 `@put` 导出等新鲜解析产物）不
/// 让位；DB 无该键或值相等 → 零副作用直通；`merged` 为 None → None；
/// `merged` / 各输入非 JSON 对象 → 降级原样返回（不阻断换源）。
///
/// 已知降级（有意为之）：本阶段 JS 写入的同名键若同时被用户在 DB 编辑
/// 过，也一并让位给 DB 值（DB 权威），与账本「让位给更新的 DB 值」一致。
pub(crate) fn yield_stale_overlay_to_db(
    merged: Option<&str>,
    db_variable: Option<&str>,
    candidate_variable: Option<&str>,
    overlay_keys: &HashMap<String, String>,
) -> Option<String> {
    let merged_raw = merged?;
    let Some(serde_json::Value::Object(mut map)) =
        serde_json::from_str::<serde_json::Value>(merged_raw).ok()
    else {
        return Some(merged_raw.to_string());
    };
    let candidate_has_key = |k: &str| {
        candidate_variable
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
            .map(|v| v.as_object().is_some_and(|o| o.contains_key(k)))
            .unwrap_or(false)
    };
    let db_value = |k: &str| {
        db_variable
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
            .and_then(|v| v.as_object().and_then(|o| o.get(k)).cloned())
    };
    for k in overlay_keys.keys() {
        if candidate_has_key(k) {
            continue;
        }
        if let Some(db_v) = db_value(k) {
            if map.get(k) != Some(&db_v) {
                map.insert(k.clone(), db_v);
            }
        }
    }
    Some(serde_json::Value::Object(map).to_string())
}

/// 定位书籍 + 加载新书源配置（只读；旧路径与预拉缓存版共用）
///
/// 先不写库，待新目录抓取成功后才在提交事务里统一落库，避免新源抰 0 章
/// 时已改了 origin/tocUrl 却没有章节的不一致中间态。
fn locate_switch_book_and_source(
    book_url: &str,
    new_source_url: &str,
) -> LegadoResult<(Book, BookSource)> {
    use crate::db_state::with_database;
    use legado_db::BookRepository;

    let (book, source) = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        let book = repo
            .find_by_url(book_url)?
            .ok_or_else(|| LegadoError::Database("书籍不存在".into()))?;

        // 新书源配置：既用于抓取新目录，也用于取书源名称
        let source_repo = legado_db::BookSourceRepository::new(db.connection());
        let source = source_repo
            .find_by_url(new_source_url)?
            .ok_or_else(|| LegadoError::Database(format!("书源不存在: {new_source_url}")))?;

        Ok((book, source))
    })?;
    Ok((book, source))
}

/// [T5] 候选搜索期变量：searchBooks 行按 (new_book_url, origin=new_source_url)
/// 命中时取 variable（对齐原版 SearchBook.toBook() 复制 variable 进入换源）
fn lookup_candidate_variable(
    new_book_url: &str,
    new_source_url: &str,
) -> LegadoResult<Option<String>> {
    let variable = crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        match repo.find_by_book_url(new_book_url)? {
            Some(row) if row.origin == new_source_url => Ok(row.variable),
            _ => Ok(None),
        }
    })?;
    Ok(variable)
}

/// [T5] book.variable = 候选搜索期变量 ⊕ 详情/预拉 info 导出变量（后者写入
/// 者优先，对齐原版覆盖语义）；旧源旧值不再残留（R1 清单项）。
/// [P2-15 剩项②] 陈旧 overlay 让位：见 [`yield_stale_overlay_to_db`] 文档
/// （规则与降级不变，旧路径/预拉缓存版共用同一合并点）。
fn apply_book_variable_merge(
    book: &mut Book,
    candidate_variable: Option<&str>,
    info_variable: Option<&str>,
    new_book_url: &str,
) {
    let merged_variable = merge_variables(candidate_variable, info_variable);
    book.variable = yield_stale_overlay_to_db(
        merged_variable.as_deref(),
        book.variable.as_deref(),
        candidate_variable,
        &super::web_book::book_var_overlay_map(new_book_url),
    );
}

/// 当前 Unix 时间戳（毫秒）——目录派生字段同步写 latestChapterTime 用
/// （与 legado-core::toc_updater::now_millis 同一实现风格）
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// 换源提交尾段（旧路径与预拉缓存版共用）：
/// tocUrl 解析 → 空目录守卫 → BookChapter 转换（稳定 bookUrl）→ 单事务落库
/// → [B-6] 新源下一章登记 → 书籍 JSON。
fn commit_source_switch(
    book: &mut Book,
    source: &BookSource,
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
    info: WebBookInfo,
    web_chapters: Vec<WebChapter>,
) -> LegadoResult<String> {
    use crate::db_state::with_database;
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

    // [T2] tocUrl = 详情解析出的真实目录页（目录页可与详情页不同，
    //     如「详情页=books/1、目录页=/book/1/chapters」的源）
    let toc_url = if info.toc_url.trim().is_empty() {
        new_book_url.to_string()
    } else {
        info.toc_url.clone()
    };

    // Task #21 修复：空结果保护。新书源未解析到任何章节时（目录抓取返回
    //    Ok(vec![]) 而非错误），直接返回可读错误，且不改动任何库记录
    //    （保留原 origin/tocUrl 与原目录），避免把书换成「无章节」而比未换源
    //    更糟的回归。
    if web_chapters.is_empty() {
        return Err(LegadoError::Parser(format!(
            "换源失败：新书源未解析到任何章节（目录地址={toc_url}），已保留原书源与目录"
        )));
    }

    // 3. 转换为 BookChapter，base_url/book_url 均落稳定的原 bookUrl
    //    [T1] 保留解析值 variable/is_volume：章节级 @put 变量（翻页 token 类）
    //    与卷章标记是正文请求/去重的前置输入，写死 None/false 会导致换源后正文错误
    let book_chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: wc.is_volume,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: None,
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: wc.variable.clone(),
            img_url: None,
        })
        .collect();

    // 4. 将书源字段更新 + 清旧缓存/旧章节 + 写入新章节，全部包进单个 DB 事务：
    //    全部成功才提交；中途失败自动回滚，保留原书源与原章节，
    //    避免留下"无章节"状态（比未换源更糟）。bookUrl 保持稳定，仅改
    //    origin/originName/tocUrl，update 的 WHERE 命中原行（稳定主键）。
    //    connection() 返回共享的 &Connection（r2d2 池），无法用需 &mut 的
    //    Connection::transaction()，故沿用项目既有的 unchecked_transaction()
    //    模式（见 highlight_rule_repository / book_chapter_repository）。
    //    insert_batch 内部会自开事务，此处改用 insert_batch_no_tx 避免嵌套 BEGIN。
    // 仅更新书源相关字段；bookUrl 不变 → update 的 WHERE 命中原行（稳定主键）
    book.origin = new_source_url.to_string();
    book.origin_name = source.book_source_name.clone();
    // [T2] tocUrl = 详情解析出的真实目录页（原写死详情页 URL，使「目录独立页」
    //      源后续刷新目录/正文定位全错）
    book.toc_url = toc_url;
    // [P2-8] 换源根因修复：写入当前书源下该书的详情页地址（new_book_url）。
    //    换源后 bookUrl（稳定主键）仍为旧源地址，「抓取书籍页」路径
    //    （详情刷新 / tocUrl 推导 / preUpdateJs 钩子）优先用本字段，为空时
    //    回退 bookUrl（未换源书籍与存量库行为不变）。
    book.origin_book_url = new_book_url.to_string();
    // [T2] 详情字段按 parse 门控结果更新（name/author 已含 canReName 门控；
    //      Option 字段仅在解析出值时覆盖，避免新源缺字段抹掉既有信息）
    book.name = info.name;
    book.author = info.author;
    if info.cover_url.is_some() {
        book.cover_url = info.cover_url;
    }
    if info.intro.is_some() {
        book.intro = info.intro;
    }
    if info.kind.is_some() {
        book.kind = info.kind;
    }
    if info.word_count.is_some() {
        book.word_count = info.word_count;
    }
    // [目录派生字段同步] 对齐上游 BookChapterList.updateBookTocInfo（目录成功
    // 后 totalChapterNum/latestChapterTitle 以目录结果写入；详情 lastChapter
    // 规则值写在目录写之前，由目录值覆盖——此处不再取详情值）：
    // - totalChapterNum = 落库章节数（与同事务 insert_batch 的 bookChapters
    //   行数一致，DB 内部一致性；书架进度百分比 = durChapterIndex/(N-1) 随之
    //   正确）
    // - latestChapterTitle = 新目录末章标题
    // - latestChapterTime = now，仅章数增长时（上游 updateBookTocInfo 条件分支）
    // 截断目录（非 2xx 保留前缀）按前缀章数写入——对齐上游「body-null 判停
    // 后 updateBookTocInfo 写 list.size」；I/O 级失败/空结果不会走到提交
    // （目录抓取 Err 上抛 + 函数入口空目录守卫），不存在陈旧值写回路径。
    let old_total = book.total_chapter_num;
    let new_total = book_chapters.len() as i32;
    book.total_chapter_num = new_total;
    book.latest_chapter_title = book_chapters.last().map(|c| c.title.clone());
    if old_total < new_total {
        book.latest_chapter_time = now_millis();
    }
    // 标记需要重新获取章节列表
    book.last_check_time = 0;
    book.last_check_count = 0;
    with_database(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启换源事务失败: {e}")))?;

        // [B-4] `update` 的 UPDATE SET 结构性排除进度列（见
        // BookRepository::update 的 [B-3] 注释）：本事务的入参 book 是「抓取前
        // 快照」（locate_switch_book_and_source 读取），不含分钟级网络抓取
        // 窗口内写入的进度——全行写回会把窗口内进度抹平。此处零代码改动：
        // 靠结构排除实现「换源提交不抹窗口内进度」。
        BookRepository::new(conn).update(book)?;
        let cache_repo = legado_db::CacheBookRepository::new(conn);
        cache_repo.delete_by_book(book_url)?;
        let chapter_repo = legado_db::BookChapterRepository::new(conn);
        chapter_repo.delete_by_book_url(book_url)?;
        chapter_repo.insert_batch_no_tx(&book_chapters)?;

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交换源事务失败: {e}")))?;
        Ok(())
    })?;

    // [B-6] 换源提交后按**新书源**登记 (书源, 章节) → 下一章 URL：换源后
    // 正文分页「命中下一章即截断」按当前书源的目录判定（registry 复合键
    // (书源, 章节) 天然隔离旧源登记，此处为当前书源补齐精确通道）
    super::web_book::record_next_chapter_map(new_source_url, &web_chapters);

    serde_json::to_string(&book).map_err(LegadoError::Serialization)
}

/// 换源核心（fetcher 注入，便于单测以 Mock 验证 T2 执行链）
///
/// [T2 | ChangeBookSourceViewModel.kt:718-731 getToc] 对齐原版换源执行链：
/// **先 `getBookInfoAwait`（canReName=false，保留既有书名/作者）解析真实
/// tocUrl（ruleBookInfo.tocUrl 的目录页可与详情页不同），再用它取目录**；
/// 详情或目录任一步失败 → 整个换源失败返回可读错误（含书源名），单事务
/// 未提交即保留旧源。禁止拿 new_book_url 硬闯目录。
///
/// 2026-09-24 重构（行为不变）：定位/候选变量/变量合并/提交尾段拆为
/// [`locate_switch_book_and_source`]/[`lookup_candidate_variable`]/
/// [`apply_book_variable_merge`]/[`commit_source_switch`]，与预拉缓存版
/// [`switch_book_source_prefetch`] 共用；执行顺序与副作用逐项保持原样。
fn switch_book_source_with<F: BookSourceFetcher>(
    fetcher: &F,
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    // Task #21 修复：换源目标详情页 URL 为空时提前返回可读错误。
    // 否则空 URL 会传入 get_chapters（步骤 2b），触发解析器抛出令人困惑的
    // "bookUrl不能为空"（web_book.rs get_chapters 空值校验）。
    // 空 book_url 通常源于书源 ruleSearch.bookUrl 未解析出详情页 URL 的候选，
    // 此处兜底防御，主过滤在 search_for_switch（不让空候选进入换源列表）。
    if new_book_url.trim().is_empty() {
        return Err(LegadoError::Parser(
            "换源目标书籍详情页 URL 为空，无法切换书源（该候选未解析出有效链接）".into(),
        ));
    }

    // 1. 定位书籍 + 加载新书源配置（只读，见 helper 文档）
    let (mut book, source) = locate_switch_book_and_source(book_url, new_source_url)?;

    // [T5] 候选搜索期变量（searchBooks 行回查）
    let candidate_variable = lookup_candidate_variable(new_book_url, new_source_url)?;

    // P1-2 入口收口：换源执行 ruleBookInfo + 写 DB（变量桥读写）→ 先切
    // flow scope（键 = 新源详情页 URL，与 webbook_info 同键族），防上一
    // 流程残留 scope 串读/误清
    crate::api::web_book::begin_book_flow(new_book_url);

    // 2a. [T2] 新源详情解析（canReName=false：保留既有书名/作者，对齐原版
    //     changeSource getBookInfoAwait 门控；cover/intro/kind/lastChapter/
    //     wordCount 在 parse 内按解析值更新，tocUrl 为真实目录页）
    //     [R1 修复 2026-09-06] 详情请求带候选搜索期变量表：原版
    //     getBookInfoAwait 的 AnalyzeUrl 以 ruleData=book 构建（WebBook.kt:225-231，
    //     book.variable=候选变量），bookUrl 的 {{key}} 模板与 ,{json} 请求选项
    //     用其展开；此前恒空表 → 变量依赖源详情请求打错地址。
    let detail_vars = super::web_book::chapter_url_variables(candidate_variable.as_deref());
    let info = runtime::block_on(async {
        fetcher
            .get_book_info_with_existing_and_vars(
                &source,
                new_book_url,
                false,
                &book.name,
                &book.author,
                &detail_vars,
            )
            .await
    })
    .map_err(|e| {
        LegadoError::Parser(format!(
            "换源失败：新源「{}」详情页解析失败，已保留原书源与目录: {e}",
            source.book_source_name
        ))
    })?;

    // [T5] 变量合并 + 陈旧 overlay 让位（须在 2b 目录抓取前完成：目录请求
    //      变量表 = 候选 ⊕ 详情导出合并值，见 helper 文档）
    apply_book_variable_merge(
        &mut book,
        candidate_variable.as_deref(),
        info.variable.as_deref(),
        new_book_url,
    );

    // 2b. [T2] 用解析出的真实 tocUrl 抓取新目录
    let toc_url = if info.toc_url.trim().is_empty() {
        new_book_url.to_string()
    } else {
        info.toc_url.clone()
    };
    let web_chapters: Vec<WebChapter> = runtime::block_on(async {
        // [R1 修复 2026-09-06] 目录请求带合并后 book.variable（候选 ⊕ 详情导出）：
        // 原版 getChapterListAwait 的 AnalyzeUrl 以 ruleData=book 构建
        // （WebBook.kt:312-318）；此前恒空表 → 变量依赖源目录请求打错地址。
        let toc_vars = super::web_book::chapter_url_variables(book.variable.as_deref());
        // P2-2（2026-09-17）：传 2a 详情解析出的书名作 hint。上游
        // BookChapterList.kt:196 以 `AnalyzeRule(book, bookSource)` 构建
        // 解析器，`@js:[{title: book.name, url: …}]` 类 ruleToc.chapterList
        // 规则可读取 book.name；已知目录页直抓路径不抓详情页，无 hint 时
        // book 绑定名为空 → 此类规则标题退化（SiS文學網简体等 4 源）。
        // hint 为 Option：Mock 等实现走 trait 默认（退化为
        // get_chapters_with_vars），既有签名不变。
        fetcher
            .get_chapters_with_vars_and_name_hint(&source, &toc_url, &toc_vars, Some(&info.name))
            .await
    })
    .map_err(|e| {
        LegadoError::Parser(format!(
            "换源失败：新源「{}」目录获取失败，已保留原书源与目录: {e}",
            source.book_source_name
        ))
    })?;

    // 3+4. 空目录守卫 + 单事务提交 + 下一章登记 + 书籍 JSON（共用尾段）
    commit_source_switch(
        &mut book,
        &source,
        book_url,
        new_source_url,
        new_book_url,
        info,
        web_chapters,
    )
}

/// 换源（预拉缓存版，2026-09-24 加法式；FFI `source_switch_apply_prefetch`）
///
/// 命中/未命中语义对齐上游 `getToc`（ChangeBookSourceViewModel.kt L659-682）：
/// - **命中**（预拉缓存有该候选非空目录）：直接用缓存的详情 + 目录，
///   **零网络**（2a/2b 均跳过；变量合并/陈旧 overlay 让位/空目录守卫/
///   单事务提交/下一章登记逐项不变）——「选中源即落地」的感知等待消除点；
/// - **未命中**：详情 + 目录现场抓取（执行链与 [`switch_book_source_with`]
///   一致），**可取消**——[`cancel_switch_apply`] 使 apply 代数 +1 并 bump
///   TOC 刷新代数，事务前代数比对防取消后提交（DB 零变更），在途
///   nextTocUrl 分页链在下一页边界中止。
///
/// `book_url` — 当前书籍的 bookUrl（稳定主键，换源后保持不变）
/// `new_source_url` — 新书源的 URL
/// `new_book_url` — 新书源中该书籍的详情页 URL
pub fn switch_book_source_prefetch(
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    let fetcher = super::web_book::RealBookSourceFetcher::new()?;
    switch_book_source_prefetch_with(&fetcher, book_url, new_source_url, new_book_url)
}

/// 换源核心（预拉缓存版，fetcher 注入便于单测以 Mock 验证命中零抓取/
/// 未命中现场抓取/取消路径）
fn switch_book_source_prefetch_with<F: BookSourceFetcher>(
    fetcher: &F,
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    // Task #21 同款兜底防御（与旧路径同一文案/同一前置）
    if new_book_url.trim().is_empty() {
        return Err(LegadoError::Parser(
            "换源目标书籍详情页 URL 为空，无法切换书源（该候选未解析出有效链接）".into(),
        ));
    }

    // 取消代数：cancel_switch_apply +1；各网络步骤前与提交前比对，取消后
    // 不提交（DB 零变更），并 bump TOC 刷新代数中止在途分页链
    let apply_epoch = SWITCH_APPLY_EPOCH.load(Ordering::SeqCst);
    let ensure_not_cancelled = |epoch: u64| -> LegadoResult<()> {
        if epoch != SWITCH_APPLY_EPOCH.load(Ordering::SeqCst) {
            super::web_book::bump_toc_fetch_epoch();
            return Err(LegadoError::Internal("换源已取消".into()));
        }
        Ok(())
    };

    // 1. 定位书籍 + 加载新书源配置（与旧路径共用）
    let (mut book, source) = locate_switch_book_and_source(book_url, new_source_url)?;

    // [T5] 候选搜索期变量（与旧路径共用）
    let candidate_variable = lookup_candidate_variable(new_book_url, new_source_url)?;

    // P1-2 入口收口（与旧路径共用同一 flow scope 切点）
    crate::api::web_book::begin_book_flow(new_book_url);

    // 命中/未命中分支（上游 getToc L659-682：命中 → 不抓取直接用；
    // 未命中 → 现场抓取）
    let entry = prefetch_cache_get(new_source_url, new_book_url);
    let cached_info = entry.as_ref().and_then(|e| e.info.clone());
    let cached_chapters = entry.map(|e| e.chapters).filter(|c| !c.is_empty());

    // 2a. 详情（命中：缓存 info 直接用（零网络），None 降级现场补抓；
    //     未命中：现场抓取，执行链与旧路径 2a 一致，请求带候选变量表）
    let detail_vars = super::web_book::chapter_url_variables(candidate_variable.as_deref());
    let info = match cached_info {
        Some(info) => info,
        None => {
            ensure_not_cancelled(apply_epoch)?;
            runtime::block_on(async {
                fetcher
                    .get_book_info_with_existing_and_vars(
                        &source,
                        new_book_url,
                        false,
                        &book.name,
                        &book.author,
                        &detail_vars,
                    )
                    .await
            })
            .map_err(|e| {
                LegadoError::Parser(format!(
                    "换源失败：新源「{}」详情页解析失败，已保留原书源与目录: {e}",
                    source.book_source_name
                ))
            })?
        }
    };

    // [T5] 变量合并 + 陈旧 overlay 让位（须在未命中路径的目录抓取前完成：
    //      目录请求变量表 = 候选 ⊕ 详情导出合并值）
    apply_book_variable_merge(
        &mut book,
        candidate_variable.as_deref(),
        info.variable.as_deref(),
        new_book_url,
    );

    // 2b. 目录（命中：预拉缓存目录直接用，零网络；未命中：现场抓取，可取消）。
    // 真实 tocUrl 由共用尾段 commit_source_switch 从 info 统一解析
    // （「空 toc_url → new_book_url」回退与旧路径同一逻辑）
    let web_chapters: Vec<WebChapter> = match cached_chapters {
        Some(chapters) => chapters,
        None => {
            ensure_not_cancelled(apply_epoch)?;
            let toc_url = if info.toc_url.trim().is_empty() {
                new_book_url.to_string()
            } else {
                info.toc_url.clone()
            };
            runtime::block_on(async {
                // 目录请求变量表 = 合并后 book.variable（与旧路径 2b 一致）
                let toc_vars = super::web_book::chapter_url_variables(book.variable.as_deref());
                fetcher
                    .get_chapters_with_vars_and_name_hint(
                        &source,
                        &toc_url,
                        &toc_vars,
                        Some(&info.name),
                    )
                    .await
            })
            .map_err(|e| {
                LegadoError::Parser(format!(
                    "换源失败：新源「{}」目录获取失败，已保留原书源与目录: {e}",
                    source.book_source_name
                ))
            })?
        }
    };

    // 提交前取消兜底：2a/2b 均成功后若已取消 → 不提交（DB 零变更）
    ensure_not_cancelled(apply_epoch)?;

    // 3+4. 空目录守卫 + 单事务提交 + 下一章登记 + 书籍 JSON（共用尾段）
    commit_source_switch(
        &mut book,
        &source,
        book_url,
        new_source_url,
        new_book_url,
        info,
        web_chapters,
    )
}

/// 解析换源场景待搜索的书源列表（留项#12，Task #131/Task #145）
///
/// 复用 [`crate::api::search::load_search_sources`] 过滤语义：
/// 空串/空数组（`[]`）=全部启用源；非空 JSON 数组=仅搜指定 URL 的启用源。
///
/// Task #145：追加按 config `searchGroup` 的原生分组过滤（零 FFI 签名变更，
/// Rust 内部读 config，对齐原版 ChangeBookSourceViewModel L197-206 读取
/// `AppConfig.searchGroup` 后走 `getEnabledPartByGroup` 的行为）。
pub(crate) fn resolve_switch_sources(source_urls_json: &str) -> LegadoResult<Vec<BookSource>> {
    let sources = crate::api::search::load_search_sources(source_urls_json)?;
    Ok(filter_sources_by_search_group(sources))
}

/// config 键：换源搜索分组（键名对齐原版 `AppConfig.searchGroup`，Task #145）
const SEARCH_GROUP_CONFIG_KEY: &str = "searchGroup";

/// 按 config `searchGroup` 过滤候选书源（留项#12，Task #145）
///
/// 对齐原版 `ChangeBookSourceViewModel` L197-206：
/// - `searchGroup` 为空（trim 后）= 不过滤，搜全部启用源；
/// - 非空时仅保留分组字段包含该分组的源（`getEnabledPartByGroup` 语义）。
///   config 读取失败时按空分组处理（不误伤全量搜索）。
fn filter_sources_by_search_group(sources: Vec<BookSource>) -> Vec<BookSource> {
    let group = crate::api::config_api::get_config(SEARCH_GROUP_CONFIG_KEY).unwrap_or_default();
    let target = group.trim();
    if target.is_empty() {
        return sources;
    }
    sources
        .into_iter()
        .filter(|s| source_group_contains(s.book_source_group.as_deref().unwrap_or(""), target))
        .collect()
}

/// 分组包含判定（Task #145，对齐原版 `SOURCE_GROUP_MEMBERSHIP_FILTER` SQL 语义：
/// SearchBookDao.kt L13-32 / BookSourceDao.getEnabledPartByGroup）
///
/// 分组字段为多组列表：`,`/`;`/`，`/`；` 四种分隔符统一规范化为逗号后拆分，
/// 每个组名各自 trim（原版按空白字符集 trim）后与目标分组做**精确相等**匹配，
/// 不做子串匹配（原版递归 CTE 逐组名 `group_name = trim(:sourceGroup)` 判定）。
fn source_group_contains(source_group: &str, target: &str) -> bool {
    let normalized: String = source_group
        .chars()
        .map(|c| match c {
            ';' | '；' | '，' => ',',
            other => other,
        })
        .collect();
    normalized.split(',').any(|name| name.trim() == target)
}

/// 对单个书源执行搜索（用于换源场景）
///
/// Task #16 P1：复用 [`crate::api::search::search_single_source`] 的完整
/// AnalyzeRule 解析链路，确保每个候选的 `book_url` 是真实的书籍**详情页 URL**
/// （而非搜索结果页 URL），使后续 [`switch_book_source`]/refresh_toc 能正确
/// 定位并获取目录。旧实现直接把响应 URL 当作 book_url，导致换源后目录抓取失败。
async fn search_for_switch(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchCandidate>> {
    // 换源候选搜索固定第 1 页（批次B：search_single_source 新增 page 参数，一次性场景传 1）
    let results =
        crate::api::search::search_single_source(client, source, keyword, 1, false).await?;
    let candidates = results
        .into_iter()
        // [审计 D2 | BookList.kt:281-284] 原版对 bookUrl 解析为空的条目回退
        // baseUrl 后照常入列表（不剔除）；解析层（search.rs S0-E）已实现同一
        // 回退，此处不再按空 book_url 过滤——空 URL 候选保留展示，点击切换时
        // 由 switch_book_source 兜底报错。
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
            // [T5] 网络路径：元素级解析导出的搜索期级联变量
            variable: r.variable,
        })
        .collect();
    Ok(candidates)
}

fn config_flag(key: &str) -> bool {
    crate::api::config_api::get_config(key)
        .map(|v| v.trim() == "true")
        .unwrap_or(false)
}

/// 解析换源搜索选项：优先 options_json，缺省回退 config
pub(crate) fn resolve_switch_options(options_json: &str) -> SwitchSearchOptions {
    let trimmed = options_json.trim();
    if !trimmed.is_empty() && trimmed != "null" {
        if let Ok(opts) = serde_json::from_str::<SwitchSearchOptions>(trimmed) {
            return opts;
        }
    }
    SwitchSearchOptions {
        load_info: config_flag("changeSourceLoadInfo"),
        load_toc: config_flag("changeSourceLoadToc"),
        load_word_count: config_flag("changeSourceLoadWordCount"),
        force_refresh: false,
    }
}

/// 按开关加载详情/目录/试读字数（对齐 ChangeBookSourceViewModel.loadBookInfo/Toc/WordCount）
///
/// T6：拆为原生 async 核心 [`enrich_switch_candidates_async`] + 本同步包装——
/// 批量路径（`search_alternative_sources`，同步上下文）保留 block_on 驱动；
/// 流式驱动器在 async 上下文中直接 await 核心，**不得嵌套 block_on**。
fn enrich_switch_candidates(
    sources: &[BookSource],
    candidates: Vec<SearchCandidate>,
    options: &SwitchSearchOptions,
) -> LegadoResult<Vec<SearchCandidate>> {
    runtime::block_on(enrich_switch_candidates_async(
        sources,
        candidates,
        options,
        super::web_book::RealBookSourceFetcher::new,
    ))
}

/// 流内后置增强核心（T6）：原生 async，孤儿（书源不在列表中）直通
///
/// 2026-09-24 重写（加法式，对齐上游 `search()` L317-344 语义）：
/// - **有界并发** [`ENRICH_CONCURRENCY`]=8（上游 threadCount=32 作用于
///   「逐源搜索+增强」整链；我方搜索期已 32 并发，增强期是重型目录抓取的
///   集中突发，取 8 防连接池饱和，见常量文档论证）；
/// - **单候选 60s 超时**（上游逐源 `withTimeout(60000L)`，L334）：超时/
///   异常时候选原样直通（单失败隔离，不阻塞他项，对齐上游逐源 try/catch）；
/// - 索引槽重建原始候选顺序（孤儿在前、其余按原顺序，旧行为不变）；
/// - **命中预拉缓存**：增强结果写入 [`SWITCH_PREFETCH_CACHE`]（键同上游
///   `primaryStr()`），选中源时 [`switch_book_source_prefetch`] 命中免抓取。
///
/// `make_fetcher` 为可注入 fetcher 工厂：生产路径传
/// `|_| RealBookSourceFetcher::new()`；单测注入 Mock 验证并发上限/
/// 失败隔离/顺序恢复（生产行为不变）。
async fn enrich_switch_candidates_async<F, MF>(
    sources: &[BookSource],
    candidates: Vec<SearchCandidate>,
    options: &SwitchSearchOptions,
    make_fetcher: MF,
) -> LegadoResult<Vec<SearchCandidate>>
where
    F: BookSourceFetcher + Send + 'static,
    MF: Fn() -> LegadoResult<F> + Send + Sync + 'static,
{
    let source_map: HashMap<String, BookSource> = sources
        .iter()
        .map(|s| (s.book_source_url.clone(), s.clone()))
        .collect();

    let mut orphans = Vec::new();
    let mut jobs: Vec<(SearchCandidate, BookSource)> = Vec::new();
    for candidate in candidates {
        match source_map.get(&candidate.source_url) {
            Some(source) => jobs.push((candidate, source.clone())),
            None => orphans.push(candidate),
        }
    }

    // 有界并发 + 单候选超时（并发上限/索引槽/孤儿在前序恢复均在
    // run_enrich_jobs 内）
    let job_count = jobs.len();
    let done = run_enrich_jobs(make_fetcher, jobs, options).await;

    let mut filled: Vec<Option<SearchCandidate>> = vec![None; job_count];
    for (idx, c) in done {
        filled[idx] = Some(c);
    }
    let mut out = orphans;
    out.extend(filled.into_iter().flatten());
    Ok(out)
}

/// 有界并发增强执行器（泛型工厂：单候选超时/索引槽/并发上限集中于此）。
///
/// 生产路径注入 [`super::web_book::RealBookSourceFetcher`]；单测注入 Mock
/// 验证并发上限（[`ENRICH_CONCURRENCY`]）与失败隔离。每个任务独立构造
/// fetcher（构建失败 → 该候选原样直通，不阻塞他项）。
async fn run_enrich_jobs<F, MF>(
    make_fetcher: MF,
    jobs: Vec<(SearchCandidate, BookSource)>,
    options: &SwitchSearchOptions,
) -> Vec<(usize, SearchCandidate)>
where
    F: BookSourceFetcher + Send + 'static,
    MF: Fn() -> LegadoResult<F> + Send + Sync + 'static,
{
    let mf = &make_fetcher;
    stream::iter(jobs.into_iter().enumerate())
        .map(|(idx, (candidate, source))| {
            let opts = options.clone();
            async move {
                let fetcher = match mf() {
                    Ok(fetcher) => fetcher,
                    Err(_) => return (idx, candidate),
                };
                let out = enrich_item_with_timeout(
                    &fetcher,
                    &source,
                    candidate,
                    &opts,
                    crate::api::search::SWITCH_SOURCE_TIMEOUT,
                )
                .await;
                (idx, out)
            }
        })
        .buffer_unordered(ENRICH_CONCURRENCY)
        .collect()
        .await
}

/// 单候选 60s 超时（上游逐源 `withTimeout(60000L)`）：超时/异常时候选
/// 原样直通——单失败隔离，不阻塞其他候选（对齐上游逐源 try/catch 语义）。
async fn enrich_item_with_timeout(
    fetcher: &impl BookSourceFetcher,
    source: &BookSource,
    candidate: SearchCandidate,
    options: &SwitchSearchOptions,
    timeout: std::time::Duration,
) -> SearchCandidate {
    match tokio::time::timeout(
        timeout,
        enrich_one_switch_candidate_with(fetcher, source, candidate.clone(), options),
    )
    .await
    {
        Ok(enriched) => enriched,
        Err(_) => {
            log::warn!(
                "换源预拉超时（{}s）候选={} 源={}：候选原样保留（单失败隔离不阻塞他项）",
                timeout.as_secs(),
                candidate.book_url,
                source.book_source_url
            );
            candidate
        }
    }
}

/// 单候选增强（fetcher 注入便于 Mock 验证；fetch 细节见函数体注释）。
///
/// 旧版构造 `RealBookSourceFetcher` 直用并调 inherent 方法
/// `get_chapters_with_hints`（空变量表薄委托）；本版本用 trait 6 参
/// [`BookSourceFetcher::get_chapters_with_hints_and_vars`] + 空变量表——
/// 生产语义等价（RealBookSourceFetcher 的 4 参方法即委托到此 + 空表），
/// 且可 Mock。详情抓取从 `build_engine().get_book_info`（canReName 默认
/// true + 空变量表）改为 apply 对齐的
/// [`BookSourceFetcher::get_book_info_with_existing_and_vars`]（canReName=false
/// + 候选搜索期变量表）：缓存详情 ≡ apply 时详情，选中命中后字段更新/
///   变量合并与旧 apply 路径逐项一致。
async fn enrich_one_switch_candidate_with(
    fetcher: &impl BookSourceFetcher,
    source: &BookSource,
    mut candidate: SearchCandidate,
    options: &SwitchSearchOptions,
) -> SearchCandidate {
    candidate.origin_order = source.custom_order;
    if !(options.load_info || options.load_toc || options.load_word_count) {
        return candidate;
    }

    let book_url = candidate.book_url.clone();
    let mut toc_url = String::new();
    let mut prefetched_info: Option<WebBookInfo> = None;
    // [R1] 详情请求带候选搜索期变量表（与 apply 2a 同一展开口径：原版
    // getBookInfoAwait 的 AnalyzeUrl 以 ruleData=book 构建，WebBook.kt:225-231）
    let detail_vars = super::web_book::chapter_url_variables(candidate.variable.as_deref());

    if options.load_info {
        if let Ok(info) = fetcher
            .get_book_info_with_existing_and_vars(
                source,
                &book_url,
                false,
                &candidate.book_name,
                &candidate.author,
                &detail_vars,
            )
            .await
        {
            if candidate
                .latest_chapter
                .as_ref()
                .is_none_or(|s| s.is_empty())
            {
                candidate.latest_chapter = info.last_chapter.clone();
            }
            if candidate.word_count.as_ref().is_none_or(|s| s.is_empty()) {
                candidate.word_count = info.word_count.clone();
            }
            toc_url = info.toc_url.clone();
            prefetched_info = Some(info.clone());
            // 上游 bookMap 恒写语义（loadBookInfo 成功后必写）：即使目录未
            // 拉取也先写「详情-only」条目，apply 命中可降级「缓存详情 +
            // 现场目录」省一次详情抓取
            prefetch_cache_insert(&source.book_source_url, &book_url, Some(info), Vec::new());
        }
    }

    if options.load_toc || options.load_word_count {
        let toc_opt = if toc_url.trim().is_empty() {
            None
        } else {
            Some(toc_url.as_str())
        };
        match fetcher
            .get_chapters_with_hints_and_vars(
                source,
                &book_url,
                toc_opt,
                Some(&candidate.book_name),
                &HashMap::new(),
            )
            .await
        {
            Ok(chapters) if !chapters.is_empty() => {
                if options.load_word_count {
                    apply_word_count_sample(&mut candidate, source, fetcher, &chapters).await;
                }
                // 上游 loadBookToc L395-415：tocMap[primaryStr()] 写入（章数
                // 上限守卫在缓存内）。完整条目要求携带详情（apply 需要
                // tocUrl 解析 + 字段更新 + 变量合并）：load_info 已抓则复用，
                // 否则补抓一次（与 apply 2a 同一调用形态）
                let cache_info = match prefetched_info.take() {
                    Some(info) => Some(info),
                    None => fetcher
                        .get_book_info_with_existing_and_vars(
                            source,
                            &book_url,
                            false,
                            &candidate.book_name,
                            &candidate.author,
                            &detail_vars,
                        )
                        .await
                        .ok(),
                };
                prefetch_cache_insert(&source.book_source_url, &book_url, cache_info, chapters);
            }
            Ok(_) => {}
            Err(_) => {}
        }
    }

    candidate
}

async fn apply_word_count_sample(
    candidate: &mut SearchCandidate,
    source: &BookSource,
    engine: &impl legado_core::web_book::BookSourceFetcher,
    chapters: &[WebChapter],
) {
    let chapter_index = chapters.len().saturating_sub(1);
    let chapter = &chapters[chapter_index];
    let mut title = chapter.title.trim().to_string();
    if title.chars().count() > 20 {
        title = format!("{}…", title.chars().take(20).collect::<String>());
    }
    let start = std::time::Instant::now();
    let web_ch = WebChapter {
        url: chapter.url.clone(),
        title: chapter.title.clone(),
        index: chapter.index,
        is_vip: chapter.is_vip,
        is_volume: chapter.is_volume,
        variable: chapter.variable.clone(),
        word_count: None,
    };
    let (count, text) = match engine.get_content(source, &web_ch).await {
        Ok(content) => {
            let len = content.chars().count() as i32;
            (
                len,
                format!("[{}] {}\n字数：{}", chapter_index + 1, title, len),
            )
        }
        Err(e) => (
            -1,
            format!("[{}] {}\n获取字数失败：{}", chapter_index + 1, title, e),
        ),
    };
    candidate.chapter_word_count = count;
    candidate.chapter_word_count_text = Some(text);
    candidate.respond_time = start.elapsed().as_millis() as i32;
}

/// 换源网络结果落库（对齐原版 searchSuccess → insert）
fn persist_switch_matches(matches: &[SourceMatch]) {
    if matches.is_empty() || !crate::db_state::is_initialized() {
        return;
    }
    use legado_core::models::SearchBook;
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let books: Vec<SearchBook> = matches
        .iter()
        .map(|m| SearchBook {
            book_url: m.book_url.clone(),
            origin: m.source_url.clone(),
            origin_name: m.source_name.clone(),
            name: m.book_name.clone(),
            author: m.author.clone(),
            word_count: m.word_count.clone(),
            latest_chapter_title: m.latest_chapter.clone(),
            time: now,
            origin_order: m.origin_order,
            chapter_word_count_text: m.chapter_word_count_text.clone(),
            chapter_word_count: m.chapter_word_count,
            respond_time: m.respond_time,
            book_score: m.book_score,
            // [R1 修复 2026-09-06] 落库必须带候选搜索期变量：switch_book_source
            // 按 (new_book_url, origin) 回查 searchBooks 取候选变量（对齐原版
            // SearchBook.toBook() 复制 variable），此前 `..default()` 丢字段导致
            // 网络路径与读库路径的候选变量双双丢失，变量依赖源换源后目录/正文
            // 请求打错地址（内容错书的链路根因）
            variable: m.variable.clone(),
            ..SearchBook::default()
        })
        .collect();
    let _ = crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        let _ = repo.insert_all(&books);
        Ok(())
    });
}

/// 更新换源列表项用户评分（-1/0/1）
///
/// 对齐原版 `SourceConfig.setBookScore`：持久化书维度评分并同步书源聚合分。
pub fn update_search_book_score(book_url: &str, score: i32) -> LegadoResult<()> {
    let book_url = book_url.trim();
    if book_url.is_empty() {
        return Err(LegadoError::Database("bookUrl 不能为空".into()));
    }
    if !(-1..=1).contains(&score) {
        return Err(LegadoError::Database("评分仅允许 -1/0/1".into()));
    }
    if !crate::db_state::is_initialized() {
        return Err(LegadoError::Database("数据库未初始化".into()));
    }
    crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        let pre = repo
            .find_by_book_url(book_url)?
            .map(|b| b.book_score)
            .unwrap_or(0);
        let affected = repo.update_book_score(book_url, score)?;
        if affected == 0 {
            return Err(LegadoError::Database(format!(
                "searchBooks 中不存在 bookUrl={book_url}"
            )));
        }
        if let Some(book) = repo.find_by_book_url(book_url)? {
            sync_source_score_delta(&book.origin, pre, score);
        }
        Ok(())
    })
}

/// 删除换源列表项（按 bookUrl）
pub fn delete_search_book(book_url: &str) -> LegadoResult<()> {
    let book_url = book_url.trim();
    if book_url.is_empty() {
        return Err(LegadoError::Database("bookUrl 不能为空".into()));
    }
    if !crate::db_state::is_initialized() {
        return Err(LegadoError::Database("数据库未初始化".into()));
    }
    crate::db_state::with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        let affected = repo.delete_by_book_url(book_url)?;
        if affected == 0 {
            return Err(LegadoError::Database(format!(
                "searchBooks 中不存在 bookUrl={book_url}"
            )));
        }
        Ok(())
    })
}

/// 同步书源聚合评分（对标 SourceConfig.setBookScore 对 origin 键的增量更新）
fn sync_source_score_delta(origin: &str, pre_score: i32, new_score: i32) {
    let delta = if pre_score != 0 {
        new_score - pre_score
    } else {
        new_score
    };
    if delta == 0 {
        return;
    }
    let cur = crate::api::config_api::get_config(origin)
        .ok()
        .and_then(|v| v.parse::<i32>().ok())
        .unwrap_or(0);
    let _ = crate::api::config_api::set_config(origin, &(cur + delta).to_string());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::source as source_api;

    #[test]
    fn test_source_switch_response_serialize() {
        let resp = SourceSwitchResponse {
            book_name: "斗破苍穹".to_string(),
            author: "天蚕土豆".to_string(),
            matches: Vec::new(),
        };
        let json = serde_json::to_string(&resp).unwrap();
        assert!(json.contains("斗破苍穹"));
        assert!(json.contains("天蚕土豆"));
    }

    /// 留项#12（Task #131）：传 URL 列表时仅搜指定源
    /// Task #145：先清空 searchGroup config，避免分组过滤干扰本用例
    #[test]
    fn test_resolve_switch_sources_url_filter() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");
        crate::api::config_api::set_config("searchGroup", "").expect("清空 searchGroup 失败");

        let all = source_api::list_enabled_sources().expect("列出启用书源失败");
        assert!(!all.is_empty(), "测试夹具应含启用书源");

        // 取首个启用源 URL，仅搜该源
        let target = all[0].book_source_url.clone();
        let urls_json = serde_json::to_string(&vec![target.clone()]).unwrap();
        let filtered = resolve_switch_sources(&urls_json).expect("URL 列表解析失败");
        assert_eq!(filtered.len(), 1, "传 URL 列表应只搜指定源");
        assert_eq!(filtered[0].book_source_url, target);
    }

    /// 留项#12（Task #131）：空参数（空串/空数组）搜全部启用源
    /// Task #145：先清空 searchGroup config，避免分组过滤干扰本用例
    #[test]
    fn test_resolve_switch_sources_empty_means_all() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");
        crate::api::config_api::set_config("searchGroup", "").expect("清空 searchGroup 失败");

        let enabled = source_api::list_enabled_sources().expect("列出启用书源失败");
        let from_empty_str = resolve_switch_sources("").expect("空串解析失败");
        let from_empty_array = resolve_switch_sources("[]").expect("空数组解析失败");
        assert_eq!(from_empty_str.len(), enabled.len(), "空串应搜全部启用源");
        assert_eq!(
            from_empty_array.len(),
            enabled.len(),
            "空数组应搜全部启用源"
        );
    }

    /// Task #145（留项#12）：分组包含判定纯语义单测
    #[test]
    fn test_source_group_contains_membership() {
        // 逗号分隔多组：首/尾/中间组均命中
        assert!(source_group_contains("玄幻,仙侠,都市", "玄幻"));
        assert!(source_group_contains("玄幻,仙侠,都市", "都市"));
        assert!(source_group_contains("玄幻,仙侠,都市", "仙侠"));
        // 组名两侧空白（含全角空格）trim 后命中
        assert!(source_group_contains("玄幻, 仙侠", "仙侠"));
        assert!(source_group_contains("玄幻,\u{3000}仙侠", "仙侠"));
        // 分隔符规范化：`;`/`；`/`，` 等同逗号
        assert!(source_group_contains("玄幻;仙侠；都市，科幻", "科幻"));
        // 精确匹配：不做子串匹配（原版逐组名相等判定）
        assert!(!source_group_contains("玄幻仙侠", "玄幻"));
        assert!(!source_group_contains("玄幻", "幻"));
        // 空分组字段不命中任何目标
        assert!(!source_group_contains("", "玄幻"));
        assert!(!source_group_contains("  ,  ", "玄幻"));
    }

    #[test]
    fn test_resolve_switch_options_from_json_and_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = r#"{"loadInfo":true,"loadToc":false,"loadWordCount":true}"#;
        let opts = resolve_switch_options(json);
        assert!(opts.load_info);
        assert!(!opts.load_toc);
        assert!(opts.load_word_count);

        crate::api::config_api::set_config("changeSourceLoadInfo", "false").unwrap();
        crate::api::config_api::set_config("changeSourceLoadToc", "true").unwrap();
        crate::api::config_api::set_config("changeSourceLoadWordCount", "false").unwrap();
        let from_config = resolve_switch_options("");
        assert!(!from_config.load_info);
        assert!(from_config.load_toc);
        assert!(!from_config.load_word_count);
    }

    /// Task #145（留项#12）：多组包含匹配——分组字段含多组的源按目标组命中
    #[test]
    fn test_resolve_switch_sources_group_membership() {
        use crate::db_state::with_database;
        use legado_db::repository::Repository;
        use legado_db::BookSourceRepository;

        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");

        // 给首个启用源打上多组标记（逗号分隔，第二个组名为目标组）
        let all = source_api::list_enabled_sources().expect("列出启用书源失败");
        assert!(!all.is_empty(), "测试夹具应含启用书源");
        let target_url = all[0].book_source_url.clone();
        with_database(|db| {
            let repo = BookSourceRepository::new(db.connection());
            let mut src = repo
                .find_by_url(&target_url)?
                .ok_or_else(|| legado_core::LegadoError::Database("测试源不存在".into()))?;
            src.book_source_group = Some("Task145组A, Task145组B".to_string());
            repo.update(&src)
        })
        .expect("更新测试源分组失败");

        // searchGroup 指向第二个组（含前导空格组名，验证 trim 匹配）
        crate::api::config_api::set_config("searchGroup", "Task145组B")
            .expect("设置 searchGroup 失败");
        let filtered = resolve_switch_sources("").expect("分组过滤解析失败");
        assert_eq!(filtered.len(), 1, "应仅保留含目标分组的源");
        assert_eq!(filtered[0].book_source_url, target_url);

        // 收尾：清空分组 config，避免污染后续共享库用例
        crate::api::config_api::set_config("searchGroup", "").expect("清空 searchGroup 失败");
    }

    /// Task #145（留项#12）：空分组 config（空串/纯空白）= 全部启用源
    #[test]
    fn test_resolve_switch_sources_blank_group_means_all() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");

        let enabled = source_api::list_enabled_sources().expect("列出启用书源失败");
        crate::api::config_api::set_config("searchGroup", "   ").expect("设置 searchGroup 失败");
        let filtered = resolve_switch_sources("[]").expect("分组过滤解析失败");
        assert_eq!(filtered.len(), enabled.len(), "纯空白分组应等同全部分组");
        crate::api::config_api::set_config("searchGroup", "").expect("清空 searchGroup 失败");
    }

    /// Task #145（留项#12）：过滤后零结果——目标分组无任何源时返回空列表
    /// （UI 侧据此弹「分组搜索结果为空，是否切换到全部分组」对话框）
    #[test]
    fn test_resolve_switch_sources_group_no_match() {
        let _db_guard = crate::db_state::ensure_test_db();
        let json = std::fs::read_to_string("tests/fixtures/yckceo_7631.json")
            .expect("读取 yckceo_7631.json 失败");
        crate::api::source::import_sources(&json).expect("导入书源失败");

        crate::api::config_api::set_config("searchGroup", "Task145不存在的分组")
            .expect("设置 searchGroup 失败");
        let filtered = resolve_switch_sources("").expect("分组过滤解析失败");
        assert!(filtered.is_empty(), "目标分组无源时应返回空列表");
        crate::api::config_api::set_config("searchGroup", "").expect("清空 searchGroup 失败");
    }

    /// Task #16 P0：换源保持 bookUrl 稳定——不产生僵尸记录且旧章节/旧缓存被清理
    ///
    /// `switch_book_source` 的网络抓取部分（get_chapters）需真实网络，见下方
    /// `#[ignore]` 集成测试；本用例在 DB 层确定性验证修复后的契约：
    /// 仅更新书源字段且 **bookUrl 保持不变** 时 `BookRepository::update` 命中原行
    /// （不会因 WHERE 落空而 insert 出新 new_book_url 僵尸行），且旧章节与旧缓存
    /// 可经 `delete_by_book_url`/`delete_by_book` 清理干净。
    #[test]
    fn test_switch_keeps_book_url_stable_no_zombie() {
        use crate::db_state::with_database;
        use legado_core::cache_book::CachedChapter;
        use legado_core::models::{Book, BookChapter};
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, CacheBookRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://task16-old-src.example.com/book/1";
        let new_url = "https://task16-new-src.example.com/book/1";

        // 初始数据：旧源书籍 + 旧章节 + 旧缓存正文
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let book = Book {
                book_url: old_url.to_string(),
                origin: "https://task16-old-src.example.com".to_string(),
                origin_name: "旧源".to_string(),
                ..Book::default()
            };
            repo.insert(&book)?;

            let chapter_repo = BookChapterRepository::new(db.connection());
            chapter_repo.insert_batch(&[BookChapter {
                url: format!("{old_url}/ch0"),
                title: "旧章节".to_string(),
                base_url: old_url.to_string(),
                book_url: old_url.to_string(),
                index: 0,
                ..BookChapter::default()
            }])?;

            let cache_repo = CacheBookRepository::new(db.connection());
            cache_repo.insert(&CachedChapter {
                id: 0,
                book_url: old_url.to_string(),
                chapter_index: 0,
                chapter_title: "旧章节".to_string(),
                chapter_url: format!("{old_url}/ch0"),
                content: "旧源正文".to_string(),
                cached_at: 1,
                size_bytes: 9,
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 复现 switch_book_source 的 DB 部分：仅改书源字段，bookUrl 保持稳定，然后清旧章节+缓存
        // [B-7] 与换源事务同款：删旧章节须包事务（delete_by_book_url 事务外为 no-op）
        with_database(|db| {
            let conn = db.connection();
            let tx = conn.unchecked_transaction().map_err(|e| {
                legado_core::LegadoError::Database(format!("开启换源测试事务失败: {e}"))
            })?;
            let repo = BookRepository::new(conn);
            let mut book = repo.find_by_url(old_url)?.expect("书籍应存在");
            book.origin = "https://task16-new-src.example.com".to_string();
            book.origin_name = "新源".to_string();
            book.toc_url = new_url.to_string();
            repo.update(&book)?; // WHERE bookUrl=old_url 命中原行

            let cache_repo = CacheBookRepository::new(conn);
            cache_repo.delete_by_book(old_url)?;
            let chapter_repo = BookChapterRepository::new(conn);
            chapter_repo.delete_by_book_url(old_url)?;
            tx.commit().map_err(|e| {
                legado_core::LegadoError::Database(format!("提交换源测试事务失败: {e}"))
            })?;
            Ok(())
        })
        .expect("换源 DB 更新失败");

        // 断言：原 bookUrl 仍在且已换源；无 new_url 僵尸记录；旧章节/旧缓存已清
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let updated = repo.find_by_url(old_url)?.expect("原 bookUrl 记录应仍存在");
            assert_eq!(updated.origin, "https://task16-new-src.example.com");
            assert_eq!(updated.origin_name, "新源");
            assert_eq!(updated.toc_url, new_url);
            assert!(
                repo.find_by_url(new_url)?.is_none(),
                "不应出现 new_book_url 僵尸记录"
            );

            let chapter_repo = BookChapterRepository::new(db.connection());
            assert_eq!(
                chapter_repo.count_by_book_url(old_url)?,
                0,
                "旧章节应被清理"
            );
            let cache_repo = CacheBookRepository::new(db.connection());
            assert!(
                cache_repo.get_by_book(old_url)?.is_empty(),
                "旧缓存正文应被清理"
            );
            Ok(())
        })
        .expect("断言查询失败");

        // 收尾：删除本用例书籍，避免污染共享测试库
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.delete(old_url)
        })
        .ok();
    }

    // ─── [T2 | ChangeBookSourceViewModel.kt:718-731] 换源执行链 mock 单测 ─────

    /// 换源链 mock：详情/目录按序注入，记录 get_chapters 实际收到的 URL
    struct SwitchMockFetcher {
        info: LegadoResult<legado_core::web_book::WebBookInfo>,
        chapters: LegadoResult<Vec<WebChapter>>,
        /// 记录每次 get_chapters 调用的 book_url 入参
        chapters_requested: std::sync::Mutex<Vec<String>>,
        /// [R1 变量链] 记录每次详情请求收到的变量表
        detail_vars_requested: std::sync::Mutex<Vec<std::collections::HashMap<String, String>>>,
        /// [R1 变量链] 记录每次目录请求收到的变量表
        toc_vars_requested: std::sync::Mutex<Vec<std::collections::HashMap<String, String>>>,
    }

    impl BookSourceFetcher for SwitchMockFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            self.get_book_info_with_existing(_source, _book_url, true, "", "")
                .await
        }

        async fn get_book_info_with_existing(
            &self,
            _source: &BookSource,
            _book_url: &str,
            can_re_name: bool,
            existing_name: &str,
            existing_author: &str,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            // 模拟 Real fetcher parse 的 B2.1 重命名门控：can_re_name=false 且
            // 既有值非空时保留既有书名/作者
            match &self.info {
                Ok(info) => {
                    let mut info = info.clone();
                    if !can_re_name && !existing_name.is_empty() {
                        info.name = existing_name.to_string();
                    }
                    if !can_re_name && !existing_author.is_empty() {
                        info.author = existing_author.to_string();
                    }
                    Ok(info)
                }
                Err(e) => Err(LegadoError::Internal(e.to_string())),
            }
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.chapters_requested
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(book_url.to_string());
            match &self.chapters {
                Ok(list) => Ok(list.clone()),
                Err(e) => Err(LegadoError::Internal(e.to_string())),
            }
        }

        /// [R1 变量链] 记录详情请求变量表后委托既有门控行为
        async fn get_book_info_with_existing_and_vars(
            &self,
            source: &BookSource,
            book_url: &str,
            can_re_name: bool,
            existing_name: &str,
            existing_author: &str,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            self.detail_vars_requested
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            self.get_book_info_with_existing(
                source,
                book_url,
                can_re_name,
                existing_name,
                existing_author,
            )
            .await
        }

        /// [R1 变量链] 记录目录请求变量表后委托既有行为
        async fn get_chapters_with_vars(
            &self,
            source: &BookSource,
            toc_url: &str,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.toc_vars_requested
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            self.get_chapters(source, toc_url).await
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// T2 主路径：详情解析出的 tocUrl（目录页≠详情页）用于取目录并落库；
    /// 书名/作者保留既有值（canReName=false）；章节 variable/is_volume 保留解析值
    #[test]
    fn test_switch_uses_parsed_toc_url_and_preserves_parsed_values() {
        // 调 switch_book_source_with（换源执行链内含 begin_book_flow 切
        // flow scope，JS 解析可写全局表）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_core::web_book::WebBookInfo;
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://t2-old.example.com/book/1";
        let new_source = "https://t2-new.example.com";
        let new_detail = "https://t2-new.example.com/book/1";
        let new_toc = "https://t2-new.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://t2-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "旧源书名".to_string(),
                author: "旧作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            // [T5] 搜索期候选行（searchBooks），携带搜索期级联变量
            legado_db::SearchBookRepository::new(db.connection()).insert(
                &legado_core::models::SearchBook {
                    book_url: new_detail.to_string(),
                    origin: new_source.to_string(),
                    origin_name: "新源".to_string(),
                    name: "旧源书名".to_string(),
                    toc_url: new_detail.to_string(),
                    variable: Some(r#"{"token":"c456","sid":"s1"}"#.to_string()),
                    ..Default::default()
                },
            )?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let mock = SwitchMockFetcher {
            info: Ok(WebBookInfo {
                name: "新源解析名".to_string(),
                author: "新源解析作者".to_string(),
                cover_url: Some("https://t2-new.example.com/cover.jpg".to_string()),
                intro: Some("新简介".to_string()),
                categories: vec![],
                last_chapter: Some("大结局".to_string()),
                // [T5] 详情页导出变量（@put 级联）：token 覆盖候选值
                variable: Some(r#"{"token":"d123"}"#.to_string()),
                book_url: new_detail.to_string(),
                toc_url: new_toc.to_string(),
                word_count: Some("123456".to_string()),
                kind: Some("玄幻".to_string()),
                book_type: 0,
            }),
            chapters: Ok(vec![WebChapter {
                index: 0,
                title: "第一卷 第一章".to_string(),
                url: format!("{new_toc}/c1"),
                is_vip: false,
                is_volume: true,
                variable: Some(r#"{"token":"abc123"}"#.to_string()),
                word_count: None,
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp =
            switch_book_source_with(&mock, old_url, new_source, new_detail).expect("换源应成功");
        let book: Book = serde_json::from_str(&resp).unwrap();

        // 2a/2b：取目录用的是详情解析出的 toc_url，而非详情页 URL
        assert_eq!(
            mock.chapters_requested.lock().unwrap().as_slice(),
            [new_toc],
            "get_chapters 应收到解析后的目录页 URL"
        );
        assert_eq!(book.toc_url, new_toc, "toc_url 应为解析后目录页");
        // canReName=false：保留既有书名/作者；其余字段按解析值更新
        assert_eq!(book.name, "旧源书名");
        assert_eq!(book.author, "旧作者");
        assert_eq!(book.origin, new_source);
        // [目录派生字段同步] 目录成功后 latestChapterTitle 以目录末章为准
        // （对齐上游：详情写在目录写之前，目录写胜出——详情「大结局」被覆盖）；
        // totalChapterNum = 落库章节数
        assert_eq!(
            book.latest_chapter_title.as_deref(),
            Some("第一卷 第一章"),
            "latestChapterTitle 应为目录末章标题（覆盖详情 lastChapter 值）"
        );
        assert_eq!(book.total_chapter_num, 1, "totalChapterNum 应为落库章节数");
        // [T5] book.variable = 候选变量 ⊕ 详情导出变量（详情页后写入者优先），
        // 旧源旧值不再残留（R1）
        let book_var: serde_json::Value =
            serde_json::from_str(book.variable.as_deref().expect("book.variable 应有值")).unwrap();
        assert_eq!(book_var["token"], serde_json::json!("d123"));
        assert_eq!(book_var["sid"], serde_json::json!("s1"));
        // [R1 变量链 2026-09-06] 详情请求变量表=候选搜索期变量（对齐原版
        // getBookInfoAwait ruleData=book）；目录请求变量表=候选⊕详情导出合并值
        assert_eq!(
            mock.detail_vars_requested.lock().unwrap().as_slice(),
            [std::collections::HashMap::from([
                ("token".to_string(), "c456".to_string()),
                ("sid".to_string(), "s1".to_string()),
            ])],
            "详情请求应携带候选搜索期变量"
        );
        assert_eq!(
            mock.toc_vars_requested.lock().unwrap().as_slice(),
            [std::collections::HashMap::from([
                ("token".to_string(), "d123".to_string()),
                ("sid".to_string(), "s1".to_string()),
            ])],
            "目录请求应携带候选⊕详情导出合并变量（详情页优先）"
        );

        // T1：章节 variable/is_volume 保留解析值
        with_database(|db| {
            let repo = BookChapterRepository::new(db.connection());
            let chapters = repo.find_by_book_url(old_url).expect("章节查询失败");
            assert_eq!(chapters.len(), 1);
            assert_eq!(
                chapters[0].variable.as_deref(),
                Some(r#"{"token":"abc123"}"#)
            );
            assert!(chapters[0].is_volume, "卷章标记应保留解析值");
            Ok(())
        })
        .expect("章节断言失败");

        // 收尾清理
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            let _ = legado_db::SearchBookRepository::new(db.connection())
                .delete_by_book_url(new_detail);
            Ok(())
        })
        .ok();
    }

    /// [目录派生字段同步] 换源（现场抓取通道）后 totalChapterNum/latestChapterTitle
    /// 必须按**新目录**同步：播种陈旧派生字段（999 章/「旧源最新章节」），新目录
    /// 5 章（末章「第4章」）→ 提交后两字段 == 新目录值（返回 JSON + DB 双断言），
    /// 且与同事务落库的 bookChapters 行数一致（DB 内部一致性）。
    /// 红态（修复前）：commit_source_switch 从 total_chapter_num 取值，全行
    /// `update` 把抓取前快照的旧值原样写回（999/「旧源最新章节」）；
    /// latestChapterTitle 只取详情 lastChapter（B-13），目录末章被忽略。
    /// 语义对齐上游 updateBookTocInfo：目录成功后 total=目录章数、
    /// latest=目录末章标题（详情值被目录写覆盖——上游目录写在详情写之后）。
    #[test]
    fn test_source_switch_syncs_toc_derived_fields() {
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_core::web_book::WebBookInfo;
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://sw-sync-old.example.com/book/1";
        let new_source = "https://sw-sync-new.example.com";
        let new_detail = "https://sw-sync-new.example.com/book/1";
        let new_toc = "https://sw-sync-new.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://sw-sync-old-src.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                // 红态播种：陈旧的目录派生字段（换源前旧源值）
                total_chapter_num: 999,
                latest_chapter_title: Some("旧源最新章节".to_string()),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 新目录 5 章：第0章..第4章（末章标题 = 第4章）
        let mock = SwitchMockFetcher {
            info: Ok(WebBookInfo {
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                cover_url: None,
                intro: None,
                categories: vec![],
                // 详情 lastChapter 值不得胜出：目录成功后由目录末章覆盖
                // （对齐上游：详情写在目录写之前，目录写胜出）
                last_chapter: Some("详情末章".to_string()),
                variable: None,
                book_url: new_detail.to_string(),
                toc_url: new_toc.to_string(),
                word_count: None,
                kind: None,
                book_type: 0,
            }),
            chapters: Ok(test_web_chapters(5, new_toc)),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp =
            switch_book_source_with(&mock, old_url, new_source, new_detail).expect("换源应成功");
        let book: Book = serde_json::from_str(&resp).unwrap();

        assert_eq!(
            book.total_chapter_num, 5,
            "totalChapterNum 应为新目录章数（不得写回抓取前快照旧值 999）"
        );
        assert_eq!(
            book.latest_chapter_title.as_deref(),
            Some("第4章"),
            "latestChapterTitle 应为新目录末章标题（覆盖详情值/旧值）"
        );

        // DB 终态：派生字段与目录行数同事务一致
        with_database(|db| {
            let persisted = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                persisted.total_chapter_num, 5,
                "DB totalChapterNum 应为新目录章数"
            );
            assert_eq!(
                persisted.latest_chapter_title.as_deref(),
                Some("第4章"),
                "DB latestChapterTitle 应为新目录末章标题"
            );
            let chapters = BookChapterRepository::new(db.connection()).find_by_book_url(old_url)?;
            assert_eq!(
                chapters.len() as i32,
                persisted.total_chapter_num,
                "DB 内部一致性：totalChapterNum == 落库章节数"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// [P2-15 剩项②] `yield_stale_overlay_to_db` 规则矩阵（纯函数，不触 DB）：
    /// - overlay 键域内键 + DB 有同名不同值 → 让位 DB 值；
    /// - DB 值与合并值相等 → 不动（零副作用）；
    /// - DB 无该键 → 原样直通；
    /// - 键在候选搜索行 → 绝不让位（T5 候选优先不变）；
    /// - overlay 键域为空 → 原样直通；
    /// - merged None → None；merged / 输入非法 JSON → 降级直通（不阻断换源）。
    #[test]
    fn test_p215_yield_stale_overlay_to_db_rule_matrix() {
        let overlay = std::collections::HashMap::from([
            ("custom".to_string(), "stale-overlay".to_string()),
            ("page".to_string(), "stale-page".to_string()),
        ]);

        // ① 让位：DB 同名不同值 → 用 DB 值；非 overlay 键不动
        let out = yield_stale_overlay_to_db(
            Some(r#"{"custom":"stale-overlay","detail":"d"}"#),
            Some(r#"{"custom":"db-value"}"#),
            None,
            &overlay,
        )
        .expect("merged 为 JSON 对象应可产出");
        let v: serde_json::Value = serde_json::from_str(&out).expect("输出应为 JSON");
        assert_eq!(
            v["custom"],
            serde_json::json!("db-value"),
            "DB 持久权威值应覆盖陈旧 overlay"
        );
        assert_eq!(v["detail"], serde_json::json!("d"), "非 overlay 键不动");

        // ② DB 值与合并值相等 → 不动（输出与输入语义相等）
        let out = yield_stale_overlay_to_db(
            Some(r#"{"custom":"db-value"}"#),
            Some(r#"{"custom":"db-value"}"#),
            None,
            &overlay,
        )
        .expect("merged 为 JSON 对象应可产出");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&out).unwrap()["custom"],
            serde_json::json!("db-value")
        );

        // ③ DB 无该键 → overlay 值原样保留
        assert_eq!(
            yield_stale_overlay_to_db(
                Some(r#"{"custom":"stale-overlay"}"#),
                Some(r#"{"other":"o"}"#),
                None,
                &overlay,
            ),
            Some(r#"{"custom":"stale-overlay"}"#.to_string()),
            "DB 无同名键 → 不动"
        );

        // ④ 键在候选搜索行 → 绝不让位（即使 DB 值不同）
        let out = yield_stale_overlay_to_db(
            Some(r#"{"custom":"stale-overlay"}"#),
            Some(r#"{"custom":"db-value"}"#),
            Some(r#"{"custom":"cand"}"#),
            &overlay,
        )
        .expect("merged 为 JSON 对象应可产出");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&out).unwrap()["custom"],
            serde_json::json!("stale-overlay"),
            "候选携带键绝不让位（T5 候选优先）"
        );

        // ⑤ overlay 键域为空 → 原样直通
        assert_eq!(
            yield_stale_overlay_to_db(
                Some(r#"{"custom":"stale-overlay"}"#),
                Some(r#"{"custom":"db-value"}"#),
                None,
                &std::collections::HashMap::new(),
            ),
            Some(r#"{"custom":"stale-overlay"}"#.to_string()),
            "空 overlay 键域 → 直通"
        );

        // ⑥ merged None → None
        assert_eq!(
            yield_stale_overlay_to_db(None, Some(r#"{"custom":"db-value"}"#), None, &overlay),
            None,
            "merged None → None"
        );

        // ⑦ merged 非 JSON 对象 → 降级原样返回（不阻断换源）
        assert_eq!(
            yield_stale_overlay_to_db(
                Some("not-json"),
                Some(r#"{"custom":"db-value"}"#),
                None,
                &overlay,
            ),
            Some("not-json".to_string()),
            "非 JSON merged 降级直通"
        );

        // ⑧ DB / 候选非法 JSON → 降级不让位
        assert_eq!(
            yield_stale_overlay_to_db(
                Some(r#"{"custom":"stale-overlay"}"#),
                Some("not-json"),
                Some("not-json"),
                &overlay,
            ),
            Some(r#"{"custom":"stale-overlay"}"#.to_string()),
            "非法 JSON 输入降级为不让位"
        );
    }

    /// [P2-15 剩项②] 换源端到端：本进程 JS 写路径残留 overlay（bookVar 层
    /// 预置 `custom=stale-overlay`，流程级不清——P2-15 剩项① 的 bookVar
    /// 进程级保留语义）+ DB `books.variable` 已有同名不同值（持久权威）
    /// 且候选搜索行未携带该键 → 换源后 `book.variable` 取 DB 值（陈旧
    /// overlay 让位）；DB 非 overlay 键域内的键（`keep`）不并入结果
    /// （让位仅针对 overlay 键域，非通用 DB 合并）。
    ///
    /// 与 web_book 的 flow-scope 相关测试持有同一把
    /// `GLOBAL_STORE_TEST_LOCK`（换源执行链内含 `begin_book_flow` 切
    /// scope，并行清 scope 会互串），串行执行。
    #[test]
    fn test_p215_switch_yields_stale_overlay_to_db_variable() {
        use crate::db_state::{ensure_test_db, with_database};
        use legado_core::models::{Book, BookSource};
        use legado_core::web_book::{WebBookInfo, WebChapter};
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};
        use legado_js::host_api::variable_store;

        let _lock = crate::test_support::lock_global_store();
        let _db_guard = ensure_test_db();
        let old_url = "https://p215-yield.example.com/book/1";
        let new_source = "https://p215-yield.example.com/new";
        let new_detail = "https://p215-yield.example.com/book/1";

        // DB 预置：books.variable 已有 custom（持久权威值：用户编辑/既有落库）
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://p215-yield.example.com/old".to_string(),
                origin_name: "旧源".to_string(),
                name: "让位测试书".to_string(),
                author: "作者".to_string(),
                variable: Some(r#"{"custom":"db-value","keep":"k"}"#.to_string()),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 预置本进程 JS 写路径残留 overlay（bookVar 持久裸层键）
        let overlay_key = variable_store::book_var_key(new_detail, "custom");
        variable_store::set_variable(&overlay_key, "stale-overlay").expect("预置 bookVar overlay");

        // Mock 详情导出：模拟 parse_book_info_from_body 的
        // 「详情 @put 导出 ⊕ overlay」合并结果（custom 来自 overlay 并入）
        let mock = SwitchMockFetcher {
            info: Ok(WebBookInfo {
                name: "让位测试书".to_string(),
                author: "作者".to_string(),
                cover_url: None,
                intro: None,
                categories: vec![],
                last_chapter: None,
                variable: Some(r#"{"detail_key":"d","custom":"stale-overlay"}"#.to_string()),
                book_url: new_detail.to_string(),
                toc_url: new_detail.to_string(),
                word_count: None,
                kind: None,
                book_type: 0,
            }),
            chapters: Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: format!("{new_detail}/c1"),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp =
            switch_book_source_with(&mock, old_url, new_source, new_detail).expect("换源应成功");
        let book: Book = serde_json::from_str(&resp).expect("换源返回应可解析");
        let book_var: serde_json::Value =
            serde_json::from_str(book.variable.as_deref().expect("book.variable 应有值")).unwrap();
        assert_eq!(
            book_var["custom"],
            serde_json::json!("db-value"),
            "陈旧 overlay 应让位给 DB 持久权威值"
        );
        assert_eq!(
            book_var["detail_key"],
            serde_json::json!("d"),
            "详情导出键不动"
        );
        assert!(
            book_var.get("keep").is_none(),
            "DB 非 overlay 键域内的键不并入（让位非通用 DB 合并）"
        );

        // 收尾：清 bookVar 键 + 复位 flow scope（换源链已切至 new_detail）
        let _ = variable_store::remove_variable(&overlay_key);
        variable_store::clear_flow_scope().expect("复位 flow scope");
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// [R1 变量链 2026-09-06] persist_switch_matches 落库必须携带候选搜索期变量：
    /// switch_book_source 按 (new_book_url, origin) 回查 searchBooks 取候选变量
    /// （对齐原版 SearchBook.toBook() 复制 variable），此前 `..SearchBook::default()`
    /// 丢字段导致网络/读库两条路径的候选变量双双丢失。
    #[test]
    fn test_persist_switch_matches_keeps_candidate_variable() {
        use crate::db_state::with_database;
        use legado_core::source_matcher::SourceMatch;

        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://r1-persist.example.com/book/1";
        let origin = "https://r1-persist.example.com";

        // searchBooks.origin 外键引用 book_sources，须先建源
        with_database(|db| {
            use legado_core::models::BookSource;
            use legado_db::repository::Repository;
            legado_db::BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: origin.to_string(),
                book_source_name: "变量源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("建源失败");

        persist_switch_matches(&[SourceMatch {
            source_url: origin.to_string(),
            source_name: "变量源".to_string(),
            book_url: book_url.to_string(),
            book_name: "变量书".to_string(),
            author: "作者".to_string(),
            latest_chapter: None,
            word_count: None,
            score: 100.0,
            chapter_word_count_text: None,
            chapter_word_count: -1,
            respond_time: -1,
            origin_order: 0,
            book_score: 0,
            variable: Some(r#"{"token":"tk-1"}"#.to_string()),
        }]);

        let row = with_database(|db| {
            legado_db::SearchBookRepository::new(db.connection()).find_by_book_url(book_url)
        })
        .expect("查询失败")
        .expect("searchBooks 行应存在");
        assert_eq!(
            row.variable.as_deref(),
            Some(r#"{"token":"tk-1"}"#),
            "落库行必须保留候选搜索期变量"
        );
        assert_eq!(row.origin, origin, "switch 回查需按 origin 匹配候选");

        // 收尾清理，避免污染共享测试库
        with_database(|db| {
            let _ =
                legado_db::SearchBookRepository::new(db.connection()).delete_by_book_url(book_url);
            Ok(())
        })
        .ok();
    }

    /// T2 失败语义：详情解析失败 → 整个换源失败，旧源/旧目录/旧章节原样保留
    #[test]
    fn test_switch_fails_and_keeps_old_source_when_info_fails() {
        // 调 switch_book_source_with（换源执行链内含 begin_book_flow 切
        // flow scope）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://t2f-old.example.com/book/1";
        let new_source = "https://t2f-new.example.com";
        let new_detail = "https://t2f-new.example.com/book/1";

        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://t2f-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "旧源书名".to_string(),
                toc_url: "https://t2f-old.example.com/toc".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let mock = SwitchMockFetcher {
            info: Err(LegadoError::Internal("详情页 403".into())),
            chapters: Ok(vec![WebChapter {
                index: 0,
                title: "不应被使用".to_string(),
                url: "https://t2f-new.example.com/c1".to_string(),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let err = switch_book_source_with(&mock, old_url, new_source, new_detail)
            .expect_err("详情失败应导致换源失败");
        assert!(err.to_string().contains("新源"), "错误应含书源名: {err}");
        assert!(
            mock.chapters_requested.lock().unwrap().is_empty(),
            "详情失败后不得再用 new_book_url 硬闯目录"
        );

        // 旧源/旧目录/旧章节原样保留（单事务未提交）
        with_database(|db| {
            let book = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("书籍应存在");
            assert_eq!(book.origin, "https://t2f-old.example.com");
            assert_eq!(book.toc_url, "https://t2f-old.example.com/toc");
            assert_eq!(
                BookChapterRepository::new(db.connection()).count_by_book_url(old_url)?,
                0
            );
            Ok(())
        })
        .expect("保留旧源断言失败");

        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// [P2-8] 换源根因修复：换源事务必须写入当前书源详情页地址
    /// （originBookUrl = new_book_url），且 bookUrl（稳定主键）保持不变；
    /// 旧书（originBookUrl 为空，存量库）换源同样成功（向后兼容）。
    /// 同时验证「按新字段抓详情」链路：详情解析出的真实 tocUrl 用于取目录。
    #[test]
    fn test_switch_writes_origin_book_url_and_keeps_book_url_stable() {
        // 调 switch_book_source_with（换源执行链内含 begin_book_flow 切
        // flow scope）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_core::web_book::WebBookInfo;
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://p8-old.example.com/book/1";
        let new_source = "https://p8-new.example.com";
        let new_detail = "https://p8-new.example.com/book/9";
        let new_toc = "https://p8-new.example.com/book/9/chapters";

        with_database(|db| {
            // 存量书：originBookUrl 为空（未换源 / 迁移前旧库形态）
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://p8-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "书名".to_string(),
                author: "作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let mock = SwitchMockFetcher {
            info: Ok(WebBookInfo {
                name: "书名".to_string(),
                author: "作者".to_string(),
                cover_url: None,
                intro: None,
                categories: vec![],
                last_chapter: None,
                variable: None,
                book_url: new_detail.to_string(),
                // 目录页≠详情页：详情解析出的真实 tocUrl 必须被采用
                toc_url: new_toc.to_string(),
                word_count: None,
                kind: None,
                book_type: 0,
            }),
            chapters: Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: format!("{new_toc}/c1"),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp = switch_book_source_with(&mock, old_url, new_source, new_detail)
            .expect("存量书（originBookUrl 为空）换源应成功");
        let book: Book = serde_json::from_str(&resp).unwrap();
        assert_eq!(book.book_url, old_url, "bookUrl 必须保持稳定主键不变");
        assert_eq!(
            book.origin_book_url, new_detail,
            "换源后必须写入当前书源详情页地址 originBookUrl"
        );
        // 详情按 new_book_url 抓取并解析出真实 tocUrl，目录抓取用该 tocUrl
        assert_eq!(book.toc_url, new_toc, "tocUrl 应为详情解析出的目录页");
        assert_eq!(
            mock.chapters_requested.lock().unwrap().as_slice(),
            [new_toc],
            "取目录应使用详情解析出的 tocUrl，而非详情页/旧 bookUrl"
        );

        // DB 行持久值与返回值一致
        with_database(|db| {
            let persisted = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("原 bookUrl 记录应仍存在");
            assert_eq!(persisted.book_url, old_url);
            assert_eq!(
                persisted.origin_book_url, new_detail,
                "DB 落库 originBookUrl 必须等于新源详情页地址"
            );
            assert_eq!(persisted.origin, new_source);
            assert!(
                BookRepository::new(db.connection())
                    .find_by_url(new_detail)?
                    .is_none(),
                "不应出现 new_book_url 僵尸记录"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// [P2-8] 回归网：连续两次换源均成功——第二次换源时 DB 行 originBookUrl
    /// 已非空（第一次写入），执行链仍按稳定主键 bookUrl 命中并更新
    /// originBookUrl 为第二源的详情页地址，不产生僵尸记录、不丢章节。
    #[test]
    fn test_two_consecutive_switches_both_succeed() {
        // 连续两次 switch_book_source_with（换源执行链内含 begin_book_flow
        // 切 flow scope）→ 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_core::web_book::WebBookInfo;
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://p8-2x.example.com/book/1";
        let src_a = "https://p8-2x-a.example.com";
        let detail_a = "https://p8-2x-a.example.com/book/7";
        let src_b = "https://p8-2x-b.example.com";
        let detail_b = "https://p8-2x-b.example.com/book/8";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://p8-2x-origin.example.com".to_string(),
                origin_name: "原源".to_string(),
                name: "书名".to_string(),
                author: "作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: src_a.to_string(),
                book_source_name: "源A".to_string(),
                ..BookSource::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: src_b.to_string(),
                book_source_name: "源B".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        fn switch_mock(detail: &str) -> SwitchMockFetcher {
            SwitchMockFetcher {
                info: Ok(WebBookInfo {
                    name: "书名".to_string(),
                    author: "作者".to_string(),
                    cover_url: None,
                    intro: None,
                    categories: vec![],
                    last_chapter: None,
                    variable: None,
                    book_url: detail.to_string(),
                    toc_url: String::new(),
                    word_count: None,
                    kind: None,
                    book_type: 0,
                }),
                chapters: Ok(vec![WebChapter {
                    index: 0,
                    title: "第一章".to_string(),
                    url: format!("{detail}/c1"),
                    is_vip: false,
                    is_volume: false,
                    variable: None,
                    word_count: None,
                }]),
                chapters_requested: std::sync::Mutex::new(Vec::new()),
                detail_vars_requested: std::sync::Mutex::new(Vec::new()),
                toc_vars_requested: std::sync::Mutex::new(Vec::new()),
            }
        }

        // 第一次换源：存量书（originBookUrl 空）→ 源A
        let mock_a = switch_mock(detail_a);
        let r1 =
            switch_book_source_with(&mock_a, old_url, src_a, detail_a).expect("第一次换源应成功");
        let b1: Book = serde_json::from_str(&r1).unwrap();
        assert_eq!(b1.book_url, old_url, "第一次换源 bookUrl 不变");
        assert_eq!(
            b1.origin_book_url, detail_a,
            "第一次换源 originBookUrl=源A 详情页"
        );

        // 第二次换源：DB 行 originBookUrl 已非空（=detail_a），
        // 执行链仍按稳定主键命中，更新为源B 详情页地址
        let mock_b = switch_mock(detail_b);
        let r2 =
            switch_book_source_with(&mock_b, old_url, src_b, detail_b).expect("第二次换源应成功");
        let b2: Book = serde_json::from_str(&r2).unwrap();
        assert_eq!(b2.book_url, old_url, "第二次换源 bookUrl 仍不变");
        assert_eq!(
            b2.origin_book_url, detail_b,
            "第二次换源 originBookUrl 应刷新为源B 详情页地址"
        );

        // DB 终态：单行、originBookUrl=detail_b、源A/B 详情页地址均无僵尸行、
        // 章节挂在稳定主键下
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let final_book = repo.find_by_url(old_url)?.expect("原 bookUrl 记录应仍存在");
            assert_eq!(final_book.origin_book_url, detail_b);
            assert_eq!(final_book.origin, src_b);
            assert!(
                repo.find_by_url(detail_a)?.is_none(),
                "源A 详情页地址不应产生僵尸记录"
            );
            assert!(
                repo.find_by_url(detail_b)?.is_none(),
                "源B 详情页地址不应产生僵尸记录"
            );
            let chapters = BookChapterRepository::new(db.connection()).find_by_book_url(old_url)?;
            assert_eq!(chapters.len(), 1, "第二次换源后章节应挂在稳定主键下");
            assert_eq!(
                chapters[0].book_url, old_url,
                "章节 book_url 必须保持稳定主键"
            );
            Ok(())
        })
        .expect("DB 终态断言失败");

        // 收尾清理
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(src_a);
            let _ = BookSourceRepository::new(db.connection()).delete(src_b);
            Ok(())
        })
        .ok();
    }

    /// [P2-8 P1-1 | 回归固化 2026-09-18] 换源后以**不含 originBookUrl 键**的
    /// Book JSON 调 update_book，DB 内该列不得被清空：`bookshelf::update_book`
    /// 写侧防守（`fill_origin_book_url_if_empty`）必须从库内既有行补齐。
    ///
    /// 触发场景：Dart 侧持有换源前构造的陈旧 Book 内存对象（字段缺失/为空），
    /// 全行 UPDATE 会把缺失键序列化为空串覆盖换源事务写入的详情页地址。
    /// 本测试固化防守行为，防止后续重构把该分支删掉。
    #[test]
    fn test_update_book_missing_origin_book_url_keeps_column() {
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://p1-1-regression.example.com/book/1";
        let source_url = "https://p1-1-regression-src.example.com";
        let origin_detail = "https://p1-1-regression-src.example.com/book/9";

        // 初始：模拟换源事务后的库内状态（originBookUrl 已由换源写入）
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "固化源".to_string(),
                name: "书名".to_string(),
                author: "作者".to_string(),
                origin_book_url: origin_detail.to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "固化源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 完全不含 originBookUrl 键的 Book JSON（Dart 陈旧内存对象形态）
        let book_json = r#"{
            "bookUrl": "https://p1-1-regression.example.com/book/1",
            "name": "书名",
            "author": "作者",
            "type": 0
        }"#;
        crate::api::bookshelf::update_book(book_json).expect("update_book 应成功");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.origin_book_url, origin_detail,
                "入参缺 originBookUrl 时不得清空换源事务写入的列，写侧防守须从库内既有行补齐"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理，避免污染共享测试库
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(book_url);
            let _ = BookSourceRepository::new(db.connection()).delete(source_url);
            Ok(())
        })
        .ok();
    }

    /// Task #16 P0：换源完整链路集成测试（需真实网络，CI 忽略）
    ///
    /// 验证 switch_book_source 返回的 JSON 中 bookUrl 与传入的原 bookUrl 一致（稳定主键）。
    #[test]
    #[ignore = "requires network access"]
    fn test_switch_book_source_keeps_book_url_in_returned_json() {
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://switch-old.example.com/book/1";
        let new_source = "https://switch-new.example.com";
        let new_book_url = "https://switch-new.example.com/book/1";

        with_database(|db| {
            let brepo = BookRepository::new(db.connection());
            brepo.insert(&Book {
                book_url: old_url.to_string(),
                ..Book::default()
            })?;
            let srepo = BookSourceRepository::new(db.connection());
            srepo.insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .unwrap();

        let json = switch_book_source(old_url, new_source, new_book_url).unwrap();
        let decoded: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            decoded["bookUrl"].as_str(),
            Some(old_url),
            "返回 bookUrl 应保持稳定"
        );
    }

    /// Task #21 回归：换源目标详情页 URL 为空时应提前返回可读错误，
    /// 而非把空 URL 传进解析器抛出令人困惑的 "bookUrl不能为空"。
    ///
    /// guard 位于 switch_book_source 最顶部（DB/网络访问之前），故本用例
    /// 无需任何 DB/网络即可确定性验证：空串与纯空白 new_book_url 均被拦截，
    /// 且错误信息可读（不含裸 "bookUrl不能为空"）。
    #[test]
    fn test_switch_book_source_rejects_empty_new_book_url() {
        for empty in ["", "   ", "\t\n"] {
            let err = switch_book_source(
                "https://any-book.example.com/1",
                "https://any-src.example.com",
                empty,
            )
            .expect_err("空 new_book_url 应返回错误");
            let msg = err.to_string();
            assert!(
                msg.contains("详情页 URL 为空"),
                "错误信息应可读地说明详情页 URL 为空，实际: {msg}"
            );
            assert!(
                !msg.contains("bookUrl不能为空"),
                "不应暴露解析器内部的 bookUrl不能为空，实际: {msg}"
            );
        }
    }

    // ─── [2026-09-24 换源预拉缓存] 缓存/取消/增强 单测 ─────────────────────
    //
    // 全部涉及进程级全局态（SWITCH_PREFETCH_CACHE / SWITCH_APPLY_EPOCH /
    // TOC 刷新代数 / JS 全局表 flow scope），统一持 crate 级 test_support
    // 锁串行执行（与 web_book / T2 换源链测试同一把锁，防串表）。

    /// 测试辅助：全字段 WebBookInfo（测试书/测试作者，目录页 = 入参）
    fn test_web_info(toc_url: &str) -> WebBookInfo {
        WebBookInfo {
            name: "测试书".to_string(),
            author: "测试作者".to_string(),
            cover_url: None,
            intro: None,
            categories: vec![],
            last_chapter: Some("大结局".to_string()),
            variable: None,
            book_url: String::new(),
            toc_url: toc_url.to_string(),
            word_count: Some("9999".to_string()),
            kind: None,
            book_type: 0,
        }
    }

    /// 测试辅助：n 章（URL 在 base 下，c0..c(n-1)）
    fn test_web_chapters(n: usize, base: &str) -> Vec<WebChapter> {
        (0..n)
            .map(|i| WebChapter {
                index: i as i32,
                title: format!("第{i}章"),
                url: format!("{base}/c{i}"),
                is_vip: false,
                is_volume: false,
                variable: None,
                word_count: None,
            })
            .collect()
    }

    /// 测试辅助：候选（SearchCandidate 无 Default，13 字段全量构造）
    fn mk_candidate(source_url: &str, book_url: &str, book_name: &str) -> SearchCandidate {
        SearchCandidate {
            source_url: source_url.to_string(),
            source_name: "测试源".to_string(),
            book_url: book_url.to_string(),
            book_name: book_name.to_string(),
            author: "测试作者".to_string(),
            latest_chapter: None,
            word_count: None,
            chapter_word_count_text: None,
            chapter_word_count: -1,
            respond_time: -1,
            origin_order: 0,
            book_score: 0,
            variable: None,
        }
    }

    /// 在途取消 mock：目录抓取时调 [`cancel_switch_apply`]（apply 代数 +1
    /// 并 bump TOC 刷新代数）再返回 Ok —— 验证预拉缓存版 apply 事务前代数
    /// 比对阻断提交（DB 零变更，对齐上游 cancelChangeSource L715-721）
    struct CancelDuringTocFetcher {
        info: WebBookInfo,
        chapters: Vec<WebChapter>,
    }

    impl BookSourceFetcher for CancelDuringTocFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            Ok(self.info.clone())
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            // 本用例核心：目录抓取途中取消（上游 cancelChangeSource）
            cancel_switch_apply();
            Ok(self.chapters.clone())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// 慢目录 mock：get_chapters 睡 300ms 再返回 —— 与
    /// [`enrich_item_with_timeout`]（50ms）配合验证单候选超时 → 原样直通
    /// + 不写缓存（单失败隔离，不阻塞他项）
    struct SlowTocFetcher {
        info: WebBookInfo,
        chapters: Vec<WebChapter>,
    }

    impl BookSourceFetcher for SlowTocFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            Ok(self.info.clone())
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            Ok(self.chapters.clone())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// 并发探针 mock：get_chapters 记录在飞数/最大在飞并睡 100ms ——
    /// 验证 [`ENRICH_CONCURRENCY`] 上限（≤8）且真并行（≥2，非串行）
    #[derive(Clone)]
    struct ConcurrencyProbeFetcher {
        in_flight: std::sync::Arc<std::sync::atomic::AtomicUsize>,
        max_in_flight: std::sync::Arc<std::sync::atomic::AtomicUsize>,
        chapters: Vec<WebChapter>,
    }

    impl BookSourceFetcher for ConcurrencyProbeFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            Ok(WebBookInfo {
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                cover_url: None,
                intro: None,
                categories: vec![],
                last_chapter: None,
                variable: None,
                book_url: String::new(),
                toc_url: String::new(),
                word_count: None,
                kind: None,
                book_type: 0,
            })
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            let now = self.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
            loop {
                let cur = self.max_in_flight.load(Ordering::SeqCst);
                if now <= cur {
                    break;
                }
                match self.max_in_flight.compare_exchange_weak(
                    cur,
                    now,
                    Ordering::SeqCst,
                    Ordering::SeqCst,
                ) {
                    Ok(_) => break,
                    Err(_) => continue,
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            self.in_flight.fetch_sub(1, Ordering::SeqCst);
            Ok(self.chapters.clone())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// 缓存往返 + 键分隔符：两对键直接拼接会同串（"https://a"+"bc.example.com/x"
    /// ≡ "https://ab"+"c.example.com/x"），\0 分隔后不得互相串扰（对齐上游
    /// primaryStr 两键拼接，且修复其边界歧义）
    #[test]
    fn test_prefetch_cache_roundtrip_and_key_separator() {
        let _lock = crate::test_support::lock_global_store();
        prefetch_cache_clear();

        prefetch_cache_insert(
            "https://a",
            "bc.example.com/x",
            Some(test_web_info("https://a/toc-1")),
            test_web_chapters(1, "https://a/b1"),
        );
        prefetch_cache_insert(
            "https://ab",
            "c.example.com/x",
            Some(test_web_info("https://ab/toc-2")),
            test_web_chapters(2, "https://ab/b2"),
        );

        let e1 = prefetch_cache_get("https://a", "bc.example.com/x")
            .expect("键对1 应命中（不得被键对2 串扰）");
        assert_eq!(e1.chapters.len(), 1);
        assert_eq!(
            e1.info.as_ref().expect("info 应随条目缓存").toc_url,
            "https://a/toc-1"
        );

        let e2 = prefetch_cache_get("https://ab", "c.example.com/x").expect("键对2 应命中");
        assert_eq!(e2.chapters.len(), 2);
        assert_eq!(
            e2.info.as_ref().expect("info 应随条目缓存").toc_url,
            "https://ab/toc-2"
        );

        assert!(
            prefetch_cache_get("https://a", "https://a/b1").is_none(),
            "未写入的键不得命中"
        );

        // 清空语义（对齐上游 startSearch 清 tocMap/bookMap，L279-281）
        prefetch_cache_clear();
        assert!(
            prefetch_cache_get("https://a", "bc.example.com/x").is_none(),
            "clear 后不得残留（防选中读到上一会话陈旧目录）"
        );
    }

    /// 总章数上限守卫（对齐上游 tocMapChapterCount < 30000，L399-403）：
    /// 超限写入跳过；被跳过的写入**不推进计数器**（否则后续合法写入被误拒）
    #[test]
    fn test_prefetch_cache_cap_skips_oversized_entry() {
        let _lock = crate::test_support::lock_global_store();
        prefetch_cache_clear();

        // A：25000 章放行（0+25000 ≤ 30000）
        prefetch_cache_insert("cap-src", "cap-a", None, test_web_chapters(25_000, "cap-a"));
        // B：25000+6000=31000 > 30000 → 跳过
        prefetch_cache_insert("cap-src", "cap-b", None, test_web_chapters(6_000, "cap-b"));
        // C：若跳过未推进计数器 → 25000+4000=29000 ≤ 30000 应放行
        prefetch_cache_insert("cap-src", "cap-c", None, test_web_chapters(4_000, "cap-c"));

        assert!(
            prefetch_cache_get("cap-src", "cap-a").is_some(),
            "上限内条目应写入"
        );
        assert!(
            prefetch_cache_get("cap-src", "cap-b").is_none(),
            "超限条目应跳过（仅损失命中收益，不影响候选展示）"
        );
        assert!(
            prefetch_cache_get("cap-src", "cap-c").is_some(),
            "跳过不得推进计数器（否则 C 也会被误拒）"
        );

        prefetch_cache_clear();
    }

    /// cancel_switch_apply：apply 代数 +1（重复取消累加），对齐上游
    /// changeSourceCancelable 语义——取消后新一轮 apply 是全新代数（合法）
    #[test]
    fn test_cancel_switch_apply_bumps_apply_epoch() {
        let _lock = crate::test_support::lock_global_store();
        let before = SWITCH_APPLY_EPOCH.load(Ordering::SeqCst);
        cancel_switch_apply();
        assert_eq!(
            SWITCH_APPLY_EPOCH.load(Ordering::SeqCst),
            before + 1,
            "取消应使 apply 代数 +1"
        );
        cancel_switch_apply();
        assert_eq!(
            SWITCH_APPLY_EPOCH.load(Ordering::SeqCst),
            before + 2,
            "重复取消应累加"
        );
    }

    /// 命中零抓取：缓存有完整条目（info + 非空目录）→ 2a/2b 全跳过
    /// （mock 详情/目录均 Err 仍不影响换源——证明零网络），缓存目录以稳定
    /// bookUrl 落库，字段更新/下一章登记用缓存值
    #[test]
    fn test_prefetch_hit_skips_fetch() {
        // apply 执行链内含 begin_book_flow 切 flow scope + 命中路径最终代数
        // 比对 → 持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://pf-hit.example.com/book/1";
        let old_origin = "https://pf-hit-old.example.com";
        let new_source = "https://pf-hit.example.com/new";
        let new_detail = "https://pf-hit.example.com/book/1";
        let new_toc = "https://pf-hit.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: old_origin.to_string(),
                origin_name: "旧源".to_string(),
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "预拉新源".to_string(),
                custom_order: 7,
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 种子预拉缓存完整条目（info + 2 章目录）
        prefetch_cache_clear();
        prefetch_cache_insert(
            new_source,
            new_detail,
            Some(test_web_info(new_toc)),
            test_web_chapters(2, new_toc),
        );

        // mock 全 Err：全命中路径下三者均不得被调用
        let mock = SwitchMockFetcher {
            info: Err(LegadoError::Internal("全命中不得抓详情".into())),
            chapters: Err(LegadoError::Internal("全命中不得抓目录".into())),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp = switch_book_source_prefetch_with(&mock, old_url, new_source, new_detail)
            .expect("全命中换源应成功");
        let book: Book = serde_json::from_str(&resp).expect("换源返回应可解析");

        // 零网络：三个 mock 记录向量全空
        assert!(
            mock.detail_vars_requested.lock().unwrap().is_empty(),
            "全命中不得发起详情抓取"
        );
        assert!(
            mock.toc_vars_requested.lock().unwrap().is_empty(),
            "全命中不得发起目录抓取"
        );
        assert!(
            mock.chapters_requested.lock().unwrap().is_empty(),
            "全命中不得发起目录抓取"
        );

        // 字段更新来自缓存 info（canReName 门控后：书名/作者保留既有值）
        assert_eq!(book.origin, new_source);
        assert_eq!(book.toc_url, new_toc, "tocUrl 应为缓存详情解析出的目录页");
        assert_eq!(
            book.word_count.as_deref(),
            Some("9999"),
            "字数应用缓存详情值"
        );
        // [目录派生字段同步] 命中路径同样以目录为准：缓存目录 2 章（第0章/第1章）
        // → 末章「第1章」覆盖缓存详情 lastChapter（「大结局」）
        assert_eq!(
            book.latest_chapter_title.as_deref(),
            Some("第1章"),
            "最新章节应用缓存目录末章值（目录写覆盖详情 lastChapter）"
        );
        assert_eq!(
            book.total_chapter_num, 2,
            "totalChapterNum 应为缓存目录章数"
        );

        // DB 终态：目录挂稳定主键、字段落库一致
        with_database(|db| {
            let persisted = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("原 bookUrl 记录应仍存在");
            assert_eq!(persisted.origin, new_source);
            assert_eq!(persisted.toc_url, new_toc);
            let chapters = BookChapterRepository::new(db.connection()).find_by_book_url(old_url)?;
            assert_eq!(chapters.len(), 2, "缓存的 2 章应落库");
            assert_eq!(chapters[0].book_url, old_url, "章节须挂稳定主键");
            Ok(())
        })
        .expect("DB 断言失败");

        // apply 不消费缓存条目（条目留待同会话其他候选/重选）
        assert!(
            prefetch_cache_get(new_source, new_detail).is_some(),
            "apply 不得删除缓存条目"
        );

        // 收尾清理
        prefetch_cache_clear();
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// [目录派生字段同步] 预拉缓存命中通道（零网络）同样同步派生字段：
    /// 缓存目录（3 章，末章「第2章」）为准——mock 全 Err 证明命中路径零抓取，
    /// 缓存 info 的 lastChapter（「大结局」）不得胜出；提交后 total/latest
    /// == 缓存目录值（返回 JSON + DB 双断言）。
    /// 红态（修复前）：同现场抓取通道——全行 update 写回抓取前快照旧值
    /// （999/「旧源最新章节」），latest 取缓存详情值（「大结局」）。
    #[test]
    fn test_source_switch_prefetch_hit_syncs_toc_derived_fields() {
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_core::models::{Book, BookSource};
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://sw-pf-sync.example.com/book/1";
        let new_source = "https://sw-pf-sync.example.com/new";
        let new_detail = "https://sw-pf-sync.example.com/book/1";
        let new_toc = "https://sw-pf-sync.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://sw-pf-sync-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                // 红态播种：陈旧的目录派生字段
                total_chapter_num: 999,
                latest_chapter_title: Some("旧源最新章节".to_string()),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "预拉新源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 缓存种子：3 章目录（第0章..第2章）+ 详情 info（lastChapter=「大结局」）
        prefetch_cache_clear();
        prefetch_cache_insert(
            new_source,
            new_detail,
            Some(test_web_info(new_toc)),
            test_web_chapters(3, new_toc),
        );

        // mock 全 Err：命中路径零网络（详情/目录均不得抓取），目录以缓存值为准
        let mock = SwitchMockFetcher {
            info: Err(LegadoError::Internal("全命中不得抓详情".into())),
            chapters: Err(LegadoError::Internal("全命中不得抓目录".into())),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp = switch_book_source_prefetch_with(&mock, old_url, new_source, new_detail)
            .expect("全命中换源应成功");
        let book: Book = serde_json::from_str(&resp).expect("换源返回应可解析");

        // 零网络 + 派生字段同步
        assert!(
            mock.detail_vars_requested.lock().unwrap().is_empty(),
            "全命中不得发起详情抓取"
        );
        assert!(
            mock.chapters_requested.lock().unwrap().is_empty(),
            "全命中不得发起目录抓取"
        );
        assert_eq!(
            book.total_chapter_num, 3,
            "totalChapterNum 应为缓存目录章数（不得写回旧值 999）"
        );
        assert_eq!(
            book.latest_chapter_title.as_deref(),
            Some("第2章"),
            "latestChapterTitle 应为缓存目录末章标题（覆盖缓存详情 lastChapter 值）"
        );

        // DB 终态：派生字段与目录行数同事务一致
        with_database(|db| {
            let persisted = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                persisted.total_chapter_num, 3,
                "DB totalChapterNum 应为缓存目录章数"
            );
            assert_eq!(
                persisted.latest_chapter_title.as_deref(),
                Some("第2章"),
                "DB latestChapterTitle 应为缓存目录末章标题"
            );
            let chapters = BookChapterRepository::new(db.connection()).find_by_book_url(old_url)?;
            assert_eq!(
                chapters.len() as i32,
                persisted.total_chapter_num,
                "DB 内部一致性：totalChapterNum == 落库章节数"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理
        prefetch_cache_clear();
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// 性能自证（2026-09-24 换源感知等待）：「选中 → 落地」前后对比
    /// （本地假源，非真网络）。同一本书两次测量，规避 books 表
    /// (name, author) 二级唯一索引在双书场景的相互 remap：
    /// - 前（未命中/旧行为）：选中后现场抓 2a 详情 + 2b 目录（真实源为
    ///   K 页目录串行抓取，本 mock 以单抓 300ms 压缩表达，共 ~600ms）
    /// - 后（预拉缓存命中/新行为）：搜索期已预拉 → 选中零网络，仅 DB 事务提交
    ///   命中阶段抓取计数必须为 0（计数断言 + 耗时对比双重证明）。
    ///   数字经 `cargo test -p legado-ffi --lib test_perf -- --nocapture` 输出供报告引用
    #[test]
    fn test_perf_apply_hit_vs_on_spot_miss() {
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://perf-miss.example.com/book/1";
        let source_url = "https://perf-slow.example.com/new";
        let detail_url = "https://perf-slow.example.com/book/1";
        let toc_url = "https://perf-slow.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                origin: "https://perf-miss-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "性能测试书".to_string(),
                author: "性能作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "慢源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        // 慢 mock：详情/目录各睡 300ms（压缩表达真实源的 2a + K 页目录），
        // 抓取计数用于证明命中阶段零网络
        let fetch_calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let slow = PerfSlowFetcher {
            info: test_web_info(toc_url),
            chapters: test_web_chapters(50, toc_url),
            fetch_calls: fetch_calls.clone(),
        };

        // 前（未命中/旧行为）：现场 2a + 2b，~600ms 量级
        prefetch_cache_clear();
        let t0 = std::time::Instant::now();
        switch_book_source_prefetch_with(&slow, book_url, source_url, detail_url)
            .expect("未命中现场抓取换源应成功");
        let miss_ms = t0.elapsed().as_millis();
        assert_eq!(
            fetch_calls.load(Ordering::SeqCst),
            2,
            "未命中阶段应现场抓详情 + 目录各一次"
        );

        // 后（预拉缓存命中/新行为）：模拟搜索期预拉完成 → 缓存种入完整条目
        prefetch_cache_clear();
        prefetch_cache_insert(
            source_url,
            detail_url,
            Some(slow.info.clone()),
            slow.chapters.clone(),
        );
        let calls_before_hit = fetch_calls.load(Ordering::SeqCst);
        let t1 = std::time::Instant::now();
        switch_book_source_prefetch_with(&slow, book_url, source_url, detail_url)
            .expect("命中换源应成功");
        let hit_ms = t1.elapsed().as_millis();
        assert_eq!(
            fetch_calls.load(Ordering::SeqCst),
            calls_before_hit,
            "命中阶段不得发起任何网络抓取"
        );

        println!(
            "perf[apply]: 前(未命中现场抓 2a+2b, 50 章) = {miss_ms} ms; \
             后(预拉缓存命中零网络) = {hit_ms} ms; \
             提速比 = {:.1}x",
            miss_ms as f64 / hit_ms.max(1) as f64
        );
        assert!(
            hit_ms < miss_ms,
            "命中路径不得慢于现场抓取（命中 = 零网络仅 DB 提交）"
        );

        // 收尾清理
        prefetch_cache_clear();
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(book_url);
            let _ = BookSourceRepository::new(db.connection()).delete(source_url);
            Ok(())
        })
        .ok();
    }

    /// 性能自证用慢 mock：详情/目录各睡 300ms 后返回（非真网络），
    /// 每次抓取计 1（命中路径计数必须不增）
    struct PerfSlowFetcher {
        info: WebBookInfo,
        chapters: Vec<WebChapter>,
        fetch_calls: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    impl BookSourceFetcher for PerfSlowFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<WebBookInfo> {
            self.fetch_calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            Ok(self.info.clone())
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.fetch_calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            Ok(self.chapters.clone())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// 未命中现场抓取：缓存无条目 → 2a 详情 + 2b 目录各抓 1 次（执行链与
    /// 旧路径一致），目录用详情解析出的 tocUrl；apply 自身不写缓存
    /// （写缓存职责在增强期，保持 apply 纯读）
    #[test]
    fn test_prefetch_miss_fetches_on_spot() {
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_db::repository::Repository;
        use legado_db::{BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://pf-miss.example.com/book/1";
        let new_source = "https://pf-miss.example.com/new";
        let new_detail = "https://pf-miss.example.com/book/1";
        let new_toc = "https://pf-miss.example.com/book/1/chapters";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: "https://pf-miss-old.example.com".to_string(),
                origin_name: "旧源".to_string(),
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "未命中源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        prefetch_cache_clear();
        let mock = SwitchMockFetcher {
            info: Ok(test_web_info(new_toc)),
            chapters: Ok(test_web_chapters(1, new_toc)),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };

        let resp = switch_book_source_prefetch_with(&mock, old_url, new_source, new_detail)
            .expect("未命中现场抓取换源应成功");
        let book: Book = serde_json::from_str(&resp).expect("换源返回应可解析");

        // 现场抓取：2a 详情 1 次 + 2b 目录 1 次，且目录用解析后的 tocUrl
        assert_eq!(
            mock.detail_vars_requested.lock().unwrap().len(),
            1,
            "未命中应现场抓详情一次"
        );
        assert_eq!(
            mock.toc_vars_requested.lock().unwrap().len(),
            1,
            "未命中应现场抓目录一次"
        );
        assert_eq!(
            mock.chapters_requested.lock().unwrap().as_slice(),
            [new_toc],
            "目录抓取应使用详情解析出的 tocUrl"
        );
        assert_eq!(book.origin, new_source);
        assert_eq!(book.toc_url, new_toc);

        // apply 不写缓存（与增强期职责分离）
        assert!(
            prefetch_cache_get(new_source, new_detail).is_none(),
            "apply 路径不得写预拉缓存"
        );

        // 收尾清理
        prefetch_cache_clear();
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// 在途取消：目录抓取途中 cancel_switch_apply（apply 代数 +1）→ 2a/2b
    /// 成功后提交前代数比对发现取消 → Err「换源已取消」，DB 零变更
    /// （origin/tocUrl/章节全保留原值，对齐上游 cancelChangeSource）
    #[test]
    fn test_cancel_during_apply_blocks_commit() {
        let _lock = crate::test_support::lock_global_store();
        use crate::db_state::with_database;
        use legado_db::repository::Repository;
        use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

        let _db_guard = crate::db_state::ensure_test_db();
        let old_url = "https://pf-cancel.example.com/book/1";
        let old_origin = "https://pf-cancel-old.example.com";
        let old_toc = "https://pf-cancel-old.example.com/toc";
        let new_source = "https://pf-cancel.example.com/new";
        let new_detail = "https://pf-cancel.example.com/book/1";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&Book {
                book_url: old_url.to_string(),
                origin: old_origin.to_string(),
                origin_name: "旧源".to_string(),
                name: "测试书".to_string(),
                author: "测试作者".to_string(),
                toc_url: old_toc.to_string(),
                ..Book::default()
            })?;
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: new_source.to_string(),
                book_source_name: "取消源".to_string(),
                ..BookSource::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        prefetch_cache_clear();
        let mock = CancelDuringTocFetcher {
            info: test_web_info(new_detail),
            chapters: test_web_chapters(1, new_detail),
        };

        let err = switch_book_source_prefetch_with(&mock, old_url, new_source, new_detail)
            .expect_err("在途取消应阻断提交");
        assert!(
            err.to_string().contains("换源已取消"),
            "错误须明确说明换源已取消，实际: {err}"
        );

        // DB 零变更：origin/tocUrl 保持原值，章节未写入
        with_database(|db| {
            let persisted = BookRepository::new(db.connection())
                .find_by_url(old_url)?
                .expect("书籍应存在");
            assert_eq!(persisted.origin, old_origin, "origin 不得被改");
            assert_eq!(persisted.toc_url, old_toc, "tocUrl 不得被改");
            assert_eq!(
                BookChapterRepository::new(db.connection()).count_by_book_url(old_url)?,
                0,
                "章节不得写入"
            );
            Ok(())
        })
        .expect("零变更断言失败");

        // 收尾清理
        prefetch_cache_clear();
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(old_url);
            let _ = BookSourceRepository::new(db.connection()).delete(new_source);
            Ok(())
        })
        .ok();
    }

    /// 增强期缓存写入：loadInfo+loadToc → 候选补 latest_chapter/word_count/
    /// origin_order（源 customOrder），并写完整条目（info + 目录）进预拉缓存
    #[test]
    fn test_enrich_one_switch_candidate_writes_prefetch_cache() {
        let _lock = crate::test_support::lock_global_store();
        let src_url = "https://enr-1.example.com";
        let detail = "https://enr-1.example.com/book/1";
        let new_toc = "https://enr-1.example.com/book/1/chapters";
        let source = BookSource {
            book_source_url: src_url.to_string(),
            book_source_name: "增强源".to_string(),
            custom_order: 7,
            ..BookSource::default()
        };
        let mock = SwitchMockFetcher {
            info: Ok(test_web_info(new_toc)),
            chapters: Ok(test_web_chapters(2, new_toc)),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };
        let options = SwitchSearchOptions {
            load_info: true,
            load_toc: true,
            ..SwitchSearchOptions::default()
        };

        prefetch_cache_clear();
        let candidate = mk_candidate(src_url, detail, "测试书");
        let enriched = runtime::block_on(enrich_one_switch_candidate_with(
            &mock, &source, candidate, &options,
        ));

        assert_eq!(enriched.origin_order, 7, "origin_order 应用源 customOrder");
        assert_eq!(
            enriched.latest_chapter.as_deref(),
            Some("大结局"),
            "latest_chapter 应由详情补全"
        );
        assert_eq!(
            enriched.word_count.as_deref(),
            Some("9999"),
            "word_count 应由详情补全"
        );
        assert_eq!(
            mock.chapters_requested.lock().unwrap().as_slice(),
            [detail],
            "增强期目录抓取以候选 bookUrl 为取址点"
        );

        let entry = prefetch_cache_get(src_url, detail).expect("应写入完整缓存条目");
        assert_eq!(entry.chapters.len(), 2);
        assert_eq!(
            entry
                .info
                .as_ref()
                .expect("详情应随条目缓存（apply 命中零网络的前提）")
                .toc_url,
            new_toc
        );

        prefetch_cache_clear();
    }

    /// 单失败隔离（增强期）：目录抓取失败 → 候选原样直通（不传播错误、
    /// 不阻塞他项）；load_info 成功已写「详情-only」条目（对齐上游
    /// bookMap 恒写：apply 命中可降级省一次详情抓取）
    #[test]
    fn test_enrich_single_failure_passthrough_keeps_info_entry() {
        let _lock = crate::test_support::lock_global_store();
        let src_url = "https://enr-fail.example.com";
        let detail = "https://enr-fail.example.com/book/1";
        let source = BookSource {
            book_source_url: src_url.to_string(),
            book_source_name: "增强源".to_string(),
            custom_order: 3,
            ..BookSource::default()
        };
        let mock = SwitchMockFetcher {
            info: Ok(test_web_info(detail)),
            chapters: Err(LegadoError::Internal("目录解析失败".into())),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
            detail_vars_requested: std::sync::Mutex::new(Vec::new()),
            toc_vars_requested: std::sync::Mutex::new(Vec::new()),
        };
        let options = SwitchSearchOptions {
            load_info: true,
            load_toc: true,
            ..SwitchSearchOptions::default()
        };

        prefetch_cache_clear();
        let candidate = mk_candidate(src_url, detail, "测试书");
        let enriched = runtime::block_on(enrich_one_switch_candidate_with(
            &mock, &source, candidate, &options,
        ));

        // 候选原样直通：字段补全不受目录失败影响，函数不返回错误
        assert_eq!(enriched.origin_order, 3);
        assert_eq!(
            enriched.latest_chapter.as_deref(),
            Some("大结局"),
            "详情成功 → latest_chapter 照常补全"
        );

        // 目录失败 → 不得写完整条目；但 load_info 期的详情-only 条目保留
        let entry = prefetch_cache_get(src_url, detail).expect("应存在详情-only 条目");
        assert!(entry.chapters.is_empty(), "目录失败不得写完整条目");
        assert!(
            entry.info.is_some(),
            "详情应缓存（apply 命中降级：省一次详情抓取）"
        );

        prefetch_cache_clear();
    }

    /// 单候选超时隔离：慢候选（300ms）+ 50ms 超时 → 候选原样直通（字段
    /// 未补全、origin_order 未更新）、不写缓存；在途抓取随超时丢弃
    #[test]
    fn test_enrich_timeout_isolates_slow_candidate() {
        let _lock = crate::test_support::lock_global_store();
        let src_url = "https://enr-slow.example.com";
        let detail = "https://enr-slow.example.com/book/1";
        let source = BookSource {
            book_source_url: src_url.to_string(),
            book_source_name: "慢源".to_string(),
            custom_order: 4,
            ..BookSource::default()
        };
        let mock = SlowTocFetcher {
            info: test_web_info(detail),
            chapters: test_web_chapters(1, detail),
        };
        // 仅 load_toc：慢点集中在目录抓取；load_info 关闭避免详情-only
        // 条目干扰「超时无任何缓存写入」断言
        let options = SwitchSearchOptions {
            load_toc: true,
            ..SwitchSearchOptions::default()
        };

        prefetch_cache_clear();
        let candidate = mk_candidate(src_url, detail, "测试书");
        let out = runtime::block_on(enrich_item_with_timeout(
            &mock,
            &source,
            candidate.clone(),
            &options,
            std::time::Duration::from_millis(50),
        ));

        // 超时 → 原始候选直通：origin_order / latest_chapter 均保持原值
        // （SearchCandidate 未派生 PartialEq，逐字段比对）
        assert_eq!(
            out.origin_order, 0,
            "超时后候选应原样直通（origin_order 不得更新）"
        );
        assert!(
            out.latest_chapter.is_none() && out.word_count.is_none(),
            "超时后字段不得补全"
        );
        assert_eq!(
            (out.book_url.as_str(), out.source_url.as_str()),
            (candidate.book_url.as_str(), candidate.source_url.as_str()),
            "超时输出应与原始候选一致（关键标识字段）"
        );
        assert!(
            prefetch_cache_get(src_url, detail).is_none(),
            "超时候选不得写缓存（在途抓取已丢弃）"
        );

        prefetch_cache_clear();
    }

    /// 有界并发 + 顺序恢复：16 候选 + 2 孤儿候选（源不在列表）→ 孤儿在前
    /// 原样直通、其余 16 个按原顺序返回；目录抓取期最大在飞
    /// ≤ ENRICH_CONCURRENCY（=8）且 ≥2（真并行非串行）；成功候选写缓存
    #[test]
    fn test_enrich_parallel_bounded_and_order_preserved() {
        let _lock = crate::test_support::lock_global_store();
        const N: usize = 16;
        let sources: Vec<BookSource> = (0..N)
            .map(|i| BookSource {
                book_source_url: format!("https://par-{i}.example.com"),
                book_source_name: format!("源{i}"),
                custom_order: (i + 1) as i32,
                ..BookSource::default()
            })
            .collect();
        let mut candidates: Vec<SearchCandidate> = (0..N)
            .map(|i| {
                mk_candidate(
                    &format!("https://par-{i}.example.com"),
                    &format!("https://par-{i}.example.com/book/{i}"),
                    "测试书",
                )
            })
            .collect();
        // 孤儿候选：源不在 sources 列表 → 须原样直通且排最前
        candidates.insert(
            0,
            mk_candidate(
                "https://ghost-1.example.com",
                "https://ghost-1.example.com/book/9",
                "孤1",
            ),
        );
        candidates.push(mk_candidate(
            "https://ghost-2.example.com",
            "https://ghost-2.example.com/book/9",
            "孤2",
        ));

        let probe = ConcurrencyProbeFetcher {
            in_flight: std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            max_in_flight: std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            chapters: test_web_chapters(1, "probe"),
        };
        let probe_max = probe.max_in_flight.clone();
        let options = SwitchSearchOptions {
            load_toc: true,
            ..SwitchSearchOptions::default()
        };

        prefetch_cache_clear();
        let out = runtime::block_on(enrich_switch_candidates_async(
            &sources,
            candidates.clone(),
            &options,
            move || Ok::<_, LegadoError>(probe.clone()),
        ))
        .expect("增强应成功");

        // 顺序恢复：孤儿在前（原顺序），其后 16 job 按原候选顺序
        assert_eq!(out.len(), N + 2);
        assert_eq!(
            out[0].book_url, "https://ghost-1.example.com/book/9",
            "孤儿1 应排最前"
        );
        assert_eq!(out[0].origin_order, 0, "孤儿候选应原样直通（源不在列表）");
        assert_eq!(
            out[1].book_url, "https://ghost-2.example.com/book/9",
            "孤儿2 应紧随其后"
        );
        for (j, i) in (0..N).enumerate() {
            let expected = format!("https://par-{i}.example.com/book/{i}");
            assert_eq!(
                out[2 + j].book_url,
                expected,
                "job 顺序应与原始候选顺序一致"
            );
            assert_eq!(
                out[2 + j].origin_order,
                (i + 1) as i32,
                "origin_order 应用源 customOrder"
            );
        }

        // 有界并发：最大在飞 ≤ 上限且真并行
        let max = probe_max.load(Ordering::SeqCst);
        assert!(
            max <= ENRICH_CONCURRENCY,
            "在飞数不得超 ENRICH_CONCURRENCY 上限（实际 {max}）"
        );
        assert!(max >= 2, "应真并行执行（最大在飞 {max}，疑似串行）");

        // 成功候选应写预拉缓存（load_toc 成功 → 完整条目：补抓详情 + 1 章目录）
        assert!(
            prefetch_cache_get(
                "https://par-0.example.com",
                "https://par-0.example.com/book/0"
            )
            .is_some(),
            "成功候选应写预拉缓存"
        );

        prefetch_cache_clear();
    }
}
