//! 换源 API
//!
//! 提供搜索可替换书源和切换书籍来源的功能。
//! 复用 legado-net 的 HTTP 客户端和 legado-core 的 SourceMatcher 评分逻辑。

use serde::{Deserialize, Serialize};

use futures::stream::{self, StreamExt};

use legado_core::models::{BookChapter, BookSource};
use legado_core::source_matcher::{SearchCandidate, SourceMatch, SourceMatcher};
use legado_core::web_book::{BookSourceFetcher, WebChapter};
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

/// 换源核心（fetcher 注入，便于单测以 Mock 验证 T2 执行链）
///
/// [T2 | ChangeBookSourceViewModel.kt:718-731 getToc] 对齐原版换源执行链：
/// **先 `getBookInfoAwait`（canReName=false，保留既有书名/作者）解析真实
/// tocUrl（ruleBookInfo.tocUrl 的目录页可与详情页不同），再用它取目录**；
/// 详情或目录任一步失败 → 整个换源失败返回可读错误（含书源名），单事务
/// 未提交即保留旧源。禁止拿 new_book_url 硬闯目录。
fn switch_book_source_with<F: BookSourceFetcher>(
    fetcher: &F,
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    use crate::db_state::with_database;
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

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

    // 1. 定位书籍 + 加载新书源配置（只读：先不写库，待新目录抓取
    //    成功后才在步骤 4 的事务里统一落库，避免新源抰 0 章时已改了
    //    origin/tocUrl 却没有章节的不一致中间态）
    let (mut book, source) = with_database(|db| {
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

    // [T5] 候选搜索期变量：searchBooks 行按 (new_book_url, origin=new_source_url)
    // 命中时取 variable（对齐原版 SearchBook.toBook() 复制 variable 进入换源）
    let candidate_variable: Option<String> = with_database(|db| {
        let repo = legado_db::SearchBookRepository::new(db.connection());
        match repo.find_by_book_url(new_book_url)? {
            Some(row) if row.origin == new_source_url => Ok(row.variable),
            _ => Ok(None),
        }
    })?;

    // 2a. [T2] 新源详情解析（canReName=false：保留既有书名/作者，对齐原版
    //     changeSource getBookInfoAwait 门控；cover/intro/kind/lastChapter/
    //     wordCount 在 parse 内按解析值更新，tocUrl 为真实目录页）
    let info = runtime::block_on(async {
        fetcher
            .get_book_info_with_existing(&source, new_book_url, false, &book.name, &book.author)
            .await
    })
    .map_err(|e| {
        LegadoError::Parser(format!(
            "换源失败：新源「{}」详情页解析失败，已保留原书源与目录: {e}",
            source.book_source_name
        ))
    })?;

    // [T5] book.variable = 候选搜索期变量 ⊕ 详情页导出变量（详情页后写入
    //      者优先，对齐原版覆盖语义）；旧源旧值不再残留（R1 清单项）
    book.variable = merge_variables(candidate_variable.as_deref(), info.variable.as_deref());

    // 2b. [T2] 用解析出的真实 tocUrl 抓取新目录（目录页可与详情页不同，
    //     如「详情页=books/1、目录页=/book/1/chapters」的源）
    let toc_url = if info.toc_url.trim().is_empty() {
        new_book_url.to_string()
    } else {
        info.toc_url.clone()
    };
    let web_chapters: Vec<WebChapter> =
        runtime::block_on(async { fetcher.get_chapters(&source, &toc_url).await }).map_err(
            |e| {
                LegadoError::Parser(format!(
                    "换源失败：新源「{}」目录获取失败，已保留原书源与目录: {e}",
                    source.book_source_name
                ))
            },
        )?;

    // Task #21 修复：空结果保护。新书源未解析到任何章节时（get_chapters 返回
    //    Ok(vec![]) 而非错误），直接返回可读错误，且不改动任何库记录
    //    （保留原 origin/tocUrl 与原目录），避免把书换成「无章节」而比未换源
    //    更糟的回归。
    if web_chapters.is_empty() {
        return Err(LegadoError::Parser(
            "换源失败：新书源未解析到任何章节，已保留原书源与目录".into(),
        ));
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
    if info.last_chapter.is_some() {
        book.latest_chapter_title = info.last_chapter;
    }
    if info.word_count.is_some() {
        book.word_count = info.word_count;
    }
    // 标记需要重新获取章节列表
    book.last_check_time = 0;
    book.last_check_count = 0;
    with_database(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启换源事务失败: {e}")))?;

        BookRepository::new(conn).update(&book)?;
        let cache_repo = legado_db::CacheBookRepository::new(conn);
        cache_repo.delete_by_book(book_url)?;
        let chapter_repo = legado_db::BookChapterRepository::new(conn);
        chapter_repo.delete_by_book_url(book_url)?;
        chapter_repo.insert_batch_no_tx(&book_chapters)?;

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交换源事务失败: {e}")))?;
        Ok(())
    })?;

    serde_json::to_string(&book).map_err(LegadoError::Serialization)
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
fn enrich_switch_candidates(
    sources: &[BookSource],
    candidates: Vec<SearchCandidate>,
    options: &SwitchSearchOptions,
) -> LegadoResult<Vec<SearchCandidate>> {
    use std::collections::HashMap;

    let source_map: HashMap<String, BookSource> = sources
        .iter()
        .map(|s| (s.book_source_url.clone(), s.clone()))
        .collect();

    runtime::block_on(async {
        let mut handles = Vec::new();
        let mut orphans = Vec::new();
        for candidate in candidates {
            let Some(source) = source_map.get(&candidate.source_url).cloned() else {
                orphans.push(candidate);
                continue;
            };
            let opts = options.clone();
            handles.push(tokio::spawn(async move {
                enrich_one_switch_candidate(&source, candidate, &opts).await
            }));
        }
        let mut out = orphans;
        for handle in handles {
            if let Ok(c) = handle.await {
                out.push(c);
            }
        }
        Ok::<_, LegadoError>(out)
    })
}

async fn enrich_one_switch_candidate(
    source: &BookSource,
    mut candidate: SearchCandidate,
    options: &SwitchSearchOptions,
) -> SearchCandidate {
    use super::web_book::{build_engine, RealBookSourceFetcher};

    candidate.origin_order = source.custom_order;
    if !(options.load_info || options.load_toc || options.load_word_count) {
        return candidate;
    }

    let Ok(engine) = build_engine() else {
        return candidate;
    };
    let Ok(fetcher) = RealBookSourceFetcher::new() else {
        return candidate;
    };
    let book_url = candidate.book_url.clone();
    let mut toc_url = String::new();

    if options.load_info {
        if let Ok(info) = engine.get_book_info(source, &book_url).await {
            if candidate
                .latest_chapter
                .as_ref()
                .is_none_or(|s| s.is_empty())
            {
                candidate.latest_chapter = info.last_chapter;
            }
            if candidate.word_count.as_ref().is_none_or(|s| s.is_empty()) {
                candidate.word_count = info.word_count;
            }
            toc_url = info.toc_url;
        }
    }

    if options.load_toc || options.load_word_count {
        let toc_opt = if toc_url.trim().is_empty() {
            None
        } else {
            Some(toc_url.as_str())
        };
        match fetcher
            .get_chapters_with_hints(source, &book_url, toc_opt, Some(&candidate.book_name))
            .await
        {
            Ok(chapters) if !chapters.is_empty() => {
                if options.load_word_count {
                    apply_word_count_sample(&mut candidate, source, &fetcher, &chapters).await;
                }
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
        with_database(|db| {
            let repo = BookRepository::new(db.connection());
            let mut book = repo.find_by_url(old_url)?.expect("书籍应存在");
            book.origin = "https://task16-new-src.example.com".to_string();
            book.origin_name = "新源".to_string();
            book.toc_url = new_url.to_string();
            repo.update(&book)?; // WHERE bookUrl=old_url 命中原行

            let cache_repo = CacheBookRepository::new(db.connection());
            cache_repo.delete_by_book(old_url)?;
            let chapter_repo = BookChapterRepository::new(db.connection());
            chapter_repo.delete_by_book_url(old_url)?;
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
            }),
            chapters: Ok(vec![WebChapter {
                index: 0,
                title: "第一卷 第一章".to_string(),
                url: format!("{new_toc}/c1"),
                is_vip: false,
                is_volume: true,
                variable: Some(r#"{"token":"abc123"}"#.to_string()),
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
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
        assert_eq!(book.latest_chapter_title.as_deref(), Some("大结局"));
        // [T5] book.variable = 候选变量 ⊕ 详情导出变量（详情页后写入者优先），
        // 旧源旧值不再残留（R1）
        let book_var: serde_json::Value =
            serde_json::from_str(book.variable.as_deref().expect("book.variable 应有值")).unwrap();
        assert_eq!(book_var["token"], serde_json::json!("d123"));
        assert_eq!(book_var["sid"], serde_json::json!("s1"));

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

    /// T2 失败语义：详情解析失败 → 整个换源失败，旧源/旧目录/旧章节原样保留
    #[test]
    fn test_switch_fails_and_keeps_old_source_when_info_fails() {
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
            }]),
            chapters_requested: std::sync::Mutex::new(Vec::new()),
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
}
