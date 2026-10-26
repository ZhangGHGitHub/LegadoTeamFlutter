//! RSS 源调试 WebSocket — 实时日志流（自研通道，批15e 接真实引擎）
//!
//! 对应 Kotlin RSS 源调试验证。客户端连接后发送调试请求，服务端复用原版
//! `/rssSourceDebug` 的同一执行函数（[`super::original::run_rss_source_debug`]）
//! 流式返回调试日志。
//!
//! ## 请求协议（既有 `{type, data}` 信封保持不变）
//!
//! - 首帧：`{"type":"connected","data":"rss source debug websocket connected"}`
//! - 请求（客户端 → 服务端，文本帧）：
//!   - JSON 对象 `{"tag":"<sourceUrl>","key":"<可选>"}`
//!     （`sourceUrl` 作为 `tag` 的别名同样接受）；
//!   - 非 JSON 文本按「源 URL」处理（兼容旧 echo 客户端的纯文本输入）。
//! - 响应：`debug_log`（阶段/请求/字段行，带原版 `[mm:ss.SSS]` 前缀）、
//!   `debug_error`（state=-1 失败行）、`debug_done`（本次调试结束，连接保持）。
//!
//! ## 执行语义
//!
//! - `key` 缺省/空白 → 原版两参流程（默认分类首项 → 列表 → 内容）；
//! - `key` 非空 → 原版 App 调试页三参分流（`::` 分类 / 绝对 URL 正文 /
//!   其它搜索），与原版 `/rssSourceDebug` 的同一引擎实现；
//! - 与书源/RSS 原版通道共享进程级调试单槽（`DebugSlot::try_acquire`）：
//!   占用中返回 `debug_error`「调试通道占用中，请稍后重试」+ `debug_done`；
//! - 请求级 HTTP 观测沿用批13 task-local 槽（与全局 HTTP 日志开关独立）。

use std::sync::Arc;

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    response::IntoResponse,
};
use tokio::sync::mpsc;

use crate::state::AppState;
use legado_db::repository::rss_source_repository::RssSourceRepository;

use super::original::{run_rss_source_debug, DebugEvent, DebugSink, DebugSlot, MSG_DEBUG_BUSY};

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

/// 自研通道的一条调试请求
#[derive(Debug)]
struct RssDebugRequest {
    /// 订阅源 URL（`tag` / `sourceUrl`）
    tag: String,
    /// 可选调试键（空 → 原版两参流程；非空 → 三参分流）
    key: Option<String>,
}

/// 解析请求文本（JSON 对象优先，非 JSON 文本按源 URL 兼容旧客户端）
fn parse_request(text: &str) -> Result<RssDebugRequest, &'static str> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("输入不能为空");
    }
    if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(trimmed) {
        let tag = ["tag", "sourceUrl"]
            .iter()
            .find_map(|field| map.get(*field))
            .and_then(lenient_string)
            .unwrap_or_default();
        let tag = tag.trim().to_string();
        if tag.is_empty() {
            return Err("输入不能为空");
        }
        let key = map
            .get("key")
            .and_then(lenient_string)
            .map(|key| key.trim().to_string())
            .filter(|key| !key.is_empty());
        return Ok(RssDebugRequest { tag, key });
    }
    // 非 JSON：兼容旧 echo 客户端（整段文本视作源 URL）
    Ok(RssDebugRequest {
        tag: trimmed.to_string(),
        key: None,
    })
}

/// Gson `Map<String, String>` 口径的宽松取值（字符串/数字/布尔）
fn lenient_string(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(text) => Some(text.clone()),
        serde_json::Value::Number(number) => Some(number.to_string()),
        serde_json::Value::Bool(boolean) => Some(boolean.to_string()),
        _ => None,
    }
}

/// WebSocket RSS 源调试端点
///
/// 路径: `/api/ws/debug/rss-source`
/// 客户端发送 RSS 源信息，服务端流式返回调试日志。
pub async fn ws_rss_source_debug(
    ws: WebSocketUpgrade,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_rss_source_debug(socket, state))
}

async fn handle_rss_source_debug(mut socket: WebSocket, state: Arc<AppState>) {
    // 发送连接成功消息（既有信封首帧）
    let welcome = RssSourceDebugMessage::connected();
    if send_message(&mut socket, welcome).await.is_err() {
        return;
    }

    // 接收调试请求，执行真实 RSS 引擎并实时推送日志；连接可复用多条请求
    while let Some(msg) = socket.recv().await {
        match msg {
            Ok(Message::Text(text)) => {
                if !run_one_request(&mut socket, &state, text.as_str()).await {
                    return;
                }
            }
            Ok(Message::Close(_)) | Err(_) => return,
            _ => {}
        }
    }
}

/// 执行一条调试请求并转发事件；返回连接是否可继续接收下一条请求
async fn run_one_request(socket: &mut WebSocket, state: &Arc<AppState>, text: &str) -> bool {
    let request = match parse_request(text) {
        Ok(request) => request,
        Err(message) => {
            let _ = send_message(socket, RssSourceDebugMessage::error(message)).await;
            let _ = send_message(socket, RssSourceDebugMessage::done("调试结束")).await;
            return true;
        }
    };

    // 查源（与 `RssSourceDao.getByKey` 同语义：按 sourceUrl 精确匹配）
    let lookup = {
        let db = state.db.lock().await;
        RssSourceRepository::new(db.connection()).find_by_url(&request.tag)
    };
    let source = match lookup {
        Ok(Some(source)) => source,
        Ok(None) => {
            let _ = send_message(socket, RssSourceDebugMessage::error("订阅源不存在")).await;
            let _ = send_message(socket, RssSourceDebugMessage::done("调试结束")).await;
            return true;
        }
        Err(e) => {
            tracing::warn!("自研 RSS 调试读取订阅源失败: {e}");
            let _ = send_message(socket, RssSourceDebugMessage::error("读取订阅源失败")).await;
            let _ = send_message(socket, RssSourceDebugMessage::done("调试结束")).await;
            return true;
        }
    };

    // 与书源/RSS 原版通道共享调试单槽（对齐 `Debug.tryAcquireCallback`）
    let Some(slot) = DebugSlot::try_acquire() else {
        let _ = send_message(socket, RssSourceDebugMessage::error(MSG_DEBUG_BUSY)).await;
        let _ = send_message(socket, RssSourceDebugMessage::done("调试结束")).await;
        return true;
    };

    let (tx, mut rx) = mpsc::unbounded_channel();
    let sink = DebugSink::new(tx);
    let task = tokio::spawn(legado_net::scope_debug_request_sink(
        sink.request_sink(),
        run_rss_source_debug(Arc::clone(state), source, request.key, sink),
    ));

    let keep_open = loop {
        tokio::select! {
            biased;
            event = rx.recv() => match event {
                Some(DebugEvent::Log(line)) => {
                    if send_message(socket, RssSourceDebugMessage::log(&line)).await.is_err() {
                        break false;
                    }
                }
                Some(DebugEvent::Error(line)) => {
                    if send_message(socket, RssSourceDebugMessage::error(&line)).await.is_err() {
                        break false;
                    }
                }
                Some(DebugEvent::Done) | None => {
                    let _ = send_message(socket, RssSourceDebugMessage::done("调试结束")).await;
                    break true;
                }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break false,
                // 调试执行中的其他客户端消息按原版忽略
                Some(Ok(_)) => {}
            }
        }
    };
    task.abort();
    drop(slot);
    keep_open
}

/// 发送一条信封消息
async fn send_message(
    socket: &mut WebSocket,
    message: RssSourceDebugMessage,
) -> Result<(), axum::Error> {
    socket.send(Message::Text(message.to_json().into())).await
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

    #[test]
    fn parse_request_accepts_tag_and_source_url_alias() {
        let request = parse_request(r#"{"tag":"https://rss.example.com/feed"}"#).unwrap();
        assert_eq!(request.tag, "https://rss.example.com/feed");
        assert!(request.key.is_none());

        let request =
            parse_request(r#"{"sourceUrl":"https://rss.example.com/f","key":" 科技 "}"#).unwrap();
        assert_eq!(request.tag, "https://rss.example.com/f");
        assert_eq!(request.key.as_deref(), Some("科技"), "key 应 trim");

        // 数字/布尔按 Gson 宽松口径转字符串
        let request = parse_request(r#"{"tag":123,"key":true}"#).unwrap();
        assert_eq!(request.tag, "123");
        assert_eq!(request.key.as_deref(), Some("true"));
    }

    #[test]
    fn parse_request_falls_back_to_raw_text_and_rejects_blank() {
        // 非 JSON：整段文本视作源 URL（兼容旧 echo 客户端）
        let request = parse_request("https://rss.example.com/feed").unwrap();
        assert_eq!(request.tag, "https://rss.example.com/feed");
        assert!(request.key.is_none());

        assert_eq!(parse_request("   ").unwrap_err(), "输入不能为空");
        assert_eq!(
            parse_request(r#"{"tag":"  "}"#).unwrap_err(),
            "输入不能为空"
        );
    }
}
