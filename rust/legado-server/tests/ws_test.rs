//! WebSocket 集成测试
//!
//! 测试 WebSocket 握手、消息收发、断连处理。

use std::sync::Arc;

use legado_core::download_manager::DownloadManager;
use legado_core::models::RssSource;
use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_server::routes::create_router;
use legado_server::state::AppState;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

/// 自研 RSS 调试与书源调试共享进程级单槽：本文件的真实解析用例串行执行
static RSS_DEBUG_SLOT_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 启动测试服务器并在起服前执行种子回调，返回监听地址
async fn start_test_server_with<F>(seed: F) -> String
where
    F: FnOnce(&legado_db::Database),
{
    let db = legado_db::init_in_memory_database().unwrap();
    seed(&db);
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths: Default::default(),
        legacy_review: Default::default(),
    });

    let app = create_router(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    format!("ws://127.0.0.1:{}", addr.port())
}

/// 启动测试服务器，返回监听地址
async fn start_test_server() -> String {
    start_test_server_with(|_| {}).await
}

#[tokio::test]
async fn test_ws_search_handshake() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/search");

    let result = connect_async(&url).await;
    assert!(result.is_ok(), "WebSocket handshake should succeed");

    let (mut ws, _resp) = result.unwrap();
    // 关闭连接
    futures_util::SinkExt::close(&mut ws).await.ok();
}

#[tokio::test]
async fn test_ws_search_receives_welcome() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/search");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    // 应收到欢迎消息
    use futures_util::StreamExt;
    let msg = ws.next().await.unwrap().unwrap();
    if let Message::Text(text) = msg {
        assert!(
            text.contains("connected"),
            "Welcome message should contain 'connected'"
        );
        assert!(text.contains("search websocket connected"));
    } else {
        panic!("Expected text message");
    }

    futures_util::SinkExt::close(&mut ws).await.ok();
}

#[tokio::test]
async fn test_ws_debug_book_source_handshake() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/book-source");

    let result = connect_async(&url).await;
    assert!(
        result.is_ok(),
        "Debug book-source WebSocket handshake should succeed"
    );

    let (mut ws, _) = result.unwrap();
    futures_util::SinkExt::close(&mut ws).await.ok();
}

#[tokio::test]
async fn test_ws_debug_book_source_receives_welcome() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/book-source");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    use futures_util::StreamExt;
    let msg = ws.next().await.unwrap().unwrap();
    if let Message::Text(text) = msg {
        assert!(text.contains("connected"));
        assert!(text.contains("debug websocket connected"));
    } else {
        panic!("Expected text message");
    }

    futures_util::SinkExt::close(&mut ws).await.ok();
}

#[tokio::test]
async fn test_ws_debug_send_and_receive() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/book-source");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    use futures_util::{SinkExt, StreamExt};

    // 先接收欢迎消息
    let _welcome = ws.next().await.unwrap().unwrap();

    // 发送调试请求
    ws.send(Message::Text("test-source-url".into()))
        .await
        .unwrap();

    // 应收到 debug_log 响应
    let msg = ws.next().await.unwrap().unwrap();
    if let Message::Text(text) = msg {
        assert!(text.contains("debug_log"));
        assert!(text.contains("Processing: test-source-url"));
    } else {
        panic!("Expected text message");
    }

    // 应收到 debug_done 响应
    let msg = ws.next().await.unwrap().unwrap();
    if let Message::Text(text) = msg {
        assert!(text.contains("debug_done"));
        assert!(text.contains("Completed: test-source-url"));
    } else {
        panic!("Expected text message");
    }

    ws.close(None).await.ok();
}

#[tokio::test]
async fn test_ws_debug_rss_source_handshake() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/rss-source");

    let result = connect_async(&url).await;
    assert!(
        result.is_ok(),
        "Debug rss-source WebSocket handshake should succeed"
    );

    let (mut ws, _) = result.unwrap();
    futures_util::SinkExt::close(&mut ws).await.ok();
}

#[tokio::test]
async fn test_ws_debug_multiple_messages() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/book-source");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    use futures_util::{SinkExt, StreamExt};

    // 接收欢迎消息
    let _welcome = ws.next().await.unwrap().unwrap();

    // 发送多条消息并验证响应
    for i in 1..=3 {
        let req = format!("source-{i}");
        ws.send(Message::Text(req.clone().into())).await.unwrap();

        let msg = ws.next().await.unwrap().unwrap();
        if let Message::Text(text) = msg {
            assert!(text.contains(&format!("Processing: source-{i}")));
        } else {
            panic!("Expected text message");
        }

        // done 消息
        let msg = ws.next().await.unwrap().unwrap();
        if let Message::Text(text) = msg {
            assert!(text.contains(&format!("Completed: source-{i}")));
        } else {
            panic!("Expected text message");
        }
    }

    ws.close(None).await.ok();
}

#[tokio::test]
async fn test_ws_disconnect_handling() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/debug/book-source");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    use futures_util::StreamExt;

    // 接收欢迎消息
    let _welcome = ws.next().await.unwrap().unwrap();

    // 发送 Close 帧，服务端应优雅断开
    ws.close(None).await.unwrap();

    // 验证连接已关闭（下次读取应返回 None 或 Close 或协议错误）
    let next = ws.next().await;
    match next {
        None => {}                        // 连接已关闭
        Some(Ok(Message::Close(_))) => {} // 收到关闭确认
        Some(Err(_)) => {}                // 协议层断开（ResetWithoutClosingHandshake）
        Some(other) => panic!("Unexpected message after close: {other:?}"),
    }
}

#[tokio::test]
async fn test_ws_search_disconnect() {
    let base = start_test_server().await;
    let url = format!("{base}/api/ws/search");

    let (mut ws, _) = connect_async(&url).await.unwrap();

    use futures_util::StreamExt;

    // 接收欢迎消息
    let _welcome = ws.next().await.unwrap().unwrap();

    // 直接关闭
    ws.close(None).await.unwrap();

    // 验证连接已关闭
    let next = ws.next().await;
    match next {
        None => {}
        Some(Ok(Message::Close(_))) => {}
        _ => {}
    }
}

// ─── 自研 RSS 调试通道（批15e：echo 桩替换为真实引擎）──────────────────────

/// 回环 RSS 源站（列表 + 正文）
async fn start_mock_rss_site() -> String {
    use axum::response::Html;
    use axum::routing::get;

    let app = axum::Router::new()
        // 默认分类（无 sortUrl 配置）按 sourceUrl 请求根路径
        .route(
            "/",
            get(|| async {
                Html(
                    "<html><body>\
                     <div class=\"item\"><h2 class=\"title\">自研通道文章</h2>\
                     <a class=\"link\" href=\"/a/1\">一</a>\
                     <span class=\"desc\">自研通道描述</span></div>\
                     </body></html>"
                        .to_string(),
                )
            }),
        )
        .route(
            "/list",
            get(|| async {
                Html(
                    "<html><body>\
                     <div class=\"item\"><h2 class=\"title\">自研通道文章</h2>\
                     <a class=\"link\" href=\"/a/1\">一</a>\
                     <span class=\"desc\">自研通道描述</span></div>\
                     </body></html>"
                        .to_string(),
                )
            }),
        )
        .route(
            "/a/1",
            get(|| async {
                Html(
                    "<html><body><div class=\"content\">自研通道正文</div></body></html>"
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

/// 自研通道真实解析（非 echo）：connected → debug_log 阶段/字段行 → debug_done
#[tokio::test]
async fn test_ws_debug_rss_source_runs_real_parser() {
    use futures_util::{SinkExt, StreamExt};

    let _guard = RSS_DEBUG_SLOT_LOCK.lock().await;
    let base = start_mock_rss_site().await;
    let base_for_seed = base.clone();
    let ws_base = start_test_server_with(move |db| {
        RssSourceRepository::new(db.connection())
            .insert(&RssSource {
                source_url: base_for_seed.clone(),
                source_name: "自研通道源".to_string(),
                enabled: true,
                rule_articles: Some(".item".to_string()),
                rule_title: Some(".title@text".to_string()),
                rule_description: Some(".desc@text".to_string()),
                rule_link: Some(".link@href".to_string()),
                ..Default::default()
            })
            .unwrap();
    })
    .await;

    let (mut ws, _) = connect_async(format!("{ws_base}/api/ws/debug/rss-source"))
        .await
        .unwrap();

    // 既有的 connected 首帧
    let welcome = ws.next().await.unwrap().unwrap();
    match welcome {
        Message::Text(text) => {
            assert!(text.contains("\"type\":\"connected\""), "{text}");
            assert!(
                text.contains("rss source debug websocket connected"),
                "{text}"
            );
        }
        other => panic!("首帧应为 connected 文本，实际: {other:?}"),
    }

    // 纯文本请求兼容：整段文本按源 URL 处理（旧 echo 客户端形态）
    ws.send(Message::Text(base.clone().into())).await.unwrap();

    let mut logs = Vec::new();
    loop {
        match ws.next().await {
            Some(Ok(Message::Text(text))) => {
                let value: serde_json::Value = serde_json::from_str(&text).unwrap();
                match value["type"].as_str().unwrap_or_default() {
                    "debug_log" => logs.push(value["data"].as_str().unwrap_or("").to_string()),
                    "debug_done" => break,
                    "debug_error" => panic!("真实解析不应失败: {text}"),
                    other => panic!("未知消息类型 {other}: {text}"),
                }
            }
            other => panic!("调试应在 debug_done 结束: {other:?}"),
        }
    }

    assert!(
        logs.iter().any(|line| line.contains("︾开始解析")),
        "应输出原版阶段行: {logs:#?}"
    );
    assert!(
        logs.iter().any(|line| line.contains("┌获取列表")),
        "应走真实规则解析: {logs:#?}"
    );
    assert!(
        logs.iter().any(|line| line.contains("└列表大小:1")),
        "应输出真实文章数: {logs:#?}"
    );
    assert!(
        logs.iter()
            .any(|line| line.contains("⇒存在描述规则，不解析内容页")),
        "描述规则非空应止步列表: {logs:#?}"
    );
    assert!(
        logs.iter().any(|line| line.contains("︽解析完成")),
        "原版结束行应输出: {logs:#?}"
    );

    ws.close(None).await.ok();
}

/// 自研通道错误路径：源不存在 → debug_error + debug_done（连接保持）
#[tokio::test]
async fn test_ws_debug_rss_source_reports_missing_source() {
    use futures_util::{SinkExt, StreamExt};

    let _guard = RSS_DEBUG_SLOT_LOCK.lock().await;
    let ws_base = start_test_server().await;
    let (mut ws, _) = connect_async(format!("{ws_base}/api/ws/debug/rss-source"))
        .await
        .unwrap();

    let _welcome = ws.next().await.unwrap().unwrap();
    ws.send(Message::Text(
        serde_json::json!({ "tag": "https://none.example.com/feed" })
            .to_string()
            .into(),
    ))
    .await
    .unwrap();

    let error = ws.next().await.unwrap().unwrap();
    match error {
        Message::Text(text) => {
            assert!(text.contains("\"type\":\"debug_error\""), "{text}");
            assert!(text.contains("订阅源不存在"), "{text}");
        }
        other => panic!("应为 debug_error 文本，实际: {other:?}"),
    }
    let done = ws.next().await.unwrap().unwrap();
    match done {
        Message::Text(text) => assert!(text.contains("\"type\":\"debug_done\""), "{text}"),
        other => panic!("应为 debug_done 文本，实际: {other:?}"),
    }

    ws.close(None).await.ok();
}
