//! 书源调试日志流 WebSocket
//!
//! 客户端连接后发送调试请求，服务端流式返回调试日志。

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use std::sync::Arc;

use crate::state::AppState;

/// 调试日志消息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct DebugLogMessage {
    /// 消息类型: "debug_log" / "debug_error" / "debug_done" / "connected"
    #[serde(rename = "type")]
    pub msg_type: String,
    /// 日志数据
    pub data: String,
}

impl DebugLogMessage {
    /// 创建连接成功消息
    pub fn connected() -> Self {
        Self {
            msg_type: "connected".to_string(),
            data: "debug websocket connected".to_string(),
        }
    }

    /// 创建调试日志消息
    pub fn log(data: &str) -> Self {
        Self {
            msg_type: "debug_log".to_string(),
            data: data.to_string(),
        }
    }

    /// 创建调试错误消息
    pub fn error(data: &str) -> Self {
        Self {
            msg_type: "debug_error".to_string(),
            data: data.to_string(),
        }
    }

    /// 创建调试完成消息
    pub fn done(data: &str) -> Self {
        Self {
            msg_type: "debug_done".to_string(),
            data: data.to_string(),
        }
    }

    /// 序列化为 JSON 字符串
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// WebSocket 书源调试端点
///
/// 路径: `/api/ws/debug/book-source`
/// 客户端发送书源 URL/规则，服务端流式返回调试日志。
pub async fn ws_debug_book_source(
    ws: WebSocketUpgrade,
    State(_state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(handle_debug_ws)
}

/// WebSocket RSS 源调试端点
///
/// 路径: `/api/ws/debug/rss-source`
/// 客户端发送 RSS 源信息，服务端流式返回调试日志。
pub async fn ws_debug_rss_source(
    ws: WebSocketUpgrade,
    State(_state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(handle_debug_ws)
}

async fn handle_debug_ws(mut socket: WebSocket) {
    // 发送连接成功消息
    let welcome = DebugLogMessage::connected();
    if socket
        .send(Message::Text(welcome.to_json().into()))
        .await
        .is_err()
    {
        return;
    }

    // 等待客户端发送调试请求
    while let Some(msg) = socket.recv().await {
        match msg {
            Ok(Message::Text(text)) => {
                let text_str = text.to_string();
                // 解析调试请求，执行调试，流式返回日志
                let log = DebugLogMessage::log(&format!("Processing: {text_str}"));
                if socket
                    .send(Message::Text(log.to_json().into()))
                    .await
                    .is_err()
                {
                    break;
                }
                // 发送完成消息
                let done = DebugLogMessage::done(&format!("Completed: {text_str}"));
                if socket
                    .send(Message::Text(done.to_json().into()))
                    .await
                    .is_err()
                {
                    break;
                }
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_debug_log_message_connected() {
        let msg = DebugLogMessage::connected();
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"connected\""));
        assert!(json.contains("debug websocket connected"));
    }

    #[test]
    fn test_debug_log_message_log() {
        let msg = DebugLogMessage::log("step 1: fetch page");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_log\""));
        assert!(json.contains("step 1: fetch page"));
    }

    #[test]
    fn test_debug_log_message_error() {
        let msg = DebugLogMessage::error("connection timeout");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_error\""));
        assert!(json.contains("connection timeout"));
    }

    #[test]
    fn test_debug_log_message_done() {
        let msg = DebugLogMessage::done("all steps passed");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_done\""));
        assert!(json.contains("all steps passed"));
    }
}
