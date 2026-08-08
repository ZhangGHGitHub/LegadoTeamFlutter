//! 换源 API
//!
//! 提供搜索可替换书源和切换书籍来源的功能。
//! 复用 legado-net 的 HTTP 客户端和 legado-core 的 SourceMatcher 评分逻辑。

use serde::{Deserialize, Serialize};

use legado_core::models::{BookChapter, BookSource};
use legado_core::source_matcher::{SearchCandidate, SourceMatch, SourceMatcher};
use legado_core::web_book::WebChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_net::LegadoClient;

use crate::runtime;

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
///
/// 在指定（或全部启用）的书源中搜索，返回按匹配度排序的候选列表。
pub fn search_alternative_sources(
    book_name: &str,
    author: &str,
    source_urls_json: &str,
) -> LegadoResult<SourceSwitchResponse> {
    let sources = resolve_switch_sources(source_urls_json)?;
    if sources.is_empty() {
        return Ok(SourceSwitchResponse {
            book_name: book_name.to_string(),
            author: author.to_string(),
            matches: Vec::new(),
        });
    }

    // 使用 tokio runtime 并行搜索
    let candidates = runtime::block_on(async {
        let client = crate::http_state::shared_client();

        let mut handles = Vec::new();
        for source in sources {
            let client = client.clone();
            let keyword = book_name.to_string();
            handles.push(tokio::spawn(async move {
                search_for_switch(&client, &source, &keyword).await
            }));
        }

        let mut all_candidates: Vec<SearchCandidate> = Vec::new();
        for handle in handles {
            if let Ok(Ok(mut items)) = handle.await {
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

    // 使用 SourceMatcher 评分排序（同名同作者高分在前）
    let matches = SourceMatcher::rank_candidates(candidates, book_name, author);

    Ok(SourceSwitchResponse {
        book_name: book_name.to_string(),
        author: author.to_string(),
        matches,
    })
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
pub fn switch_book_source(
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    use crate::db_state::with_database;
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

    // Task #21 修复：换源目标详情页 URL 为空时提前返回可读错误。
    // 否则空 URL 会传入 WebBookEngine::get_chapters（步骤 2），触发解析器
    // 抛出令人困惑的 "bookUrl不能为空"（web_book.rs get_chapters 空值校验）。
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

    // 2. 用 new_book_url（新源详情页）从新书源抓取章节列表
    let engine = super::web_book::build_engine();
    let web_chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, new_book_url).await })?;

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
    let book_chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: false,
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
            variable: None,
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
    // tocUrl 指向新源详情页，供后续刷新目录定位（bookUrl 仍为旧源 URL）
    book.toc_url = new_book_url.to_string();
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
/// config 读取失败时按空分组处理（不误伤全量搜索）。
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
    let results = crate::api::search::search_single_source(client, source, keyword).await?;
    let candidates = results
        .into_iter()
        // Task #21 修复：过滤掉未解析出详情页 URL 的候选。空 book_url 无法用于
        // switch_book_source/refresh_toc 定位书籍，若进入换源列表被用户选中，
        // 会以空 URL 调用解析器抛 "bookUrl不能为空"。此处从源头剔除无效候选。
        .filter(|r| !r.book_url.trim().is_empty())
        .map(|r| SearchCandidate {
            source_url: r.source_url,
            source_name: r.source_name,
            book_url: r.book_url,
            book_name: r.book_name,
            author: r.author,
            latest_chapter: r.latest_chapter,
            word_count: None,
        })
        .collect();
    Ok(candidates)
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
        assert_eq!(from_empty_array.len(), enabled.len(), "空数组应搜全部启用源");
    }

    /// Task #145（留项#12）：分组包含判定纯语义单测
    /// 多组分隔符规范化（`,`/`;`/`，`/`；`）+ 组名 trim + 精确匹配非子串，
    /// 对齐原版 SOURCE_GROUP_MEMBERSHIP_FILTER SQL 语义
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
        crate::api::config_api::set_config("searchGroup", "   ")
            .expect("设置 searchGroup 失败");
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
        assert_eq!(decoded["bookUrl"].as_str(), Some(old_url), "返回 bookUrl 应保持稳定");
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
            let err = switch_book_source("https://any-book.example.com/1", "https://any-src.example.com", empty)
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
