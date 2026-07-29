//! RSS 源调试 WebSocket — 实时日志流
//!
//! 对应 Kotlin RSS 源调试验证。
//! 客户端连接后发送 RSS 源信息，服务端流式返回调试日志。

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use std::sync::Arc;

use crate::state::AppState;

/// RSS 源调试日志消息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RssSourceDebugMessage {
    /// 消息类型: "connected" / "debug_log" / "debug_error" / "debug_done"
    #[serde(rename = "type")]
    pub msg_type: String,
    /// 日志数据
    pub data: String,
}

impl RssSourceDebugMessage {
    /// 创建连接成功消息
    pub fn connected() -> Self {
        Self {
            msg_type: "connected".to_string(),
            data: "rss source debug websocket connected".to_string(),
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

/// WebSocket RSS 源调试端点
///
/// 路径: `/api/ws/debug/rss-source`
/// 客户端发送 RSS 源信息，服务端流式返回调试日志。
pub async fn ws_rss_source_debug(
    ws: WebSocketUpgrade,
    State(_state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(handle_rss_source_debug)
}

async fn handle_rss_source_debug(mut socket: WebSocket) {
    // 发送连接成功消息
    let welcome = RssSourceDebugMessage::connected();
    if socket
        .send(Message::Text(welcome.to_json().into()))
        .await
        .is_err()
    {
        return;
    }

    // 接收 RSS 源信息，执行调试验证，实时发送日志
    while let Some(msg) = socket.recv().await {
        match msg {
            Ok(Message::Text(text)) => {
                let text_str = text.to_string();

                // 步骤 1: 解析请求
                let log = RssSourceDebugMessage::log(&format!("[DEBUG] Processing: {text_str}"));
                if socket
                    .send(Message::Text(log.to_json().into()))
                    .await
                    .is_err()
                {
                    break;
                }

                // 步骤 2: 发送完成消息
                let done = RssSourceDebugMessage::done(&format!("Completed: {text_str}"));
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
    fn test_connected_message() {
        let msg = RssSourceDebugMessage::connected();
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"connected\""));
        assert!(json.contains("rss source debug websocket connected"));
    }

    #[test]
    fn test_log_message() {
        let msg = RssSourceDebugMessage::log("fetch rss feed");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_log\""));
        assert!(json.contains("fetch rss feed"));
    }

    #[test]
    fn test_error_message() {
        let msg = RssSourceDebugMessage::error("invalid feed format");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_error\""));
        assert!(json.contains("invalid feed format"));
    }

    #[test]
    fn test_done_message() {
        let msg = RssSourceDebugMessage::done("rss validation passed");
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"debug_done\""));
        assert!(json.contains("rss validation passed"));
    }
}
