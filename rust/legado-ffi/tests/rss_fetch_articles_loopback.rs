//! 批15a：`fetch_rss_articles` 回环 HTTP 端到端用例
//!
//! 验证链（独立测试二进制 = 独立进程，`db_open` 只初始化一次）：
//!
//! ```text
//! ffi::init + ffi::db_open(临时 DB)
//!   → add_rss_source（静态 header + enabledCookieJar）
//!   → fetch_rss_articles(回环 /feed)
//!       ├─ 断言：默认解析字段（title/link/description/content/pubDate/image）
//!       ├─ 断言：源 header 已透传、CookieJar 内部标记头未出网
//!       └─ 断言：真实落库（rusqlite 直连 rssArticles）
//!   → fetch_rss_articles(回环 /html)：解析 0 篇 → 空列表（**不再伪造单条摘要**）
//!   → fetch_rss_articles(回环 /empty)：响应体空 → 报错（对齐原版 body 空白抛错）
//!   → fetch_rss_articles(回环 /multi) 两次：
//!       ├─ 断言：多篇 `order` 严格递减（同次写入 now - i）
//!       └─ 断言：同 origin+link 二次拉取走 INSERT OR REPLACE（3 行进、3 行出、标题更新）
//! ```
//!
//! 原版对照：`Rss.getArticlesAwait` + `RssParserByRule.parseXML`
//! （`RssParserByRule.kt:32-41` body 空白抛错；`RssParserDefault.kt` 只认 item）。

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 回环服务器返回的标准 RSS 2.0（含封面图 / 正文 / 日期）
const RSS_BODY: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>回环频道</title>
    <link>http://127.0.0.1/</link>
    <item>
      <title>回环文章</title>
      <link>http://127.0.0.1/article/1</link>
      <description><![CDATA[<p>回环描述</p><img src="http://127.0.0.1/cover.jpg">]]></description>
      <content:encoded>回环正文</content:encoded>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>"#;

/// 多篇 feed 第一版（同一 `/multi` 路径首请求返回）
const RSS_MULTI_V1: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>多篇</title>
<item><title>第一篇</title><link>http://127.0.0.1/multi/1</link></item>
<item><title>第二篇</title><link>http://127.0.0.1/multi/2</link></item>
<item><title>第三篇</title><link>http://127.0.0.1/multi/3</link></item>
</channel></rss>"#;

/// 多篇 feed 第二版（同一 `/multi` 路径第二次请求返回）：
/// link（主键）不变、title 全部更新 → 验证 INSERT OR REPLACE 而非追加
const RSS_MULTI_V2: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>多篇</title>
<item><title>第一篇（更新）</title><link>http://127.0.0.1/multi/1</link></item>
<item><title>第二篇（更新）</title><link>http://127.0.0.1/multi/2</link></item>
<item><title>第三篇（更新）</title><link>http://127.0.0.1/multi/3</link></item>
</channel></rss>"#;

/// 临时 DB 路径（进程号后缀防并发二进制撞名；开头先清残留）
fn temp_db_path() -> std::path::PathBuf {
    let path =
        std::env::temp_dir().join(format!("legado-ffi-rss-loopback-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

/// 读取请求头（到 `\r\n\r\n` 为止）
fn read_request_head(stream: &mut std::net::TcpStream) -> String {
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

/// 回环服务器句柄（审查 P2-8：循环 accept + Drop 关闭，替代固定请求数）
///
/// 固定次数版本的隐患：断言提前失败时线程永久阻塞在 `accept`；重试逻辑
/// 多发一次请求时客户端挂起到超时。现改为句柄析构时关闭，且每个连接设
/// 读超时，请求数与断言解耦。
struct LoopbackServer {
    addr: SocketAddr,
    heads: Arc<Mutex<Vec<String>>>,
    shutdown: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl LoopbackServer {
    fn spawn() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let addr = listener.local_addr().expect("读取端口");
        let heads = Arc::new(Mutex::new(Vec::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let heads_thread = Arc::clone(&heads);
        let shutdown_thread = Arc::clone(&shutdown);

        let handle = std::thread::spawn(move || {
            // `/multi` 按请求顺序返回 v1 / v2（同源同 link，模拟 feed 更新）
            let mut multi_hits = 0usize;
            while !shutdown_thread.load(Ordering::SeqCst) {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                // Drop 唤醒连接：只看关闭标记，不读请求
                if shutdown_thread.load(Ordering::SeqCst) {
                    break;
                }
                let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                let head = read_request_head(&mut stream);
                if head.is_empty() {
                    continue;
                }
                let path = head
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or_default()
                    .to_string();
                let (status, body) = match path.as_str() {
                    "/feed" => ("200 OK", RSS_BODY),
                    "/multi" => {
                        let body = if multi_hits == 0 {
                            RSS_MULTI_V1
                        } else {
                            RSS_MULTI_V2
                        };
                        multi_hits += 1;
                        ("200 OK", body)
                    }
                    "/html" => ("200 OK", "<html><body>不是 feed</body></html>"),
                    "/empty" => ("200 OK", ""),
                    _ => ("404 Not Found", ""),
                };
                heads_thread.lock().unwrap().push(head);
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/rss+xml; charset=utf-8\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });

        Self {
            addr,
            heads,
            shutdown,
            handle: Some(handle),
        }
    }

    fn base_url(&self) -> String {
        format!("http://{}", self.addr)
    }

    /// 最早的请求头快照（`/feed` 首个请求）
    fn first_head(&self) -> String {
        self.heads
            .lock()
            .unwrap()
            .first()
            .cloned()
            .unwrap_or_default()
    }
}

impl Drop for LoopbackServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        // 唤醒阻塞在 accept 的线程（连接本身不读不写）
        let _ = TcpStream::connect(self.addr);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// 直接读 rssArticles（绕过仓储读路径，验证真实落库）
///
/// 返回 `(title, link, description, content, order)`，按 `order` 降序。
fn query_articles(db_path: &Path, origin: &str) -> Vec<(String, String, String, String, i64)> {
    let conn = rusqlite::Connection::open(db_path).expect("rusqlite 直连临时 DB");
    let mut stmt = conn
        .prepare(
            "SELECT title, link, COALESCE(description, ''), COALESCE(content, ''), \"order\" \
             FROM rssArticles WHERE origin = ?1 ORDER BY \"order\" DESC",
        )
        .expect("准备查询");
    stmt.query_map(rusqlite::params![origin], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })
    .expect("查询 rssArticles")
    .filter_map(|r| r.ok())
    .collect()
}

/// 追加一条 RSS 源（带自定义 header 与 CookieJar 门控）
fn add_source(source_url: &str, extra: serde_json::Value) {
    let mut source = serde_json::json!({
        "sourceUrl": source_url,
        "sourceName": "回环测试源",
        "enabled": true,
    });
    if let (Some(obj), Some(extra_obj)) = (source.as_object_mut(), extra.as_object()) {
        for (k, v) in extra_obj {
            obj.insert(k.clone(), v.clone());
        }
    }
    legado_ffi::api::rss::add_rss_source(&source.to_string()).expect("写入 RSS 源");
}

#[test]
fn fetch_rss_articles_loopback_end_to_end() {
    let db_path = temp_db_path();
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");

    let server = LoopbackServer::spawn();
    let base = server.base_url();

    // ---- 1) 真实 RSS：解析 + header 透传 + 落库 ----
    let feed_url = format!("{base}/feed");
    // 说明：小写 `proxy` 会被 AnalyzeUrl 提取为代理配置并真的走代理（该语义
    // 由 legado-fetcher `rss/request.rs` 的回环代理用例覆盖）；此处用大写
    // `Proxy` 验证「合并后大小写不敏感剔除」在 FFI 全链路同样生效。
    add_source(
        &feed_url,
        serde_json::json!({
            "enabledCookieJar": true,
            "header": "{\"X-Rss-Test\":\"1\",\"Proxy\":\"http://u:p@h:1\"}",
        }),
    );

    let articles = legado_ffi::api::rss::fetch_rss_articles(&feed_url).expect("拉取 RSS");
    assert_eq!(articles.len(), 1, "应解析出 1 篇: {articles:#?}");
    let article = &articles[0];
    assert_eq!(article.title, "回环文章");
    assert_eq!(article.link, "http://127.0.0.1/article/1");
    assert_eq!(
        article.description.as_deref(),
        Some("<p>回环描述</p><img src=\"http://127.0.0.1/cover.jpg\">")
    );
    assert_eq!(
        article.pub_date.as_deref(),
        Some("Mon, 01 Jan 2024 00:00:00 GMT")
    );
    assert_eq!(
        article.image_url.as_deref(),
        Some("http://127.0.0.1/cover.jpg"),
        "description 首图应作为封面"
    );

    // 请求头：源静态 header 透传；CookieJar 标记头只作内部门控、不得出网
    {
        let head = server.first_head();
        assert!(!head.is_empty(), "至少 1 次请求");
        let lower = head.to_ascii_lowercase();
        assert!(lower.contains("x-rss-test: 1"), "源 header 应透传: {head}");
        assert!(
            !head
                .lines()
                .any(|line| line.to_ascii_lowercase().starts_with("proxy:")),
            "`proxy` 配置键不得作为 HTTP 头发送: {head}"
        );
        assert!(
            !lower.contains("cookiejar"),
            "CookieJar 内部标记头不得出网: {head}"
        );
    }

    // 真实落库（sort 恒空；order 递减写入，单篇仅校验可读性）
    let rows = query_articles(&db_path, &feed_url);
    assert_eq!(rows.len(), 1, "应落库 1 行: {rows:#?}");
    assert_eq!(rows[0].0, "回环文章");
    assert_eq!(rows[0].1, "http://127.0.0.1/article/1");
    assert_eq!(
        rows[0].2,
        "<p>回环描述</p><img src=\"http://127.0.0.1/cover.jpg\">"
    );
    assert_eq!(rows[0].3, "回环正文", "content:encoded 应写入 content 列");

    // ---- 1.5) 多篇：order 递减 + REPLACE 主键替换（同源同 link 更新） ----
    let multi_url = format!("{base}/multi");
    add_source(&multi_url, serde_json::json!({}));

    let first = legado_ffi::api::rss::fetch_rss_articles(&multi_url).expect("多篇首次拉取");
    assert_eq!(first.len(), 3, "首次应解析 3 篇: {first:#?}");
    let rows_v1 = query_articles(&db_path, &multi_url);
    assert_eq!(rows_v1.len(), 3, "首次应落库 3 行: {rows_v1:#?}");
    assert_eq!(
        rows_v1.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec!["第一篇", "第二篇", "第三篇"],
        "order 降序应与文档顺序一致"
    );
    assert!(
        rows_v1.windows(2).all(|w| w[0].4 > w[1].4),
        "同次写入的 order 必须严格递减: {rows_v1:?}"
    );

    let second = legado_ffi::api::rss::fetch_rss_articles(&multi_url).expect("多篇二次拉取");
    assert_eq!(second.len(), 3, "二次拉取仍应解析 3 篇: {second:#?}");
    let rows_v2 = query_articles(&db_path, &multi_url);
    assert_eq!(
        rows_v2.len(),
        3,
        "主键 (origin, link, sort) 冲突应 INSERT OR REPLACE，而非追加: {rows_v2:#?}"
    );
    assert_eq!(
        rows_v2.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec!["第一篇（更新）", "第二篇（更新）", "第三篇（更新）"],
        "同 link 文章应被新标题替换"
    );
    assert!(
        rows_v2.windows(2).all(|w| w[0].4 > w[1].4),
        "二次写入 order 仍须严格递减: {rows_v2:?}"
    );
    assert!(
        rows_v2[0].4 >= rows_v1[0].4,
        "二次写入时间戳不得回退（v2={}, v1={}）",
        rows_v2[0].4,
        rows_v1[0].4
    );

    // ---- 2) 非 XML 正文：解析 0 篇 → 空列表（不伪造单条摘要） ----
    let html_url = format!("{base}/html");
    add_source(&html_url, serde_json::json!({}));
    let html_articles =
        legado_ffi::api::rss::fetch_rss_articles(&html_url).expect("非 XML 正文不应报错");
    assert!(
        html_articles.is_empty(),
        "非 XML 正文应返回空列表，不得伪造摘要: {html_articles:#?}"
    );
    assert!(
        query_articles(&db_path, &html_url).is_empty(),
        "解析 0 篇不得落库"
    );

    // ---- 3) 空响应体：对齐原版 `body.isNullOrBlank()` → 报错 ----
    let empty_url = format!("{base}/empty");
    add_source(&empty_url, serde_json::json!({}));
    let err = legado_ffi::api::rss::fetch_rss_articles(&empty_url)
        .expect_err("空响应体应报错（对齐原版）");
    let message = format!("{err}");
    assert!(
        message.contains("获取 RSS 内容失败"),
        "错误信息应说明取数失败: {message}"
    );

    // 清理共享库中的测试源（DB 文件随进程退出释放）
    for url in [&feed_url, &multi_url, &html_url, &empty_url] {
        let _ = legado_ffi::api::rss::delete_rss_source(url);
    }
    let _ = std::fs::remove_file(&db_path);
}
