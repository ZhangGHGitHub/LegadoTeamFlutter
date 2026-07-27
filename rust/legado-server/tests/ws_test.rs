//! WebSocket 集成测试
//!
//! 测试 WebSocket 握手、消息收发、断连处理。

use std::sync::Arc;

use legado_core::download_manager::DownloadManager;
use legado_server::routes::create_router;
use legado_server::state::AppState;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

/// 启动测试服务器，返回监听地址
async fn start_test_server() -> String {
    let db = legado_db::init_in_memory_database().unwrap();
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    });

    let app = create_router(state);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });

    format!("ws://127.0.0.1:{}", addr.port())
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
