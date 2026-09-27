//! [B-11 回归测试 | 2026-09-28] 目录分页经重定向后，相对链接绝对化必须用最终 URL
//!
//! 历史登记（Active 计划·第三阶段）：「B-11（分页绝对化基准应用最终 URL，
//! 需重定向 mock 复现）」。本测试原为 STAGE3-VERIFY 红复现（exit 101，
//! total=20 且 /toc/page2.html 被请求），B-11 修复后收编为正式回归测试
//! （GREEN 基线）。
//!
//! 场景：目录首抓页请求后 302 重定向到最终地址；最终页的 nextTocUrl 是
//! **相对链接**。按原版语义（WebBook.kt:357 `redirectUrl = res.url` →
//! AnalyzeRule.kt:283/375 绝对化用 redirectUrl），相对 nextTocUrl 必须基于
//! **重定向后最终 URL** 解析。
//!
//! 修复（web_book.rs，B-11）：
//! - 目录首抓页抓取点（fetch_known_toc_body / fetch_detail_and_derive_toc_body
//!   / get_chapters_from_known_toc_and_vars_with_hint）由 `fetch_url` 改
//!   `fetch_page`，将 `FetchedPage.final_url` 一路贯通至
//!   parse_chapters_from_toc_body 新参数 `toc_final_url`；
//! - 首抓页分析器 redirect 基准 = 重定向后最终 URL（对齐 WebBook.kt:357），
//!   相对章节链接绝对化 / 空 URL 回退 / nextTocUrl 去重过滤 / visited 种子
//!   均以最终 URL 为基准；
//! - **串行后续页保持请求 URL 基准不变**（对齐 BookChapterList.kt:83
//!   `(nextUrl, nextUrl)` 语义；任务书明示保留，与核验报告「串行页也统一
//!   用最终 URL」的建议有意不采纳）；
//! - 并发分支 base=请求 URL、redirect=该页响应最终 URL（对齐 BookChapterList
//!   并发 `(urlStr, res.url)`）；缓存命中页无响应对象，回退请求 URL。
//!
//! mock 拓扑（重定向目标在**更深一层目录**，使两种基准解析出不同 URL）
//! —— 收编后必须保留：
//! - GET /book/1            → 详情页（toc-start → /toc/entry）
//! - GET /toc/entry         → 302 Location: /toc/v2/index.html（最终地址，目录深一层）
//! - GET /toc/v2/index.html → 20 章 + <a class="next" href="page2.html">（相对！）
//! - GET /toc/v2/page2.html → 20 章（正确基准应请求到这里，共 40 章）
//! - GET /toc/page2.html    → 404（错误基准「请求 URL /toc/entry」会解析到这里）
//!
//! 判别力保留：修复前 RED（total=20、/toc/page2.html 被请求，exit 101）；
//! 修复后 GREEN（total=40、/toc/v2/page2.html=1、/toc/page2.html=0）。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex, MutexGuard, Once};

use legado_ffi::legado_core::models::Book;
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::BookRepository;

static TEST_LOCK: Mutex<()> = Mutex::new(());
static ENV_INIT: Once = Once::new();

fn lock_test() -> MutexGuard<'static, ()> {
    TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    legado_ffi::http_state::reset_shared_client();
}

/// 每页章节数（断言总章数 = 2 页 × 20）
const CH_PER_PAGE: usize = 20;

type Hits = Arc<Mutex<HashMap<String, u32>>>;

/// 多连接 mock 服务器（每连接一线程，与 toc_refresh_perf.rs 同纪律）
fn spawn_redirect_toc_server() -> (u16, Hits) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 mock 服务器");
    let port = listener.local_addr().expect("取端口").port();
    let hits: Hits = Arc::new(Mutex::new(HashMap::new()));
    let listener = std::sync::Arc::new(listener);
    let handle_conn_hits = Arc::clone(&hits);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut s) = stream else { continue };
            let hits = Arc::clone(&handle_conn_hits);
            std::thread::spawn(move || {
                handle_conn(&mut s, &hits);
            });
        }
    });
    (port, hits)
}

fn page_html(page_key: &str, next_link: Option<&str>) -> String {
    let mut s = String::from("<html><body><div id=\"list-chapterAll\">");
    for i in 0..CH_PER_PAGE {
        s.push_str(&format!(
            "<div class=\"chapter-item\"><a href=\"/ch/{page_key}-{i}\">第{page_key}_{i}章</a></div>"
        ));
    }
    s.push_str("</div>");
    if let Some(link) = next_link {
        // 相对链接：正确的解析基准（重定向后最终 URL /toc/index.html）应拼出
        // /toc/page2.html；错误基准（重定向前请求 URL /toc/entry）拼出 /page2.html
        s.push_str(&format!("<a class=\"next\" href=\"{link}\">下一页</a>"));
    }
    s.push_str("</body></html>");
    s
}

fn route(path: &str) -> (u16, Vec<(&'static str, String)>, String) {
    let ok = |body: String| {
        (
            200u16,
            vec![("Content-Type", "text/html; charset=utf-8".into())],
            body,
        )
    };
    match path {
        "/book/1" => ok("<html><body><h1 class=\"bookname\">B-11 重定向复现书</h1>\
             <a class=\"toc-start\" href=\"/toc/entry\">目录</a></body></html>"
            .into()),
        // 首抓页请求后 302 → 最终地址 /toc/v2/index.html（更深一层目录）
        "/toc/entry" => (
            302,
            vec![("Location", "/toc/v2/index.html".into())],
            String::new(),
        ),
        "/toc/v2/index.html" => ok(page_html("p1", Some("page2.html"))),
        "/toc/v2/page2.html" => ok(page_html("p2", None)),
        _ => (404, vec![], "not found".into()),
    }
}

fn handle_conn(stream: &mut std::net::TcpStream, hits: &Hits) {
    let mut buf = Vec::new();
    let mut one = [0u8; 1];
    // 读完整请求头（到空行）：防 Windows RST flaky（与 toc_refresh_perf 同注释）
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut one) {
            Ok(1) => buf.push(one[0]),
            _ => return,
        }
        if buf.len() > 16 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .split('?')
        .next()
        .unwrap_or("/")
        .to_string();

    let (status, headers, body) = route(&path);
    {
        let mut h = hits.lock().unwrap();
        *h.entry(path).or_insert(0) += 1;
    }
    let reason = match status {
        200 => "OK",
        302 => "Found",
        _ => "Not Found",
    };
    let mut resp = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (k, v) in &headers {
        resp.push_str(&format!("{k}: {v}\r\n"));
    }
    resp.push_str("\r\n");
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

#[test]
fn redirected_toc_pagination_resolves_next_page_against_final_url() {
    let _lock = lock_test();
    ENV_INIT.call_once(setup_env);

    let (port, hits) = spawn_redirect_toc_server();
    let source_url = format!("http://127.0.0.1:{port}/src");
    let book_url = format!("http://127.0.0.1:{port}/book/1");

    // 书源规则纯 CSS（无 JS）：两档 feature 行为一致
    let source_json = format!(
        r#"{{"bookSourceUrl":"{source_url}","bookSourceName":"B-11 重定向复现源","ruleBookInfo":{{"name":"h1.bookname@text","tocUrl":"class.toc-start@href"}},"ruleToc":{{"chapterList":"class.chapter-item","chapterName":"tag.a@text","chapterUrl":"tag.a@href","nextTocUrl":"class.next@href"}}}}"#
    );
    legado_ffi::api::source::add_source(&source_json).expect("夹具书源写入");

    // 书行（toc_url 空 → 刷新走详情页路径推导目录地址 /toc/entry）
    let book = Book {
        book_url: book_url.clone(),
        origin: source_url.clone(),
        origin_name: "B-11 重定向复现源".to_string(),
        ..Book::default()
    };
    legado_ffi::db_state::with_database(|db| BookRepository::new(db.connection()).insert(&book))
        .expect("书行写入");

    let resp = legado_ffi::api::reader::refresh_toc(&book_url, &source_url)
        .expect("刷新目录不应整体失败（分页 404 按 body-null 语义截断保留前缀）");

    let hits = hits.lock().unwrap();
    let get = |p: &str| hits.get(p).copied().unwrap_or(0);

    // 请求轨迹证据（无论红绿都打印，供报告引用）
    eprintln!("[p3verify-b11] total={} /toc/entry={} /toc/v2/index.html={} /toc/v2/page2.html={} /toc/page2.html={}",
        resp.total, get("/toc/entry"), get("/toc/v2/index.html"), get("/toc/v2/page2.html"), get("/toc/page2.html"));

    // 断言 1（缺陷形态为 RED）：相对 nextTocUrl 应基于重定向后最终 URL 绝对化
    // → 第 2 页可抓到，总计 40 章
    assert_eq!(
        resp.total as usize,
        2 * CH_PER_PAGE,
        "B-11 复现：重定向后相对 nextTocUrl 应基于最终 URL（http://127.0.0.1:{port}/toc/v2/index.html）解析，期望抓满 2 页共 {} 章，实际 {} 章",
        2 * CH_PER_PAGE,
        resp.total
    );
    // 断言 2：正确基准 → 请求 /toc/v2/page2.html
    assert_eq!(
        get("/toc/v2/page2.html"),
        1,
        "第 2 页应请求 /toc/v2/page2.html（相对链接 page2.html 基于重定向后最终 URL 解析）"
    );
    // 断言 3：错误基准（重定向前请求 URL /toc/entry 的目录 /toc/）→ 会拼出 /toc/page2.html
    assert_eq!(
        get("/toc/page2.html"),
        0,
        "不得基于重定向前的请求 URL（/toc/entry）解析出 /toc/page2.html"
    );
}
