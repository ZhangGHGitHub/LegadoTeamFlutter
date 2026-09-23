//! [回归 2026-09-17] `get_chapters_with_vars`「已解析目录页」语义（方案 A）
//!
//! 入参 `toc_url` 是**已解析的真实目录页 URL**（如换源 2a 详情解析出的
//! toc_url）：实现必须直接抓取该目录页并对响应体跑 ruleToc，**不得**把
//! 入参当 book_url 走「抓详情页 → init → tocUrl 规则重推目录地址」的
//! 详情路径（二次重推）。
//!
//! 背景：换源第二断点 2026-09-17 实测确证——松鹤庭沐源 `…/all-chapter?bookId=1100468021`
//! 被当 book_url 走详情路径后，目录体上 `ruleBookInfo.init` 求值空 →
//! `tocUrl` 规则重推出空值地址（`…/all-chapter?bookId=`）→ 服务端
//! `ret:422` → 0 章 → 换源报「新书源未解析到任何章节」。
//!
//! 本测试用本地**记录型**夹具服务器（记录全部请求 target）+ 纯 JSONPath
//! 规则（不依赖 quickjs 特性，双特性配置均可跑），钉住三条语义：
//! 1. 恰好 1 次 HTTP 请求，请求 target 恰好是传入 TOC URL 经变量展开后的
//!    地址（`{{bookId}}` → `1100468021`）——旧代码会发出第二次重推请求
//!    且 0 章；
//! 2. 章节数 = 3（夹具 rows）；
//! 3. 章节 URL 基于传入 TOC 页地址绝对化。
//!
//! 2026-09-19：全链路本即离线（127.0.0.1 记录型夹具服务器 + 纯 JSONPath
//! 规则，不发外网请求），移除陈旧的 `#[ignore = "requires network access"]`。
//! 注意：`RealBookSourceFetcher::new()` 内部走 `http_state::shared_client()`
//! （默认配置，随宿主 env/系统代理路由）——无代理环境全离线可跑；代理环境
//! 下回环流量可能被劫持（需经 http_state / web_book 注入 no_proxy 客户端，
//! 两文件在本次文件避让范围内，属后续项）。

#![cfg(test)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

use crate::api::web_book::RealBookSourceFetcher;
use legado_core::models::book_source::BookSource;
#[cfg_attr(not(feature = "quickjs"), allow(unused_imports))]
use legado_core::models::rule::{BookInfoRule, SearchRule, TocRule};
use legado_core::web_book::BookSourceFetcher;

/// 单条记录请求：完整请求 target（含 query）+ Cookie 请求行（无则 None；
/// 按行大小写不敏感提取——E2E 断言「请求头携带预期域 JS cookie」的数据源）
#[derive(Debug, Clone)]
struct RecordedRequest {
    target: String,
    /// E2E 断言数据源（quickjs 档）；默认档不读（RecordingServer 两档
    /// 一致记录保持结构形态相同）
    #[cfg_attr(not(feature = "quickjs"), allow(dead_code))]
    cookie: Option<String>,
}

/// 记录型夹具服务器：投递固定目录响应，并记录全部请求 target（含 query）
/// 与 Cookie 请求行
struct RecordingServer {
    port: u16,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
}

fn spawn_recording_server() -> RecordingServer {
    let requests: Arc<Mutex<Vec<RecordedRequest>>> = Arc::default();
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 记录型夹具服务器");
    let port = listener.local_addr().unwrap().port();
    let reqs = Arc::clone(&requests);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            handle_conn(&mut stream, &reqs);
        }
    });
    RecordingServer { port, requests }
}

fn handle_conn(stream: &mut TcpStream, requests: &Arc<Mutex<Vec<RecordedRequest>>>) {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    // 读请求头（到空行为止）
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut byte) {
            Ok(1) => buf.push(byte[0]),
            _ => return,
        }
        if buf.len() > 16 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    // 完整请求 target（含 query）——断言「请求 URL == 传入 TOC URL」的关键
    let target = head
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    // Cookie 请求行（按行大小写不敏感匹配：reqwest 发 "Cookie"，源 header
    // 小写 "cookie" 变体同样要能记录）
    let cookie = head.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("cookie")
            .then(|| value.trim().to_string())
    });
    requests.lock().unwrap().push(RecordedRequest {
        target: target.clone(),
        cookie,
    });

    let path_only = target.split('?').next().unwrap_or("/").to_string();
    let (status, body) = match path_only.as_str() {
        // 目录页：3 章 + nextPage（旧代码二次重推会去抓的次级地址）
        "/all-chapter" => (
            200,
            r#"{"rows":[{"title":"第一章","url":"/c/1"},{"title":"第二章","url":"/c/2"},{"title":"第三章","url":"/c/3"}],"nextPage":"/toc/page2"}"#
                .as_bytes()
                .to_vec(),
        ),
        // 重推目标页（旧代码 tocUrl 规则重推后会抓这里）：空 rows → 0 章
        "/toc/page2" => (200, r#"{"rows":[]}"#.as_bytes().to_vec()),
        // 目录内嵌详情页：目录体与详情体是同一份 body（无独立目录页的源，
        // 如传详情 URL 当已知目录页地址直抓 → ruleToc 直接出章）
        "/detail" => (
            200,
            r#"{"rows":[{"title":"第一章","url":"/c/1"},{"title":"第二章","url":"/c/2"},{"title":"第三章","url":"/c/3"}]}"#
                .as_bytes()
                .to_vec(),
        ),
        _ => (404, b"not found".to_vec()),
    };
    let resp = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.write_all(&body);
    let _ = stream.flush();
}

/// 回归断言：入参为已解析目录页时——恰好 1 次请求打到该目录页（无二次
/// 重推 tocUrl），解析出 3 章，章节 URL 基于目录页地址绝对化。
#[tokio::test]
async fn get_chapters_with_vars_fetches_passed_toc_url_without_rederive() {
    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);

    // 目录体上没有 data.bookInfo（init 求值空）但有 nextPage（tocUrl 规则
    // 可重推出次级地址）——正是旧代码会触发「二次重推」的形态
    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "toc-no-rederive-fixture".into(),
        rule_book_info: Some(BookInfoRule {
            init: Some("$.data.bookInfo".into()),
            toc_url: Some("$.nextPage".into()),
            ..Default::default()
        }),
        rule_toc: Some(TocRule {
            chapter_list: Some("$.rows[*]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let mut vars = HashMap::new();
    vars.insert("bookId".to_string(), "1100468021".to_string());

    let chapters = fetcher
        .get_chapters_with_vars(
            &source,
            &format!("{base}/all-chapter?bookId={{bookId}}"),
            &vars,
        )
        .await
        .expect("get_chapters_with_vars 不应失败");

    // 1) 请求 target == 传入 TOC URL（变量展开后），且恰好 1 次请求。
    //    HTTP/1.1 同源请求 reqwest 发 origin-form（`/path?query`）；剥掉
    //    base 前缀归一化后对两种 form 都成立。
    let requests: Vec<String> = server
        .requests
        .lock()
        .unwrap()
        .iter()
        .map(|r| {
            r.target
                .strip_prefix(&base)
                .unwrap_or(r.target.as_str())
                .to_string()
        })
        .collect();
    assert_eq!(
        requests,
        vec!["/all-chapter?bookId=1100468021".to_string()],
        "应恰好一次请求且打到传入的目录页（不得「抓详情 → 重推 tocUrl」二次请求）: {requests:?}"
    );

    // 2) 章节数
    assert_eq!(chapters.len(), 3, "应解析出 3 章: {chapters:?}");

    // 3) 章节 URL 基于传入 TOC 页地址绝对化
    assert_eq!(chapters[0].title, "第一章");
    assert_eq!(chapters[0].url, format!("{base}/c/1"));
    assert_eq!(chapters[2].url, format!("{base}/c/3"));
}

// ─── [回归 P2-1 2026-09-17] 已知目录页路径 loginCheckJs 检测 ────────────────
//
// 新路径（方案 A）此前取目录体后直接解析、未跑 execute_login_check；
// 上游 WebBook.kt:346-352 顺序为 get response → login check → parse
// （旧详情路径均有）。`login_check_js="false"` 且目录体含章节的需登录源
// 会错误地直接返回目录（23/526 源受影响）。

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn known_toc_login_check_js_blocks_when_not_logged_in() {
    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);

    // loginCheckJs 恒判「未登录」（eval 返回 false）→ 语义须与详情路径一致：
    // 二次 errResponse 评估后仍 NotLoggedIn → Err(LoginRequired)，不返回章节
    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "toc-login-check-fixture".into(),
        login_check_js: Some("false".into()),
        rule_toc: Some(TocRule {
            chapter_list: Some("$.rows[*]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let vars = HashMap::new();
    let err = fetcher
        .get_chapters_with_vars(&source, &format!("{base}/all-chapter"), &vars)
        .await
        .expect_err("loginCheckJs 判定未登录应报错（目录体有章节也不应放行）");

    assert!(
        matches!(err, legado_core::LegadoError::LoginRequired(_)),
        "应为登录失败错误（与详情路径 LoginRequired 语义一致）: {err}"
    );
}

/// 非 quickjs 构建：loginCheckJs 静默降级跳过（execute_login_check_js 为
/// no-op stub）——与同构建详情路径行为一致，目录正常解析。
#[cfg(not(feature = "quickjs"))]
#[tokio::test]
async fn known_toc_login_check_js_degrades_without_quickjs() {
    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);

    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "toc-login-check-degrade-fixture".into(),
        login_check_js: Some("false".into()),
        rule_toc: Some(TocRule {
            chapter_list: Some("$.rows[*]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let vars = HashMap::new();
    let chapters = fetcher
        .get_chapters_with_vars(&source, &format!("{base}/all-chapter"), &vars)
        .await
        .expect("非 quickjs 构建 loginCheckJs 降级为 no-op，应正常返回目录");
    assert_eq!(chapters.len(), 3, "降级后目录解析不受影响: {chapters:?}");
}

// ─── [回归 P2-2 2026-09-17] 书名 hint 注入 @js: chapterList 规则 ───────────
//
// 上游 BookChapterList.kt:196 以 `AnalyzeRule(book, bookSource)` 构建解析器，
// `@js:[{title: book.name, url: …}]` 类 ruleToc.chapterList 规则可读
// book.name。已知目录页直抓路径不抓详情页：无 hint 时 book 绑定 name 为
// 空 → 标题退化（SiS文學網简体 / 51漫画 / HentaiCosplay / AsianPornImage）。

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn known_toc_js_chapter_list_reads_book_name_hint() {
    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);

    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "toc-book-name-hint-fixture".into(),
        rule_toc: Some(TocRule {
            chapter_list: Some("@js:[{title: book.name, url: '/c/1'}]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let vars = HashMap::new();

    // hint 存在：章节标题 = 详情步解析出的书名
    let chapters = fetcher
        .get_chapters_with_vars_and_name_hint(
            &source,
            &format!("{base}/all-chapter"),
            &vars,
            Some("测试书名"),
        )
        .await
        .expect("hint 路径不应失败");
    assert_eq!(chapters.len(), 1, "JS 数组展开为单章: {chapters:?}");
    assert_eq!(chapters[0].title, "测试书名", "book.name 应取 hint 值");
    assert_eq!(chapters[0].url, format!("{base}/c/1"));

    // hint 为 None：维持既有行为（book.name 为空 → 标题退化「无标题」，
    // URL 非空故章节保留）——默认 trait 实现与旧路径行为不变
    let chapters = fetcher
        .get_chapters_with_vars_and_name_hint(&source, &format!("{base}/all-chapter"), &vars, None)
        .await
        .expect("无 hint 路径不应失败");
    assert_eq!(chapters.len(), 1, "无 hint 时章节保留: {chapters:?}");
    assert_eq!(
        chapters[0].title, "无标题",
        "无 hint 时 book.name 为空 → 无标题"
    );
}

// ─── [回归 2026-09-17] 目录内嵌详情页：传详情 URL 当已知目录页直抓 ─────────

/// 目录内嵌详情页的源（`ruleBookInfo.tocUrl` 空/缺失，目录体即详情体）：
/// 入参传详情页 URL 时，新契约下 ruleToc 直接在传入 body 上出章（> 0），
/// 且仅 1 次请求打到该 URL（无二次重推）。
#[tokio::test]
async fn toc_embedded_in_detail_page_url() {
    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);

    // 不设 rule_book_info：目录与详情同体（源无独立目录页）
    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "toc-embedded-detail-fixture".into(),
        rule_toc: Some(TocRule {
            chapter_list: Some("$.rows[*]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let chapters = fetcher
        .get_chapters_with_vars(&source, &format!("{base}/detail"), &HashMap::new())
        .await
        .expect("目录内嵌详情页：传详情 URL 应直接出章");
    assert!(
        !chapters.is_empty(),
        "详情 body 上 ruleToc 应解析出章节: {chapters:?}"
    );

    // 恰好 1 次请求且打到详情 URL 本身
    let requests: Vec<String> = server
        .requests
        .lock()
        .unwrap()
        .iter()
        .map(|r| {
            r.target
                .strip_prefix(&base)
                .unwrap_or(r.target.as_str())
                .to_string()
        })
        .collect();
    assert_eq!(
        requests,
        vec!["/detail".to_string()],
        "应恰好一次请求且打到传入的详情/目录 URL: {requests:?}"
    );
}

// ─── [P2-19 E2E 2026-09-23] 请求头携带预期域 JS cookie（不变式端到端化）──
//
// 记录型夹具服务器现在同时记录每个请求的 Cookie 请求行，可端到端断言：
// 1. fetch_page 路径（search）的请求携带请求域（127.0.0.1）的 JS cookie；
// 2. fetch_simple_cached 路径（目录 nextTocUrl 分页）的请求同样携带
//    请求域的 JS cookie（此前该路径漏注入 → 分页请求丢 cookie 的回归）；
// 3. 不变式：异域 JS cookie 绝不出现在 127.0.0.1 请求头（P2-19）。
//
// quickjs 门控：跨路径共享 127.0.0.1 域键依赖 ETLD+1 归一（IP 字面量
// 自键，写 /all-chapter 与读 /toc/page2 均归一到 127.0.0.1）；默认档
// raw 串自键只能命中同串 → 跨路径必 miss，本组断言仅在 quickjs 档成立。
// 持 `lock_global_store()` 与本 crate P2-19 测试组（共享全局 cookie store
// 的 127.0.0.1 键）串行。

/// 异域 JS cookie 键（域 e2e-iso.com.cn；127.0.0.1 请求头必须不含它）
#[cfg(feature = "quickjs")]
const FOREIGN: &str = "https://www.f.e2e-iso.com.cn/";

/// 清全局 cookie store 中本组测试可能占用的键（write 键 / IP 自键 /
/// 异域两种归一形态），开/关各清一次防测试间串键。
#[cfg(feature = "quickjs")]
fn clear_e2e_cookie_keys(write_url: &str) {
    use legado_js::host_api::cookie_store;
    cookie_store::clear_cookies(write_url);
    cookie_store::clear_cookies("127.0.0.1");
    cookie_store::clear_cookies(FOREIGN);
    cookie_store::clear_cookies("e2e-iso.com.cn");
}

/// E2E ① fetch_page 路径：search 请求头携带请求域 JS cookie，且不含异域 cookie。
/// 测试锁语义：`lock_global_store()` 必须覆盖「写 → 请求 → 断言 → 清理」整段
///（防并行用例途中抹掉对方键）；该 await 是本地回环 RecordingServer 请求，
/// 测试锁为进程级串行而非生产锁，故显式 allow。
#[cfg(feature = "quickjs")]
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn e2e_fetch_page_path_carries_request_domain_js_cookie() {
    let _lock = crate::test_support::lock_global_store();
    use legado_js::host_api::cookie_store;

    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);
    let write_url = format!("{base}/all-chapter");
    clear_e2e_cookie_keys(&write_url);
    // JS 写请求域 cookie（quickjs 档归一为 IP 自键 127.0.0.1）+ 异域 cookie
    cookie_store::set_cookie(&write_url, "p219_e2e", "e2e-val-7c41");
    cookie_store::set_cookie(FOREIGN, "p219_foreign", "foreign-val-0a1b");

    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "p219-e2e-fetch-page-fixture".into(),
        search_url: Some(write_url.clone()),
        rule_search: Some(SearchRule {
            book_list: Some("$.rows[*]".into()),
            name: Some(".title".into()),
            book_url: Some(".url".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let books = fetcher
        .search(&source, "k", 1)
        .await
        .expect("search 不应失败");
    assert_eq!(books.len(), 3, "夹具应出 3 本: {books:?}");

    // fetch_page 路径请求（target /all-chapter）头携带请求域 JS cookie
    let reqs = server.requests.lock().unwrap();
    let req = reqs
        .iter()
        .find(|r| {
            r.target
                .strip_prefix(&base)
                .unwrap_or(r.target.as_str())
                .starts_with("/all-chapter")
        })
        .expect("search 应向 /all-chapter 发请求");
    let cookie = req.cookie.clone().expect("请求头应携带 Cookie 行");
    assert!(
        cookie.contains("p219_e2e=e2e-val-7c41"),
        "fetch_page 路径请求应携带请求域 JS cookie，实际: {cookie}"
    );
    assert!(
        !cookie.contains("p219_foreign"),
        "异域 JS cookie 不得出现在请求头（P2-19 不变式），实际: {cookie}"
    );

    clear_e2e_cookie_keys(&write_url);
}

/// E2E ② fetch_simple_cached 路径：目录 nextTocUrl 分页请求头携带请求域
/// JS cookie（改前该路径漏注入 → 本用例必红），且不含异域 cookie
#[cfg(feature = "quickjs")]
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn e2e_fetch_simple_cached_path_carries_request_domain_js_cookie() {
    let _lock = crate::test_support::lock_global_store();
    use legado_js::host_api::cookie_store;

    let server = spawn_recording_server();
    let base = format!("http://127.0.0.1:{}", server.port);
    let write_url = format!("{base}/all-chapter");
    clear_e2e_cookie_keys(&write_url);
    cookie_store::set_cookie(&write_url, "p219_e2e2", "e2e2-val-3d58");
    cookie_store::set_cookie(FOREIGN, "p219_foreign", "foreign-val-0a1b");

    let source = BookSource {
        book_source_url: base.clone(),
        book_source_name: "p219-e2e-simple-cached-fixture".into(),
        rule_toc: Some(TocRule {
            chapter_list: Some("$.rows[*]".into()),
            chapter_name: Some(".title".into()),
            chapter_url: Some(".url".into()),
            next_toc_url: Some("$.nextPage".into()),
            ..Default::default()
        }),
        ..BookSource::default()
    };

    let fetcher = RealBookSourceFetcher::new().expect("real fetcher");
    let chapters = fetcher
        .get_chapters_with_vars(&source, &write_url, &HashMap::new())
        .await
        .expect("get_chapters_with_vars 不应失败");
    // page1 3 章 + page2（nextPage）空 rows → 共 3 章
    assert_eq!(chapters.len(), 3, "应解析出 3 章: {chapters:?}");

    // fetch_simple_cached 路径请求（nextTocUrl 分页 /toc/page2）头携带请求域 JS cookie
    let reqs = server.requests.lock().unwrap();
    let req = reqs
        .iter()
        .find(|r| {
            r.target
                .strip_prefix(&base)
                .unwrap_or(r.target.as_str())
                .starts_with("/toc/page2")
        })
        .expect("nextTocUrl 分页应向 /toc/page2 发请求");
    let cookie = req.cookie.clone().expect("分页请求头应携带 Cookie 行");
    assert!(
        cookie.contains("p219_e2e2=e2e2-val-3d58"),
        "fetch_simple_cached 路径请求应携带请求域 JS cookie，实际: {cookie}"
    );
    assert!(
        !cookie.contains("p219_foreign"),
        "异域 JS cookie 不得出现在请求头（P2-19 不变式），实际: {cookie}"
    );

    clear_e2e_cookie_keys(&write_url);
}
