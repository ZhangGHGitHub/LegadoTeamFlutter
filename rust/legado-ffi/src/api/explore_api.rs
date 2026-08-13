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

    // JS 书源分派：spawn_blocking 避免嵌套 runtime 死锁（R1）
    if source.is_js_source() {
        let source_clone = source.clone();
        let url_clone = url.to_string();
        let values = runtime::block_on(async {
            tokio::task::spawn_blocking(move || {
                let mut orchestrator = crate::api::web_book::build_js_orchestrator(&source_clone)?
                    .ok_or_else(|| LegadoError::Internal("JS 书源缺少 mainJs".into()))?;
                orchestrator.explore(&source_clone, &url_clone, page)
            })
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 发现任务异常: {e}")))?
        })?;
        let results = crate::api::web_book::convert_js_search_results(
            values,
            &source.book_source_url,
        );
        return serde_json::to_string(&results).map_err(LegadoError::Serialization);
    }

    // 规则书源路径
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

    // 发起 HTTP 请求（复用进程共享客户端单例）
    let client = crate::http_state::shared_client();

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

    // 对齐原版 BookList：explore.bookList 为空时回退 search 规则
    let explore_rule = source.rule_explore.as_ref();
    let search_rule = source.rule_search.as_ref();
    let use_search_fallback = explore_rule
        .and_then(|r| r.book_list.as_deref())
        .unwrap_or("")
        .is_empty();

    let book_list_rule = if use_search_fallback {
        search_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("")
    } else {
        explore_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("")
    };

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

        let name_rule = if use_search_fallback {
            search_rule.and_then(|r| r.name.as_deref()).unwrap_or("")
        } else {
            explore_rule.and_then(|r| r.name.as_deref()).unwrap_or("")
        };
        let author_rule = if use_search_fallback {
            search_rule.and_then(|r| r.author.as_deref()).unwrap_or("")
        } else {
            explore_rule.and_then(|r| r.author.as_deref()).unwrap_or("")
        };
        let book_url_rule = if use_search_fallback {
            search_rule.and_then(|r| r.book_url.as_deref()).unwrap_or("")
        } else {
            explore_rule.and_then(|r| r.book_url.as_deref()).unwrap_or("")
        };
        let cover_url_rule = if use_search_fallback {
            search_rule.and_then(|r| r.cover_url.as_deref()).unwrap_or("")
        } else {
            explore_rule.and_then(|r| r.cover_url.as_deref()).unwrap_or("")
        };
        let intro_rule = if use_search_fallback {
            search_rule.and_then(|r| r.intro.as_deref()).unwrap_or("")
        } else {
            explore_rule.and_then(|r| r.intro.as_deref()).unwrap_or("")
        };
        let last_chapter_rule = if use_search_fallback {
            search_rule
                .and_then(|r| r.last_chapter.as_deref())
                .unwrap_or("")
        } else {
            explore_rule
                .and_then(|r| r.last_chapter.as_deref())
                .unwrap_or("")
        };

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
            kind: None,
            word_count: None,
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

    /// 发现页 URL 组装：`{{page}}` 须展开为页码，禁止误伤成字面量 `{1}`（思路客回归）
    #[test]
    fn test_explore_analyze_url_double_brace_page() {
        let analyze = AnalyzeUrl::new(
            "/list1/{{page}}.html",
            None,
            Some(1),
            "http://www.silukezw.com",
            None,
        );
        assert_eq!(analyze.url(), "http://www.silukezw.com/list1/1.html");
        assert!(!analyze.url().contains('{'), "URL 不得残留花括号占位: {}", analyze.url());
    }

    /// 网络回归：思路客发现「玄幻」页码展开后应 HTTP 成功并解析到书名
    #[test]
    fn test_explore_fetch_siluke_xuanhuan_live() {
        let source = serde_json::json!({
            "bookSourceUrl": "http://www.silukezw.com",
            "bookSourceName": "思路客#2",
            "bookSourceType": 0,
            "ruleExplore": {
                "bookList": "",
                "name": "",
                "author": "",
                "bookUrl": "",
                "coverUrl": ""
            },
            "ruleSearch": {
                "bookList": ".col-md-6@dl",
                "name": "h3@a@text##.*\\]|小说全文阅读|小说全集",
                "author": "dd.1@span.0@text",
                "bookUrl": "a.0@href",
                "coverUrl": "img@src",
                "kind": "dd.2:3@text##.*：|.*：",
                "lastChapter": "dd.4@a@text"
            }
        });
        let source_json = source.to_string();
        let result = explore_fetch_books(&source_json, "/list1/{{page}}.html", 1);
        match result {
            Ok(json) => {
                assert!(!json.contains("{1}"), "响应不得含未替换占位: {json}");
                let books: Vec<serde_json::Value> =
                    serde_json::from_str(&json).expect("应为书籍 JSON 数组");
                assert!(
                    !books.is_empty(),
                    "思路客玄幻发现应解析到书籍，实际: {json}"
                );
            }
            Err(e) => {
                let msg = e.to_string();
                assert!(
                    !msg.contains("{1}"),
                    "失败信息不得含未替换占位 {{1}}: {msg}"
                );
                assert!(
                    !msg.contains("404"),
                    "页码未替换导致的 404 回归: {msg}"
                );
                panic!("网络/解析失败（非占位符问题）: {msg}");
            }
        }
    }
}
