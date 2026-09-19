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

#![cfg(test)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

use crate::api::web_book::RealBookSourceFetcher;
use legado_core::models::book_source::BookSource;
use legado_core::models::rule::{BookInfoRule, TocRule};
use legado_core::web_book::BookSourceFetcher;

/// 记录型夹具服务器：投递固定目录响应，并记录全部请求 target（含 query）
struct RecordingServer {
    port: u16,
    requests: Arc<Mutex<Vec<String>>>,
}

fn spawn_recording_server() -> RecordingServer {
    let requests: Arc<Mutex<Vec<String>>> = Arc::default();
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

fn handle_conn(stream: &mut TcpStream, requests: &Arc<Mutex<Vec<String>>>) {
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
    requests.lock().unwrap().push(target.clone());

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
#[ignore = "requires network access"]
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
        .map(|t| t.strip_prefix(&base).unwrap_or(t.as_str()).to_string())
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
#[ignore = "requires network access"]
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
#[ignore = "requires network access"]
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
        .map(|t| t.strip_prefix(&base).unwrap_or(t.as_str()).to_string())
        .collect();
    assert_eq!(
        requests,
        vec!["/detail".to_string()],
        "应恰好一次请求且打到传入的详情/目录 URL: {requests:?}"
    );
}
