//! BackstageWebView DOM 执行通道 FFI（SOURCE_DIFF P1）
//!
//! 对 `legado_core::webview_channel` 的纯 FFI 包装：
//! - 事件流：[`run_webview_request_stream`]
//! - 回传：[`submit_webview_result`]
//! - 取消：[`cancel_webview_request`]

use std::time::Duration;

use legado_core::webview_channel::{self, WebViewRequest};

const STREAM_POLL_INTERVAL: Duration = Duration::from_secs(1);

pub fn serialize_event(request: &WebViewRequest) -> String {
    serde_json::to_string(request).unwrap_or_default()
}

/// WebView 请求事件流（长期存活）
pub async fn run_webview_request_stream<F>(mut on_event: F)
where
    F: FnMut(String) -> Result<(), String>,
{
    use std::sync::mpsc::RecvTimeoutError;

    let mut rx = webview_channel::webview_manager().subscribe();
    loop {
        let recv = tokio::task::spawn_blocking(move || {
            let item = rx.recv_timeout(STREAM_POLL_INTERVAL);
            (rx, item)
        })
        .await;
        let (next_rx, item) = match recv {
            Ok(v) => v,
            Err(_) => break,
        };
        rx = next_rx;
        match item {
            Ok(request) => {
                if on_event(serialize_event(&request)).is_err() {
                    break;
                }
            }
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

pub fn submit_webview_result(key: &str, result: &str) -> bool {
    webview_channel::submit_webview_result(key, result)
}

pub fn cancel_webview_request(key: &str) -> bool {
    webview_channel::cancel_webview_request(key)
}

pub fn pending_requests_json() -> String {
    let pending = webview_channel::webview_manager().pending();
    serde_json::to_string(&pending).unwrap_or_else(|_| "[]".to_string())
}
