//! RSS 正文规则与正文分页（批15c）
//!
//! 逐行对齐原版 `Rss.getContentAwait`（`app/src/main/java/io/legado/app/model/rss/Rss.kt:99-242`）：
//!
//! ```text
//! getContentAwait(article, ruleContent, source, concurrency = threadCount) {
//!   first = getContentResponse(article.link, printLog = true)
//!   firstPage = analyzeContentPage(article, source, ruleContent, article.link, first)
//!   contentList = [firstPage.content]
//!   if nextUrlList.size == 1:
//!     visited = {first.url}
//!     while nextUrl 非空 && visited.add(nextUrl):
//!       res = getContentResponse(nextUrl, printLog = false)
//!       page = analyzeContentPage(..., nextUrl, res)       // 继续跟随各页 next
//!       contentList += page.content
//!       nextUrl = page.nextUrls.firstOrNull() ?: ""
//!   else if nextUrlList.size > 1:
//!     nextUrlList.mapAsync(concurrency) { getContentResponse(it, false)
//!         analyzeContentPage(..., getNextPageUrl = false).content }
//!       .collect { contentList += it }                     // 保序
//!   return contentList.joinToString("\n")
//! }
//!
//! getContentResponse(url) {
//!   AnalyzeUrl(url, baseUrl = article.origin, ruleData = article, hasLoginHeader = false)
//!   → HTTP → loginCheckJs 成功/失败两路检测 → 返回 StrResponse
//! }
//!
//! analyzeContentPage(..., baseUrl, response, getNextPageUrl) {
//!   rule = AnalyzeRule(article, source)
//!   rule.setContent(response.body)
//!       .setBaseUrl(absolute(article.origin, baseUrl))
//!       .setRedirectUrl(response.url)
//!   content = rule.getString(ruleContent)
//!   nextUrls = 仅当 getNextPageUrl && source.type == 0 && article.type == 0
//!                 && nextContentUrl 非空
//!              → rule.getStringList(nextContentUrl, isUrl = true)
//! }
//! ```
//!
//! ## 与原版逐项等价说明
//!
//! - **请求**：`AnalyzeUrl(url, baseUrl = sourceUrl)`（`page`/`key` 为空）；
//!   源静态 header 始终透传，`loginHeader_<url>` / `userInfo_<url>` 仅当
//!   目标 URL 与 `sourceUrl` 同源（scheme + host + port 全等）时附加并注入
//!   JS setup（复用批15b 门控，跨域正文分页不外发凭据）；
//! - **登录检测**：成功响应 / 请求失败两路 `loginCheckJs` 与列表共用
//!   [`super::login::gate_login`]（逐行对齐 `Rss.kt:186-209`）；
//! - **正文解析**：`AnalyzeRule::new(body)` + `set_base_url(absolute(sourceUrl,
//!   当页请求 URL))` + `set_redirect_url(响应最终 URL)` + `get_string(ruleContent)`；
//!   空规则 → 空串（原版 `getString(null/"") → ""`）；
//! - **正文分页**：`get_strings_ex(nextContentUrl, is_url = true)` 与
//!   `AnalyzeRule.getStringList(isUrl = true)` 同口径（按重定向最终 URL
//!   绝对化 + 去重）；单链顺序跟随、多链有界并发保序；
//! - **拼接**：`"\n"` join，空页也占一行（原版 `contentList.add("")` 同理）。
//!
//! ## 已登记的边界差异
//!
//! 1. **正文页 `@put` 变量不回写**：原版 `AnalyzeRule(ruleData = rssArticle)`
//!    把 `@put` 写进文章 `variable`（跨页共享并随 `insert` 落库）；本实现
//!    仅用库内 `rssArticles.variable` 种子化每页 `@get`，页内 `@put` 只影响
//!    当页，且不回写文章行；
//! 2. **多链并发不接取消信号**：原版每页 `currentCoroutineContext()
//!    .ensureActive()`；FFI 无会话取消面，本实现只由 `buffered` 的异常短路
//!    中止后续页；
//! 3. **单链分页不设总页数上限**：与原版一致（同一份逻辑），靠 URL 去环判停；
//! 4. **非 2xx 严格报错**：沿用批15b `request::fetch_list` 的校验（原版不校验
//!    状态码），差异与列表请求同一条登记。

use std::collections::HashSet;

use futures::StreamExt;
use legado_core::models::RssSource;
use legado_core::LegadoResult;
use legado_net::LegadoClient;
use legado_parser::AnalyzeUrl;

use crate::js_adapter::{construct_analyzer_with_source_context, sanitize_js_lib_for_quickjs};

use super::login;
use super::request;
use super::request::RssListResponse;

/// 多链并发上限：对齐原版 `AppConfig.threadCount` 默认值 32
///
/// 原版 `Rss.getContentAwait` 以 `AppConfig.threadCount`（默认 32，用户可配置）
/// 作为 `mapAsync` 并发度；我方 FFI 无全局配置面，固定为该默认值——既避免
/// 单源正文分页打满连接（列表/目录同口径），也不会与用户可调值大幅偏离。
pub const CONTENT_PAGE_CONCURRENCY: usize = 32;

/// 单页正文解析结果（内部结构，不跨 crate 暴露）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct RssContentPage {
    /// 本页正文（规则求值结果，可能为空串）
    content: String,
    /// 本页解析出的下一页 URL（`getNextPageUrl = false` 时恒空）
    next_urls: Vec<String>,
    /// 本页响应的最终 URL（重定向后；单链去环的初始已访问项取首屏值）
    final_url: String,
}

/// 拉取 RSS 文章正文（对齐 `Rss.getContentAwait`，`Rss.kt:99-169`）
///
/// 参数：
/// - `source`：RSS 源（`ruleContent` / `nextContentUrl` / `type` / header /
///   jsLib / loginCheckJs 从这里读取）；
/// - `link`：文章链接（首屏请求 URL，`AnalyzeUrl` 模板可含 `{{...}}`）；
/// - `article_type`：文章类型（0 网页 / 1 图片 / 2 视频），仅参与分页门控
///   （原版 `rssArticle.type == 0`）；文章行不存在时按 0 处理；
/// - `rule_data_variable`：`rssArticles.variable` JSON（原版 `AnalyzeRule(
///   ruleData = rssArticle)` 的 `@get` 初值；`None` = 无变量）；
/// - `login_header_json` / `login_info_json`：宿主登录缓存（仅同源附加）。
///
/// 返回正文（多页以 `"\n"` 拼接）；`ruleContent` 空/空白直接返回空串（不发
/// 请求，原版该分支不会被调用）；首屏或任一后续页失败返回 `Err`。
pub async fn fetch_content(
    client: &LegadoClient,
    source: &RssSource,
    link: &str,
    article_type: i32,
    rule_data_variable: Option<&str>,
    login_header_json: Option<&str>,
    login_info_json: Option<&str>,
) -> LegadoResult<String> {
    // [Rss.kt:230] getString(ruleContent) 空规则 → ""；原版调用方
    // （ReadRssViewModel.resolveRssReadLoadTarget）在规则空白时根本不会进入
    // getContent，故此处直接短路、避免无意义的首屏请求（已登记差异）。
    let rule_content = source.rule_content.as_deref().unwrap_or("");
    if rule_content.trim().is_empty() {
        return Ok(String::new());
    }

    // [Rss.kt:119-128] 首屏：getContentResponse(link, printLog = true)
    // + analyzeContentPage（默认继续跟随下一页）
    let first = fetch_content_page(
        client,
        source,
        link,
        article_type,
        rule_data_variable,
        login_header_json,
        login_info_json,
        true,
    )
    .await?;
    let mut content_list = vec![first.content];

    // [Rss.kt:129-147] 单链：顺序跟随，已访问集合从首屏响应最终 URL 起算
    if first.next_urls.len() == 1 {
        let mut visited_urls: HashSet<String> = HashSet::new();
        visited_urls.insert(first.final_url.clone());
        let mut next_url = first.next_urls[0].clone();
        while !next_url.is_empty() && visited_urls.insert(next_url.clone()) {
            let page = fetch_content_page(
                client,
                source,
                &next_url,
                article_type,
                rule_data_variable,
                login_header_json,
                login_info_json,
                true,
            )
            .await?;
            content_list.push(page.content);
            next_url = page.next_urls.first().cloned().unwrap_or_default();
            log::debug!("[rss] 正文第{}页完成", content_list.len());
        }
        log::debug!("[rss] ◇正文总页数:{}", content_list.len());
    } else if first.next_urls.len() > 1 {
        // [Rss.kt:148-167] 多链：有界并发、保序收集；各页不再跟随下一页
        // （`getNextPageUrl = false`）。任一页异常即整次失败（原版 mapAsync
        // 按列表顺序 await，异常从对应位置抛出，无部分返回）——
        // `buffered` 在异常处短路并丢弃未完成 future，语义等价。
        log::debug!("[rss] ◇并发解析正文,总页数:{}", first.next_urls.len());
        let pages = futures::stream::iter(first.next_urls.iter().map(|next_url| {
            fetch_content_page(
                client,
                source,
                next_url,
                article_type,
                rule_data_variable,
                login_header_json,
                login_info_json,
                false,
            )
        }))
        .buffered(CONTENT_PAGE_CONCURRENCY);
        let mut pages = pages;
        while let Some(page) = pages.next().await {
            content_list.push(page?.content);
        }
    }

    // [Rss.kt:168] joinToString("\n")：空正文/空页会保留空行，与原版一致
    Ok(content_list.join("\n"))
}

/// 请求并解析单页正文（`getContentResponse` + `analyzeContentPage` 的组合）
///
/// `get_next_page_url = false` 对应原版并发分支（不解析各页下一页）。
#[allow(clippy::too_many_arguments)] // 与 `analyzeContentPage` 入参 + 宿主登录缓存注入对齐
async fn fetch_content_page(
    client: &LegadoClient,
    source: &RssSource,
    url: &str,
    article_type: i32,
    rule_data_variable: Option<&str>,
    login_header_json: Option<&str>,
    login_info_json: Option<&str>,
    get_next_page_url: bool,
) -> LegadoResult<RssContentPage> {
    // 同源门控：先展开请求 URL（URL 模板可能含相对路径），再判定凭据是否
    // 可附加（与批15b 列表请求同一实现；跨域正文分页不外发登录头）。
    let probe_url = AnalyzeUrl::new(url, None, None, &source.source_url, None)
        .url()
        .to_string();
    let same_origin = request::is_same_origin(&probe_url, &source.source_url);
    let effective_login_header = login_header_json.filter(|_| same_origin);
    let effective_login_info = login_info_json.filter(|_| same_origin);
    let headers = request::source_headers_with_login(source, effective_login_header);
    let analyze_url = AnalyzeUrl::new(url, None, None, &source.source_url, headers.clone());
    // RSS 源 JS 最小绑定（正文规则 @js / loginCheckJs 共用）
    let setup_script = Some(crate::source_setup::rss_source_js_setup_script(
        source,
        effective_login_header,
        effective_login_info,
    )?);
    let request_url = analyze_url.url().to_string();

    // [Rss.kt:177-213] 正文页请求 + 登录检测（与列表共用 gate_login）
    let fetched = request::fetch_list(client, &analyze_url, headers).await;
    let response = login::gate_login(source, &request_url, setup_script.clone(), fetched)?;
    log::debug!("[rss] ≡获取成功:{}", response.final_url);

    // [Rss.kt:216-242] analyzeContentPage
    analyze_content_page(
        source,
        rule_content_of(source),
        &request_url,
        &response,
        get_next_page_url,
        article_type,
        rule_data_variable,
        setup_script,
    )
}

/// `analyzeContentPage`（`Rss.kt:216-242`）
///
/// 逐行对齐：
/// 1. `AnalyzeRule::new(body)`（JS 执行器注入 jsLib + setup）；
/// 2. `set_base_url(get_absolute_url(sourceUrl, 当页请求 URL))`——
///    原版 `NetworkUtils.getAbsoluteURL(rssArticle.origin, baseUrl)`；
/// 3. `set_redirect_url(响应最终 URL)`——原版 `setRedirectUrl(response.url)`；
/// 4. `get_string(ruleContent)`；
/// 5. 页码门控 `getNextPageUrl && source.type == 0 && article.type == 0 &&
///    nextContentUrl 非空`（注意「非空」不做 trim，与原版 `isNullOrEmpty` 一致）。
#[allow(clippy::too_many_arguments)] // 逐项对应原版 analyzeContentPage 形参
fn analyze_content_page(
    source: &RssSource,
    rule_content: &str,
    request_url: &str,
    response: &RssListResponse,
    get_next_page_url: bool,
    article_type: i32,
    rule_data_variable: Option<&str>,
    setup_script: Option<String>,
) -> LegadoResult<RssContentPage> {
    let base_url = AnalyzeUrl::get_absolute_url(&source.source_url, request_url);
    let js_lib = source.js_lib.as_deref().map(sanitize_js_lib_for_quickjs);
    let mut analyzer = construct_analyzer_with_source_context(
        response.body.clone(),
        base_url,
        &source.source_url,
        js_lib.as_deref(),
        setup_script,
    );
    analyzer.set_redirect_url(&response.final_url);
    // 原版 AnalyzeRule(ruleData = rssArticle)：@get 可读文章 variable；
    // 差异见模块文档「正文页 @put 变量不回写」。
    if let Some(variable_json) = rule_data_variable {
        analyzer.seed_variables_json(variable_json);
    }

    let content = analyzer.get_string(rule_content)?;

    let mut next_urls = Vec::new();
    if get_next_page_url && source.rss_type == 0 && article_type == 0 {
        // [Rss.kt:232-234] `isNullOrEmpty`：仅 null/空串跳过，空白串仍参与求值
        if let Some(next_content_url) = source
            .next_content_url
            .as_deref()
            .filter(|rule| !rule.is_empty())
        {
            log::debug!("[rss] ┌获取正文下一页链接");
            next_urls = analyzer.get_strings_ex(next_content_url, true)?;
            log::debug!("[rss] └{}", next_urls.join("，"));
        }
    }

    Ok(RssContentPage {
        content,
        next_urls,
        final_url: response.final_url.clone(),
    })
}

/// 源正文规则（供内部调用，避免多处 `unwrap_or`）
fn rule_content_of(source: &RssSource) -> &str {
    source.rule_content.as_deref().unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    /// 请求目标（`path?query`）→ `(状态行, 正文, 人为延迟毫秒)`
    type Routes = Arc<dyn Fn(&str) -> (String, String, u64) + Send + Sync>;

    /// 回环服务器句柄（循环 accept + Drop 关闭，避免请求数耦合挂死）
    struct LoopbackServer {
        addr: SocketAddr,
        targets: Arc<Mutex<Vec<String>>>,
        shutdown: Arc<AtomicBool>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl LoopbackServer {
        fn spawn(routes: Routes) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
            let addr = listener.local_addr().expect("读取端口");
            let targets = Arc::new(Mutex::new(Vec::new()));
            let shutdown = Arc::new(AtomicBool::new(false));
            let targets_thread = Arc::clone(&targets);
            let shutdown_thread = Arc::clone(&shutdown);
            let handle = std::thread::spawn(move || {
                while !shutdown_thread.load(Ordering::SeqCst) {
                    let Ok((mut stream, _)) = listener.accept() else {
                        break;
                    };
                    if shutdown_thread.load(Ordering::SeqCst) {
                        break;
                    }
                    // 每连接独立线程：并发用例需要服务器同时处理多页请求
                    //（单线程 accept 循环会把并发压成串行，测不出并发语义）。
                    let routes = Arc::clone(&routes);
                    let targets = Arc::clone(&targets_thread);
                    std::thread::spawn(move || {
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                        let head = read_request_head(&mut stream);
                        if head.is_empty() {
                            return;
                        }
                        let target = head
                            .lines()
                            .next()
                            .unwrap_or_default()
                            .split_whitespace()
                            .nth(1)
                            .unwrap_or_default()
                            .to_string();
                        let (status, body, delay_ms) = routes(&target);
                        targets.lock().unwrap().push(target);
                        if delay_ms > 0 {
                            std::thread::sleep(Duration::from_millis(delay_ms));
                        }
                        let response = format!(
                            "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
                             Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                            body.len(),
                            body
                        );
                        let _ = stream.write_all(response.as_bytes());
                        let _ = stream.flush();
                    });
                }
            });
            Self {
                addr,
                targets,
                shutdown,
                handle: Some(handle),
            }
        }

        fn base_url(&self) -> String {
            format!("http://{}", self.addr)
        }

        /// 已收到的请求目标快照（按到达顺序）
        fn targets(&self) -> Vec<String> {
            self.targets.lock().unwrap().clone()
        }
    }

    impl Drop for LoopbackServer {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::SeqCst);
            // 唤醒阻塞在 accept 的线程
            let _ = TcpStream::connect(self.addr);
            if let Some(handle) = self.handle.take() {
                let _ = handle.join();
            }
        }
    }

    fn read_request_head(stream: &mut TcpStream) -> String {
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match stream.read(&mut byte) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    head.push(byte[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
            }
        }
        String::from_utf8_lossy(&head).into_owned()
    }

    fn test_client() -> LegadoClient {
        LegadoClient::new(legado_net::LegadoClientConfig {
            no_proxy: true,
            ..legado_net::LegadoClientConfig::default()
        })
        .expect("test http client")
    }

    fn content_source(source_url: &str, next_content_url: Option<&str>) -> RssSource {
        RssSource {
            source_url: source_url.to_string(),
            rule_content: Some(".content".to_string()),
            next_content_url: next_content_url.map(str::to_string),
            ..RssSource::default()
        }
    }

    fn run<F: std::future::Future>(future: F) -> F::Output {
        crate::test_support::block_on(future)
    }

    /// 单页：无 nextContentUrl → 只请求首屏，返回规则求值结果
    #[test]
    fn single_page_returns_content_without_pagination() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/article/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">正文一</div></body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), None);

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/article/1"),
            0,
            None,
            None,
            None,
        ))
        .expect("单页正文");
        assert_eq!(content, "正文一");
        assert_eq!(server.targets(), vec!["/article/1"]);
    }

    /// 单链 2 页：顺序拼接；第 2 页指回第 1 页 → 去环停止（只发 2 次请求）
    #[test]
    fn single_chain_joins_in_order_and_stops_on_cycle() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/a/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">第一页</div>\
                 <a class=\"next\" href=\"/a/2\">下一页</a></body></html>"
                    .to_string(),
                0,
            ),
            "/a/2" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">第二页</div>\
                 <a class=\"next\" href=\"/a/1\">回环</a></body></html>"
                    .to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/a/1"),
            0,
            None,
            None,
            None,
        ))
        .expect("单链正文");
        assert_eq!(content, "第一页\n第二页", "单链按跟随顺序拼接，回环处停止");
        let targets = server.targets();
        assert_eq!(
            targets,
            vec!["/a/1", "/a/2"],
            "指回首屏最终 URL 时不得重复请求: {targets:?}"
        );
    }

    /// 多链：并发请求但结果按 nextContentUrl 列表顺序拼接（完成顺序不影响）
    #[test]
    fn multi_chain_joins_in_list_order_despite_completion_order() {
        // 第 1 条最慢（120ms）、第 2 条 60ms、第 3 条即时：完成顺序为 3/2/1
        let routes: Routes = Arc::new(|target: &str| match target {
            "/m/0" => (
                "200 OK".to_string(),
                "<html><body>\
                 <div class=\"content\">首屏</div>\
                 <a class=\"next\" href=\"/m/1\">一</a>\
                 <a class=\"next\" href=\"/m/2\">二</a>\
                 <a class=\"next\" href=\"/m/3\">三</a>\
                 </body></html>"
                    .to_string(),
                0,
            ),
            "/m/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">分页一</div></body></html>".to_string(),
                120,
            ),
            "/m/2" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">分页二</div></body></html>".to_string(),
                60,
            ),
            "/m/3" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">分页三</div></body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/m/0"),
            0,
            None,
            None,
            None,
        ))
        .expect("多链正文");
        assert_eq!(
            content, "首屏\n分页一\n分页二\n分页三",
            "多链必须按列表顺序拼接（对齐 mapAsync 保序 await）"
        );
        let mut targets = server.targets();
        targets.sort();
        assert_eq!(
            targets,
            vec!["/m/0", "/m/1", "/m/2", "/m/3"],
            "四页各请求一次"
        );
    }

    /// 多链并发确实并行（最慢页 120ms 不应串行叠加到 180ms 以上）
    #[test]
    fn multi_chain_requests_overlap() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/p/0" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">首屏</div>\
                 <a class=\"next\" href=\"/p/1\">一</a>\
                 <a class=\"next\" href=\"/p/2\">二</a>\
                 </body></html>"
                    .to_string(),
                0,
            ),
            "/p/1" | "/p/2" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">分页</div></body></html>".to_string(),
                300,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let started = std::time::Instant::now();
        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/p/0"),
            0,
            None,
            None,
            None,
        ))
        .expect("并发正文");
        let elapsed = started.elapsed();
        assert_eq!(content, "首屏\n分页\n分页");
        assert!(
            elapsed < Duration::from_millis(500),
            "两页 300ms 应并发完成（串行 ≥600ms），实测 {elapsed:?}"
        );
    }

    /// `source.type != 0`（图片/视频源）不分页：nextContentUrl 不生效
    #[test]
    fn non_web_source_skips_pagination() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/img/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">图集</div>\
                 <a class=\"next\" href=\"/img/2\">下一页</a></body></html>"
                    .to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let mut source = content_source(&format!("{base}/feed"), Some(".next@href"));
        source.rss_type = 1;

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/img/1"),
            0,
            None,
            None,
            None,
        ))
        .expect("图源正文");
        assert_eq!(content, "图集");
        assert_eq!(server.targets(), vec!["/img/1"], "图源不得跟随正文分页");
    }

    /// 文章 `type != 0` 同样不分页（对齐 `rssArticle.type == 0` 门控）
    #[test]
    fn non_web_article_skips_pagination() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/v/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">视频页</div>\
                 <a class=\"next\" href=\"/v/2\">下一页</a></body></html>"
                    .to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/v/1"),
            2,
            None,
            None,
            None,
        ))
        .expect("视频文章正文");
        assert_eq!(content, "视频页");
        assert_eq!(server.targets(), vec!["/v/1"], "type=2 文章不得分页");
    }

    /// 规则为空：直接返回空串，不发任何请求（含无效域名也不报错）
    #[test]
    fn blank_rule_content_returns_empty_without_request() {
        let source = RssSource {
            source_url: "http://rss.invalid/feed".to_string(),
            rule_content: Some("   ".to_string()),
            ..RssSource::default()
        };
        let content = run(fetch_content(
            &test_client(),
            &source,
            "http://rss.invalid/a",
            0,
            None,
            None,
            None,
        ))
        .expect("空规则不报错");
        assert_eq!(content, "");
    }

    /// 首屏 HTTP 失败 → Err（不做部分返回）
    #[test]
    fn first_page_failure_returns_err() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/bad" => (
                "500 Internal Server Error".to_string(),
                "boom".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), None);

        let err = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/bad"),
            0,
            None,
            None,
            None,
        ))
        .expect_err("首屏失败应报错");
        assert!(err.to_string().contains("HTTP 500"), "{err}");
    }

    /// 分页某页失败 → Err（原版 mapAsync 保序 await 异常传播，无部分返回）
    #[test]
    fn pagination_page_failure_returns_err() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/s/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">首屏</div>\
                 <a class=\"next\" href=\"/s/2\">下一页</a></body></html>"
                    .to_string(),
                0,
            ),
            "/s/2" => ("503 Service Unavailable".to_string(), "down".to_string(), 0),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let err = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/s/1"),
            0,
            None,
            None,
            None,
        ))
        .expect_err("分页失败应整次报错");
        assert!(err.to_string().contains("HTTP 503"), "{err}");
    }

    /// 空正文：规则无匹配 → `Ok("")`（原版 UI 显示空内容，不抛错）
    #[test]
    fn empty_content_returns_empty_string() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/empty" => (
                "200 OK".to_string(),
                "<html><body>没有正文节点</body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), None);

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/empty"),
            0,
            None,
            None,
            None,
        ))
        .expect("空正文不报错");
        assert_eq!(content, "");
    }

    /// 空页仍占一行：首屏有正文、分页页无匹配 → `"首屏\n"`（对齐 join 语义）
    #[test]
    fn empty_pagination_page_keeps_blank_line() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/b/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">首屏</div>\
                 <a class=\"next\" href=\"/b/2\">下一页</a></body></html>"
                    .to_string(),
                0,
            ),
            "/b/2" => (
                "200 OK".to_string(),
                "<html><body>无正文</body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let source = content_source(&format!("{base}/feed"), Some(".next@href"));

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/b/1"),
            0,
            None,
            None,
            None,
        ))
        .expect("空页正文");
        assert_eq!(content, "首屏\n", "空页保留空行，与原版 join 一致");
    }

    /// quickjs 门控：正文规则 `@js:` 可执行（复用源 jsLib/setup 上下文）
    #[cfg(feature = "quickjs")]
    #[test]
    fn js_content_rule_executes_with_source_context() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/js/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">JS 正文</div></body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let mut source = content_source(&format!("{base}/feed"), None);
        source.rule_content =
            Some(r#".content@js:"前缀:" + result + ":" + source.getKey()"#.to_string());

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/js/1"),
            0,
            None,
            None,
            None,
        ))
        .expect("JS 正文规则");
        assert_eq!(content, format!("前缀:JS 正文:{}", source.source_url));
    }

    /// quickjs 门控：文章 variable 种子化 `@get`（对齐 AnalyzeRule(ruleData)）
    #[cfg(feature = "quickjs")]
    #[test]
    fn article_variable_seeds_get_binding() {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/v/1" => (
                "200 OK".to_string(),
                "<html><body><div class=\"content\">正文</div></body></html>".to_string(),
                0,
            ),
            _ => ("404 Not Found".to_string(), String::new(), 0),
        });
        let server = LoopbackServer::spawn(routes);
        let base = server.base_url();
        let mut source = content_source(&format!("{base}/feed"), None);
        source.rule_content = Some(r#".content@js:"令牌:" + java.get("token")"#.to_string());

        let content = run(fetch_content(
            &test_client(),
            &source,
            &format!("{base}/v/1"),
            0,
            Some(r#"{"token":"令牌"}"#),
            None,
            None,
        ))
        .expect("variable 种子");
        assert_eq!(content, "令牌:令牌");
    }

    /// 计数辅助：确认并发上限与 `AppConfig.threadCount` 默认值一致
    #[test]
    fn concurrency_matches_upstream_default_thread_count() {
        assert_eq!(CONTENT_PAGE_CONCURRENCY, 32);
    }
}
