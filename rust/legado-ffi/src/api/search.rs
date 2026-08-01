//! 搜索 API
//!
//! 提供跨书源并行搜索能力，通过 legado-net 发起 HTTP 请求，
//! 使用 legado-parser 的 AnalyzeUrl + AnalyzeRule 解析搜索结果。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use legado_core::models::BookSource;
use legado_core::search_engine::{MultiSourceSearcher, SearchConfig};
use legado_core::source_matcher::SearchCandidate;
use legado_core::{LegadoError, LegadoResult};
use legado_net::LegadoClient;
use legado_parser::{AnalyzeRule, AnalyzeUrl, RequestMethod};

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

// ─── WebSourceSearcher ────────────────────────────────────────────────────────

/// 真实的网络书源搜索器
///
/// 使用 AnalyzeUrl 构建请求、LegadoClient 发送请求、AnalyzeRule 解析结果。
/// 实现 `SourceSearcher` trait 以接入 `MultiSourceSearcher` 并行框架。
pub struct WebSourceSearcher {
    client: LegadoClient,
}

impl WebSourceSearcher {
    pub fn new(client: LegadoClient) -> Self {
        Self { client }
    }
}

impl legado_core::SourceSearcher for WebSourceSearcher {
    async fn search(
        &self,
        source: &BookSource,
        query: &str,
        max_results: usize,
    ) -> Vec<SearchCandidate> {
        match search_single_source(&self.client, source, query).await {
            Ok(results) => results
                .into_iter()
                .take(max_results)
                .map(|r| SearchCandidate {
                    source_url: r.source_url,
                    source_name: r.source_name,
                    book_url: r.book_url,
                    book_name: r.book_name,
                    author: r.author,
                    latest_chapter: r.latest_chapter,
                    word_count: None,
                })
                .collect(),
            Err(_) => Vec::new(),
        }
    }
}

// ─── 公共 API ─────────────────────────────────────────────────────────────────

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
        let client = crate::http_state::shared_client();

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
        let client = crate::http_state::shared_client();

        let searcher = MultiSourceSearcher::new(WebSourceSearcher::new(client));
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
        Ok::<_, LegadoError>(searcher.search(config, sources, cancel).await)
    })?;

    serde_json::to_string(&results).map_err(LegadoError::Serialization)
}

/// 取消正在进行的搜索
pub fn cancel_search() {
    SEARCH_CANCELLED.store(true, Ordering::SeqCst);
}

// ─── 内部实现 ─────────────────────────────────────────────────────────────────

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
///
/// 完整链路：AnalyzeUrl 构建请求 → LegadoClient 发送 → AnalyzeRule 解析结果
async fn search_single_source(
    client: &LegadoClient,
    source: &BookSource,
    keyword: &str,
) -> LegadoResult<Vec<SearchResult>> {
    // 1. 获取搜索 URL 模板
    let search_url_template = source
        .search_url
        .as_ref()
        .ok_or_else(|| LegadoError::Parser("书源未配置 searchUrl".into()))?;

    if search_url_template.is_empty() {
        return Err(LegadoError::Parser("书源 searchUrl 为空".into()));
    }

    // 2. 使用 AnalyzeUrl 构建请求
    let analyze_url = build_search_url(search_url_template, keyword, source);

    // 3. 合并请求头：书源全局 header + AnalyzeUrl 提取的 header
    let mut headers = parse_header_option(source.header.as_deref()).unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    // 4. 发送 HTTP 请求
    let response = match analyze_url.method() {
        RequestMethod::Post => {
            let body = analyze_url.body().unwrap_or("");
            client.post(analyze_url.url(), body, headers_opt).await?
        }
        _ => client.get(analyze_url.url(), headers_opt).await?,
    };

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "搜索请求失败: HTTP {}",
            response.status
        )));
    }

    // 5. 使用 AnalyzeRule 解析搜索结果
    parse_search_response(&response.body, &response.url, source)
}

/// 构建搜索 URL
///
/// 处理 `{key}`、`{{key}}`、`searchKey` 等关键词占位符，
/// 然后通过 AnalyzeUrl 解析 URL 选项（method/headers/body 等）。
fn build_search_url(template: &str, keyword: &str, source: &BookSource) -> AnalyzeUrl {
    // 替换关键词占位符（在 AnalyzeUrl 处理之前）
    let url_with_key = template
        .replace("{{key}}", keyword)
        .replace("{key}", keyword);

    // AnalyzeUrl::new 内部会替换 "searchKey" 和处理 URL 选项
    AnalyzeUrl::new(
        &url_with_key,
        Some(keyword),
        Some(1),
        &source.book_source_url,
        None,
    )
}

/// 解析搜索响应（HTML 或 JSON）
///
/// 使用书源的 `rule_search` 规则解析响应体为结构化搜索结果。
fn parse_search_response(
    body: &str,
    base_url: &str,
    source: &BookSource,
) -> LegadoResult<Vec<SearchResult>> {
    let rule_search = match source.rule_search.as_ref() {
        Some(r) => r,
        None => return Ok(Vec::new()),
    };

    // 创建顶层 AnalyzeRule（quickjs 启用时注入 JS 执行器，使 @js: 搜索规则生效）
    let analyzer = crate::js_executor::construct_analyzer(
        body.to_string(),
        base_url.to_string(),
        &source.book_source_url,
    );

    // 获取书籍列表元素
    let book_list_rule = rule_search.book_list.as_deref().unwrap_or("");
    let elements = if book_list_rule.is_empty() {
        // 无 bookList 规则：尝试将整个响应作为单条结果解析
        vec![body.to_string()]
    } else {
        analyzer.get_elements(book_list_rule).unwrap_or_default()
    };

    if elements.is_empty() {
        return Ok(Vec::new());
    }

    // 对每个元素解析各字段
    let mut results = Vec::new();
    for element_html in &elements {
        let item_analyzer = crate::js_executor::construct_analyzer(
            element_html.clone(),
            base_url.to_string(),
            &source.book_source_url,
        );

        // 提取书名（必填，无书名则跳过）
        let book_name = get_field_first(&item_analyzer, rule_search.name.as_deref());
        if book_name.is_empty() {
            continue;
        }

        // 提取作者
        let author = get_field_first(&item_analyzer, rule_search.author.as_deref());

        // 提取书籍详情页 URL
        let raw_book_url = get_field_first(&item_analyzer, rule_search.book_url.as_deref());
        let book_url = resolve_url(&raw_book_url, base_url);

        // 提取封面 URL
        let raw_cover = get_field_first(&item_analyzer, rule_search.cover_url.as_deref());
        let cover_url = if raw_cover.is_empty() {
            None
        } else {
            Some(resolve_url(&raw_cover, base_url))
        };

        // 提取简介
        let intro = get_field_optional(&item_analyzer, rule_search.intro.as_deref());

        // 提取最新章节
        let latest_chapter =
            get_field_optional(&item_analyzer, rule_search.last_chapter.as_deref());

        results.push(SearchResult {
            source_url: source.book_source_url.clone(),
            source_name: source.book_source_name.clone(),
            book_name,
            author,
            book_url,
            latest_chapter,
            intro,
            cover_url,
        });
    }

    Ok(results)
}

/// 从 AnalyzeRule 中获取字段的第一个值（返回 String，无结果返回空串）
fn get_field_first(analyzer: &AnalyzeRule, rule: Option<&str>) -> String {
    match rule {
        Some(r) if !r.is_empty() => analyzer.get_string(r).unwrap_or_default(),
        _ => String::new(),
    }
}

/// 从 AnalyzeRule 中获取字段（返回 Option<String>）
fn get_field_optional(analyzer: &AnalyzeRule, rule: Option<&str>) -> Option<String> {
    match rule {
        Some(r) if !r.is_empty() => {
            let val = analyzer.get_string(r).unwrap_or_default();
            if val.is_empty() {
                None
            } else {
                Some(val)
            }
        }
        _ => None,
    }
}

/// 解析 URL（将相对路径转为绝对路径）
fn resolve_url(url: &str, base_url: &str) -> String {
    if url.is_empty() {
        return String::new();
    }
    // 已是绝对 URL
    if url.starts_with("http://") || url.starts_with("https://") {
        return url.to_string();
    }
    // 协议相对
    if url.starts_with("//") {
        if let Some(pos) = base_url.find("://") {
            return format!("{}:{}", &base_url[..pos], url);
        }
        return format!("https:{}", url);
    }
    // 绝对路径
    if url.starts_with('/') {
        if let Some(pos) = base_url.find("://") {
            if let Some(slash_pos) = base_url[pos + 3..].find('/') {
                let domain = &base_url[..pos + 3 + slash_pos];
                return format!("{}{}", domain, url);
            }
        }
        return format!("{}{}", base_url.trim_end_matches('/'), url);
    }
    // 相对路径
    if let Some(pos) = base_url.rfind('/') {
        format!("{}/{}", &base_url[..pos], url)
    } else {
        format!("{}/{}", base_url, url)
    }
}

/// 解析 JSON 格式的请求头字符串
fn parse_header_option(header_str: Option<&str>) -> Option<HashMap<String, String>> {
    header_str.and_then(|s| serde_json::from_str(s).ok())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::SearchRule;
    use legado_core::SourceSearcher;
    use legado_net::LegadoClientConfig;

    /// 构造带搜索规则的书源
    fn make_source_with_rules(
        book_list: &str,
        name: &str,
        author: &str,
        book_url: &str,
        cover_url: &str,
        intro: &str,
        last_chapter: &str,
    ) -> BookSource {
        BookSource {
            book_source_url: "https://www.example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://www.example.com/search?q={key}".to_string()),
            rule_search: Some(SearchRule {
                book_list: Some(book_list.to_string()),
                name: Some(name.to_string()),
                author: Some(author.to_string()),
                book_url: Some(book_url.to_string()),
                cover_url: Some(cover_url.to_string()),
                intro: Some(intro.to_string()),
                last_chapter: Some(last_chapter.to_string()),
                ..SearchRule::default()
            }),
            ..BookSource::default()
        }
    }

    // ─── 测试 1: HTML 搜索结果解析 ────────────────────────────────────────────

    #[test]
    fn test_parse_html_search_results() {
        let html = r#"<html><body>
            <div class="book-item">
                <a class="name" href="/book/1">斗破苍穹</a>
                <span class="author">天蚕土豆</span>
                <img class="cover" src="/covers/1.jpg" />
                <p class="intro">这里是简介</p>
                <span class="last">第100章 大结局</span>
            </div>
            <div class="book-item">
                <a class="name" href="/book/2">凡人修仙传</a>
                <span class="author">忘语</span>
                <img class="cover" src="/covers/2.jpg" />
                <p class="intro">修仙之路</p>
                <span class="last">第200章 飞升</span>
            </div>
        </body></html>"#;

        let source = make_source_with_rules(
            ".book-item",
            ".name",
            ".author",
            ".name@href",
            ".cover@src",
            ".intro",
            ".last",
        );

        let results =
            parse_search_response(html, "https://www.example.com/search?q=test", &source).unwrap();

        assert_eq!(results.len(), 2);

        // 验证第一条结果
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert_eq!(results[0].author, "天蚕土豆");
        assert_eq!(results[0].book_url, "https://www.example.com/book/1");
        assert_eq!(
            results[0].cover_url,
            Some("https://www.example.com/covers/1.jpg".to_string())
        );
        assert_eq!(results[0].intro, Some("这里是简介".to_string()));
        assert_eq!(
            results[0].latest_chapter,
            Some("第100章 大结局".to_string())
        );
        assert_eq!(results[0].source_url, "https://www.example.com");
        assert_eq!(results[0].source_name, "测试书源");

        // 验证第二条结果
        assert_eq!(results[1].book_name, "凡人修仙传");
        assert_eq!(results[1].author, "忘语");
        assert_eq!(results[1].book_url, "https://www.example.com/book/2");
    }

    // ─── 测试 2: JSON 搜索结果解析 ────────────────────────────────────────────

    #[test]
    fn test_parse_json_search_results() {
        let json = r#"{
            "data": [
                {
                    "title": "三体",
                    "writer": "刘慈欣",
                    "url": "https://api.example.com/book/3",
                    "cover": "https://cdn.example.com/cover3.jpg",
                    "desc": "地球往事三部曲",
                    "lastCh": "第30章"
                },
                {
                    "title": "黑暗森林",
                    "writer": "刘慈欣",
                    "url": "https://api.example.com/book/4",
                    "cover": "https://cdn.example.com/cover4.jpg",
                    "desc": "面壁计划",
                    "lastCh": "第25章"
                }
            ]
        }"#;

        let source = make_source_with_rules(
            "@json:$.data[*]",
            "@json:$.title",
            "@json:$.writer",
            "@json:$.url",
            "@json:$.cover",
            "@json:$.desc",
            "@json:$.lastCh",
        );

        let results =
            parse_search_response(json, "https://api.example.com/search", &source).unwrap();

        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "三体");
        assert_eq!(results[0].author, "刘慈欣");
        assert_eq!(results[0].book_url, "https://api.example.com/book/3");
        assert_eq!(
            results[0].cover_url,
            Some("https://cdn.example.com/cover3.jpg".to_string())
        );
        assert_eq!(results[0].intro, Some("地球往事三部曲".to_string()));
        assert_eq!(results[1].book_name, "黑暗森林");
    }

    // ─── 测试 3: 空结果和无规则处理 ───────────────────────────────────────────

    #[test]
    fn test_parse_empty_response() {
        let html = r#"<html><body><p>没有找到相关书籍</p></body></html>"#;

        let source =
            make_source_with_rules(".book-item", ".name", ".author", ".name@href", "", "", "");

        let results =
            parse_search_response(html, "https://www.example.com/search", &source).unwrap();

        assert!(results.is_empty());
    }

    #[test]
    fn test_parse_no_rule_search_returns_empty() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            book_source_name: "无规则源".to_string(),
            rule_search: None,
            ..BookSource::default()
        };

        let results =
            parse_search_response("<html></html>", "https://www.example.com", &source).unwrap();

        assert!(results.is_empty());
    }

    // ─── 测试 4: URL 解析（相对/绝对/协议相对）────────────────────────────────

    #[test]
    fn test_resolve_url_variants() {
        let base = "https://www.example.com/search/page";

        // 绝对 URL 不变
        assert_eq!(
            resolve_url("https://other.com/book/1", base),
            "https://other.com/book/1"
        );

        // 协议相对
        assert_eq!(
            resolve_url("//cdn.example.com/cover.jpg", base),
            "https://cdn.example.com/cover.jpg"
        );

        // 绝对路径
        assert_eq!(
            resolve_url("/book/1", base),
            "https://www.example.com/book/1"
        );

        // 相对路径
        assert_eq!(
            resolve_url("detail.html", base),
            "https://www.example.com/search/detail.html"
        );

        // 空 URL
        assert_eq!(resolve_url("", base), "");
    }

    // ─── 测试 5: build_search_url 关键词替换 ──────────────────────────────────

    #[test]
    fn test_build_search_url_key_replacement() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            ..BookSource::default()
        };

        // {key} 替换
        let url = build_search_url(
            "https://www.example.com/search?q={key}",
            "斗破苍穹",
            &source,
        );
        assert!(url.url().contains("斗破苍穹") || url.url().contains("%E6%96%97"));

        // {{key}} 替换
        let url2 = build_search_url("https://www.example.com/search?q={{key}}", "三体", &source);
        assert!(url2.url().contains("三体") || url2.url().contains("%E4%B8%89"));

        // searchKey 替换
        let url3 = build_search_url(
            "https://www.example.com/search?q=searchKey",
            "rust",
            &source,
        );
        assert!(url3.url().contains("rust"));
    }

    // ─── 测试 6: POST 方法检测 ────────────────────────────────────────────────

    #[test]
    fn test_build_search_url_post_method() {
        let source = BookSource {
            book_source_url: "https://www.example.com".to_string(),
            ..BookSource::default()
        };

        let url = build_search_url(
            r#"https://www.example.com/api,{"method":"POST","body":"keyword={key}"}"#,
            "测试",
            &source,
        );
        assert_eq!(url.method(), &RequestMethod::Post);
        assert!(url.body().unwrap_or("").contains("测试"));
    }

    // ─── 测试 7: WebSourceSearcher 错误容错 ───────────────────────────────────

    #[tokio::test]
    async fn test_web_source_searcher_no_search_url() {
        let client = LegadoClient::new(LegadoClientConfig::default()).unwrap();
        let searcher = WebSourceSearcher::new(client);

        // 无 searchUrl 的书源应返回空列表（不 panic）
        let source = BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "无搜索源".to_string(),
            search_url: None,
            ..BookSource::default()
        };

        let results = searcher.search(&source, "测试", 10).await;
        assert!(results.is_empty());
    }

    // ─── 测试 8: 无书名时跳过该条目 ──────────────────────────────────────────

    #[test]
    fn test_parse_skips_items_without_name() {
        let html = r#"<html><body>
            <div class="book-item">
                <span class="author">无名氏</span>
            </div>
            <div class="book-item">
                <a class="name" href="/book/9">有书名</a>
                <span class="author">作者A</span>
            </div>
        </body></html>"#;

        let source =
            make_source_with_rules(".book-item", ".name", ".author", ".name@href", "", "", "");

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        // 第一条无书名被跳过，只剩第二条
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].book_name, "有书名");
    }

    // ─── 测试 9: @js: 搜索规则注入（quickjs 启用时生效，否则降级）───────────────

    #[test]
    fn test_parse_search_js_rule() {
        let html = r#"<html><body>
            <div class="book-item"><span class="author">作者</span></div>
        </body></html>"#;

        // name / book_url 规则使用 @js:：quickjs 启用时返回固定值，未启用时降级为空
        let source = make_source_with_rules(
            ".book-item",
            "@js:'JS注入书名'",
            ".author",
            "@js:'https://www.example.com/book/js'",
            "",
            "",
            "",
        );

        let results = parse_search_response(html, "https://www.example.com", &source).unwrap();

        #[cfg(feature = "quickjs")]
        {
            assert_eq!(results.len(), 1, "quickjs 启用时 @js: 规则应被执行");
            assert_eq!(results[0].book_name, "JS注入书名");
            assert_eq!(results[0].book_url, "https://www.example.com/book/js");
        }

        #[cfg(not(feature = "quickjs"))]
        {
            // 未启用 quickjs：@js: 规则降级为空，书名为空该条目被跳过
            assert!(results.is_empty(), "未启用 quickjs 时 @js: 规则应降级为空");
        }
    }
}
