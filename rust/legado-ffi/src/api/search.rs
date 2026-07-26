//! 搜索 API
//!
//! 提供跨书源并行搜索能力，通过 legado-net 发起 HTTP 请求并解析结果。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;
use legado_core::search_engine::{MultiSourceSearcher, NoopSourceSearcher, SearchConfig};
use legado_core::{LegadoError, LegadoResult};
use legado_net::{LegadoClient, LegadoClientConfig};

use crate::api::source as source_api;
use crate::runtime;

/// 全局搜索取消标志
static SEARCH_CANCELLED: AtomicBool = AtomicBool::new(false);

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
}

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

    // 使用 tokio runtime 并行搜索
    let results = runtime::block_on(async {
        let client = LegadoClient::new(LegadoClientConfig::default())
            .map_err(|e| LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

        let mut handles = Vec::new();
        for source in sources {
            let client = client.clone();
            let keyword = keyword.to_string();
            handles.push(tokio::spawn(async move {
                search_single_source(&client, &source, &keyword).await
            }));
        }

        let mut all_results: Vec<SearchResult> = Vec::new();
        for handle in handles {
            if let Ok(Ok(mut items)) = handle.await {
                all_results.append(&mut items);
            }
        }
        Ok::<_, LegadoError>(all_results)
    })?;

    Ok(results)
}

/// 加载待搜索的书源列表
fn load_search_sources(source_urls_json: &str) -> LegadoResult<Vec<BookSource>> {
    if source_urls_json.is_empty() {
        // 使用所有启用的书源
        source_api::list_enabled_sources()
    } else {
        let urls: Vec<String> = serde_json::from_str(source_urls_json)
            .map_err(|e| LegadoError::Ffi(format!("书源 URL 列表解析失败: {e}")))?;
        // 从数据库逐个加载（简化实现）
        let all = source_api::list_enabled_sources()?;
        let filtered: Vec<BookSource> = all
            .into_iter()
            .filter(|s| urls.contains(&s.book_source_url))
            .collect();
        Ok(filtered)
    }
}

/// 对单个书源执行搜索（异步）
async fn search_single_source(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchResult>> {
    // 构造搜索 URL
    let search_url_template = source
        .search_url
        .as_ref()
        .ok_or_else(|| LegadoError::Parser("书源未配置 searchUrl".into()))?;

    // 简单替换关键词占位符
    let search_url = search_url_template
        .replace("{{key}}", keyword)
        .replace("{key}", keyword)
        .replace("searchKey", keyword);

    // 解析自定义请求头
    let headers = parse_header_option(source.header.as_deref());

    // 发起 GET 请求
    let response = client.get(&search_url, headers).await?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "搜索请求失败: HTTP {}",
            response.status
        )));
    }

    // 构造搜索结果（简化：返回原始响应作为单条结果）
    // 实际生产环境应使用 AnalyzeRule 解析 HTML/JSON
    let result = SearchResult {
        source_url: source.book_source_url.clone(),
        source_name: source.book_source_name.clone(),
        book_name: keyword.to_string(),
        author: String::new(),
        book_url: response.url,
        latest_chapter: None,
        intro: None,
        cover_url: None,
    };

    Ok(vec![result])
}

/// 解析 JSON 格式的请求头字符串
fn parse_header_option(header_str: Option<&str>) -> Option<HashMap<String, String>> {
    header_str.and_then(|s| serde_json::from_str(s).ok())
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
        // 使用 NoopSourceSearcher 占位（网络实现待 legado-net 完善后替换）
        let searcher = MultiSourceSearcher::new(NoopSourceSearcher);
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
        searcher.search(config, sources, cancel).await
    });

    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

/// 取消正在进行的搜索
pub fn cancel_search() {
    SEARCH_CANCELLED.store(true, Ordering::SeqCst);
}
