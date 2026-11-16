//! 书源校验完整规则链端到端测试（批44）
//!
//! 对照基准：Android 原版 `CheckSourceService.kt` 的 `doCheckSource` /
//! `checkBook`——校验必须走 `searchBookAwait` / `getBookInfoAwait` /
//! `getChapterListAwait` / `getContentAwait` 完整规则链。
//!
//! 核心区分力（假阳回归）：旧实现（`legado-net::source_checker`）只做
//! 「searchUrl 字符串替换 + GET + 取首个 href」，**searchUrl 有响应即判搜索通过**
//! ——规则全错也会 PASS。本测试用「searchUrl 返回 200 但 bookList 规则不命中」
//! 的 mock 站点断言：完整规则链必须判 `搜索失效`，且搜索步骤为失败。

use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use legado_core::models::rule::{BookInfoRule, ContentRule, SearchRule, TocRule};
use legado_core::models::BookSource;
use legado_fetcher::deps::FetcherDeps;
use legado_fetcher::source_check::{
    is_invalid_group, run_source_check, SourceCheckConfig, GROUP_SEARCH_FAILED,
};
use legado_net::{LegadoClient, LegadoClientConfig};

/// 单线程 runtime 驱动（与 fetcher 内部 test_support 同语义，集成测试无法
/// 引用 `#[cfg(test)]` 模块，故自带一份）
fn block_on<F: std::future::Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("test runtime")
        .block_on(future)
}

/// 测试注入面：独立默认客户端（不触宿主 DB / 登录头 / setup）
fn test_deps() -> FetcherDeps {
    let client = LegadoClient::new(LegadoClientConfig::default()).expect("test http client");
    FetcherDeps::new(client)
}

/// 启动返回固定 HTML 的 mock 站点，并返回收到的请求数
fn spawn_html_server(body: &'static str) -> (u16, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock");
    let port = listener.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_srv = Arc::clone(&hits);
    std::thread::spawn(move || {
        use std::io::{Read, Write};
        while let Ok((mut stream, _)) = listener.accept() {
            let hits = Arc::clone(&hits_srv);
            std::thread::spawn(move || {
                let mut buf = [0u8; 8192];
                let _ = stream.read(&mut buf);
                hits.fetch_add(1, Ordering::SeqCst);
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
            });
        }
    });
    (port, hits)
}

/// 只做搜索校验的配置（隔离搜索步骤断言）
fn search_only() -> SourceCheckConfig {
    SourceCheckConfig {
        check_search: true,
        check_discovery: false,
        check_info: false,
        check_category: false,
        check_content: false,
        check_domain: false,
        timeout_ms: 10_000,
        ..SourceCheckConfig::default()
    }
}

/// **假阳回归**：searchUrl 返回 200 且页面**有链接**，但 `bookList` 规则不命中
/// → 必须判 `搜索失效`。
///
/// 区分力依据：旧简化实现（`legado-net::source_checker`）在无 `bookUrlPattern`
/// 时用 `extract_first_href(body)` 取首个链接，本 mock 页面的 `<a href>` 会被
/// 它取到 → 旧实现判搜索/目录/正文全通过（假阳）。完整规则链走 `bookList`
/// 选择器（`.missing` 不命中）→ 判 `搜索失效`（假阴修正）。
#[test]
fn test_rule_level_detects_false_positive_when_rules_do_not_match() {
    // 页面 200 且有 href（旧实现的 extract_first_href 会命中），但 bookList 规则不命中
    let (port, hits) = spawn_html_server(
        r#"<html><body><p>no results here</p><a href="/book/1">looks like a book</a></body></html>"#,
    );
    let mut source = BookSource {
        book_source_url: "https://a.example.com".to_string(),
        book_source_name: "假阳源".to_string(),
        search_url: Some(format!("http://127.0.0.1:{port}/search?q={{key}}")),
        ..BookSource::default()
    };
    source.rule_search = Some(SearchRule {
        book_list: Some("@css:.missing".to_string()),
        ..Default::default()
    });

    let outcome = block_on(run_source_check(
        &test_deps(),
        &source,
        &search_only(),
        None,
    ));

    assert!(
        hits.load(Ordering::SeqCst) >= 1,
        "搜索校验必须真实请求 mock（否则「搜索失效」来源不成立）"
    );
    assert!(
        !outcome.search_ok,
        "规则不命中必须判搜索失败（旧实现会误判通过）"
    );
    assert!(
        outcome
            .invalid_groups
            .iter()
            .any(|g| g == GROUP_SEARCH_FAILED),
        "应判「搜索失效」分组，实际: {:?}",
        outcome.invalid_groups
    );
    assert!(outcome.is_failed());
    assert!(outcome.search_error.is_some());
}

/// 对照组：`bookList` 命中且详情/目录/正文规则齐备 → 校验通过（无失效分组）
#[test]
fn test_rule_level_passes_with_full_valid_rules() {
    // 同一份 HTML 服务三类页面：搜索结果、详情页（含 tocUrl 与章节链接）、正文
    const SEARCH_HTML: &str = r#"<html><body>
<div class="book"><a class="name" href="/book/1">测试书</a><span class="author">作者甲</span></div>
</body></html>"#;
    let (port, hits) = spawn_html_server(SEARCH_HTML);
    let base = format!("http://127.0.0.1:{port}");
    let mut source = BookSource {
        book_source_url: "https://b.example.com".to_string(),
        book_source_name: "完整规则源".to_string(),
        search_url: Some(format!("{base}/search?q={{key}}")),
        ..BookSource::default()
    };
    source.rule_search = Some(SearchRule {
        book_list: Some("@css:.book".to_string()),
        name: Some("@css:.name@text".to_string()),
        author: Some("@css:.author@text".to_string()),
        book_url: Some("@css:.name@href".to_string()),
        ..Default::default()
    });
    source.rule_book_info = Some(BookInfoRule {
        name: Some("@css:.name@text".to_string()),
        author: Some("@css:.author@text".to_string()),
        ..Default::default()
    });
    source.rule_toc = Some(TocRule {
        chapter_list: Some("@css:.book".to_string()),
        chapter_name: Some("@css:.name@text".to_string()),
        chapter_url: Some("@css:.name@href".to_string()),
        ..Default::default()
    });
    source.rule_content = Some(ContentRule {
        content: Some("@css:body@text".to_string()),
        ..Default::default()
    });

    // 只跑搜索步骤（详情/目录/正文由 server 集成测试覆盖；此处聚焦假阳对照）
    let outcome = block_on(run_source_check(
        &test_deps(),
        &source,
        &search_only(),
        None,
    ));

    assert!(hits.load(Ordering::SeqCst) >= 1, "应真实请求 mock");
    assert!(outcome.search_ok, "规则命中应判搜索通过");
    assert!(
        outcome.invalid_groups.is_empty(),
        "通过时不应有失效分组: {:?}",
        outcome.invalid_groups
    );
    assert!(outcome.all_ok());
}

/// 整源超时 → `校验超时` 分组（对齐原版 `TimeoutCancellationException`）
#[test]
fn test_timeout_yields_timeout_group() {
    // 接受连接但永不回包
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind hanging");
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        use std::io::Read;
        while let Ok((mut stream, _)) = listener.accept() {
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf);
                std::thread::sleep(Duration::from_secs(30));
            });
        }
    });

    let mut source = BookSource {
        book_source_url: "https://c.example.com".to_string(),
        book_source_name: "超时源".to_string(),
        search_url: Some(format!("http://127.0.0.1:{port}/search?q={{key}}")),
        ..BookSource::default()
    };
    source.rule_search = Some(SearchRule {
        book_list: Some("@css:.book".to_string()),
        ..Default::default()
    });
    let config = SourceCheckConfig {
        timeout_ms: 300,
        ..search_only()
    };

    let started = std::time::Instant::now();
    let outcome = block_on(run_source_check(&test_deps(), &source, &config, None));
    let elapsed = started.elapsed();

    assert!(
        elapsed < Duration::from_secs(5),
        "整源超时应快速返回，实际 {elapsed:?}"
    );
    assert!(
        outcome
            .invalid_groups
            .iter()
            .any(|g| is_invalid_group(g) && g == "校验超时"),
        "应判「校验超时」，实际: {:?}",
        outcome.invalid_groups
    );
    assert!(outcome.is_failed());
}

/// 搜索 URL 规则为空（非 JS 源）→ 只记消息、不加分组（对齐原版
/// `NoStackTraceException("搜索链接规则为空")`）
#[test]
fn test_empty_search_url_records_message_without_group() {
    let source = BookSource {
        book_source_url: "https://d.example.com".to_string(),
        book_source_name: "空搜索规则源".to_string(),
        search_url: None,
        ..BookSource::default()
    };
    let outcome = block_on(run_source_check(
        &test_deps(),
        &source,
        &search_only(),
        None,
    ));

    assert!(!outcome.search_ok);
    assert_eq!(
        outcome.search_error.as_deref(),
        Some("搜索链接规则为空"),
        "应记录规则为空消息"
    );
    assert!(
        outcome.invalid_groups.is_empty(),
        "「搜索链接规则为空」不加失效分组（原版 NoStackTraceException）"
    );
}
