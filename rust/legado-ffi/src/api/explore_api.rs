//! 发现页（Explore）FFI API
//!
//! 为 Flutter/Dart 提供发现页分类解析和书籍抓取能力。
//! 对标 Android 端 ExploreShowActivity / ExploreShowViewModel。
//!
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。

use std::collections::HashMap;

use legado_core::explore::{parse_explore_url, ExploreCategory};
use legado_core::models::BookSource;
use legado_core::web_book::WebSearchResult;
use legado_core::{LegadoError, LegadoResult};
use legado_net::{LegadoClient, LegadoClientConfig};
use legado_parser::AnalyzeUrl;

use crate::runtime;

// ─── 公开 API 函数 ─────────────────────────────────────────────────────────────

/// 解析 exploreUrl 为分类列表
///
/// `explore_url` — 书源的 exploreUrl 字段
///
/// 返回 `ExploreCategory` JSON 数组字符串
pub fn explore_parse_url(explore_url: &str) -> LegadoResult<String> {
    let categories: Vec<ExploreCategory> = parse_explore_url(explore_url);
    serde_json::to_string(&categories).map_err(LegadoError::Serialization)
}

/// 抓取发现分类的书籍列表
///
/// 对标 Android WebBook.exploreBookAwait：
/// 1. 使用 AnalyzeUrl 解析分类 URL（替换页码占位符）
/// 2. 发起 HTTP 请求获取页面内容
/// 3. 使用 ruleExplore 规则解析书籍列表
///
/// # 参数
/// - `source_json`: BookSource JSON 字符串
/// - `url`: 分类 URL（可能含页码占位符）
/// - `page`: 页码（从 1 开始）
///
/// # 返回
/// `WebSearchResult` JSON 数组字符串
pub fn explore_fetch_books(source_json: &str, url: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    if url.is_empty() {
        return Err(LegadoError::Internal("发现分类 URL 为空".into()));
    }

    let results: Vec<WebSearchResult> =
        runtime::block_on(async { explore_books_async(&source, url, page).await })?;

    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

// ─── 内部异步实现 ─────────────────────────────────────────────────────────────

/// 异步抓取发现分类书籍（内部实现）
async fn explore_books_async(
    source: &BookSource,
    url: &str,
    page: i32,
) -> LegadoResult<Vec<WebSearchResult>> {
    // 解析书源 header
    let source_headers: Option<HashMap<String, String>> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok());

    // 使用 AnalyzeUrl 解析分类 URL（处理页码替换等）
    let analyze_url = AnalyzeUrl::new(
        url,
        None,
        Some(page.max(1) as u32),
        &source.book_source_url,
        source_headers.clone(),
    );

    let final_url = analyze_url.url().to_string();
    if final_url.is_empty() {
        return Err(LegadoError::Internal("解析后发现 URL 为空".into()));
    }

    // 发起 HTTP 请求
    let config = LegadoClientConfig::default();
    let client = LegadoClient::new(config)
        .map_err(|e| LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

    // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
    let mut headers = source_headers.clone().unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    let response = client
        .get(&final_url, headers_opt)
        .await
        .map_err(|e| LegadoError::Network(format!("请求发现页失败: {e}")))?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "HTTP {} for {}",
            response.status, final_url
        )));
    }

    let body = response.body;

    // 使用 ruleExplore 规则解析书籍列表
    let explore_rule = source.rule_explore.as_ref();
    let book_list_rule = explore_rule
        .and_then(|r| r.book_list.as_deref())
        .unwrap_or("");

    let base_url = final_url.clone();
    let analyzer =
        crate::js_executor::construct_analyzer(body, base_url.clone(), &source.book_source_url);

    let elements = if book_list_rule.is_empty() {
        vec![analyzer.content().to_string()]
    } else {
        analyzer.get_elements(book_list_rule).unwrap_or_default()
    };

    let mut results = Vec::new();
    for elem in elements.iter().take(50) {
        let elem_analyzer = crate::js_executor::construct_analyzer(
            elem.clone(),
            base_url.clone(),
            &source.book_source_url,
        );

        let name_rule = explore_rule.and_then(|r| r.name.as_deref()).unwrap_or("");
        let author_rule = explore_rule.and_then(|r| r.author.as_deref()).unwrap_or("");
        let book_url_rule = explore_rule
            .and_then(|r| r.book_url.as_deref())
            .unwrap_or("");
        let cover_url_rule = explore_rule
            .and_then(|r| r.cover_url.as_deref())
            .unwrap_or("");
        let intro_rule = explore_rule.and_then(|r| r.intro.as_deref()).unwrap_or("");
        let last_chapter_rule = explore_rule
            .and_then(|r| r.last_chapter.as_deref())
            .unwrap_or("");

        let name = elem_analyzer.get_string(name_rule).unwrap_or_default();
        if name.is_empty() {
            continue;
        }

        let author = elem_analyzer.get_string(author_rule).unwrap_or_default();
        let book_url = elem_analyzer.get_string(book_url_rule).unwrap_or_default();
        let cover_url = {
            let v = elem_analyzer.get_string(cover_url_rule).unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        };
        let intro = {
            let v = elem_analyzer.get_string(intro_rule).unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        };
        let latest_chapter = {
            let v = elem_analyzer
                .get_string(last_chapter_rule)
                .unwrap_or_default();
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        };

        results.push(WebSearchResult {
            name,
            author,
            book_url,
            cover_url,
            intro,
            latest_chapter,
            source_url: source.book_source_url.clone(),
        });
    }

    Ok(results)
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_explore_parse_url_text() {
        let json = explore_parse_url("玄幻::https://a.com\n都市::https://b.com").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert_eq!(categories.len(), 2);
        assert_eq!(categories[0].title, "玄幻");
    }

    #[test]
    fn test_explore_parse_url_empty() {
        let json = explore_parse_url("").unwrap();
        let categories: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap();
        assert!(categories.is_empty());
    }

    #[test]
    fn test_explore_fetch_books_invalid_source_json() {
        let err = explore_fetch_books("not valid json", "https://example.com", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_explore_fetch_books_empty_url() {
        let source_json = serde_json::to_string(&BookSource::default()).unwrap();
        let err = explore_fetch_books(&source_json, "", 1).unwrap_err();
        assert!(err.to_string().contains("URL 为空"));
    }
}
