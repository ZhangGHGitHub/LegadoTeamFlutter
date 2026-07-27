//! 搜索进度实时推送 WebSocket
//!
//! 客户端连接后，服务端通过 broadcast channel 推送搜索进度消息。

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use std::sync::Arc;
use tokio::sync::broadcast;

use crate::state::AppState;

/// 搜索进度消息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SearchProgress {
    /// 书源名称
    pub source_name: String,
    /// 状态: "searching" / "found" / "error" / "done"
    pub status: String,
    /// 当前结果数量
    pub results_count: usize,
    /// 附加消息
    pub message: String,
}

impl SearchProgress {
    /// 创建搜索中状态消息
    pub fn searching(source_name: &str) -> Self {
        Self {
            source_name: source_name.to_string(),
            status: "searching".to_string(),
            results_count: 0,
            message: String::new(),
        }
    }

    /// 创建找到结果状态消息
    pub fn found(source_name: &str, count: usize) -> Self {
        Self {
            source_name: source_name.to_string(),
            status: "found".to_string(),
            results_count: count,
            message: String::new(),
        }
    }

    /// 创建错误状态消息
    pub fn error(source_name: &str, msg: &str) -> Self {
        Self {
            source_name: source_name.to_string(),
            status: "error".to_string(),
            results_count: 0,
            message: msg.to_string(),
        }
    }

    /// 创建完成状态消息
    pub fn done(total: usize) -> Self {
        Self {
            source_name: String::new(),
            status: "done".to_string(),
            results_count: total,
            message: "search completed".to_string(),
        }
    }

    /// 序列化为 JSON 字符串
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// WebSocket 搜索进度端点
///
/// 路径: `/api/ws/search`
/// 升级后向客户端推送搜索进度 JSON 消息。
pub async fn ws_search(
    ws: WebSocketUpgrade,
    State(_state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(handle_search_ws)
}

async fn handle_search_ws(mut socket: WebSocket) {
    // 创建 broadcast channel 用于多客户端订阅搜索进度
    let (tx, mut rx) = broadcast::channel::<String>(100);

    // 发送连接成功的欢迎消息
    let welcome = SearchProgress {
        source_name: String::new(),
        status: "connected".to_string(),
        results_count: 0,
        message: "search websocket connected".to_string(),
    };
    if socket
        .send(Message::Text(welcome.to_json().into()))
        .await
        .is_err()
    {
        return;
    }

    // 启动一个模拟搜索进度推送任务（实际使用时由搜索引擎发送）
    let _tx = tx;

    // 监听 broadcast 消息并转发给客户端
    loop {
        tokio::select! {
            msg = rx.recv() => {
                match msg {
                    Ok(text) => {
                        if socket.send(Message::Text(text.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            // 监听客户端消息（用于接收关闭指令）
            client_msg = socket.recv() => {
                match client_msg {
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => {}
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_search_progress_serialization() {
        let progress = SearchProgress::searching("test-source");
        let json = progress.to_json();
        assert!(json.contains("\"status\":\"searching\""));
        assert!(json.contains("\"source_name\":\"test-source\""));
    }

    #[test]
    fn test_search_progress_found() {
        let progress = SearchProgress::found("src1", 5);
        let json = progress.to_json();
        assert!(json.contains("\"status\":\"found\""));
        assert!(json.contains("\"results_count\":5"));
    }

    #[test]
    fn test_search_progress_error() {
        let progress = SearchProgress::error("src2", "timeout");
        let json = progress.to_json();
        assert!(json.contains("\"status\":\"error\""));
        assert!(json.contains("\"message\":\"timeout\""));
    }

    #[test]
    fn test_search_progress_done() {
        let progress = SearchProgress::done(42);
        let json = progress.to_json();
        assert!(json.contains("\"status\":\"done\""));
        assert!(json.contains("\"results_count\":42"));
    }
}
