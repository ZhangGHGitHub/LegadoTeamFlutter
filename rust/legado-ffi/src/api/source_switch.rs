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

use crate::api::source as source_api;
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
///
/// 在所有启用的书源中搜索，返回按匹配度排序的候选列表。
pub fn search_alternative_sources(
    book_name: &str,
    author: &str,
) -> LegadoResult<SourceSwitchResponse> {
    let sources = source_api::list_enabled_sources()?;
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
}
