//! WebBook — 书源规则驱动的完整书籍获取协调器
//!
//! 提供搜索、详情、目录、内容四大能力，对标 Kotlin 侧 WebBook 对象。
//! 当前阶段使用 `BookSourceFetcher` trait + 注入模式，便于 Mock 测试；
//! 真实实现待 AnalyUrl + LegadoClient 完善后对接。

use serde::{Deserialize, Serialize};

use crate::error::{LegadoError, LegadoResult};
use crate::models::book_source::BookSource;

// ─── 数据结构 ─────────────────────────────────────────────────────────────────

/// 搜索结果项
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebSearchResult {
    /// 书名
    pub name: String,
    /// 作者
    pub author: String,
    /// 详情页 URL
    pub book_url: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 最新章节标题
    pub latest_chapter: Option<String>,
    /// 来源书源 URL
    pub source_url: String,
    /// 分类（kind 原始字符串，对标 Kotlin SearchBook.kind）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 字数（对标 Kotlin SearchBook.wordCount）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
}

/// 章节信息
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebChapter {
    /// 章节序号（从 0 开始）
    pub index: i32,
    /// 章节标题
    pub title: String,
    /// 章节 URL
    pub url: String,
    /// 是否 VIP 章节
    pub is_vip: bool,
    /// 是否卷章（卷章不检查空内容）
    #[serde(default)]
    pub is_volume: bool,
}

/// 书籍详情
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WebBookInfo {
    /// 书名
    pub name: String,
    /// 作者
    pub author: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 分类标签
    pub categories: Vec<String>,
    /// 最新章节标题
    pub last_chapter: Option<String>,
    /// 详情页 URL
    pub book_url: String,
    /// 目录页 URL（可能与详情页相同）
    pub toc_url: String,
    /// 字数（对标 Kotlin Book.wordCount）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    /// 分类（kind 原始字符串，对标 Kotlin Book.kind）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

// ─── Fetcher trait ────────────────────────────────────────────────────────────

/// HTTP 响应结构，由 fetcher 返回
#[derive(Debug, Clone)]
pub struct FetchResponse {
    /// 最终 URL（可能经过重定向）
    pub url: String,
    /// 响应体文本
    pub body: String,
}

/// 书源数据抓取 trait
///
/// 将网络请求与规则解析抽象为统一接口，便于：
/// - 注入 Mock 实现用于单元测试
/// - 后续替换为真实的 AnalyUrl + LegadoClient 实现
#[allow(async_fn_in_trait)]
pub trait BookSourceFetcher: Send + Sync {
    /// 搜索书籍
    ///
    /// - `source`: 书源配置
    /// - `query`: 搜索关键词
    /// - `page`: 页码（从 1 开始）
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>>;

    /// 获取书籍详情
    ///
    /// - `source`: 书源配置
    /// - `book_url`: 书籍详情页 URL
    async fn get_book_info(&self, source: &BookSource, book_url: &str)
        -> LegadoResult<WebBookInfo>;

    /// 获取章节列表
    ///
    /// - `source`: 书源配置
    /// - `book_url`: 书籍详情页 URL（用于构造目录请求）
    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>>;

    /// 获取章节正文内容
    ///
    /// - `source`: 书源配置
    /// - `chapter`: 目标章节（含 URL 等信息）
    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String>;
}

// ─── Mock Fetcher ─────────────────────────────────────────────────────────────

/// 用于单元测试的 Mock Fetcher
///
/// 通过 `VecDeque` 存储预设响应，每次调用按序消费。
/// 测试代码可预先通过 `push_*` 方法注入返回值。
#[derive(Default)]
pub struct MockBookSourceFetcher {
    search_results: std::sync::Mutex<Vec<LegadoResult<Vec<WebSearchResult>>>>,
    info_results: std::sync::Mutex<Vec<LegadoResult<WebBookInfo>>>,
    chapter_results: std::sync::Mutex<Vec<LegadoResult<Vec<WebChapter>>>>,
    content_results: std::sync::Mutex<Vec<LegadoResult<String>>>,
}

impl MockBookSourceFetcher {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注入搜索响应
    pub fn push_search(&self, result: LegadoResult<Vec<WebSearchResult>>) {
        self.search_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入书籍详情响应
    pub fn push_info(&self, result: LegadoResult<WebBookInfo>) {
        self.info_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入章节列表响应
    pub fn push_chapters(&self, result: LegadoResult<Vec<WebChapter>>) {
        self.chapter_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }

    /// 注入章节内容响应
    pub fn push_content(&self, result: LegadoResult<String>) {
        self.content_results
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(result);
    }
}

impl BookSourceFetcher for MockBookSourceFetcher {
    async fn search(
        &self,
        _source: &BookSource,
        _query: &str,
        _page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        let mut queue = self
            .search_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no search result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_book_info(
        &self,
        _source: &BookSource,
        _book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        let mut queue = self.info_results.lock().unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no info result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_chapters(
        &self,
        _source: &BookSource,
        _book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        let mut queue = self
            .chapter_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no chapter result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }

    async fn get_content(
        &self,
        _source: &BookSource,
        _chapter: &WebChapter,
    ) -> LegadoResult<String> {
        let mut queue = self
            .content_results
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if queue.is_empty() {
            Err(LegadoError::Internal(
                "MockBookSourceFetcher: no content result queued".into(),
            ))
        } else {
            queue.remove(0)
        }
    }
}

// ─── WebBookEngine ─────────────────────────────────────────────────────────────

/// WebBook 协调器
///
/// 封装完整的书源驱动书籍获取链路：搜索 → 详情 → 目录 → 内容。
/// 内部通过注入的 `BookSourceFetcher` 执行实际的网络请求与规则解析。
pub struct WebBookEngine<F: BookSourceFetcher> {
    fetcher: F,
}

impl<F: BookSourceFetcher> WebBookEngine<F> {
    /// 使用指定的 fetcher 构建 engine
    pub fn new(fetcher: F) -> Self {
        Self { fetcher }
    }

    /// 搜索书籍
    ///
    /// 流程（对标 Kotlin WebBook.searchBookAwait）：
    /// 1. 校验 searchUrl 不为空
    /// 2. 委托 fetcher 发起请求并解析结果
    /// 3. 返回 `WebSearchResult` 列表
    pub async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        // 校验搜索 URL（JS 书源的 searchUrl 通常为空，豁免校验）
        if !source.is_js_source()
            && source.search_url.as_ref().is_none_or(|u| u.trim().is_empty())
        {
            return Err(LegadoError::Parser("搜索url不能为空".into()));
        }
        // 校验关键词
        if query.is_empty() {
            return Err(LegadoError::Parser("搜索关键词不能为空".into()));
        }
        let page = if page < 1 { 1 } else { page };
        self.fetcher.search(source, query, page).await
    }

    /// 获取书籍详情
    ///
    /// 流程（对标 Kotlin WebBook.getBookInfoAwait）：
    /// 1. 委托 fetcher 请求书籍详情页
    /// 2. 用 ruleBookInfo 规则解析
    pub async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        if book_url.is_empty() {
            // [v2.0.10] 可读文案（原裸「bookUrl不能为空」无上下文）— Reasonix
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取详情（该书源搜索/发现规则未解析出详情链接）"
                    .into(),
            ));
        }
        self.fetcher.get_book_info(source, book_url).await
    }

    /// 获取章节列表
    ///
    /// 流程（对标 Kotlin WebBook.getChapterListAwait）：
    /// 1. 委托 fetcher 请求目录页
    /// 2. 用 ruleToc 规则解析章节列表
    pub async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        if book_url.is_empty() {
            // [v2.0.10] 可读文案（原裸「bookUrl不能为空」无上下文）— Reasonix
            return Err(LegadoError::Parser(
                "书籍详情页地址为空，无法获取目录（该书源搜索/发现规则未解析出详情链接）"
                    .into(),
            ));
        }
        let mut chapters = self.fetcher.get_chapters(source, book_url).await?;
        // 确保章节序号正确（从 0 开始递增）
        for (i, ch) in chapters.iter_mut().enumerate() {
            ch.index = i as i32;
        }
        Ok(chapters)
    }

    /// 获取章节内容
    ///
    /// 流程（对标 Kotlin WebBook.getContentAwait）：
    /// 1. 校验 ruleContent 不为空
    /// 2. 委托 fetcher 请求章节页并提取正文
    pub async fn get_content(
        &self,
        source: &BookSource,
        chapter: &WebChapter,
    ) -> LegadoResult<String> {
        // 校验正文规则（JS 书源由脚本直接返回内容，豁免规则校验）
        if !source.is_js_source() {
            let has_content_rule = source
                .rule_content
                .as_ref()
                .is_some_and(|r| r.content.as_ref().is_some_and(|c| !c.is_empty()));
            if !has_content_rule {
                return Err(LegadoError::Parser("正文规则为空".into()));
            }
        }
        if chapter.url.is_empty() {
            return Err(LegadoError::Parser("章节URL不能为空".into()));
        }
        self.fetcher.get_content(source, chapter).await
    }
}

// ─── 辅助构造函数 ──────────────────────────────────────────────────────────────

impl WebSearchResult {
    pub fn new(
        name: impl Into<String>,
        author: impl Into<String>,
        book_url: impl Into<String>,
        source_url: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            author: author.into(),
            book_url: book_url.into(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
            source_url: source_url.into(),
            kind: None,
            word_count: None,
        }
    }
}

impl WebChapter {
    pub fn new(index: i32, title: impl Into<String>, url: impl Into<String>) -> Self {
        Self {
            index,
            title: title.into(),
            url: url.into(),
            is_vip: false,
            is_volume: false,
        }
    }
}

impl WebBookInfo {
    pub fn new(
        name: impl Into<String>,
        author: impl Into<String>,
        book_url: impl Into<String>,
        toc_url: impl Into<String>,
    ) -> Self {
        Self {
            name: name.into(),
            author: author.into(),
            cover_url: None,
            intro: None,
            categories: Vec::new(),
            last_chapter: None,
            book_url: book_url.into(),
            toc_url: toc_url.into(),
            word_count: None,
            kind: None,
        }
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造用于测试的 BookSource（含 searchUrl 和 ruleContent）
    fn make_test_source() -> BookSource {
        use crate::models::rule::{ContentRule, SearchRule};
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_search: Some(SearchRule::default()),
            rule_content: Some(ContentRule {
                content: Some("css(.content).html".to_string()),
                ..ContentRule::default()
            }),
            ..BookSource::default()
        }
    }

    /// 构造无 searchUrl 的书源
    fn make_no_search_source() -> BookSource {
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "无搜索源".to_string(),
            search_url: None,
            ..BookSource::default()
        }
    }

    // ─── search 测试 ──────────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_search_returns_results() {
        let mock = MockBookSourceFetcher::new();
        mock.push_search(Ok(vec![
            WebSearchResult::new(
                "三体",
                "刘慈欣",
                "https://example.com/book/1",
                "https://example.com",
            ),
            WebSearchResult::new(
                "黑暗森林",
                "刘慈欣",
                "https://example.com/book/2",
                "https://example.com",
            ),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let results = engine.search(&source, "三体", 1).await.unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].name, "三体");
        assert_eq!(results[1].name, "黑暗森林");
    }

    #[tokio::test]
    async fn test_search_empty_query_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.search(&source, "", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
    }

    #[tokio::test]
    async fn test_search_no_search_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_no_search_source();

        let err = engine.search(&source, "关键词", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索url不能为空"));
    }

    #[tokio::test]
    async fn test_search_page_zero_normalized_to_one() {
        let mock = MockBookSourceFetcher::new();
        // 注入一个结果，page 参数由 fetcher 接收，这里只验证不崩溃
        mock.push_search(Ok(vec![WebSearchResult::new(
            "书A", "作者A", "url1", "src1",
        )]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let results = engine.search(&source, "书A", 0).await.unwrap();
        assert_eq!(results.len(), 1);
    }

    #[tokio::test]
    async fn test_search_empty_search_url_string_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            search_url: Some("".to_string()),
            ..BookSource::default()
        };

        let err = engine.search(&source, "关键词", 1).await.unwrap_err();
        assert!(err.to_string().contains("搜索url不能为空"));
    }

    // ─── get_book_info 测试 ────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_book_info_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_info(Ok(WebBookInfo::new(
            "三体",
            "刘慈欣",
            "https://example.com/book/1",
            "https://example.com/book/1",
        )));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let info = engine
            .get_book_info(&source, "https://example.com/book/1")
            .await
            .unwrap();
        assert_eq!(info.name, "三体");
        assert_eq!(info.author, "刘慈欣");
    }

    #[tokio::test]
    async fn test_get_book_info_empty_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_book_info(&source, "").await.unwrap_err();
        assert!(err.to_string().contains("详情页地址为空"));
    }

    #[tokio::test]
    async fn test_get_book_info_with_categories() {
        let mock = MockBookSourceFetcher::new();
        let mut info = WebBookInfo::new("凡人修仙传", "忘语", "url1", "url1");
        info.categories = vec!["仙侠".to_string(), "修真".to_string()];
        info.intro = Some("一个普通山村少年的修仙之路".to_string());
        mock.push_info(Ok(info));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let result = engine.get_book_info(&source, "url1").await.unwrap();
        assert_eq!(result.categories.len(), 2);
        assert!(result.intro.as_ref().unwrap().contains("修仙"));
    }

    #[tokio::test]
    async fn test_get_book_info_network_error_propagated() {
        let mock = MockBookSourceFetcher::new();
        mock.push_info(Err(LegadoError::Network("connection refused".into())));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_book_info(&source, "url1").await.unwrap_err();
        assert!(matches!(err, LegadoError::Network(_)));
    }

    #[tokio::test]
    async fn test_get_book_info_serde_roundtrip() {
        let info = WebBookInfo {
            name: "斗破苍穹".to_string(),
            author: "天蚕土豆".to_string(),
            cover_url: Some("https://example.com/cover.jpg".to_string()),
            intro: Some("这里是简介".to_string()),
            categories: vec!["玄幻".to_string()],
            last_chapter: Some("第100章".to_string()),
            book_url: "https://example.com/book/10".to_string(),
            toc_url: "https://example.com/book/10/toc".to_string(),
            word_count: None,
            kind: None,
        };
        let json = serde_json::to_string(&info).unwrap();
        let de: WebBookInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de, info);
    }

    // ─── get_chapters 测试 ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_chapters_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![
            WebChapter::new(0, "第一章", "https://example.com/ch/1"),
            WebChapter::new(1, "第二章", "https://example.com/ch/2"),
            WebChapter::new(2, "第三章", "https://example.com/ch/3"),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine
            .get_chapters(&source, "https://example.com/book/1")
            .await
            .unwrap();
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].index, 0);
        assert_eq!(chapters[2].index, 2);
        assert_eq!(chapters[1].title, "第二章");
    }

    #[tokio::test]
    async fn test_get_chapters_empty_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let err = engine.get_chapters(&source, "").await.unwrap_err();
        assert!(err.to_string().contains("详情页地址为空"));
    }

    #[tokio::test]
    async fn test_get_chapters_reindex() {
        // 即使 fetcher 返回乱序 index，engine 应重新编号
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![
            WebChapter::new(99, "第一章", "url1"),
            WebChapter::new(100, "第二章", "url2"),
        ]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert_eq!(chapters[0].index, 0);
        assert_eq!(chapters[1].index, 1);
    }

    #[tokio::test]
    async fn test_get_chapters_empty_list() {
        let mock = MockBookSourceFetcher::new();
        mock.push_chapters(Ok(vec![]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert!(chapters.is_empty());
    }

    #[tokio::test]
    async fn test_get_chapters_vip_flag_preserved() {
        let mock = MockBookSourceFetcher::new();
        let mut ch = WebChapter::new(0, "VIP章节", "url_vip");
        ch.is_vip = true;
        mock.push_chapters(Ok(vec![ch]));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();

        let chapters = engine.get_chapters(&source, "book_url").await.unwrap();
        assert!(chapters[0].is_vip);
    }

    // ─── get_content 测试 ──────────────────────────────────────────────────────

    #[tokio::test]
    async fn test_get_content_success() {
        let mock = MockBookSourceFetcher::new();
        mock.push_content(Ok("这是正文内容，测试用。".to_string()));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "https://example.com/ch/1");

        let content = engine.get_content(&source, &chapter).await.unwrap();
        assert!(content.contains("正文内容"));
    }

    #[tokio::test]
    async fn test_get_content_no_content_rule_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        // source 无 ruleContent
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_content: None,
            ..BookSource::default()
        };
        let chapter = WebChapter::new(0, "第一章", "url1");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(err.to_string().contains("正文规则为空"));
    }

    #[tokio::test]
    async fn test_get_content_empty_chapter_url_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }

    #[tokio::test]
    async fn test_get_content_empty_content_rule_string_returns_error() {
        let mock = MockBookSourceFetcher::new();
        let engine = WebBookEngine::new(mock);
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            rule_content: Some(crate::models::rule::ContentRule {
                content: Some("".to_string()), // 空字符串
                ..crate::models::rule::ContentRule::default()
            }),
            ..BookSource::default()
        };
        let chapter = WebChapter::new(0, "第一章", "url1");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(err.to_string().contains("正文规则为空"));
    }

    #[tokio::test]
    async fn test_get_content_network_error_propagated() {
        let mock = MockBookSourceFetcher::new();
        mock.push_content(Err(LegadoError::Network("timeout".into())));
        let engine = WebBookEngine::new(mock);
        let source = make_test_source();
        let chapter = WebChapter::new(0, "第一章", "url1");

        let err = engine.get_content(&source, &chapter).await.unwrap_err();
        assert!(matches!(err, LegadoError::Network(_)));
    }

    // ─── 数据结构序列化测试 ────────────────────────────────────────────────────

    #[test]
    fn test_web_search_result_serde() {
        let r = WebSearchResult::new("书名", "作者", "url1", "src1");
        let json = serde_json::to_string(&r).unwrap();
        let de: WebSearchResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.name, "书名");
        assert_eq!(de.author, "作者");
    }

    #[test]
    fn test_web_chapter_serde() {
        let ch = WebChapter::new(5, "第五章", "url5");
        let json = serde_json::to_string(&ch).unwrap();
        let de: WebChapter = serde_json::from_str(&json).unwrap();
        assert_eq!(de.index, 5);
        assert_eq!(de.title, "第五章");
        assert!(!de.is_vip);
    }
}
