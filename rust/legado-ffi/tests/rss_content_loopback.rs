//! 批15c：RSS 正文规则 + 正文分页 + 写回 回环端到端用例
//!
//! 独立测试二进制（独立进程，`db_open` 只初始化一次）。覆盖：
//!
//! ```text
//! 规则正文源（ruleContent / nextContentUrl）
//!   → rssRefreshArticles 落库文章行
//!   → rssFetchContent：首屏 + 单链第 2 页 "\n" 拼接
//!   → 写回 rssArticles.description（REPLACE 保留其余字段）
//!   → 已收藏行同步写回 rssStars.description
//!   → sort 参数定位主键（sort="" 与 refresh 写入一致）
//! 登录源
//!   → loginCheckJs 改写正文页响应（首屏成功响应检测）
//!   → 文章不在库时仍返回正文，仅跳过写回
//! 错误/空正文
//!   → 首屏 HTTP 500 → Err
//!   → 规则无匹配 → Ok("")，描述写回空串
//! ```

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// 列表页：1 篇文章 `/a/1`
const LIST_BODY: &str = r#"<html><body>
<div class="item"><h2 class="title">正文测试文章</h2><a class="link" href="/a/1">一</a></div>
</body></html>"#;

/// 正文第 1 页：有正文 + 下一页 `/a/2`
const CONTENT_P1: &str = r#"<html><body>
<div class="content">第一页正文</div>
<a class="next" href="/a/2">下一页</a>
</body></html>"#;

/// 正文第 2 页：有正文、无下一页
const CONTENT_P2: &str = r#"<html><body>
<div class="content">第二页正文</div>
</body></html>"#;

/// 请求目标（`path?query`）→ `(状态行, 正文)`
type Routes = Arc<dyn Fn(&str) -> (String, String) + Send + Sync>;

/// 回环服务器句柄（循环 accept + 每连接独立线程 + Drop 关闭）
struct LoopbackServer {
    addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl LoopbackServer {
    fn spawn(routes: Routes) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let addr = listener.local_addr().expect("读取端口");
        let shutdown = Arc::new(AtomicBool::new(false));
        let shutdown_thread = Arc::clone(&shutdown);
        let handle = std::thread::spawn(move || {
            while !shutdown_thread.load(Ordering::SeqCst) {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                if shutdown_thread.load(Ordering::SeqCst) {
                    break;
                }
                let routes = Arc::clone(&routes);
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
                    let (status, body) = routes(&target);
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
            shutdown,
            handle: Some(handle),
        }
    }

    fn base_url(&self) -> String {
        format!("http://{}", self.addr)
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

fn temp_db_path() -> std::path::PathBuf {
    let path =
        std::env::temp_dir().join(format!("legado-ffi-rss-content-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

fn add_source(source_url: &str, extra: serde_json::Value) {
    let mut source = serde_json::json!({
        "sourceUrl": source_url,
        "sourceName": "批15c 正文回环源",
        "enabled": true,
    });
    if let (Some(obj), Some(extra_obj)) = (source.as_object_mut(), extra.as_object()) {
        for (k, v) in extra_obj {
            obj.insert(k.clone(), v.clone());
        }
    }
    legado_ffi::api::rss::add_rss_source(&source.to_string()).expect("写入 RSS 源");
}

fn decode(json: &str) -> serde_json::Value {
    serde_json::from_str(json).expect("解析 JSON 载荷")
}

/// 直连 DB 读文章描述（覆盖「空串写回」与「未写回」两态）
fn article_description(db_path: &Path, origin: &str, link: &str) -> Option<String> {
    let conn = rusqlite::Connection::open(db_path).expect("直连临时 DB");
    conn.query_row(
        "SELECT description FROM rssArticles WHERE origin = ?1 AND link = ?2",
        rusqlite::params![origin, link],
        |row| row.get::<_, Option<String>>(0),
    )
    .ok()
    .flatten()
}

/// 直连 DB 读收藏描述
fn star_description(db_path: &Path, origin: &str, link: &str) -> Option<String> {
    let conn = rusqlite::Connection::open(db_path).expect("直连临时 DB");
    conn.query_row(
        "SELECT description FROM rssStars WHERE origin = ?1 AND link = ?2",
        rusqlite::params![origin, link],
        |row| row.get::<_, Option<String>>(0),
    )
    .ok()
    .flatten()
}

#[test]
fn rss_content_pagination_writeback_and_login_end_to_end() {
    let db_path = temp_db_path();
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");

    let routes: Routes = Arc::new(|target: &str| match target {
        "/feed" => ("200 OK".to_string(), LIST_BODY.to_string()),
        "/a/1" => ("200 OK".to_string(), CONTENT_P1.to_string()),
        "/a/2" => ("200 OK".to_string(), CONTENT_P2.to_string()),
        "/login/a" => (
            "200 OK".to_string(),
            "<html><body>未登录</body></html>".to_string(),
        ),
        "/bad" => ("500 Internal Server Error".to_string(), "boom".to_string()),
        "/empty" => (
            "200 OK".to_string(),
            "<html><body>没有正文节点</body></html>".to_string(),
        ),
        "/empty-feed" => (
            "200 OK".to_string(),
            "<html><body><div class=\"item\"><h2 class=\"title\">空正文文章</h2>\
             <a class=\"link\" href=\"/empty\">一</a></div></body></html>"
                .to_string(),
        ),
        _ => ("404 Not Found".to_string(), String::new()),
    });
    let server = LoopbackServer::spawn(routes);
    let base = server.base_url();

    // ─── 1) 正文源 + 列表落库（文章行是写回目标） ───────────────────
    let source_url = format!("{base}/feed");
    add_source(
        &source_url,
        serde_json::json!({
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
            "ruleContent": ".content",
            "nextContentUrl": ".next@href",
        }),
    );
    let page = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&source_url, "", &source_url, None)
            .expect("刷新列表"),
    );
    let link = page["articles"][0]["link"]
        .as_str()
        .expect("文章 link")
        .to_string();
    assert_eq!(link, format!("{base}/a/1"));
    assert!(
        article_description(&db_path, &source_url, &link).is_none(),
        "刷新列表后文章描述应为 NULL（正文尚未抓取）"
    );

    // 收藏同一篇：正文成功后应同步写回 rssStars.description
    legado_ffi::api::rss_star_api::add_rss_star(&source_url, "正文测试文章", &link)
        .expect("添加收藏");

    // ─── 2) 正文抓取：首屏 + 单链第 2 页，"\n" 拼接 ────────────────
    let content =
        legado_ffi::api::rss::rss_fetch_content(&source_url, &link, None).expect("抓取正文");
    assert_eq!(content, "第一页正文\n第二页正文");

    // ─── 3) 写回断言：文章 + 收藏 ─────────────────────────────────
    assert_eq!(
        article_description(&db_path, &source_url, &link).as_deref(),
        Some("第一页正文\n第二页正文"),
        "正文成功后应写回 rssArticles.description"
    );
    assert_eq!(
        star_description(&db_path, &source_url, &link).as_deref(),
        Some("第一页正文\n第二页正文"),
        "已收藏行应同步写回 rssStars.description"
    );

    // ─── 3.5) sort 参数：refresh 写入 sort=""，按主键定位命中 ──────
    let with_sort = legado_ffi::api::rss::rss_fetch_content(&source_url, &link, Some(""))
        .expect("按 sort 抓取正文");
    assert_eq!(with_sort, "第一页正文\n第二页正文");
    // 不匹配的 sort 不命中文章行：仍返回正文，但不会改动该行描述
    let other_sort = legado_ffi::api::rss::rss_fetch_content(&source_url, &link, Some("不存在"))
        .expect("sort 不匹配仍可抓取");
    assert_eq!(other_sort, "第一页正文\n第二页正文");
    assert_eq!(
        article_description(&db_path, &source_url, &link).as_deref(),
        Some("第一页正文\n第二页正文"),
        "sort 不匹配时跳过写回，旧描述保持"
    );

    // ─── 4) loginCheckJs：正文页成功响应经检测后采用改写结果 ────────
    let login_url = format!("{base}/login");
    add_source(
        &login_url,
        serde_json::json!({
            "ruleContent": ".content",
            "loginCheckJs": "(function(){ if (result.body().indexOf('未登录') >= 0) return { code: 200, body: '<html><body><div class=\\\"content\\\">登录后正文</div></body></html>', url: result.url() }; return result; })()",
        }),
    );
    let login_link = format!("{base}/login/a");
    let login_content = legado_ffi::api::rss::rss_fetch_content(&login_url, &login_link, None)
        .expect("loginCheckJs 改写正文");
    assert_eq!(login_content, "登录后正文");
    // 文章行不存在（未刷新列表）→ 跳过写回、不新建行
    assert!(
        article_description(&db_path, &login_url, &login_link).is_none(),
        "文章不在库时不得写入新行"
    );

    // ─── 5) 首屏失败 → Err（无部分返回） ──────────────────────────
    let bad_link = format!("{base}/bad");
    let err = legado_ffi::api::rss::rss_fetch_content(&source_url, &bad_link, None)
        .expect_err("首屏 500 应报错");
    assert!(format!("{err}").contains("HTTP 500"), "{err}");

    // ─── 6) 规则无匹配 → Ok("")，描述写回空串 ─────────────────────
    let empty_url = format!("{base}/empty-feed");
    add_source(
        &empty_url,
        serde_json::json!({
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
            "ruleContent": ".content",
        }),
    );
    let empty_page = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&empty_url, "", &empty_url, None)
            .expect("刷新空正文源列表"),
    );
    let empty_link = empty_page["articles"][0]["link"]
        .as_str()
        .expect("空正文文章 link")
        .to_string();
    let empty = legado_ffi::api::rss::rss_fetch_content(&empty_url, &empty_link, None)
        .expect("空正文不报错");
    assert_eq!(empty, "");
    assert_eq!(
        article_description(&db_path, &empty_url, &empty_link).as_deref(),
        Some(""),
        "空正文按原版写回空串（对齐 description = body）"
    );

    // ─── 清理 ────────────────────────────────────────────────────
    for url in [&source_url, &login_url, &empty_url] {
        let _ = legado_ffi::api::rss::delete_rss_source(url);
    }
    let _ = legado_ffi::api::rss_star_api::delete_rss_star(&link);
    let _ = std::fs::remove_file(&db_path);
}
