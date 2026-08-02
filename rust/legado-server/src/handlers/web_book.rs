//! WebBook 处理器 — 书源规则驱动的完整搜索链路 API
//!
//! 提供以下端点：
//! - POST /api/webbook/search   — 搜索书籍
//! - POST /api/webbook/info     — 获取书籍详情
//! - POST /api/webbook/chapters — 获取章节列表
//! - POST /api/webbook/content  — 获取章节内容

use std::sync::Arc;

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_core::web_book::{
    BookSourceFetcher, WebBookEngine, WebBookInfo, WebChapter, WebSearchResult,
};

// ─── 请求/响应类型 ─────────────────────────────────────────────────────────────

/// 搜索请求体
#[derive(Debug, Deserialize)]
pub struct WebBookSearchRequest {
    /// 书源 JSON（完整 BookSource 对象）
    pub source: BookSource,
    /// 搜索关键词
    pub query: String,
    /// 页码（从 1 开始），默认为 1
    pub page: Option<i32>,
}

/// 书籍详情请求体
#[derive(Debug, Deserialize)]
pub struct WebBookInfoRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 书籍详情页 URL
    pub book_url: String,
}

/// 章节列表请求体
#[derive(Debug, Deserialize)]
pub struct WebBookChaptersRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 书籍详情页 URL
    pub book_url: String,
}

/// 章节内容请求体
#[derive(Debug, Deserialize)]
pub struct WebBookContentRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 章节信息（至少需要 url 字段）
    pub chapter: WebChapter,
}

/// 搜索响应
#[derive(Debug, Serialize)]
pub struct WebBookSearchResponse {
    pub results: Vec<WebSearchResult>,
    pub total: usize,
    pub query: String,
    pub page: i32,
}

/// 章节列表响应
#[derive(Debug, Serialize)]
pub struct WebBookChaptersResponse {
    pub chapters: Vec<WebChapter>,
    pub total: usize,
}

/// 章节内容响应
#[derive(Debug, Serialize)]
pub struct WebBookContentResponse {
    pub content: String,
    pub chapter_url: String,
    pub chapter_title: String,
}

// ─── 真实 Fetcher 实现 ─────────────────────────────────────────────────────────

use legado_net::{LegadoClient, LegadoClientConfig};
use legado_parser::{AnalyzeRule, AnalyzeUrl, RequestMethod};

/// 真实书源数据抓取器
///
/// 基于 legado-net HTTP 客户端 + legado-parser 规则解析引擎，
/// 实现完整的搜索→详情→目录→正文链路。
struct RealBookSourceFetcher {
    client: LegadoClient,
}

impl RealBookSourceFetcher {
    fn new() -> Self {
        let config = LegadoClientConfig::default();
        let client = LegadoClient::new(config)
            .unwrap_or_else(|_| LegadoClient::new(LegadoClientConfig::default()).expect("client"));
        Self { client }
    }

    /// 解析书源 header 字段为请求头
    fn parse_source_headers(
        source: &BookSource,
    ) -> Option<std::collections::HashMap<String, String>> {
        source
            .header
            .as_ref()
            .and_then(|h| serde_json::from_str::<std::collections::HashMap<String, String>>(h).ok())
    }

    /// 根据 AnalyzeUrl 解析结果发起 HTTP 请求，返回响应体文本
    async fn fetch_url(
        &self,
        analyze_url: &AnalyzeUrl,
        source_headers: Option<&std::collections::HashMap<String, String>>,
    ) -> legado_core::LegadoResult<String> {
        let url = analyze_url.url();
        if url.is_empty() {
            return Err(legado_core::LegadoError::Internal(
                "AnalyzeUrl 解析后 URL 为空".into(),
            ));
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
            return Err(legado_core::LegadoError::Network(format!(
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
        source_headers: Option<&std::collections::HashMap<String, String>>,
    ) -> legado_core::LegadoResult<String> {
        let headers_opt = source_headers.cloned();
        let response = self.client.get(url, headers_opt).await?;
        if !response.is_success() {
            return Err(legado_core::LegadoError::Network(format!(
                "HTTP {} for {}",
                response.status, url
            )));
        }
        Ok(response.body)
    }
}

impl BookSourceFetcher for RealBookSourceFetcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        page: i32,
    ) -> legado_core::LegadoResult<Vec<WebSearchResult>> {
        let search_url = source.search_url.as_deref().unwrap_or("");
        if search_url.is_empty() {
            return Err(legado_core::LegadoError::Internal(
                "书源未配置 searchUrl".into(),
            ));
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
        let analyzer = AnalyzeRule::new(body, base_url.clone());

        // 获取书籍列表元素
        let elements = if book_list_rule.is_empty() {
            // 无 bookList 规则时，尝试整体作为 JSON 解析
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(book_list_rule).unwrap_or_default()
        };

        let mut results = Vec::new();
        for elem in elements.iter().take(50) {
            let elem_analyzer = AnalyzeRule::new(elem.clone(), base_url.clone());

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
            let kind_rule = search_rule.and_then(|r| r.kind.as_deref()).unwrap_or("");
            let word_count_rule = search_rule
                .and_then(|r| r.word_count.as_deref())
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
            let kind = {
                let v = elem_analyzer.get_string(kind_rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            };
            let word_count = {
                let v = elem_analyzer.get_string(word_count_rule).unwrap_or_default();
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
                kind,
                word_count,
            });
        }

        Ok(results)
    }

    async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> legado_core::LegadoResult<WebBookInfo> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 请求书籍详情页
        let body = self.fetch_simple(book_url, source_headers.as_ref()).await?;

        // 2. 使用 bookInfo 规则解析
        let info_rule = source.rule_book_info.as_ref();
        let analyzer = AnalyzeRule::new(body, book_url.to_string());

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
        let word_count = info_rule
            .and_then(|r| r.word_count.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            })
            .unwrap_or(None);
        let kind = info_rule
            .and_then(|r| r.kind.as_deref())
            .map(|rule| {
                let v = analyzer.get_string(rule).unwrap_or_default();
                if v.is_empty() {
                    None
                } else {
                    Some(v)
                }
            })
            .unwrap_or(None);

        Ok(WebBookInfo {
            name,
            author,
            cover_url,
            intro,
            categories,
            last_chapter,
            book_url: book_url.to_string(),
            toc_url,
            word_count,
            kind,
        })
    }

    async fn get_chapters(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> legado_core::LegadoResult<Vec<WebChapter>> {
        let source_headers = Self::parse_source_headers(source);

        // 1. 先获取详情页以确定 toc_url
        let info_body = self.fetch_simple(book_url, source_headers.as_ref()).await?;
        let info_rule = source.rule_book_info.as_ref();
        let info_analyzer = AnalyzeRule::new(info_body, book_url.to_string());

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

        // 2. 请求目录页（如果 toc_url 与 book_url 相同则复用已有 body）
        let toc_body = if toc_url == book_url {
            // 复用详情页内容
            let info_rule2 = source.rule_book_info.as_ref();
            let _ = info_rule2;
            // 重新获取（因为 info_body 已 move）
            self.fetch_simple(&toc_url, source_headers.as_ref()).await?
        } else {
            self.fetch_simple(&toc_url, source_headers.as_ref()).await?
        };

        // 3. 解析目录
        let toc_rule = source.rule_toc.as_ref();
        let chapter_list_rule = toc_rule
            .and_then(|r| r.chapter_list.as_deref())
            .unwrap_or("");

        let analyzer = AnalyzeRule::new(toc_body, toc_url.clone());

        let elements = if chapter_list_rule.is_empty() {
            vec![analyzer.content().to_string()]
        } else {
            analyzer.get_elements(chapter_list_rule).unwrap_or_default()
        };

        let mut chapters = Vec::new();
        for (index, elem) in elements.iter().enumerate() {
            let elem_analyzer = AnalyzeRule::new(elem.clone(), toc_url.clone());

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
                is_volume: false,
            });
        }

        Ok(chapters)
    }

    async fn get_content(
        &self,
        source: &BookSource,
        chapter: &WebChapter,
    ) -> legado_core::LegadoResult<String> {
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

        let analyzer = AnalyzeRule::new(body, chapter.url.clone());

        let content = if content_rule_str.is_empty() {
            // 无规则时返回 body 原文（去除 HTML 标签的基本处理）
            analyzer.content().to_string()
        } else {
            analyzer.get_string(content_rule_str).unwrap_or_default()
        };

        Ok(content)
    }
}

/// 构建 WebBookEngine（使用真实 HTTP + 规则解析实现）
fn build_engine() -> WebBookEngine<RealBookSourceFetcher> {
    WebBookEngine::new(RealBookSourceFetcher::new())
}

// ─── 处理器函数 ────────────────────────────────────────────────────────────────

/// POST /api/webbook/search — 搜索书籍
pub async fn search_books(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookSearchRequest>,
) -> Result<Json<WebBookSearchResponse>, ApiError> {
    let engine = build_engine();
    let page = req.page.unwrap_or(1);
    let results = engine
        .search(&req.source, &req.query, page)
        .await
        .map_err(ApiError::from)?;
    let total = results.len();
    Ok(Json(WebBookSearchResponse {
        results,
        total,
        query: req.query,
        page,
    }))
}

/// POST /api/webbook/info — 获取书籍详情
pub async fn get_book_info(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookInfoRequest>,
) -> Result<Json<WebBookInfo>, ApiError> {
    let engine = build_engine();
    let info = engine
        .get_book_info(&req.source, &req.book_url)
        .await
        .map_err(ApiError::from)?;
    Ok(Json(info))
}

/// POST /api/webbook/chapters — 获取章节列表
pub async fn get_chapters(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookChaptersRequest>,
) -> Result<Json<WebBookChaptersResponse>, ApiError> {
    let engine = build_engine();
    let chapters = engine
        .get_chapters(&req.source, &req.book_url)
        .await
        .map_err(ApiError::from)?;
    let total = chapters.len();
    Ok(Json(WebBookChaptersResponse { chapters, total }))
}

/// POST /api/webbook/content — 获取章节内容
pub async fn get_content(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookContentRequest>,
) -> Result<Json<WebBookContentResponse>, ApiError> {
    let engine = build_engine();
    let chapter_url = req.chapter.url.clone();
    let chapter_title = req.chapter.title.clone();
    let content = engine
        .get_content(&req.source, &req.chapter)
        .await
        .map_err(ApiError::from)?;
    Ok(Json(WebBookContentResponse {
        content,
        chapter_url,
        chapter_title,
    }))
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request, StatusCode};
    use serde_json::{json, Value};
    use std::sync::atomic::AtomicBool;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(legado_core::models::rule::ContentRule {
                content: Some("css(.content).html".to_string()),
                ..legado_core::models::rule::ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    /// 无 searchUrl 的书源 → 触发 Internal 错误
    fn make_source_no_search_url() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: None,
            ..BookSource::default()
        })
        .unwrap()
    }

    #[tokio::test]
    async fn test_webbook_search_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        // 使用真实书源配置发起搜索（可能因网络不可达返回 502）
        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "query": "三体",
            "page": 1
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502 (BAD_GATEWAY)
        assert!(
            resp.status() == StatusCode::OK
                || resp.status() == StatusCode::BAD_GATEWAY
                || resp.status() == StatusCode::INTERNAL_SERVER_ERROR,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_search_no_search_url() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_no_search_url()).unwrap(),
            "query": "测试",
            "page": 1
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 无 searchUrl → 错误响应（400 或 500）
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "expected error status, got: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_info_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "book_url": "https://example.com/book/1"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/info")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_chapters_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "book_url": "https://example.com/book/1"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/chapters")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_content_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "chapter": {
                "index": 0,
                "title": "第一章",
                "url": "https://example.com/ch/1",
                "is_vip": false
            }
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/content")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_search_missing_query_returns_bad_request() {
        let state = make_test_state();
        let app = create_router(state);

        // 发送不合法 JSON（缺少 query 字段）
        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap()
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Axum 反序列化失败 → 422 Unprocessable Entity
        assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }
}
