//! JS 源书籍操作 — 搜索/发现/书籍信息/目录/正文
//! 移植自 Kotlin JsSourceBook.kt (143行)
//!
//! 包含两层：
//! - **JsSourceBookManager** — 纯数据层（解析/验证/过滤）
//! - **JsSourceBookOrchestrator** — 编排层（调用 JsSourceEngine 执行 JS 函数）

use legado_core::models::{Book, BookChapter, BookSource};
use legado_core::{LegadoError, LegadoResult};
use serde::{Deserialize, Serialize};

use crate::engine::JsValue;
use crate::source_engine::JsSourceEngine;

use super::js_source_marshaller::{JsBookInfo as MarshalledBookInfo, JsSourceMarshaller};
use super::js_source_review::{JsSourceReview, ReviewDetailPage, ReviewSummary};

/// JS 源搜索请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsSearchRequest {
    pub key: String,
    pub page: i32,
    pub source_url: String,
}

/// JS 源搜索结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsSearchResult {
    pub book_name: String,
    pub author: String,
    pub book_url: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub latest_chapter: Option<String>,
}

/// JS 源书籍信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsBookInfo {
    pub name: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub categories: Vec<String>,
    pub word_count: Option<String>,
    pub last_chapter: Option<String>,
    pub book_url: String,
}

/// JS 源章节
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsChapter {
    pub index: i32,
    pub title: String,
    pub url: String,
    pub is_vip: bool,
}

/// JS 源书籍管理器
pub struct JsSourceBookManager;

impl JsSourceBookManager {
    /// 解析搜索结果 JSON
    pub fn parse_search_results(json: &str) -> Result<Vec<JsSearchResult>, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 解析书籍信息 JSON
    pub fn parse_book_info(json: &str) -> Result<JsBookInfo, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 解析章节列表 JSON
    pub fn parse_chapters(json: &str) -> Result<Vec<JsChapter>, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 构建搜索 URL（使用 AnalyUrl 模板）
    pub fn build_search_url(search_url_template: &str, key: &str, page: i32) -> String {
        search_url_template
            .replace("{key}", key)
            .replace("{page}", &page.to_string())
    }

    /// 验证搜索结果是否有效（name 和 book_url 不为空）
    pub fn validate_search_result(result: &JsSearchResult) -> bool {
        !result.book_name.is_empty() && !result.book_url.is_empty()
    }

    /// 过滤无效搜索结果（参考 Kotlin: 丢弃缺少 name/bookUrl 的搜索条目）
    pub fn filter_valid_results(results: Vec<JsSearchResult>) -> Vec<JsSearchResult> {
        results
            .into_iter()
            .filter(Self::validate_search_result)
            .collect()
    }

    /// 验证章节是否有效（title 和 url 不为空）
    pub fn validate_chapter(chapter: &JsChapter) -> bool {
        !chapter.title.is_empty() && !chapter.url.is_empty()
    }

    /// 过滤无效章节（参考 Kotlin: 丢弃缺少 title/url 的章节）
    pub fn filter_valid_chapters(chapters: Vec<JsChapter>) -> Vec<JsChapter> {
        chapters
            .into_iter()
            .filter(Self::validate_chapter)
            .collect()
    }
}

// ─── 编排层：JsSourceBookOrchestrator ────────────────────────────────────

/// JS 书源编排器
///
/// 封装对 `JsSourceEngine` 的调用，实现五个核心函数：
/// - search → callFunction("search", ...)
/// - explore → callFunction("explore", ...)
/// - get_book_info → callFunctionIfExists("getBookInfo", ...)
/// - get_chapter_list → callFunction("getChapters", ...)
/// - get_content → callFunction("getContent", ...)
///
/// 参考 Kotlin `JsSourceBook.kt`
pub struct JsSourceBookOrchestrator {
    /// JS 源执行引擎
    engine: JsSourceEngine,
}

impl JsSourceBookOrchestrator {
    /// 创建编排器
    pub fn new(engine: JsSourceEngine) -> Self {
        Self { engine }
    }

    /// 搜索：JS 书源 searchAwait
    ///
    /// 参考 Kotlin JsSourceBook.kt:23-39
    /// 调用 JS: callFunction("search", {key, page})
    pub fn search(
        &mut self,
        _source: &BookSource,
        key: &str,
        page: i32,
    ) -> LegadoResult<Vec<serde_json::Value>> {
        let result = self.engine.call_function(
            "search",
            &[
                ("key", JsValue::String(key.to_string())),
                ("page", JsValue::Int(page as i64)),
            ],
        )?;
        let json_str = result.unwrap_or_default();
        let results = JsSourceMarshaller::marshal_search(&json_str)
            .map_err(|e| LegadoError::Parser(e))?;
        Ok(results)
    }

    /// 发现：JS 书源 exploreAwait
    ///
    /// 参考 Kotlin JsSourceBook.kt:41-53
    /// 调用 JS: callFunction("explore", {url, page})
    pub fn explore(
        &mut self,
        _source: &BookSource,
        url: &str,
        page: i32,
    ) -> LegadoResult<Vec<serde_json::Value>> {
        let result = self.engine.call_function(
            "explore",
            &[
                ("url", JsValue::String(url.to_string())),
                ("page", JsValue::Int(page as i64)),
            ],
        )?;
        let json_str = result.unwrap_or_default();
        let results = JsSourceMarshaller::marshal_search(&json_str)
            .map_err(|e| LegadoError::Parser(e))?;
        Ok(results)
    }

    /// 详情：JS 书源 getBookInfoAwait
    ///
    /// 注意：getBookInfo 函数可能不存在（callFunctionIfExists），
    /// 缺失时沿用搜索字段。
    /// 参考 Kotlin JsSourceBook.kt:55-82
    pub fn get_book_info(
        &mut self,
        _source: &BookSource,
        book: &Book,
        can_re_name: bool,
    ) -> LegadoResult<MarshalledBookInfo> {
        let book_json = serde_json::to_string(book)?;
        let call_result = self.engine.call_function_if_exists(
            "getBookInfo",
            &[("book", JsValue::String(book_json))],
        )?;

        if call_result.exists {
            if let Some(json_str) = call_result.value {
                // 经 Marshaller 解析（downloadUrls 绝对化 + javascript: 过滤）
                let info_value = JsSourceMarshaller::marshal_book_info(&json_str, &book.book_url)
                    .map_err(LegadoError::Parser)?;
                let mut info: MarshalledBookInfo = serde_json::from_value(info_value)?;

                // canReName 门控：仅当 can_re_name 为 true 时才允许覆盖 name
                if !can_re_name {
                    info.name = book.name.clone();
                }

                // tocUrl 空回退 bookUrl
                if info.toc_url.as_ref().map_or(true, |u| u.trim().is_empty()) {
                    info.toc_url = Some(book.book_url.clone());
                }

                return Ok(info);
            }
        }

        // getBookInfo 函数不存在或无返回值，沿用搜索字段构造 BookInfo
        Ok(MarshalledBookInfo::from_book(book))
    }

    /// 目录：JS 书源 getChapterListAwait
    ///
    /// 参考 Kotlin JsSourceBook.kt:84-106
    /// 调用 JS: callFunction("getChapters", {book})
    pub fn get_chapter_list(
        &mut self,
        source: &BookSource,
        book: &Book,
    ) -> LegadoResult<Vec<serde_json::Value>> {
        let book_json = serde_json::to_string(book)?;
        let result = self.engine.call_function(
            "getChapters",
            &[("book", JsValue::String(book_json))],
        )?;
        let json_str = result.unwrap_or_default();
        let toc_url = if book.toc_url.is_empty() {
            &book.book_url
        } else {
            &book.toc_url
        };
        let chapters = JsSourceMarshaller::marshal_chapters(&json_str, toc_url)
            .map_err(LegadoError::Parser)?;

        // 空目录抛 TocEmpty 异常
        if chapters.is_empty() {
            return Err(LegadoError::TocEmpty(format!(
                "书源 {} 目录为空",
                source.book_source_url
            )));
        }

        Ok(chapters)
    }

    /// 正文：JS 书源 getContentAwait
    ///
    /// 参考 Kotlin JsSourceBook.kt:108-137
    /// 调用 JS: callFunction("getContent", {chapter, book, nextChapterUrl})
    pub fn get_content(
        &mut self,
        _source: &BookSource,
        chapter: &BookChapter,
        book: &Book,
        next_chapter_url: Option<&str>,
    ) -> LegadoResult<String> {
        // 卷章直通：isVolume && url.startsWith(title) → 返回 chapter.tag
        if chapter.is_volume && chapter.url.starts_with(&chapter.title) {
            return Ok(chapter.tag.clone().unwrap_or_default());
        }

        let chapter_json = serde_json::to_string(chapter)?;
        let book_json = serde_json::to_string(book)?;
        let next_url = next_chapter_url.unwrap_or("");

        let result = self.engine.call_function(
            "getContent",
            &[
                ("chapter", JsValue::String(chapter_json)),
                ("book", JsValue::String(book_json)),
                ("nextChapterUrl", JsValue::String(next_url.to_string())),
            ],
        )?;
        let content = result.unwrap_or_default();

        // 空正文抛 ContentEmpty 异常（非卷章）
        if content.trim().is_empty() {
            return Err(LegadoError::ContentEmpty(format!(
                "章节 {} 正文为空",
                chapter.title
            )));
        }

        Ok(JsSourceMarshaller::marshal_content(&content))
    }

    /// 段评摘要：JS 书源 getReviewSummaryAwait（P2-9）
    ///
    /// 参考 Kotlin JsSourceReview.kt:23-54：
    /// 调用 JS: callFunction("getReviewSummary", {chapter, book})，
    /// 返回 JSON 数组 `[{paraIndex,count,paraData}]`。
    /// 函数不存在时返回空摘要（对齐 Kotlin callOptionalFunction + capability 短路）。
    pub fn get_review_summary(
        &mut self,
        book: &Book,
        chapter: &BookChapter,
    ) -> LegadoResult<ReviewSummary> {
        let chapter_json = serde_json::to_string(chapter)?;
        let book_json = serde_json::to_string(book)?;
        let result = self.engine.call_function(
            "getReviewSummary",
            &[
                ("chapter", JsValue::String(chapter_json)),
                ("book", JsValue::String(book_json)),
            ],
        );
        let json = match result {
            Ok(Some(j)) => j,
            Ok(None) => return Ok(ReviewSummary::default()),
            Err(_) => {
                // 函数缺失/引擎错误 → 空摘要（可选能力）
                return Ok(ReviewSummary::default());
            }
        };
        JsSourceReview::parse_review_summary(&json).map_err(LegadoError::Parser)
    }

    /// 段评详情：JS 书源 getReviewDetailAwait（R10，Task #134）
    ///
    /// 参考 Kotlin JsSourceReview.kt:57-78：
    /// 调用 JS: callFunction("getReviewDetail", {chapter, book, paraIndex, paraData, page})，
    /// 返回 JSON `{items, nextPageUrl}`，经 [`JsSourceReview::parse_detail_page`]
    /// 解析（含嵌套回复扁平化 + avatar 相对 URL 绝对化，baseUrl 取 chapter.url）。
    ///
    /// 与 Kotlin 差异说明：原版返回 null 时 UI 层不更新；此处降级为空页
    /// （items 为空、无下一页），便于 FFI 调用方统一按空列表处理。
    pub fn get_review_detail(
        &mut self,
        book: &Book,
        chapter: &BookChapter,
        para_index: i32,
        para_data: &str,
        page: i32,
    ) -> LegadoResult<ReviewDetailPage> {
        let chapter_json = serde_json::to_string(chapter)?;
        let book_json = serde_json::to_string(book)?;
        let result = self.engine.call_function(
            "getReviewDetail",
            &[
                ("chapter", JsValue::String(chapter_json)),
                ("book", JsValue::String(book_json)),
                ("paraIndex", JsValue::Int(para_index as i64)),
                ("paraData", JsValue::String(para_data.to_string())),
                ("page", JsValue::Int(page as i64)),
            ],
        )?;
        let json = match result {
            Some(j) => j,
            None => {
                return Ok(ReviewDetailPage {
                    items: Vec::new(),
                    next_page_url: None,
                })
            }
        };
        JsSourceReview::parse_detail_page(&json, &chapter.url).map_err(LegadoError::Parser)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_search_results_valid() {
        let json = r#"[
            {"book_name":"斗破苍穹","author":"天蚕土豆","book_url":"http://example.com/1","cover_url":null,"intro":"简介","latest_chapter":"第100章"},
            {"book_name":"完美世界","author":"辰东","book_url":"http://example.com/2","cover_url":"http://img.com/2.jpg","intro":null,"latest_chapter":null}
        ]"#;
        let results = JsSourceBookManager::parse_search_results(json).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert_eq!(results[1].author, "辰东");
        assert_eq!(
            results[1].cover_url,
            Some("http://img.com/2.jpg".to_string())
        );
    }

    #[test]
    fn test_parse_search_results_invalid_json() {
        let result = JsSourceBookManager::parse_search_results("not json");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_book_info_valid() {
        let json = r#"{"name":"测试书籍","author":"作者","cover_url":"http://img.com/cover.jpg","intro":"这是简介","categories":["玄幻","热血"],"word_count":"100万字","last_chapter":"第500章","book_url":"http://example.com/book/1"}"#;
        let info = JsSourceBookManager::parse_book_info(json).unwrap();
        assert_eq!(info.name, "测试书籍");
        assert_eq!(info.categories.len(), 2);
        assert_eq!(info.word_count, Some("100万字".to_string()));
    }

    #[test]
    fn test_parse_book_info_missing_required_field() {
        let json = r#"{"name":"测试","author":"作者"}"#;
        let result = JsSourceBookManager::parse_book_info(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_chapters_valid() {
        let json = r#"[
            {"index":0,"title":"第一章","url":"http://example.com/1","is_vip":false},
            {"index":1,"title":"第二章","url":"http://example.com/2","is_vip":true}
        ]"#;
        let chapters = JsSourceBookManager::parse_chapters(json).unwrap();
        assert_eq!(chapters.len(), 2);
        assert!(!chapters[0].is_vip);
        assert!(chapters[1].is_vip);
    }

    #[test]
    fn test_parse_chapters_empty_array() {
        let json = "[]";
        let chapters = JsSourceBookManager::parse_chapters(json).unwrap();
        assert!(chapters.is_empty());
    }

    #[test]
    fn test_build_search_url() {
        let template = "http://example.com/search?q={key}&p={page}";
        let url = JsSourceBookManager::build_search_url(template, "斗破", 3);
        assert_eq!(url, "http://example.com/search?q=斗破&p=3");
    }

    #[test]
    fn test_build_search_url_no_placeholders() {
        let template = "http://example.com/static";
        let url = JsSourceBookManager::build_search_url(template, "key", 1);
        assert_eq!(url, "http://example.com/static");
    }

    #[test]
    fn test_validate_search_result() {
        let valid = JsSearchResult {
            book_name: "书名".to_string(),
            author: "作者".to_string(),
            book_url: "http://example.com".to_string(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
        };
        assert!(JsSourceBookManager::validate_search_result(&valid));

        let invalid = JsSearchResult {
            book_name: "".to_string(),
            author: "作者".to_string(),
            book_url: "http://example.com".to_string(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
        };
        assert!(!JsSourceBookManager::validate_search_result(&invalid));
    }

    #[test]
    fn test_filter_valid_results() {
        let results = vec![
            JsSearchResult {
                book_name: "有效".to_string(),
                author: "A".to_string(),
                book_url: "http://a.com".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
            JsSearchResult {
                book_name: "".to_string(),
                author: "B".to_string(),
                book_url: "http://b.com".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
            JsSearchResult {
                book_name: "无URL".to_string(),
                author: "C".to_string(),
                book_url: "".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
        ];
        let filtered = JsSourceBookManager::filter_valid_results(results);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].book_name, "有效");
    }

    // ─── R10 get_review_detail 测试（Task #134，mock JS 执行） ─────────────

    use crate::engine::{CompiledScript as TestCompiledScript, JsEngine as TestJsEngine};
    use crate::JsSourceConfig;

    /// 固定返回预设 JSON 的 mock JS 引擎（模拟 getReviewDetail 执行结果）
    struct FixedJsonEngine {
        response: String,
    }

    impl TestJsEngine for FixedJsonEngine {
        fn eval(&self, _code: &str) -> LegadoResult<String> {
            Ok(String::new())
        }

        fn eval_with_bindings(
            &self,
            _code: &str,
            _bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            Ok(String::new())
        }

        fn compile(&self, code: &str) -> LegadoResult<TestCompiledScript> {
            Ok(TestCompiledScript::new(code.to_string()))
        }

        fn execute_compiled(&self, _script: &TestCompiledScript) -> LegadoResult<String> {
            Ok(self.response.clone())
        }

        fn execute_compiled_with_bindings(
            &self,
            _script: &TestCompiledScript,
            _bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            Ok(self.response.clone())
        }
    }

    fn make_review_orchestrator(response: &str) -> JsSourceBookOrchestrator {
        let config = JsSourceConfig::new(
            "http://js-source.example.com".to_string(),
            "function getReviewDetail() {}".to_string(),
        );
        let engine = crate::source_engine::JsSourceEngine::with_engine(
            config,
            Box::new(FixedJsonEngine {
                response: response.to_string(),
            }),
        );
        JsSourceBookOrchestrator::new(engine)
    }

    #[test]
    fn test_get_review_detail_parses_js_json() {
        let json = r#"{"items":[{"id":"1","name":"用户A","content":"好看","avatar":"/a/1.jpg","badge":"大佬","replies":[{"name":"用户B","content":"同意"}]}],"nextPageUrl":"http://example.com/p2"}"#;
        let mut orch = make_review_orchestrator(json);
        let book = Book::default();
        let chapter = BookChapter {
            url: "http://example.com/ch1".to_string(),
            ..BookChapter::default()
        };
        let page = orch.get_review_detail(&book, &chapter, 2, "段落数据", 1).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].name.as_deref(), Some("用户A"));
        // 嵌套回复扁平化
        assert_eq!(page.items[0].replies.len(), 1);
        assert_eq!(page.items[0].replies[0].content, "同意");
        // avatar 相对 URL 基于 chapter.url 绝对化
        assert_eq!(
            page.items[0].avatar.as_deref(),
            Some("http://example.com/a/1.jpg")
        );
        assert_eq!(page.next_page_url.as_deref(), Some("http://example.com/p2"));
    }

    #[test]
    fn test_get_review_detail_null_result_returns_empty_page() {
        // JS 返回 "null" → 归一化为 None → 空页（对标 Kotlin `?: return null` 的降级）
        let mut orch = make_review_orchestrator("null");
        let page = orch
            .get_review_detail(&Book::default(), &BookChapter::default(), 1, "", 1)
            .unwrap();
        assert!(page.items.is_empty());
        assert!(page.next_page_url.is_none());
    }

    #[test]
    fn test_get_review_detail_invalid_json_errors() {
        let mut orch = make_review_orchestrator("这不是JSON");
        let err = orch
            .get_review_detail(&Book::default(), &BookChapter::default(), 1, "", 1)
            .unwrap_err();
        assert!(matches!(err, LegadoError::Parser(_)));
    }

    #[test]
    fn test_filter_valid_chapters() {
        let chapters = vec![
            JsChapter {
                index: 0,
                title: "第一章".to_string(),
                url: "http://a.com".to_string(),
                is_vip: false,
            },
            JsChapter {
                index: 1,
                title: "".to_string(),
                url: "http://b.com".to_string(),
                is_vip: false,
            },
            JsChapter {
                index: 2,
                title: "第三章".to_string(),
                url: "".to_string(),
                is_vip: false,
            },
        ];
        let filtered = JsSourceBookManager::filter_valid_chapters(chapters);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].title, "第一章");
    }
}
