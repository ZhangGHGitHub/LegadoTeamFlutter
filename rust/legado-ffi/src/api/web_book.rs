//! WebBook FFI API
//!
//! 为 Flutter/Dart 提供书源驱动的搜索、目录、内容获取能力。
//! 所有复杂类型通过 JSON String 传递，避免 frb 为外部类型生成绑定。
//!
//! 使用 `RealBookSourceFetcher`（LegadoClient + AnalyzeUrl + AnalyzeRule）
//! 实现完整的搜索→详情→目录→正文链路。

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};
use legado_core::{LegadoError, LegadoResult};
use legado_net::{LegadoClient, LegadoClientConfig};
use legado_parser::{AnalyzeUrl, RequestMethod};

use crate::runtime;

// ─── Real Fetcher（真实网络请求 + 规则解析） ────────────────────────────────────

/// 真实书源数据抓取器
///
/// 基于 legado-net HTTP 客户端 + legado-parser 规则解析引擎，
/// 实现完整的搜索→详情→目录→正文链路（对标 Kotlin WebBook 对象）。
pub struct RealBookSourceFetcher {
    client: LegadoClient,
}

impl RealBookSourceFetcher {
    pub fn new() -> Self {
        let config = LegadoClientConfig::default();
        let client = LegadoClient::new(config)
            .unwrap_or_else(|_| LegadoClient::new(LegadoClientConfig::default()).expect("client"));
        Self { client }
    }

    /// 解析书源 header 字段为请求头
    fn parse_source_headers(source: &BookSource) -> Option<HashMap<String, String>> {
        source
            .header
            .as_ref()
            .and_then(|h| serde_json::from_str::<HashMap<String, String>>(h).ok())
    }

    /// 根据 AnalyzeUrl 解析结果发起 HTTP 请求，返回响应体文本
    async fn fetch_url(
        &self,
        analyze_url: &AnalyzeUrl,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        let url = analyze_url.url();
        if url.is_empty() {
            return Err(LegadoError::Internal("AnalyzeUrl 解析后 URL 为空".into()));
        }

        // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
        let mut headers = source_headers.cloned().unwrap_or_default();
        headers.extend(analyze_url.headers().clone());
        let headers_opt = if headers.is_empty() {
            None
        } else {
            Some(headers)
        };

        let response = match analyze_url.method() {
            RequestMethod::Post => {
                let body = analyze_url.body().unwrap_or("");
                self.client.post(url, body, headers_opt).await?
            }
            _ => self.client.get(url, headers_opt).await?,
        };

        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }

        Ok(response.body)
    }

    /// 直接 GET 一个 URL（用于章节内容等简单场景）
    async fn fetch_simple(
        &self,
        url: &str,
        source_headers: Option<&HashMap<String, String>>,
    ) -> LegadoResult<String> {
        let headers_opt = source_headers.cloned();
        let response = self.client.get(url, headers_opt).await?;
        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }
        Ok(response.body)
    }
}

impl Default for RealBookSourceFetcher {
    fn default() -> Self {
        Self::new()
    }
}

impl BookSourceFetcher for RealBookSourceFetcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> LegadoResult<Vec<WebSearchResult>> {
        let search_url = source.search_url.as_deref().unwrap_or("");
        if search_url.is_empty() {
            return Err(LegadoError::Internal("书源未配置 searchUrl".into()));
        }

        let source_headers = Self::parse_source_headers(source);

        // 1. 解析搜索 URL 模板
        let analyze_url = AnalyzeUrl::new(
            search_url,
            Some(query),
            Some(page.max(1) as u32),
            &source.book_source_url,
            source_headers.clone(),
        );

        // 2. 发起 HTTP 请求
        let body = self
            .fetch_url(&analyze_url, source_headers.as_ref())
            .await?;

        // 3. 使用搜索规则解析结果
        let search_rule = source.rule_search.as_ref();
        let book_list_rule = search_rule
            .and_then(|r| r.book_list.as_deref())
            .unwrap_or("");

        let base_url = analyze_url.url().to_string();
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

            let name_rule = search_rule.and_then(|r| r.name.as_deref()).unwrap_or("");
            let author_rule = search_rule.and_then(|r| r.author.as_deref()).unwrap_or("");
            let book_url_rule = search_rule
                .and_then(|r| r.book_url.as_deref())
                .unwrap_or("");
            let cover_url_rule = search_rule
                .and_then(|r| r.cover_url.as_deref())
                .unwrap_or("");
            let intro_rule = search_rule.and_then(|r| r.intro.as_deref()).unwrap_or("");
            let last_chapter_rule = search_rule
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

    async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<WebBookInfo> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求书籍详情页
        let body = self.fetch_simple(book_url, source_headers.as_ref()).await?;

        // 2. 使用 bookInfo 规则解析
        let info_rule = source.rule_book_info.as_ref();
        let analyzer = crate::js_executor::construct_analyzer(
            body,
            book_url.to_string(),
            &source.book_source_url,
        );

        let name = info_rule
            .and_then(|r| r.name.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let author = info_rule
            .and_then(|r| r.author.as_deref())
            .map(|rule| analyzer.get_string(rule).unwrap_or_default())
            .unwrap_or_default();
        let intro = info_rule
            .and_then(|r| r.intro.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            })
            .unwrap_or(None);
        let cover_url = info_rule
            .and_then(|r| r.cover_url.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            })
            .unwrap_or(None);
        let toc_url = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    book_url.to_string()
                } else {
                    v
                }
            })
            .unwrap_or_else(|| book_url.to_string());
        let last_chapter = info_rule
            .and_then(|r| r.last_chapter.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            })
            .unwrap_or(None);
        let categories = info_rule
            .and_then(|r| r.kind.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    vec![]
                } else {
                    v.split([',', '，', ' '])
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                }
            })
            .unwrap_or_default();

        Ok(WebBookInfo {
            name,
            author,
            cover_url,
            intro,
            categories,
            last_chapter,
            book_url: book_url.to_string(),
            toc_url,
        })
    }

    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> LegadoResult<Vec<WebChapter>> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 先获取详情页以确定 toc_url
        let info_body = self.fetch_simple(book_url, source_headers.as_ref()).await?;
        let info_rule = source.rule_book_info.as_ref();
        let info_analyzer = crate::js_executor::construct_analyzer(
            info_body,
            book_url.to_string(),
            &source.book_source_url,
        );

        let toc_url = info_rule
            .and_then(|r| r.toc_url.as_deref())
            .map(|rule| {
                let v = info_analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    book_url.to_string()
                } else {
                    v
                }
            })
            .unwrap_or_else(|| book_url.to_string());

        // 2. 请求目录页
        let toc_body = self.fetch_simple(&toc_url, source_headers.as_ref()).await?;

        // 3. 解析目录
        let toc_rule = source.rule_toc.as_ref();
        let chapter_list_rule = toc_rule
            .and_then(|r| r.chapter_list.as_deref())
            .unwrap_or("");

        let analyzer =
            crate::js_executor::construct_analyzer(toc_body, toc_url.clone(), &source.book_source_url);

        let elements = if chapter_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(chapter_list_rule).unwrap_or_default()
        };

        let mut chapters = Vec::new();
        for (index, elem) in elements.iter().enumerate() {
            let elem_analyzer = crate::js_executor::construct_analyzer(
                elem.clone(),
                toc_url.clone(),
                &source.book_source_url,
            );

            let name_rule = toc_rule
                .and_then(|r| r.chapter_name.as_deref())
                .unwrap_or("");
            let url_rule = toc_rule
                .and_then(|r| r.chapter_url.as_deref())
                .unwrap_or("");
            let vip_rule = toc_rule.and_then(|r| r.is_vip.as_deref()).unwrap_or("");

            let title = elem_analyzer.get_string(name_rule).unwrap_or_default();
            if title.is_empty() {
                continue;
            }

            let url = elem_analyzer.get_string(url_rule).unwrap_or_default();
            let is_vip = if vip_rule.is_empty() {
                false
            } else {
                let v = elem_analyzer.get_string(vip_rule).unwrap_or_default();
                v == "true" || v == "1"
            };

            chapters.push(WebChapter {
                index: index as i32,
                title,
                url,
                is_vip,
            });
        }

        Ok(chapters)
    }

    async fn get_content(&self, source: &BookSource, chapter: &WebChapter) -> LegadoResult<String> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求章节页面
        let body = self
            .fetch_simple(&chapter.url, source_headers.as_ref())
            .await?;

        // 2. 使用正文规则解析
        let content_rule = source.rule_content.as_ref();
        let content_rule_str = content_rule
            .and_then(|r| r.content.as_deref())
            .unwrap_or("");

        let analyzer = crate::js_executor::construct_analyzer(
            body,
            chapter.url.clone(),
            &source.book_source_url,
        );

        let content = if content_rule_str.is_empty() {
            analyzer.content().to_string()
        } else {
            analyzer.get_string(content_rule_str).unwrap_or_default()
        };

        Ok(content)
    }
}

/// 构建 WebBookEngine（使用真实 HTTP + 规则解析实现）
pub fn build_engine() -> WebBookEngine<RealBookSourceFetcher> {
    WebBookEngine::new(RealBookSourceFetcher::new())
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
    let results: Vec<WebSearchResult> =
        runtime::block_on(async { engine.search(&source, query, page).await })?;
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
    let info: WebBookInfo =
        runtime::block_on(async { engine.get_book_info(&source, book_url).await })?;
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
    let chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, book_url).await })?;
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
    fn test_webbook_search_invalid_source_json() {
        let err = webbook_search("not valid json", "关键词", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_info_invalid_source_json() {
        let err = webbook_info("invalid", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_chapters_invalid_source_json() {
        let err = webbook_chapters("bad json", "https://example.com/book/1").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_webbook_content_invalid_chapter_json() {
        let err = webbook_content(&make_source_json(), "not json").unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_build_engine_creates_real_fetcher() {
        // 验证 build_engine 能正常构建（不 panic）
        let _engine = build_engine();
    }

    #[test]
    fn test_real_fetcher_default() {
        // 验证 Default trait 实现
        let _fetcher = RealBookSourceFetcher::default();
    }

    #[test]
    fn test_webbook_search_empty_query_returns_error() {
        // 空关键词应返回解析错误（engine 层校验）
        let err = webbook_search(&make_source_json(), "", 1).unwrap_err();
        assert!(err.to_string().contains("搜索关键词不能为空"));
    }

    #[test]
    fn test_webbook_content_empty_chapter_url_returns_error() {
        let chapter_json = serde_json::to_string(&WebChapter::new(0, "第一章", "")).unwrap();
        let err = webbook_content(&make_source_json(), &chapter_json).unwrap_err();
        assert!(err.to_string().contains("章节URL不能为空"));
    }
}
