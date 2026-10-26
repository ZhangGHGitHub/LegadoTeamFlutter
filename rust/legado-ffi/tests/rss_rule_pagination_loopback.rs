//! 批15b：RSS 规则列表 + 分类 sortUrl + 登录头/checkJs + 分页 回环端到端用例
//!
//! 独立测试二进制（独立进程，`db_open` 只初始化一次）。覆盖：
//!
//! ```text
//! 规则列表源（ruleArticles/ruleNextPage/sortUrl 分类）
//!   → rssRefreshArticles：规则解析、order 递减 REPLACE、hasMore
//!   → rssLoadMoreArticles：第 2 页追加、第 3 页重复判到底
//!   → 再次 rssRefreshArticles：clearOld 清理旧页
//!   → rssSortUrls：@js: 求值 + 缓存命中（篡改缓存值可观察）+ rssClearSortCache
//!   → 无 sortUrl 源：回退 [{"name":"","url":sourceUrl}]
//! 登录源
//!   → loginHeader_<url> 合并进请求头
//!   → loginCheckJs 成功（返回修改后响应）
//!   → loginCheckJs 失败（二次仍 500 → LoginRequired）
//!   → checkJs 自动登录（errResponse code 500 → 二次返回可用正文）
//! ```

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::sync::{Arc, Mutex};

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

/// 回环服务器：按请求行（method path?query）返回固定正文，记录请求头
fn spawn_server(requests: usize) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
    let port = listener.local_addr().expect("读取端口").port();
    let heads = Arc::new(Mutex::new(Vec::new()));
    let heads_thread = Arc::clone(&heads);
    std::thread::spawn(move || {
        for _ in 0..requests {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let head = read_request_head(&mut stream);
            let target = head
                .lines()
                .next()
                .unwrap_or_default()
                .split_whitespace()
                .nth(1)
                .unwrap_or_default()
                .to_string();
            let (status, body) = match target.as_str() {
                "/list" => ("200 OK", LIST_P1),
                "/list?p=2" => ("200 OK", LIST_P2),
                "/list?p=3" => ("200 OK", LIST_P3),
                "/auto-login" => ("200 OK", "<html><body>未登录</body></html>"),
                "/login-ok" => (
                    "200 OK",
                    "<html><body><div class=\"item\"><h2 class=\"title\">登录成功文章</h2>\
                     <a class=\"link\" href=\"/ok/1\">一</a></div></body></html>",
                ),
                "/login-required" => ("200 OK", "<html><body>未登录</body></html>"),
                _ => ("404 Not Found", ""),
            };
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
    (port, heads)
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

    let (port, heads) = spawn_server(8);
    let base = format!("http://127.0.0.1:{port}");

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

    // ─── 4) 再次刷新：ruleNextPage 非空 → clearOld 清理旧页 ─────────
    let refreshed = decode(
        &legado_ffi::api::rss::rss_refresh_articles(&list_url, "", &list_url, None)
            .expect("二次刷新"),
    );
    assert_eq!(refreshed["hasMore"], true);
    let rows = query_articles(&db_path, &list_url);
    assert_eq!(rows.len(), 2, "旧页（P2 两篇）应被 clearOld 清理: {rows:?}");
    assert_eq!(
        rows.iter().map(|r| r.0.as_str()).collect::<Vec<_>>(),
        vec!["P1-文章一", "P1-文章二"]
    );

    // ─── 5) rssSortUrls：@js: 求值 + 缓存命中 + 清除 ────────────────
    let sort_script =
        format!("@js:(function(){{ return '科技::{base}/tech&&文学::{base}/lit'; }})()");
    add_source(&list_url, list_source_extra(&sort_script));
    let sorts = decode(&legado_ffi::api::rss::rss_sort_urls(&list_url).expect("分类解析"));
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
    let cached = decode(&legado_ffi::api::rss::rss_sort_urls(&list_url).expect("缓存命中解析"));
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
    let fallback = decode(&legado_ffi::api::rss::rss_sort_urls(&plain_url).expect("无分类回退"));
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
        let heads = heads.lock().unwrap();
        let head = heads.last().expect("应记录请求头");
        let lower = head.to_ascii_lowercase();
        assert!(
            lower.contains("x-login-token: token-1"),
            "登录头应合并: {head}"
        );
        assert!(
            lower.contains("x-rss-static: s"),
            "源 header 应保留: {head}"
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
        &login_ok,
        &login_required,
        &auto_login,
    ] {
        let _ = legado_ffi::api::rss::delete_rss_source(url);
    }
    let _ = std::fs::remove_file(&db_path);
}
