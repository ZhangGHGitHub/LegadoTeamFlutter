//! 批15b：RSS 规则列表 + 分类 sortUrl + 登录头/checkJs + 分页 回环端到端用例
//!
//! 独立测试二进制（独立进程，`db_open` 只初始化一次）。覆盖：
//!
//! ```text
//! 规则列表源（ruleArticles/ruleNextPage/sortUrl 分类）
//!   → rssRefreshArticles：规则解析、order 递减 REPLACE、hasMore
//!   → rssLoadMoreArticles：第 2 页追加、第 3 页重复判到底
//!   → 第 4 页部分重叠：已存在条目不重复、新条目接在水位之下（P2-5）
//!   → 再次 rssRefreshArticles：clearOld 清理旧页
//!   → rssSortUrls：@js: 求值 + 缓存命中（篡改缓存值可观察）+ rssClearSortCache
//!   → 无 sortUrl 源：回退 [{"name":"","url":sourceUrl}]
//! 登录源
//!   → loginHeader_<url> 合并进请求头（同源）
//!   → loginCheckJs 成功（返回修改后响应）
//!   → loginCheckJs 失败（二次仍 500 → LoginRequired）
//!   → checkJs 自动登录（errResponse code 500 → 二次返回可用正文）
//! 跨域 nextUrl（审查 P1-2）
//!   → 服务器 A 返回指向服务器 B 的 nextUrl
//!   → A（同源）请求携带 loginHeader_/userInfo_
//!   → B（跨域）请求不携带登录头，源静态 header 仍透传
//! ```
//!
//! 回环服务器加固（审查 P2-8）：循环 accept 直到 `Drop` 关闭，不再按固定
//! 请求数退出（少发/多发请求都不会挂死线程）；每个连接设读超时。

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 规则列表第 1 页：2 篇 + 下一页 `/list?p=2`
const LIST_P1: &str = r#"<html><body>
<div class="item"><h2 class="title">P1-文章一</h2><a class="link" href="/a/1">一</a></div>
<div class="item"><h2 class="title">P1-文章二</h2><a class="link" href="/a/2">二</a></div>
<a class="next" href="/list?p=2">下一页</a>
</body></html>"#;

/// 规则列表第 2 页：2 篇 + 下一页 `/list?p=3`
const LIST_P2: &str = r#"<html><body>
<div class="item"><h2 class="title">P2-文章三</h2><a class="link" href="/a/3">三</a></div>
<div class="item"><h2 class="title">P2-文章四</h2><a class="link" href="/a/4">四</a></div>
<a class="next" href="/list?p=3">下一页</a>
</body></html>"#;

/// 第 3 页：与第 2 页重复（首末条均在库 → 判到底），无下一页
const LIST_P3: &str = r#"<html><body>
<div class="item"><h2 class="title">P2-文章三</h2><a class="link" href="/a/3">三</a></div>
<div class="item"><h2 class="title">P2-文章四</h2><a class="link" href="/a/4">四</a></div>
</body></html>"#;

/// 第 4 页（部分重叠）：首条已在库（A/4）、末条为新（A/5）→ 只追加新条目，
/// 且新条目 order 接在上一页水位之下（P2-5）
const LIST_P4: &str = r#"<html><body>
<div class="item"><h2 class="title">P2-文章四</h2><a class="link" href="/a/4">四</a></div>
<div class="item"><h2 class="title">P2-文章五</h2><a class="link" href="/a/5">五</a></div>
</body></html>"#;

/// 跨域服务器 B 的列表页（无下一页）
const CROSS_TARGET_BODY: &str = r#"<html><body>
<div class="item"><h2 class="title">跨域文章</h2><a class="link" href="/x/1">一</a></div>
</body></html>"#;

/// 请求目标（`path?query`）→ `(状态行, 正文)`
type Routes = Arc<dyn Fn(&str) -> (String, String) + Send + Sync>;

/// 回环服务器句柄
///
/// 审查 P2-8：此前按固定请求次数循环，测试少发一次请求时线程永久阻塞在
/// `accept`、多发一次时客户端挂起到超时。现改为「循环 accept + Drop 关闭」：
/// 线程只在句柄析构时退出，请求数与断言解耦。
struct LoopbackServer {
    addr: SocketAddr,
    heads: Arc<Mutex<Vec<String>>>,
    shutdown: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl LoopbackServer {
    fn spawn(routes: Routes) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let addr = listener.local_addr().expect("读取端口");
        let heads = Arc::new(Mutex::new(Vec::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let heads_thread = Arc::clone(&heads);
        let shutdown_thread = Arc::clone(&shutdown);
        let handle = std::thread::spawn(move || {
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
                let target = head
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or_default()
                    .to_string();
                let (status, body) = routes(&target);
                heads_thread.lock().unwrap().push(head);
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
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

    /// 最近一次请求头快照
    fn last_head(&self) -> String {
        self.heads
            .lock()
            .unwrap()
            .last()
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

fn temp_db_path() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("legado-ffi-rss-rule-{}.db", std::process::id()));
    let _ = std::fs::remove_file(&path);
    path
}

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

fn add_source(source_url: &str, extra: serde_json::Value) {
    let mut source = serde_json::json!({
        "sourceUrl": source_url,
        "sourceName": "批15b 回环源",
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

/// 直连 DB：文章 (title, link, order) 按 order 降序
fn query_articles(db_path: &Path, origin: &str) -> Vec<(String, String, i64)> {
    let conn = rusqlite::Connection::open(db_path).expect("直连临时 DB");
    let mut stmt = conn
        .prepare(
            "SELECT title, link, \"order\" FROM rssArticles \
             WHERE origin = ?1 ORDER BY \"order\" DESC",
        )
        .expect("准备文章查询");
    stmt.query_map(rusqlite::params![origin], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })
    .expect("查询 rssArticles")
    .filter_map(|r| r.ok())
    .collect()
}

/// 直连 DB：读 sortUrl 缓存值（`rssSortUrl_%`）
fn query_sort_cache(db_path: &Path) -> Option<(String, String)> {
    let conn = rusqlite::Connection::open(db_path).expect("直连临时 DB");
    let mut stmt = conn
        .prepare("SELECT key, value FROM caches WHERE key LIKE 'rssSortUrl_%'")
        .expect("准备缓存查询");
    stmt.query_row([], |row| Ok((row.get(0)?, row.get(1)?)))
        .ok()
}

/// 规则列表源定义（CSS 规则）
fn list_source_extra(sort_url: &str) -> serde_json::Value {
    serde_json::json!({
        "sortUrl": sort_url,
        "ruleArticles": ".item",
        "ruleTitle": ".title",
        "ruleLink": ".link@href",
        "ruleNextPage": ".next@href",
    })
}

#[test]
fn rss_rule_pagination_sort_cache_and_login_end_to_end() {
    let db_path = temp_db_path();
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");

    // 跨域目标服务器 B（先起，A 的同源页面需要引用它的 nextUrl）
    let cross_base = {
        let routes: Routes = Arc::new(|target: &str| match target {
            "/third" => ("200 OK".to_string(), CROSS_TARGET_BODY.to_string()),
            _ => ("404 Not Found".to_string(), String::new()),
        });
        let server = LoopbackServer::spawn(routes);
        CrossServer::new(server)
    };
    let base_b = cross_base.base_url.clone();

    let routes_a: Routes = {
        let base_b = base_b.clone();
        Arc::new(move |target: &str| match target {
            "/list" => ("200 OK".to_string(), LIST_P1.to_string()),
            "/list?p=2" => ("200 OK".to_string(), LIST_P2.to_string()),
            "/list?p=3" => ("200 OK".to_string(), LIST_P3.to_string()),
            "/list?p=4" => ("200 OK".to_string(), LIST_P4.to_string()),
            "/auto-login" => (
                "200 OK".to_string(),
                "<html><body>未登录</body></html>".to_string(),
            ),
            "/login-ok" => (
                "200 OK".to_string(),
                "<html><body><div class=\"item\"><h2 class=\"title\">登录成功文章</h2>\
                 <a class=\"link\" href=\"/ok/1\">一</a></div></body></html>"
                    .to_string(),
            ),
            "/login-required" => (
                "200 OK".to_string(),
                "<html><body>未登录</body></html>".to_string(),
            ),
            "/cross-origin" => (
                "200 OK".to_string(),
                format!(
                    "<html><body>\
                     <div class=\"item\"><h2 class=\"title\">同源文章</h2>\
                     <a class=\"link\" href=\"/own/1\">一</a></div>\
                     <a class=\"next\" href=\"{base_b}/third\">下一页</a>\
                     </body></html>"
                ),
            ),
            _ => ("404 Not Found".to_string(), String::new()),
        })
    };
    let server_a = LoopbackServer::spawn(routes_a);
    let base = server_a.base_url();

    // ─── 1) 规则列表刷新：解析 + order 递减 + hasMore ───────────────
    let list_url = format!("{base}/list");
    add_source(&list_url, list_source_extra(&base));
    let page1 = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&list_url, "", &list_url, None)
            .expect("刷新第 1 页"),
    );
    assert_eq!(page1["articles"].as_array().unwrap().len(), 2, "{page1}");
    assert_eq!(page1["hasMore"], true, "{page1}");
    assert_eq!(
        page1["nextUrl"].as_str(),
        Some(format!("{base}/list?p=2").as_str())
    );
    let p1_article = &page1["articles"][0];
    assert_eq!(p1_article["title"], "P1-文章一");
    assert_eq!(p1_article["link"], format!("{base}/a/1"));
    assert_eq!(p1_article["sort"], "");
    assert_eq!(p1_article["origin"], list_url);

    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 2);
    assert!(
        rows.windows(2).all(|w| w[0].2 > w[1].2),
        "order 递减: {rows:?}"
    );

    // ─── 2) 第 2 页：追加（order 续接上一页之下） ───────────────────
    let next2 = page1["nextUrl"].as_str().unwrap().to_string();
    let page2 = decode(
        &legado_ffi::api::rss::rss_load_more_articles(&list_url, "", &next2, 2, None)
            .expect("加载第 2 页"),
    );
    assert_eq!(page2["articles"].as_array().unwrap().len(), 2);
    assert_eq!(page2["hasMore"], true);
    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 4, "第 2 页应追加: {rows:?}");
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec!["P1-文章一", "P1-文章二", "P2-文章三", "P2-文章四"],
        "新页排在旧页之后（order 续接递减）"
    );
    assert!(
        rows.windows(2).all(|w| w[0].2 > w[1].2),
        "order 严格递减: {rows:?}"
    );

    // ─── 3) 第 3 页：与第 2 页重复 → 首末命中判到底，不写库 ─────────
    let next3 = page2["nextUrl"].as_str().unwrap().to_string();
    let page3 = decode(
        &legado_ffi::api::rss::rss_load_more_articles(&list_url, "", &next3, 3, None)
            .expect("加载第 3 页"),
    );
    assert_eq!(page3["hasMore"], false, "判到底: {page3}");
    assert_eq!(page3["nextUrl"], serde_json::Value::Null);
    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 4, "判到底不得追加: {rows:?}");

    // ─── 3.5) 第 4 页：部分重叠（首条已在库、末条新）→ 只追加新条目 ──
    // 审查 P2-5：新条目 order 必须接在上一页水位之下，已存在行保持原 order
    let partial = format!("{base}/list?p=4");
    let page4 = decode(
        &legado_ffi::api::rss::rss_load_more_articles(&list_url, "", &partial, 4, None)
            .expect("加载部分重叠页"),
    );
    assert_eq!(page4["hasMore"], false, "第 4 页无 nextUrl: {page4}");
    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 5, "只追加新条目: {rows:?}");
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec![
            "P1-文章一",
            "P1-文章二",
            "P2-文章三",
            "P2-文章四",
            "P2-文章五"
        ],
        "重叠条目不得重复写入，新条目排在旧页之后"
    );
    assert!(
        rows.windows(2).all(|w| w[0].2 > w[1].2),
        "部分重叠页写入后 order 仍严格递减: {rows:?}"
    );

    // ─── 4) 再次刷新：ruleNextPage 非空 → clearOld 清理旧页 ─────────
    // 审查 P2-8：clearOld 水位取 `SystemTime` 毫秒。两次刷新若落在同一毫秒，
    // 新水位 now-2 恰等于上一页最小 order，旧页删不干净（测试假红）。
    // 显式等待 10ms，确保第二次刷新的 now 严格大于首次（无注入时钟的
    // 最小改动方案，语义不变）。
    std::thread::sleep(Duration::from_millis(10));
    let refreshed = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&list_url, "", &list_url, None)
            .expect("二次刷新"),
    );
    assert_eq!(refreshed["hasMore"], true);
    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 2, "旧页（P2 三篇）应被 clearOld 清理: {rows:?}");
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec!["P1-文章一", "P1-文章二"]
    );

    // ─── 5) rssSortUrls：@js: 求值 + 缓存命中 + 清除 ────────────────
    let sort_script =
        format!("@js:(function(){{ return '科技::{base}/tech&&文学::{base}/lit'; }})()");
    add_source(&list_url, list_source_extra(&sort_script));
    let sorts = decode(&legado_ffi::api::rss::rss_sort_urls(&list_url, None).expect("分类解析"));
    assert_eq!(
        sorts,
        serde_json::json!([
            {"name": "科技", "url": format!("{base}/tech")},
            {"name": "文学", "url": format!("{base}/lit")},
        ])
    );

    // 缓存已写入；篡改后再次调用应命中缓存（不再求值脚本）
    let (cache_key, _) = query_sort_cache(&db_path).expect("脚本分类应写缓存");
    assert!(cache_key.starts_with("rssSortUrl_"));
    {
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute(
            "UPDATE caches SET value = '缓存::https://cached.example.com/x' WHERE key = ?1",
            rusqlite::params![cache_key],
        )
        .expect("篡改缓存");
    }
    let cached =
        decode(&legado_ffi::api::rss::rss_sort_urls(&list_url, None).expect("缓存命中解析"));
    assert_eq!(
        cached,
        serde_json::json!([{"name": "缓存", "url": "https://cached.example.com/x"}]),
        "应使用缓存值而非重新求值"
    );

    legado_ffi::api::rss::rss_clear_sort_cache(&list_url).expect("清除分类缓存");
    assert!(
        query_sort_cache(&db_path).is_none(),
        "rssClearSortCache 应删除缓存行"
    );

    // 无 sortUrl：回退 [{"name":"","url":sourceUrl}]
    let plain_url = format!("{base}/plain");
    add_source(&plain_url, serde_json::json!({}));
    let fallback =
        decode(&legado_ffi::api::rss::rss_sort_urls(&plain_url, None).expect("无分类回退"));
    assert_eq!(
        fallback,
        serde_json::json!([{"name": "", "url": plain_url}])
    );

    // ─── 6) 登录头合并 + loginCheckJs 成功/失败/自动登录 ────────────
    legado_ffi::ffi::ffi::source_put_login_header(
        list_url.clone(),
        r#"{"X-Login-Token":"token-1"}"#.to_string(),
    )
    .expect("写入登录头");
    add_source(
        &list_url,
        serde_json::json!({
            "header": "{\"X-Rss-Static\":\"s\"}",
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
        }),
    );
    legado_ffi::api::rss::rss_refresh_articles(&list_url, "", &list_url, None)
        .expect("带登录头刷新");
    {
        let head = server_a.last_head();
        let lower = head.to_ascii_lowercase();
        assert!(
            lower.contains("x-login-token: token-1"),
            "同源请求应合并登录头: {head}"
        );
        assert!(
            lower.contains("x-rss-static: s"),
            "源 header 应保留: {head}"
        );
    }

    // ─── 6.5) 跨域 nextUrl：登录头不得外发（审查 P1-2） ─────────────
    let cross_url = format!("{base}/cross-origin");
    add_source(
        &cross_url,
        serde_json::json!({
            "header": "{\"X-Rss-Static\":\"s\"}",
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
            "ruleNextPage": ".next@href",
        }),
    );
    legado_ffi::ffi::ffi::source_put_login_header(
        cross_url.clone(),
        r#"{"X-Login-Token":"cross-token"}"#.to_string(),
    )
    .expect("写入跨域测试登录头");

    // 同源刷新：登录头应携带
    let cross_page = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&cross_url, "", &cross_url, None)
            .expect("跨域测试第 1 页"),
    );
    {
        let head = server_a.last_head();
        assert!(
            head.to_ascii_lowercase()
                .contains("x-login-token: cross-token"),
            "同源请求应携带登录头: {head}"
        );
    }
    let cross_next = cross_page["nextUrl"].as_str().expect("应有跨域 nextUrl");
    assert_eq!(cross_next, format!("{base_b}/third"));

    // 跨域翻页：B 收到的请求不得包含登录头（Cookie/Authorization 同理），
    // 源静态 header 仍应透传
    let cross_second = decode(
        &legado_ffi::api::rss::rss_load_more_articles(&cross_url, "", cross_next, 2, None)
            .expect("跨域翻页"),
    );
    assert_eq!(cross_second["articles"][0]["title"], "跨域文章");
    assert_eq!(cross_second["hasMore"], false);
    {
        let head = cross_base.server.last_head();
        let lower = head.to_ascii_lowercase();
        assert!(
            !lower.contains("x-login-token"),
            "跨域请求绝不能携带登录头: {head}"
        );
        assert!(
            lower.contains("x-rss-static: s"),
            "源静态 header 仍应透传: {head}"
        );
    }

    // 成功路径：checkJs 可读 source 绑定并原样放行
    let login_ok = format!("{base}/login-ok");
    add_source(
        &login_ok,
        serde_json::json!({
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
            "loginCheckJs": "(function(){ if (source.getKey() !== '') return result; return true; })()",
        }),
    );
    let ok = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&login_ok, "", &login_ok, None)
            .expect("loginCheckJs 成功"),
    );
    assert_eq!(ok["articles"][0]["title"], "登录成功文章");

    // 失败路径：首检抛错 + errResponse 二次仍 500 → LoginRequired
    let login_required = format!("{base}/login-required");
    add_source(
        &login_required,
        serde_json::json!({
            "ruleArticles": ".item",
            "loginCheckJs": "throw new Error('未登录');",
        }),
    );
    let err =
        legado_ffi::api::rss::rss_refresh_articles(&login_required, "", &login_required, None)
            .expect_err("未登录应报错");
    assert!(
        format!("{err}").contains("需要登录"),
        "错误应为登录失败语义: {err}"
    );

    // 自动登录：成功路径抛错 → errResponse 二次返回可用正文
    let auto_login = format!("{base}/auto-login");
    add_source(
        &auto_login,
        serde_json::json!({
            "ruleArticles": ".item",
            "ruleTitle": ".title",
            "ruleLink": ".link@href",
            "loginCheckJs": "(function(){ if (result.code() === 500) return { code: 200, body: '<html><body><div class=\"item\"><h2 class=\"title\">自动登录后文章</h2><a class=\"link\" href=\"/auto/1\">一</a></div></body></html>', url: result.url() }; if (result.body().indexOf('未登录') >= 0) throw new Error('未登录'); return result; })()",
        }),
    );
    let auto = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&auto_login, "", &auto_login, None)
            .expect("自动登录二次结果"),
    );
    assert_eq!(auto["articles"][0]["title"], "自动登录后文章");

    // 清理
    for url in [
        &list_url,
        &plain_url,
        &cross_url,
        &login_ok,
        &login_required,
        &auto_login,
    ] {
        let _ = legado_ffi::api::rss::delete_rss_source(url);
    }
    let _ = std::fs::remove_file(&db_path);
}

/// 跨域服务器包装（保留句柄到测试结束，提供 base_url）
struct CrossServer {
    server: LoopbackServer,
    base_url: String,
}

impl CrossServer {
    fn new(server: LoopbackServer) -> Self {
        let base_url = server.base_url();
        Self { server, base_url }
    }
}
