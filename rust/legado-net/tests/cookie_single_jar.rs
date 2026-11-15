//! P2-2 单罐根治（方案 B2）端到端回归：reqwest 逐跳 Cookie 写入 App 罐
//!
//! 本文件只使用 `legado-net` 公开 API（`LegadoClient` / `CookiePersistence` /
//! `COOKIE_JAR_HEADER`），因此**同一组用例可在改造前代码上运行并必红**，
//! 用于留取「修复前必红 / 修复后必绿」证据。
//!
//! 覆盖（调研报告 §7.1）：
//! 1. 302 响应 `Set-Cookie` 进入 App 罐 + DB + 下一跳请求头（最小回归）；
//! 2. 单个 200 响应多条 `Set-Cookie` 全量写入（改造前 HashMap 收头折叠，
//!    只保留最后一条）；
//! 3. 302 → 302 → 200 每跳 `Set-Cookie` 全保留；
//! 4. 规则 `Cookie` 头仍按 P1-2「规则优先」覆盖罐同名值，且本次链内被响应
//!    刷新的同名键从第二跳起由罐新值接管；
//! 5. `follow_redirects=false`：302 原样返回、不发第二跳，但该 302 响应上的
//!    **多条** `Set-Cookie` 必须全量写回（改造前该 302 即「最终响应」，虽会
//!    写回但因 HashMap 折叠只剩最后一条）；
//! 6. 写侧门控关闭：响应 cookie 不写罐/DB，但读侧罐注入无条件保留；
//! 7. 跨站重定向（P3-4）：`a.example.com` → `b.other.com` 的 302 后，
//!    规则 overlay 与源站 jar cookie 都不得带到目标站；
//! 8. 并发隔离（P3-4）：同 task `join!` 与跨 task `tokio::spawn` 的并发
//!    请求各自 overlay 不串扰。

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use legado_net::{CookiePersistence, LegadoClient, LegadoClientConfig, COOKIE_JAR_HEADER};

/// 内存型 Cookie 持久化后端（模拟 DB `cookies` 表：域名键 → 完整 cookie 串）
///
/// `save` 与生产 `DbCookiePersistence` 同语义：载荷是本次变更键
/// （P1-1 后不再传整域视图），按键并集合并、同名 incoming 胜。
#[derive(Default)]
struct MemoryPersistence {
    rows: Mutex<HashMap<String, String>>,
}

impl MemoryPersistence {
    /// 预置一行持久化 Cookie（构建客户端时载入内存罐）
    fn preload(&self, domain: &str, cookie: &str) {
        self.rows
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(domain.to_string(), cookie.to_string());
    }

    /// 读取某域当前落库行（不存在返回空串）
    fn row(&self, domain: &str) -> String {
        self.rows
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(domain)
            .cloned()
            .unwrap_or_default()
    }
}

impl CookiePersistence for MemoryPersistence {
    fn load_all(&self) -> Vec<(String, String)> {
        self.rows
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    fn save(&self, tag: &str, cookie: &str) {
        let mut rows = self.rows.lock().unwrap_or_else(|p| p.into_inner());
        let merged = match rows.get(tag) {
            Some(existing) => {
                legado_net::cookie_store::CookieStore::merge_cookies_str(existing, cookie)
                    .unwrap_or_else(|| cookie.to_string())
            }
            None => cookie.to_string(),
        };
        rows.insert(tag.to_string(), merged);
    }
}

/// 回环路由响应定义
struct Route {
    /// 状态行（如 `"302 Found"`）
    status: &'static str,
    /// `Location` 头（跟随重定向用）
    location: Option<&'static str>,
    /// 本响应的全部 `Set-Cookie` 头值（**多条独立头**，不折叠）
    set_cookies: &'static [&'static str],
    /// 响应体
    body: &'static str,
}

/// 多路由回环服务器：按路径返回预设响应，并记录每一跳 `(路径, Cookie 头)`
///
/// 每条连接读请求头至 `\r\n\r\n` 后立即写响应并关闭（`Connection: close`），
/// 记录发生在写响应**之前**，故客户端返回时记录必已就绪。
async fn spawn_routes(
    routes: Vec<(&'static str, Route)>,
) -> (SocketAddr, Arc<Mutex<Vec<(String, String)>>>) {
    spawn_routes_with(move |_port| routes).await
}

/// 同 [`spawn_routes`]，但路由表在监听端口确定后构建
///
/// 供「Location 需携带运行时端口」的跨域重定向用例使用（`Route` 的
/// `location` 为 `&'static str`，用例内以 `Box::leak` 生成）。
async fn spawn_routes_with<F>(build_routes: F) -> (SocketAddr, Arc<Mutex<Vec<(String, String)>>>)
where
    F: FnOnce(u16) -> Vec<(&'static str, Route)>,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    let seen: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
    let routes: Arc<HashMap<&'static str, Route>> =
        Arc::new(build_routes(addr.port()).into_iter().collect());

    let seen_srv = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = listener.accept().await {
            let seen = Arc::clone(&seen_srv);
            let routes = Arc::clone(&routes);
            tokio::spawn(async move {
                let mut head: Vec<u8> = Vec::new();
                loop {
                    let mut b = [0u8; 1];
                    match sock.read(&mut b).await {
                        Ok(0) | Err(_) => return,
                        Ok(_) => {}
                    }
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head).to_string();
                let path = head_str
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/")
                    .to_string();
                let cookie = head_str
                    .lines()
                    .find(|line| line.to_ascii_lowercase().starts_with("cookie:"))
                    .map(|line| {
                        line.split_once(':')
                            .map(|(_, v)| v.trim().to_string())
                            .unwrap_or_default()
                    })
                    .unwrap_or_default();
                seen.lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .push((path.clone(), cookie));

                let empty: &'static [&'static str] = &[];
                let (status, location, set_cookies, body) = match routes.get(path.as_str()) {
                    Some(route) => (route.status, route.location, route.set_cookies, route.body),
                    None => ("404 Not Found", None, empty, "not-found"),
                };
                // 固定短延迟：保证并发用例的两个请求在服务端确实同时在途
                //（每跳 +100ms，全文件用例总耗时影响可忽略）
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                let mut resp = format!("HTTP/1.1 {status}\r\nContent-Type: text/plain\r\n");
                if let Some(loc) = location {
                    resp.push_str(&format!("Location: {loc}\r\n"));
                }
                for cookie in set_cookies {
                    resp.push_str(&format!("Set-Cookie: {cookie}\r\n"));
                }
                resp.push_str(&format!(
                    "Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                ));
                let _ = sock.write_all(resp.as_bytes()).await;
                let _ = sock.shutdown().await;
            });
        }
    });

    (addr, seen)
}

/// 写侧门控标记请求头（`CookieJar: 1`，发送前由客户端剥离）
fn marker_headers() -> Option<HashMap<String, String>> {
    let mut headers = HashMap::new();
    headers.insert(COOKIE_JAR_HEADER.to_string(), "1".to_string());
    Some(headers)
}

/// 把 `Cookie` 请求头拆成 `name → value`（顺序无关断言）
fn cookie_map(header: &str) -> HashMap<String, String> {
    header
        .split(';')
        .filter_map(|part| {
            let part = part.trim();
            if part.is_empty() {
                return None;
            }
            part.split_once('=')
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        })
        .collect()
}

fn test_client(persistence: &Arc<MemoryPersistence>) -> LegadoClient {
    LegadoClient::with_cookie_persistence(
        LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        },
        Arc::clone(persistence) as Arc<dyn CookiePersistence>,
    )
    .expect("构建客户端")
}

/// 1) 302 的 `Set-Cookie` 必须进入 App 罐 + DB，并在下一跳请求头生效
///
/// **改造前必红**：reqwest 内置 jar 只在内部保存 302 的 cookie，App 罐/DB
/// 拿不到（`save_cookies_from_response` 只对最终响应调用），且下一跳因显式
/// `Cookie` 头（预置 `sid=OLD`）完全屏蔽 jar 注入 → `/home` 仍带 `sid=OLD`。
#[tokio::test]
async fn test_302_set_cookie_written_and_sent_on_next_hop() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/login",
            Route {
                status: "302 Found",
                location: Some("/home"),
                set_cookies: &["sid=NEW; Path=/"],
                body: "",
            },
        ),
        (
            "/home",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "home",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    persistence.preload("127.0.0.1", "sid=OLD; theme=dark");
    let client = test_client(&persistence);

    let resp = client
        .get(&format!("http://{addr}/login"), marker_headers())
        .await
        .expect("302 登录回环应成功");
    assert_eq!(resp.status, 200, "跟随重定向后应为 200");
    assert!(resp.url.ends_with("/home"), "最终 URL: {}", resp.url);

    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 2, "应恰好两跳（/login → /home）: {hops:?}");
    assert_eq!(hops[0].0, "/login");
    assert_eq!(
        cookie_map(&hops[0].1).get("sid"),
        Some(&"OLD".to_string()),
        "首跳应携带预置旧会话: {hops:?}"
    );
    assert_eq!(hops[1].0, "/home");
    let second = cookie_map(&hops[1].1);
    assert_eq!(
        second.get("sid"),
        Some(&"NEW".to_string()),
        "第二跳必须携带 302 新会话（修复前仍是 OLD）: {hops:?}"
    );
    assert_eq!(
        second.get("theme"),
        Some(&"dark".to_string()),
        "非冲突预置 cookie 应保留: {hops:?}"
    );

    // App 罐与持久化后端都必须能看到 302 的新值（重启保持）
    let store = client.cookie_store().read().unwrap();
    assert_eq!(
        store.get_key("127.0.0.1", "sid"),
        Some("NEW".to_string()),
        "302 Set-Cookie 必须写回 App 罐"
    );
    drop(store);
    let row = persistence.row("127.0.0.1");
    assert!(
        row.contains("sid=NEW"),
        "302 Set-Cookie 必须落库（修复前 3xx 只进 reqwest 内置 jar，进程退出即丢）: {row:?}"
    );
    assert!(
        !row.contains("sid=OLD"),
        "同名旧会话必须被 302 新值替换: {row:?}"
    );

    // 重启语义：同一持久化后端重建客户端（内存罐全新、仅从后端预载）后
    // 302 会话仍可用（风险 #3）
    let restarted = test_client(&persistence);
    let store = restarted.cookie_store().read().unwrap();
    assert_eq!(
        store.get_key("127.0.0.1", "sid"),
        Some("NEW".to_string()),
        "重建客户端后必须从 DB 回填 302 会话（修复前重启即丢 3xx cookie）"
    );
}

/// 2) 单个 200 响应上的多条 `Set-Cookie` 必须全部写入
///
/// **改造前必红**：`collect_response` 用 `HashMap` 收响应头，同名多值后者
/// 覆盖前者 → 只有最后一条进入写回路径（`a=1` 丢失）。
#[tokio::test]
async fn test_multiple_set_cookie_headers_all_written() {
    let (addr, _seen) = spawn_routes(vec![(
        "/multi",
        Route {
            status: "200 OK",
            location: None,
            set_cookies: &["a=1; Path=/", "b=2; Path=/; HttpOnly"],
            body: "ok",
        },
    )])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    let client = test_client(&persistence);

    let resp = client
        .get(&format!("http://{addr}/multi"), marker_headers())
        .await
        .expect("多条 Set-Cookie 请求应成功");
    assert_eq!(resp.status, 200);

    let store = client.cookie_store().read().unwrap();
    assert_eq!(
        store.get_key("127.0.0.1", "a"),
        Some("1".to_string()),
        "第一条 Set-Cookie 不得被折叠丢失"
    );
    assert_eq!(
        store.get_key("127.0.0.1", "b"),
        Some("2".to_string()),
        "第二条 Set-Cookie 应写入"
    );
    drop(store);

    let row = persistence.row("127.0.0.1");
    assert!(row.contains("a=1"), "落库行必须含第一条: {row:?}");
    assert!(row.contains("b=2"), "落库行必须含第二条: {row:?}");
}

/// 3) 302 → 302 → 200：每一跳的 `Set-Cookie` 都必须保留
///
/// **改造前必红**：中间两跳的 `Set-Cookie` 只进 reqwest 内置 jar，最终响应
/// 只带自己的头 → App 罐/DB 仅有最后一跳（此夹具终态无 Set-Cookie → 全丢），
/// 最终请求也带不上 `a=1; b=2`。
#[tokio::test]
async fn test_each_redirect_hop_set_cookie_retained() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/a",
            Route {
                status: "302 Found",
                location: Some("/b"),
                set_cookies: &["hop_a=1; Path=/"],
                body: "",
            },
        ),
        (
            "/b",
            Route {
                status: "302 Found",
                location: Some("/c"),
                set_cookies: &["hop_b=2; Path=/"],
                body: "",
            },
        ),
        (
            "/c",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "done",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    let client = test_client(&persistence);

    let resp = client
        .get(&format!("http://{addr}/a"), marker_headers())
        .await
        .expect("两跳重定向应成功");
    assert_eq!(resp.status, 200);
    assert_eq!(resp.body, "done");

    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 3, "应三跳（/a → /b → /c）: {hops:?}");
    let final_cookie = cookie_map(&hops[2].1);
    assert_eq!(
        final_cookie.get("hop_a"),
        Some(&"1".to_string()),
        "第一跳 cookie 必须延续到终态请求: {hops:?}"
    );
    assert_eq!(
        final_cookie.get("hop_b"),
        Some(&"2".to_string()),
        "第二跳 cookie 必须延续到终态请求: {hops:?}"
    );

    let store = client.cookie_store().read().unwrap();
    assert_eq!(store.get_key("127.0.0.1", "hop_a"), Some("1".to_string()));
    assert_eq!(store.get_key("127.0.0.1", "hop_b"), Some("2".to_string()));
    drop(store);

    let row = persistence.row("127.0.0.1");
    assert!(row.contains("hop_a=1"), "每一跳都必须落库: {row:?}");
    assert!(row.contains("hop_b=2"), "每一跳都必须落库: {row:?}");
}

/// 4) 规则 `Cookie` 覆盖罐同名值（P1-2）；链内被刷新后由罐新值接管
///
/// 首跳：`sid=OLD`（规则）+ `rule=1`（规则独有），罐 `sid=OLD`；
/// 302 下 `sid=NEW` → 第二跳必须 `sid=NEW; rule=1`（既不能保留规则旧值
/// `sid=OLD`，也不能丢掉规则独有键）。
#[tokio::test]
async fn test_rule_cookie_overlay_priority_then_chain_update() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/login",
            Route {
                status: "302 Found",
                location: Some("/home"),
                set_cookies: &["sid=NEW; Path=/"],
                body: "",
            },
        ),
        (
            "/home",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "home",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    persistence.preload("127.0.0.1", "sid=OLD; dbfill=1");
    let client = test_client(&persistence);

    let mut headers = marker_headers().unwrap();
    headers.insert("Cookie".to_string(), "sid=OLD; rule=1".to_string());

    let resp = client
        .get(&format!("http://{addr}/login"), Some(headers))
        .await
        .expect("规则 Cookie + 302 应成功");
    assert_eq!(resp.status, 200);

    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 2, "应两跳: {hops:?}");
    let first = cookie_map(&hops[0].1);
    assert_eq!(
        first.get("sid"),
        Some(&"OLD".to_string()),
        "首跳规则值应覆盖罐同名值（P1-2 规则优先）"
    );
    assert_eq!(
        first.get("rule"),
        Some(&"1".to_string()),
        "规则独有键必须保留"
    );
    assert_eq!(
        first.get("dbfill"),
        Some(&"1".to_string()),
        "罐内非冲突键必须保留"
    );

    let second = cookie_map(&hops[1].1);
    assert_eq!(
        second.get("sid"),
        Some(&"NEW".to_string()),
        "链内被响应的同名 cookie 必须由罐新值接管（规则旧值不得压制新会话）: {hops:?}"
    );
    assert_eq!(
        second.get("rule"),
        Some(&"1".to_string()),
        "未被刷新的规则键继续保留: {hops:?}"
    );
}

/// 5) `follow_redirects=false`：302 原样返回，但其 `Set-Cookie` 仍写回
///
/// 语义不变（不发第二跳），且 302 的多条 `Set-Cookie` 也必须全量写回。
#[tokio::test]
async fn test_no_follow_redirects_still_writes_302_set_cookie() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/login",
            Route {
                status: "302 Found",
                location: Some("/home"),
                set_cookies: &["m1=1; Path=/", "m2=2; Path=/"],
                body: "",
            },
        ),
        (
            "/home",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "home",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    let client = LegadoClient::with_cookie_persistence(
        LegadoClientConfig {
            no_proxy: true,
            follow_redirects: false,
            ..LegadoClientConfig::default()
        },
        Arc::clone(&persistence) as Arc<dyn CookiePersistence>,
    )
    .expect("构建客户端");

    let resp = client
        .get(&format!("http://{addr}/login"), marker_headers())
        .await
        .expect("不跟随重定向请求应成功");
    assert_eq!(resp.status, 302, "302 必须原样返回");
    assert_eq!(
        seen.lock().unwrap().len(),
        1,
        "followRedirects=false 不得请求第二跳"
    );

    let store = client.cookie_store().read().unwrap();
    assert_eq!(
        store.get_key("127.0.0.1", "m1"),
        Some("1".to_string()),
        "302 的第一条 Set-Cookie 必须写回"
    );
    assert_eq!(
        store.get_key("127.0.0.1", "m2"),
        Some("2".to_string()),
        "302 的第二条 Set-Cookie 必须写回"
    );
    drop(store);
    let row = persistence.row("127.0.0.1");
    assert!(row.contains("m1=1"), "302 cookie 必须落库: {row:?}");
    assert!(row.contains("m2=2"), "302 cookie 必须落库: {row:?}");
}

/// 6) 写侧门控关闭：响应 cookie 不写罐/DB；读侧罐注入仍无条件
///
/// 风险 #6：关闭门控的书源不得因「单罐」而偷偷获得写回（reqwest 内置 jar
/// 过去会隐式维持会话）；同时既有「读侧无条件」语义保持不变。
#[tokio::test]
async fn test_gate_off_skips_writeback_but_read_side_still_injects() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/login",
            Route {
                status: "302 Found",
                location: Some("/home"),
                set_cookies: &["sid=NEW; Path=/"],
                body: "",
            },
        ),
        (
            "/home",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "home",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    persistence.preload("127.0.0.1", "dbcookie=fromDB");
    let client = test_client(&persistence);

    // 无 CookieJar 标记 → 写侧整体跳过
    let resp = client
        .get(&format!("http://{addr}/login"), None)
        .await
        .expect("无标记请求应成功");
    assert_eq!(resp.status, 200);

    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 2, "重定向仍应跟随: {hops:?}");
    let second = cookie_map(&hops[1].1);
    assert_eq!(
        second.get("dbcookie"),
        Some(&"fromDB".to_string()),
        "读侧罐注入不受门控影响: {hops:?}"
    );
    assert!(
        !second.contains_key("sid"),
        "门控关闭时响应 cookie 不得进入后续请求（reqwest 内置 jar 的隐形维持已移除）: {hops:?}"
    );

    let store = client.cookie_store().read().unwrap();
    assert!(
        store.get_key("127.0.0.1", "sid").is_none(),
        "门控关闭时不得写入内存罐"
    );
    drop(store);
    assert_eq!(
        persistence.row("127.0.0.1"),
        "dbcookie=fromDB",
        "门控关闭时不得落库"
    );
}

/// 7) 跨站重定向（P3-4）：规则 overlay 与源站 jar cookie 都不得带到目标站
///
/// `a.example.com`（域键 `example.com`）302 → `b.other.com`（域键
/// `other.com`）。源站请求携带规则 `Cookie: rule=1`，罐内预载
/// `srcjar=1`，302 响应再写 `hop=1`；目标站请求必须**一个都不带**
/// （overlay 归属域不匹配 → 自动失效；jar 按请求域键取值 → `other.com`
/// 无条目）。同时源站 302 的 `hop=1` 必须正常落入源站域。
#[tokio::test]
async fn test_cross_domain_redirect_does_not_leak_overlay_or_jar() {
    let (addr, seen) = spawn_routes_with(|port| {
        // Location 需携带运行时端口：`Route.location` 为 `&'static str`，
        // 测试内一次性 leak 换取静态生命周期
        let location: &'static str =
            Box::leak(format!("http://b.other.com:{port}/final").into_boxed_str());
        vec![
            (
                "/start",
                Route {
                    status: "302 Found",
                    location: Some(location),
                    set_cookies: &["hop=1; Path=/"],
                    body: "",
                },
            ),
            (
                "/final",
                Route {
                    status: "200 OK",
                    location: None,
                    set_cookies: &[],
                    body: "final",
                },
            ),
        ]
    })
    .await;

    legado_net::apply_custom_hosts(r#"{"a.example.com": "127.0.0.1", "b.other.com": "127.0.0.1"}"#)
        .expect("应用 hosts 映射");

    let persistence = Arc::new(MemoryPersistence::default());
    persistence.preload("example.com", "srcjar=1");
    let client = test_client(&persistence);

    let mut headers = marker_headers().unwrap();
    headers.insert("Cookie".to_string(), "rule=1".to_string());

    let resp = client
        .get(
            &format!("http://a.example.com:{}/start", addr.port()),
            Some(headers),
        )
        .await
        .expect("跨站重定向请求应成功");
    assert_eq!(resp.status, 200, "跟随重定向后应为 200");
    assert!(resp.url.ends_with("/final"), "最终 URL: {}", resp.url);

    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 2, "应恰好两跳: {hops:?}");
    let start = cookie_map(
        &hops
            .iter()
            .find(|(p, _)| p == "/start")
            .expect("应有 /start 跳")
            .1,
    );
    assert_eq!(
        start.get("rule"),
        Some(&"1".to_string()),
        "源站首跳应携带规则 overlay: {hops:?}"
    );
    assert_eq!(
        start.get("srcjar"),
        Some(&"1".to_string()),
        "源站首跳应携带源站 jar cookie: {hops:?}"
    );

    let final_cookie = cookie_map(
        &hops
            .iter()
            .find(|(p, _)| p == "/final")
            .expect("应有 /final 跳")
            .1,
    );
    assert!(
        final_cookie.is_empty(),
        "目标站不得携带规则 overlay / 源站 jar / 302 新写 cookie: {hops:?}"
    );

    // 源站 302 的 Set-Cookie 仍落源站域键；目标域不产生条目
    let store = client.cookie_store().read().unwrap();
    assert_eq!(
        store.get_key("example.com", "hop"),
        Some("1".to_string()),
        "302 的 Set-Cookie 必须写入源站域键"
    );
    assert!(
        store.get_key("other.com", "srcjar").is_none(),
        "源站 cookie 不得出现在目标域键"
    );
    drop(store);
    let source_row = persistence.row("example.com");
    assert!(
        source_row.contains("srcjar=1") && source_row.contains("hop=1"),
        "源站落库行应为合并且含 302 新键: {source_row:?}"
    );
    assert_eq!(persistence.row("other.com"), "", "目标域不得产生持久化行");

    legado_net::clear_custom_hosts();
}

/// 8a) 并发隔离（同 task `join!`）：两个请求各自的规则 overlay 不串扰
///
/// 两个请求命中同一域键（`127.0.0.1`）但覆盖键值不同；服务端固定延迟
/// 100ms 保证两者同时在途（`join!` 在同一 task 内交替 poll）。任一请求
/// 若读到对方上下文，断言会看到对方键或缺少自身键。
#[tokio::test]
async fn test_concurrent_overlays_isolated_same_task() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/a",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "a",
            },
        ),
        (
            "/b",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "b",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    let client = test_client(&persistence);

    let mut headers_a = marker_headers().unwrap();
    headers_a.insert("Cookie".to_string(), "rule=A; shared=A".to_string());
    let mut headers_b = marker_headers().unwrap();
    headers_b.insert("Cookie".to_string(), "rule=B; shared=B".to_string());

    let url_a = format!("http://{addr}/a");
    let url_b = format!("http://{addr}/b");
    let (resp_a, resp_b) = tokio::join!(
        client.get(&url_a, Some(headers_a)),
        client.get(&url_b, Some(headers_b))
    );
    assert_eq!(resp_a.expect("请求 A 应成功").status, 200);
    assert_eq!(resp_b.expect("请求 B 应成功").status, 200);

    assert_overlay_isolation(&seen, &client);
}

/// 8b) 并发隔离（跨 task `tokio::spawn`）：两个请求各自的规则 overlay 不串扰
#[tokio::test]
async fn test_concurrent_overlays_isolated_across_tasks() {
    let (addr, seen) = spawn_routes(vec![
        (
            "/a",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "a",
            },
        ),
        (
            "/b",
            Route {
                status: "200 OK",
                location: None,
                set_cookies: &[],
                body: "b",
            },
        ),
    ])
    .await;

    let persistence = Arc::new(MemoryPersistence::default());
    let client = test_client(&persistence);

    let mut headers_a = marker_headers().unwrap();
    headers_a.insert("Cookie".to_string(), "rule=A; shared=A".to_string());
    let mut headers_b = marker_headers().unwrap();
    headers_b.insert("Cookie".to_string(), "rule=B; shared=B".to_string());

    let url_a = format!("http://{addr}/a");
    let url_b = format!("http://{addr}/b");
    let client_a = client.clone();
    let client_b = client.clone();
    let task_a = tokio::spawn(async move { client_a.get(&url_a, Some(headers_a)).await });
    let task_b = tokio::spawn(async move { client_b.get(&url_b, Some(headers_b)).await });
    assert_eq!(
        task_a
            .await
            .expect("任务 A 不应 panic")
            .expect("请求 A 应成功")
            .status,
        200
    );
    assert_eq!(
        task_b
            .await
            .expect("任务 B 不应 panic")
            .expect("请求 B 应成功")
            .status,
        200
    );

    assert_overlay_isolation(&seen, &client);
}

/// 并发隔离断言：每个路径只看到自己的 overlay（键集合精确匹配，防串扰）
fn assert_overlay_isolation(seen: &Arc<Mutex<Vec<(String, String)>>>, client: &LegadoClient) {
    let hops = seen.lock().unwrap().clone();
    assert_eq!(hops.len(), 2, "应各有一次请求: {hops:?}");

    let map_for = |path: &str| {
        cookie_map(
            &hops
                .iter()
                .find(|(p, _)| p == path)
                .unwrap_or_else(|| panic!("缺少 {path} 请求: {hops:?}"))
                .1,
        )
    };
    let a = map_for("/a");
    let b = map_for("/b");

    let expected_a: HashMap<String, String> = [("rule", "A"), ("shared", "A")]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    let expected_b: HashMap<String, String> = [("rule", "B"), ("shared", "B")]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    assert_eq!(a, expected_a, "请求 A 的 overlay 被串扰: {hops:?}");
    assert_eq!(b, expected_b, "请求 B 的 overlay 被串扰: {hops:?}");

    // overlay 只存在于请求链上下文，不得写回 App 罐/DB（无 Set-Cookie）
    let store = client.cookie_store().read().unwrap();
    assert!(
        store.domain_cookie_string("127.0.0.1").is_empty(),
        "并发 overlay 不得写入 App 罐"
    );
}
