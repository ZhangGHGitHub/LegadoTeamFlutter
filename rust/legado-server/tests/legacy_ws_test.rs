//! B5 原版 WebSocket 通道集成测试（独立端口 + 原版路径 + 原版协议）
//!
//! 覆盖：
//! 1. `port+1` 监听与 `/bookSourceDebug`、`/rssSourceDebug` 两路径连通；
//! 2. 子协议鉴权红绿对（缺省 required=true → 403；令牌正确/错误）；
//! 3. 首包协议正负例（非 JSON 1008、缺字段「输入不能为空」、源不存在）；
//! 4. 调试单槽占用（「调试通道占用中，请稍后重试」）；
//! 5. 书源调试可达链路真实执行（--正文页，回环 mock 源站）；
//! 6. 10s 认证超时（close 1008「认证超时」）；
//! 7. 主服务停止 → WS 监听同步停止；
//! 8. 既有自研 `/api/ws/*` 通道不回归由 `tests/ws_test.rs` 9 条覆盖。
//!
//! 原版依据：`WebSocketServer.kt:11-55`、`BookSourceDebugWebSocket.kt`
//! `:29-177`、`RssSourceDebugWebSocket.kt:29-175`、`WebService.kt:214-219`、
//! `BookSourceController.kt:147-179`。

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use legado_core::models::rule::ContentRule;
use legado_core::models::{BookSource, RssSource};
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_db::repository::Repository;
use legado_db::{BookSourceRepository, Database};
use legado_server::server::serve_web;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// 进程级调试单槽是全库共享状态（对齐原版 `Debug.callback` 单例）：
/// 涉及调试占用的集成测试串行执行，避免并行测试互相判「占用中」。
static DEBUG_SLOT_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 起服串行锁：保证「端口对探测 → 交 serve_web」的窗口内无同进程竞争者
static SERVER_START_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 测试端口对分配游标（步进 2，避免与 OS 临时端口段重叠：30000..45000）
static NEXT_TEST_PORT: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(30000);

// ─── 服务器启动助手 ─────────────────────────────────────────────────────────

/// 等待 `host:port` 可建立 TCP 连接（最多 `attempts` × 10ms）
async fn wait_tcp_ready(addr: &str, attempts: usize) -> bool {
    for _ in 0..attempts {
        if TcpStream::connect(addr).await.is_ok() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

/// 分配一对（主服务, WS = 主+1）固定范围内的空闲端口，返回主 listener
///
/// 固定小范围 + 步进 2 + 起服锁，避免并行测试用 `:0` 随机分配时频繁撞上
/// 彼此已占用的相邻端口（Windows 临时端口段是连续分配，极易成对冲突）。
fn allocate_port_pair() -> Option<(TcpListener, u16)> {
    use std::sync::atomic::Ordering;
    for _ in 0..500 {
        let port = NEXT_TEST_PORT.fetch_add(2, Ordering::Relaxed);
        let ws_port = port.checked_add(1)?;
        if port >= 45000 {
            return None;
        }
        let Ok(main) = std::net::TcpListener::bind(("127.0.0.1", port)) else {
            continue;
        };
        // 探测 port+1 可用后立即释放；起服锁保证窗口内无同进程竞争者
        if std::net::TcpListener::bind(("127.0.0.1", ws_port)).is_err() {
            continue;
        }
        main.set_nonblocking(true).ok()?;
        return TcpListener::from_std(main)
            .ok()
            .map(|listener| (listener, ws_port));
    }
    None
}

/// 启动完整 Web 服务（主服务 + `port+1` 原版 WS），返回
/// `(http_addr, ws_addr, JoinHandle)`。
///
/// `make_db` 每次尝试重新建库并种子（内存库廉价）；端口对由
/// [`allocate_port_pair`] 从固定范围分配，失败则换下一对重试。
async fn start_server_with<F>(make_db: F) -> (String, String, tokio::task::JoinHandle<()>)
where
    F: Fn() -> Database,
{
    let _start_guard = SERVER_START_LOCK.lock().await;
    for _ in 0..20 {
        let Some((listener, ws_port)) = allocate_port_pair() else {
            panic!("测试端口段 30000..45000 已耗尽");
        };
        let port = listener.local_addr().unwrap().port();
        let http_addr = format!("127.0.0.1:{port}");
        let ws_addr = format!("127.0.0.1:{ws_port}");
        let db = make_db();
        let handle = tokio::spawn(async move {
            let _ = serve_web(listener, db).await;
        });
        // 就绪检查：主服务 2s（600×10ms），WS 1s（100×10ms）；WS 未就绪说明
        // port+1 绑定失败（本实现降级为主服务继续），换端口对重试。
        if wait_tcp_ready(&http_addr, 600).await
            && wait_tcp_ready(&ws_addr, 100).await
            && ws_identity_probe(&ws_addr).await
        {
            return (http_addr, ws_addr, handle);
        }
        handle.abort();
        let _ = handle.await;
    }
    panic!("连续 20 次尝试均未能启动服务（port+1 端口持续被占用）");
}

/// port+1 身份探针：未知路径必须由本服务返回原版 404 文案
async fn ws_identity_probe(ws_addr: &str) -> bool {
    match connect(&format!("ws://{ws_addr}/b5ReadinessProbe"), Some("legado")).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            let body = resp
                .body()
                .as_ref()
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default();
            resp.status() == 404 && body == "WebSocket route not found"
        }
        _ => false,
    }
}

fn seed_cache(db: &Database, key: &str, value: &str) {
    CacheRepository::new(db.connection())
        .put(key, value, 0)
        .unwrap();
}

fn seed_book_source(db: &Database, source: BookSource) {
    BookSourceRepository::new(db.connection())
        .insert(&source)
        .unwrap();
}

fn seed_rss_source(db: &Database, source: RssSource) {
    RssSourceRepository::new(db.connection())
        .insert(&source)
        .unwrap();
}

/// 免令牌模式（`config:jsSourceApiTokenRequired=false`）
fn disable_token(db: &Database) {
    seed_cache(db, "config:jsSourceApiTokenRequired", "false");
}

fn new_db() -> Database {
    legado_db::init_in_memory_database().unwrap()
}

// ─── WebSocket 客户端助手 ───────────────────────────────────────────────────

async fn connect(
    url: &str,
    protocols: Option<&str>,
) -> Result<Ws, tokio_tungstenite::tungstenite::Error> {
    let mut request = url.into_client_request().unwrap();
    if let Some(protocols) = protocols {
        request.headers_mut().insert(
            "sec-websocket-protocol",
            HeaderValue::from_str(protocols).unwrap(),
        );
    }
    connect_async(request).await.map(|(ws, _resp)| ws)
}

/// 收集文本帧直至关闭帧/错误，返回 `(texts, (close_code, close_reason))`
async fn collect_until_close(mut ws: Ws) -> (Vec<String>, Option<(u16, String)>) {
    let mut texts = Vec::new();
    let mut close = None;
    while let Some(item) = ws.next().await {
        match item {
            Ok(Message::Text(text)) => texts.push(text.to_string()),
            Ok(Message::Close(frame)) => {
                if let Some(frame) = frame {
                    close = Some((u16::from(frame.code), frame.reason.to_string()));
                }
                break;
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    (texts, close)
}

// ─── 1. port+1 监听与两路径连通 ─────────────────────────────────────────────

#[tokio::test]
async fn test_port_plus_one_serves_both_original_paths() {
    let (http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    // 主服务仍在原端口提供 HTTP（port+1 不占用主服务）
    let health = reqwest::get(format!("http://{http_addr}/api/health"))
        .await
        .unwrap();
    assert_eq!(health.status(), 200);

    for path in ["/bookSourceDebug", "/rssSourceDebug"] {
        let url = format!("ws://{ws_addr}{path}");
        let mut ws = connect(&url, Some("legado"))
            .await
            .unwrap_or_else(|e| panic!("{path} 握手应成功: {e}"));
        ws.close(None).await.ok();
    }

    handle.abort();
}

/// 握手成功时服务端必须回选客户端提供过的子协议（浏览器兼容）
#[tokio::test]
async fn test_handshake_echoes_legado_subprotocol() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let url = format!("ws://{ws_addr}/bookSourceDebug");
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("sec-websocket-protocol", HeaderValue::from_static("legado"));
    let (_ws, response) = connect_async(request).await.unwrap();
    assert_eq!(
        response
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|v| v.to_str().ok()),
        Some("legado")
    );
    handle.abort();
}

// ─── 2. 未知 WS 路径（原版 404 文案）────────────────────────────────────────

#[tokio::test]
async fn test_unknown_ws_path_returns_original_404_text() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let url = format!("ws://{ws_addr}/noSuchDebug");
    match connect(&url, Some("legado")).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            assert_eq!(resp.status(), 404);
            let body = resp
                .body()
                .as_ref()
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default();
            assert_eq!(body, "WebSocket route not found");
            assert_eq!(
                resp.headers()
                    .get("x-content-type-options")
                    .and_then(|v| v.to_str().ok()),
                Some("nosniff")
            );
        }
        other => panic!("未知 WS 路径应被 404 拒绝，实际: {other:?}"),
    }
    handle.abort();
}

// ─── 3. 鉴权红绿对 ──────────────────────────────────────────────────────────

/// 缺省 required=true：无子协议 → 403 + 原版文案/头
#[tokio::test]
async fn test_missing_subprotocol_is_forbidden_by_default() {
    // 缺省 required=true，且未配置令牌
    let (_http_addr, ws_addr, handle) = start_server_with(new_db).await;

    let url = format!("ws://{ws_addr}/bookSourceDebug");
    match connect(&url, None).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            assert_eq!(resp.status(), 403);
            assert_eq!(
                resp.headers()
                    .get("cache-control")
                    .and_then(|v| v.to_str().ok()),
                Some("no-store")
            );
            assert_eq!(
                resp.headers()
                    .get("x-content-type-options")
                    .and_then(|v| v.to_str().ok()),
                Some("nosniff")
            );
            let body = resp
                .body()
                .as_ref()
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default();
            assert_eq!(body, "Web 书源访问令牌未配置或不正确");
        }
        other => panic!("缺子协议应被 403 拒绝，实际: {other:?}"),
    }
    handle.abort();
}

/// 令牌必填：正确令牌协议通过，错误令牌 403
#[tokio::test]
async fn test_token_subprotocol_red_green() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        seed_cache(&db, "config:jsSourceApiToken", "secret");
        db
    })
    .await;

    let url = format!("ws://{ws_addr}/bookSourceDebug");
    // 绿：legado + legado.token.<base64url("secret")>（= c2VjcmV0）
    let mut ws = connect(&url, Some("legado,legado.token.c2VjcmV0"))
        .await
        .expect("正确令牌协议应握手成功");
    ws.close(None).await.ok();
    // 红：错误令牌
    match connect(&url, Some("legado,legado.token.d3Jvbmc")).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            assert_eq!(resp.status(), 403);
        }
        other => panic!("错误令牌应被 403 拒绝，实际: {other:?}"),
    }
    handle.abort();
}

// ─── 4. 首包协议正负例 ──────────────────────────────────────────────────────

#[tokio::test]
async fn test_non_json_first_message_closes_1008() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    ws.send(Message::Text("not json".into())).await.unwrap();
    let (texts, close) = collect_until_close(ws).await;
    assert!(texts.is_empty());
    assert_eq!(close, Some((1008, "认证数据格式错误".to_string())));
    handle.abort();
}

#[tokio::test]
async fn test_blank_key_sends_cannot_empty_then_closes_1000() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    ws.send(Message::Text(r#"{"tag":"x","key":"  "}"#.into()))
        .await
        .unwrap();
    let (texts, close) = collect_until_close(ws).await;
    assert_eq!(texts, vec!["输入不能为空".to_string()]);
    assert_eq!(close, Some((1000, "调试结束".to_string())));
    handle.abort();
}

#[tokio::test]
async fn test_unknown_book_source_reports_missing() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    ws.send(Message::Text(r#"{"tag":"https://none","key":"k"}"#.into()))
        .await
        .unwrap();
    let (texts, close) = collect_until_close(ws).await;
    assert_eq!(texts, vec!["书源不存在".to_string()]);
    assert_eq!(close, Some((1000, "调试结束".to_string())));
    handle.abort();
}

#[tokio::test]
async fn test_unknown_rss_source_reports_missing() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/rssSourceDebug"), Some("legado"))
        .await
        .unwrap();
    ws.send(Message::Text(r#"{"tag":"https://none","key":"k"}"#.into()))
        .await
        .unwrap();
    let (texts, close) = collect_until_close(ws).await;
    assert_eq!(texts, vec!["订阅源不存在".to_string()]);
    assert_eq!(close, Some((1000, "调试结束".to_string())));
    handle.abort();
}

// ─── 5. RSS 能力降级（协议走完，显式说明，不伪造解析）──────────────────────

#[tokio::test]
async fn test_rss_existing_source_degrades_explicitly() {
    let _lock = DEBUG_SLOT_TEST_LOCK.lock().await;
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        seed_rss_source(
            &db,
            RssSource {
                source_url: "https://rss.example.com/feed".to_string(),
                source_name: "测试订阅源".to_string(),
                ..Default::default()
            },
        );
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/rssSourceDebug"), Some("legado"))
        .await
        .unwrap();
    ws.send(Message::Text(
        r#"{"tag":"https://rss.example.com/feed","key":"k"}"#.into(),
    ))
    .await
    .unwrap();
    let (texts, close) = collect_until_close(ws).await;
    assert_eq!(texts.len(), 1, "只应有一条能力缺失说明: {texts:?}");
    assert!(
        texts[0].contains("未接入订阅源规则解析引擎"),
        "必须显式说明降级，不得伪造解析结果: {texts:?}"
    );
    assert_eq!(close, Some((1000, "调试结束".to_string())));
    handle.abort();
}

// ─── 6. 书源调试可达链路（真实执行 -- 正文页）──────────────────────────────

async fn start_mock_content_source() -> String {
    use axum::response::Html;
    use axum::routing::get;

    let app = axum::Router::new().route(
        "/chapter/0",
        get(|| async {
            Html(
                "<html><body><div class=\"content\">B5 原版 WS 正文</div></body></html>"
                    .to_string(),
            )
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn test_book_debug_content_stage_runs_real_fetch() {
    let _lock = DEBUG_SLOT_TEST_LOCK.lock().await;
    let base = start_mock_content_source().await;
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        seed_book_source(
            &db,
            BookSource {
                book_source_url: base.clone(),
                book_source_name: "B5 mock 源".to_string(),
                rule_content: Some(ContentRule {
                    content: Some("class.content@html".to_string()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        );
        db
    })
    .await;

    let mut ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    let request = serde_json::json!({ "tag": base, "key": format!("--{base}/chapter/0") });
    ws.send(Message::Text(request.to_string().into()))
        .await
        .unwrap();

    let (texts, close) = collect_until_close(ws).await;
    assert!(
        texts.iter().any(|t| t.contains("⇒开始访正文页")),
        "缺少原版起始标记: {texts:?}"
    );
    assert!(
        texts.iter().any(|t| t.contains("︾开始解析正文页")),
        "缺少正文解析开始标记: {texts:?}"
    );
    assert!(
        texts.iter().any(|t| t.contains("︽正文页解析完成")),
        "真实正文抓取应完成（mock 源站）: {texts:?}"
    );
    assert_eq!(close, Some((1000, "调试结束".to_string())));
    handle.abort();
}

// ─── 7. 调试单槽占用 ────────────────────────────────────────────────────────

/// 慢搜索 mock：`/search` 延迟 800ms 后返回空列表
async fn start_slow_search_source() -> String {
    use axum::response::Html;
    use axum::routing::get;

    let app = axum::Router::new().route(
        "/search",
        get(|| async {
            tokio::time::sleep(Duration::from_millis(800)).await;
            Html("<html><body></body></html>".to_string())
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn test_debug_slot_busy_rejects_second_connection() {
    let _lock = DEBUG_SLOT_TEST_LOCK.lock().await;
    let base = start_slow_search_source().await;
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        seed_book_source(
            &db,
            BookSource {
                book_source_url: base.clone(),
                book_source_name: "B5 慢搜索源".to_string(),
                search_url: Some(format!("{base}/search?kw={{{{key}}}}")),
                rule_search: Some(legado_core::models::rule::SearchRule {
                    book_list: Some("class.item".to_string()),
                    name: Some("class.name@text".to_string()),
                    author: Some("class.author@text".to_string()),
                    book_url: Some("class.name@href".to_string()),
                    ..Default::default()
                }),
                ..Default::default()
            },
        );
        db
    })
    .await;
    let url = format!("ws://{ws_addr}/bookSourceDebug");

    let mut first = connect(&url, Some("legado")).await.unwrap();
    first
        .send(Message::Text(
            serde_json::json!({ "tag": base, "key": "kw" })
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    // 等首条日志，确认首个连接已占用调试槽并进入搜索阶段
    let first_msg = tokio::time::timeout(Duration::from_secs(3), first.next())
        .await
        .expect("首个连接应收到日志")
        .expect("首个连接应保持开启")
        .expect("日志帧应可读");
    match first_msg {
        Message::Text(text) => assert!(text.contains("开始搜索关键字"), "实际: {text}"),
        other => panic!("首帧应为文本日志，实际: {other:?}"),
    }

    let mut second = connect(&url, Some("legado")).await.unwrap();
    second
        .send(Message::Text(
            serde_json::json!({ "tag": base, "key": "kw2" })
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    let (texts, close) = collect_until_close(second).await;
    assert_eq!(texts, vec!["调试通道占用中，请稍后重试".to_string()]);
    assert_eq!(close, Some((1000, "调试结束".to_string())));

    // 清理首个连接（随后释放调试槽）
    first.close(None).await.ok();
    handle.abort();
}

// ─── 8. 认证超时 ────────────────────────────────────────────────────────────

/// 原版 `AUTH_TIMEOUT_MILLIS = 10_000L`：不发首包 10s 后 close 1008
#[tokio::test]
async fn test_auth_timeout_closes_1008() {
    let (_http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    let ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    let started = std::time::Instant::now();
    let (texts, close) = collect_until_close(ws).await;
    assert!(texts.is_empty());
    assert_eq!(close, Some((1008, "认证超时".to_string())));
    assert!(
        started.elapsed() >= Duration::from_secs(9),
        "认证窗口应接近原版 10s"
    );
    handle.abort();
}

// ─── 9. 主服务启停同步 ──────────────────────────────────────────────────────

/// 登记降级：port+1 被占用时主 HTTP 服务继续（原版会 stopSelf；FFI 启动
/// 返回语义无法回传该失败，见 server.rs / ws/original.rs 文档）。
#[tokio::test]
async fn test_ws_port_conflict_keeps_main_http_alive() {
    let (listener, blocker, http_addr) = loop {
        let main = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = main.local_addr().unwrap().port();
        let Some(ws_port) = port.checked_add(1) else {
            continue;
        };
        let Ok(blocker) = std::net::TcpListener::bind(("127.0.0.1", ws_port)) else {
            continue;
        };
        main.set_nonblocking(true).unwrap();
        let listener = TcpListener::from_std(main).unwrap();
        break (listener, blocker, format!("127.0.0.1:{port}"));
    };
    let db = new_db();
    disable_token(&db);
    let handle = tokio::spawn(async move {
        let _ = serve_web(listener, db).await;
    });

    assert!(wait_tcp_ready(&http_addr, 600).await, "主服务应正常就绪");
    let health = reqwest::get(format!("http://{http_addr}/api/health"))
        .await
        .unwrap();
    assert_eq!(health.status(), 200);
    assert!(
        !handle.is_finished(),
        "port+1 冲突不应拖垮主服务（降级为 WS 不可用）"
    );

    handle.abort();
    drop(blocker);
}

async fn wait_tcp_refused(addr: &str) -> bool {
    for _ in 0..200 {
        match TcpStream::connect(addr).await {
            Ok(stream) => drop(stream),
            Err(_) => return true,
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

#[tokio::test]
async fn test_main_server_stop_stops_ws_listener() {
    let (http_addr, ws_addr, handle) = start_server_with(|| {
        let db = new_db();
        disable_token(&db);
        db
    })
    .await;

    // 起服后可连（两端口同时在线）
    let ws = connect(&format!("ws://{ws_addr}/bookSourceDebug"), Some("legado"))
        .await
        .unwrap();
    drop(ws);

    // 停服（等价 FFI `server_stop` 的 abort + 等待）
    handle.abort();
    let _ = handle.await;

    assert!(
        wait_tcp_refused(&http_addr).await,
        "主服务端口应在停止后关闭"
    );
    assert!(
        wait_tcp_refused(&ws_addr).await,
        "port+1 WebSocket 端口应随主服务同步关闭"
    );
}
