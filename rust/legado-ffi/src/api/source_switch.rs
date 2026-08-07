//! 换源 API
//!
//! 提供搜索可替换书源和切换书籍来源的功能。
//! 复用 legado-net 的 HTTP 客户端和 legado-core 的 SourceMatcher 评分逻辑。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;
use legado_core::source_matcher::{SearchCandidate, SourceMatch, SourceMatcher};
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

    // 使用 SourceMatcher 评分排序
    let matches = SourceMatcher::rank_candidates(candidates, book_name, author);

    Ok(SourceSwitchResponse {
        book_name: book_name.to_string(),
        author: author.to_string(),
        matches,
    })
}

/// 切换到新书源
///
/// `book_url` — 当前书籍的 bookUrl（用于定位书籍记录）
/// `new_source_url` — 新书源的 URL
/// `new_book_url` — 新书源中该书籍的详情页 URL
///
/// 返回更新后的书籍信息（JSON）。
pub fn switch_book_source(
    book_url: &str,
    new_source_url: &str,
    new_book_url: &str,
) -> LegadoResult<String> {
    use crate::db_state::with_database;
    use legado_db::repository::Repository;
    use legado_db::BookRepository;

    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        let mut book = repo
            .find_by_url(book_url)?
            .ok_or_else(|| LegadoError::Database("书籍不存在".into()))?;

        // 更新书源信息
        book.origin = new_source_url.to_string();

        // 尝试从书源获取书源名称
        let source_repo = legado_db::BookSourceRepository::new(db.connection());
        if let Ok(Some(source)) = source_repo.find_by_url(new_source_url) {
            book.origin_name = source.book_source_name;
        }

        // 更新书籍 URL
        book.book_url = new_book_url.to_string();

        // 标记需要重新获取章节列表
        book.last_check_time = 0;
        book.last_check_count = 0;

        repo.update(&book)?;
        serde_json::to_string(&book).map_err(LegadoError::Serialization)
    })
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
async fn search_for_switch(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchCandidate>> {
    let search_url_template = match source.search_url.as_ref() {
        Some(u) => u,
        None => return Ok(Vec::new()),
    };

    // 简单替换关键词占位符
    let search_url = search_url_template
        .replace("{{key}}", keyword)
        .replace("{key}", keyword)
        .replace("searchKey", keyword);

    // 解析自定义请求头
    let headers: Option<HashMap<String, String>> = source
        .header
        .as_deref()
        .and_then(|s| serde_json::from_str(s).ok());

    // 发起 GET 请求
    let response = match client.get(&search_url, headers).await {
        Ok(r) => r,
        Err(_) => return Ok(Vec::new()),
    };

    if !response.is_success() {
        return Ok(Vec::new());
    }

    // 简化实现：将响应作为单条候选结果
    // 生产环境应使用 AnalyzeRule 解析 HTML/JSON 获取完整搜索结果列表
    let candidate = SearchCandidate {
        source_url: source.book_source_url.clone(),
        source_name: source.book_source_name.clone(),
        book_url: response.url,
        book_name: keyword.to_string(),
        author: String::new(),
        latest_chapter: None,
        word_count: None,
    };

    Ok(vec![candidate])
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
}
