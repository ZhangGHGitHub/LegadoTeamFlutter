//! WebBook FFI API
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力。
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。

use legado_core::models::BookSource;
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};
use legado_core::{LegadoError, LegadoResult};

use crate::runtime;

// ─── Stub Fetcher（FFI 侧占位实现） ──────────────────────────────────────────

/// FFI 侧占位 Fetcher，与 server 侧 Stub 类似，
/// 待 AnalyUrl + LegadoClient 完善后替换为真实实现。
struct FfiStubFetcher;

impl BookSourceFetcher for FfiStubFetcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        Ok(vec![WebSearchResult {
            name: format!("[ffi-stub] 搜索: {query}"),
            author: "stub".to_string(),
            book_url: format!("{}/search?q={}&page={page}", source.book_source_url, query),
            cover_url: None,
            intro: Some("FFI Stub 实现，真实解析待 AnalyUrl 完成后对接".to_string()),
            latest_chapter: None,
            source_url: source.book_source_url.clone(),
        }])
    }

    async fn get_book_info(
        &self,
        _source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        Ok(WebBookInfo {
            name: format!("[ffi-stub] {book_url}"),
            author: "stub".to_string(),
            cover_url: None,
            intro: Some("FFI Stub".to_string()),
            categories: vec![],
            last_chapter: None,
            book_url: book_url.to_string(),
            toc_url: book_url.to_string(),
        })
    }

    async fn get_chapters(
        &self,
        _source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        Ok(vec![WebChapter {
            index: 0,
            title: "[ffi-stub] 示例章节".to_string(),
            url: format!("{book_url}/chapter/0"),
            is_vip: false,
        }])
    }

    async fn get_content(
        &self,
        _source: &BookSource,
        chapter: &WebChapter,
    ) -> LegadoResult<String> {
        Ok(format!("[ffi-stub] 章节内容: {}", chapter.url))
    }
}

fn build_engine() -> WebBookEngine<FfiStubFetcher> {
    WebBookEngine::new(FfiStubFetcher)
}

// ─── 公开 API 函数 ─────────────────────────────────────────────────────────────

/// 搜索书籍
///
/// `source_json` — BookSource JSON 字符串
/// `query` — 搜索关键词
/// `page` — 页码（从 1 开始）
///
/// 返回 `WebSearchResult` JSON 数组字符串
pub fn webbook_search(source_json: &str, query: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let engine = build_engine();
    let results: Vec<WebSearchResult> = runtime::block_on(async {
        engine.search(&source, query, page).await
    })?;
    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

/// 获取书籍详情
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebBookInfo` JSON 字符串
pub fn webbook_info(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let engine = build_engine();
    let info: WebBookInfo = runtime::block_on(async {
        engine.get_book_info(&source, book_url).await
    })?;
    serde_json::to_string(&info).map_err(LegadoError::Serialization)
}

/// 获取章节列表
///
/// `source_json` — BookSource JSON 字符串
/// `book_url` — 书籍详情页 URL
///
/// 返回 `WebChapter` JSON 数组字符串
pub fn webbook_chapters(source_json: &str, book_url: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let engine = build_engine();
    let chapters: Vec<WebChapter> = runtime::block_on(async {
        engine.get_chapters(&source, book_url).await
    })?;
    serde_json::to_string(&chapters).map_err(LegadoError::Serialization)
}

/// 获取章节内容
///
/// `source_json` — BookSource JSON 字符串
/// `chapter_json` — WebChapter JSON 字符串
///
/// 返回章节正文文本
pub fn webbook_content(source_json: &str, chapter_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let chapter: WebChapter = serde_json::from_str(chapter_json)?;
    let engine = build_engine();
    runtime::block_on(async { engine.get_content(&source, &chapter).await })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::ContentRule;

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    #[test]
    fn test_webbook_search_api() {
        let result = webbook_search(&make_source_json(), "三体", 1).unwrap();
        let parsed: Vec<WebSearchResult> = serde_json::from_str(&result).unwrap();
        assert!(!parsed.is_empty());
        assert!(parsed[0].name.contains("三体"));
    }

    #[test]
    fn test_webbook_search_invalid_source_json() {
        let err = webbook_search("not valid json", "关键词", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_info_api() {
        let result = webbook_info(&make_source_json(), "https://example.com/book/1").unwrap();
        let info: WebBookInfo = serde_json::from_str(&result).unwrap();
        assert!(!info.name.is_empty());
        assert_eq!(info.book_url, "https://example.com/book/1");
    }

    #[test]
    fn test_webbook_chapters_api() {
        let result = webbook_chapters(&make_source_json(), "https://example.com/book/1").unwrap();
        let chapters: Vec<WebChapter> = serde_json::from_str(&result).unwrap();
        assert!(!chapters.is_empty());
        assert_eq!(chapters[0].index, 0);
    }

    #[test]
    fn test_webbook_content_api() {
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "https://example.com/ch/1")).unwrap();
        let content = webbook_content(&make_source_json(), &chapter_json).unwrap();
        assert!(!content.is_empty());
    }
}
