//! 验证码交互通道 FFI API（Task #90，加法式新增）
//!
//! 对 `legado_core::verification_channel` 的纯 FFI 包装，
//! 打通「书源 JS 挂起等待 ↔ Flutter 验证码对话框」的事件通道：
//!
//! - 事件流：[`run_verification_request_stream`]（Flutter 订阅验证码请求事件）
//! - 回传：[`submit_verification_result`]（用户输入验证码后唤醒 JS 等待方）
//! - 取消：[`cancel_verification_request`]（UI 关闭对话框时以空结果收尾）
//!
//! 事件 JSON 字段契约（snake_case）：
//! `key` / `source_url` / `source_name` / `image_url` / `title` /
//! `use_browser`（桌面端恒 false，浏览器模式已降级） / `created_at_ms`。
//!
//! 对齐 Kotlin `SourceVerificationHelp` + `VerificationCodeDialog` 流程。

use std::time::Duration;

use legado_core::verification_channel::{self, VerificationRequest};
use legado_db::BookSourceRepository;

use crate::db_state::with_database;

/// 事件流轮询间隔（无事件时避免空转，同时保证 sink 关闭能及时感知）
const STREAM_POLL_INTERVAL: Duration = Duration::from_secs(1);

/// 补全请求载荷的书源名称后序列化为事件 JSON
///
/// JS 钩子侧只能拿到书源 URL（线程上下文），名称由 FFI 层查库补全
/// （对齐 Kotlin `VerificationCodeActivity` 的 `sourceName` extra）；
/// 查库失败（如数据库未初始化）时保持空字符串。
pub fn serialize_event(mut request: VerificationRequest) -> String {
    if request.source_name.is_empty() && !request.source_url.is_empty() {
        if let Ok(Some(source)) = with_database(|db| {
            BookSourceRepository::new(db.connection()).find_by_url(&request.source_url)
        }) {
            request.source_name = source.book_source_name;
        }
    }
    serde_json::to_string(&request).unwrap_or_default()
}

/// 验证码请求事件流（长期存活，直到 `on_event` 返回 Err / 通道断开）
///
/// 订阅全局验证码通道：先回放当前所有进行中的请求（晚订阅的 UI
/// 不会错过已挂起的验证），之后实时推送新请求事件。
///
/// `on_event` — 每个请求事件的回调（JSON 字符串）；返回 `Err` 时结束流
///（如 flutter_rust_bridge 的 sink 已关闭）。
///
/// 供 flutter_rust_bridge 的 `StreamSink` 绑定使用
///（在 ffi.rs 中将 `on_event` 接到 `sink.add`）。
pub async fn run_verification_request_stream<F>(mut on_event: F)
where
    F: FnMut(String) -> Result<(), String>,
{
    use std::sync::mpsc::RecvTimeoutError;

    let mut rx = verification_channel::verification_manager().subscribe();
    loop {
        // std mpsc 阻塞接收放入 blocking 池，不占用 tokio 工作者线程
        let recv = tokio::task::spawn_blocking(move || {
            let item = rx.recv_timeout(STREAM_POLL_INTERVAL);
            (rx, item)
        })
        .await;
        let (next_rx, item) = match recv {
            Ok(v) => v,
            // blocking 任务被中止（runtime 关闭）：结束流
            Err(_) => break,
        };
        rx = next_rx;
        match item {
            Ok(request) => {
                if on_event(serialize_event(request)).is_err() {
                    break;
                }
            }
            // 无事件：继续轮询（长期存活流）
            Err(RecvTimeoutError::Timeout) => continue,
            // 所有发送方已断开（管理器被回收，实际不会发生）：结束流
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// 提交验证码结果，唤醒 JS 等待方（对齐 Kotlin `setResult`）
///
/// `key` — 请求事件中的 resultKey；`code` — 用户输入的验证码。
/// 返回是否命中进行中的请求（重复提交 / 已结束的请求返回 false）。
pub fn submit_verification_result(key: &str, code: &str) -> bool {
    verification_channel::submit_verification_result(key, code)
}

/// 取消验证码请求（对齐 Kotlin `checkResult`：UI 关闭对话框未提交）
///
/// 以空结果唤醒等待方（等待侧报「验证结果为空」，对齐 Kotlin 语义）。
pub fn cancel_verification_request(key: &str) -> bool {
    verification_channel::cancel_verification_request(key)
}

/// 当前进行中的验证码请求列表（JSON 数组，供拉取式消费/调试）
pub fn pending_requests_json() -> String {
    let pending = verification_channel::verification_manager().pending();
    serde_json::to_string(&pending).unwrap_or_else(|_| "[]".to_string())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// 在事件流中定位指定 image_url 的请求（过滤其他测试的事件）
    fn find_event_key(
        rx: &std::sync::mpsc::Receiver<VerificationRequest>,
        image_url: &str,
    ) -> Option<String> {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == image_url => return Some(req.key),
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        None
    }

    /// 完整流程：JS 侧发起 → 订阅收到事件 → 提交 → JS 侧拿到结果
    #[tokio::test]
    async fn test_stream_request_submit_flow() {
        let image_url = "http://img.com/ffi-stream-test.png";

        // JS 侧：后台线程发起并挂起（模拟 quickjs 工作线程）
        let url = image_url.to_string();
        let js_result = tokio::task::spawn_blocking(move || {
            verification_channel::request_verification_code(
                "https://ffi-source.example.com",
                "",
                &url,
                "",
                false,
            )
        });

        // UI 侧：订阅事件流，收到第一条后提交并关闭流
        let url_match = image_url.to_string();
        let stream_done = tokio::spawn(async move {
            let mut submitted_key: Option<String> = None;
            run_verification_request_stream(|json| {
                let req: VerificationRequest = match serde_json::from_str(&json) {
                    Ok(r) => r,
                    Err(_) => return Ok(()),
                };
                if req.image_url == url_match {
                    submitted_key = Some(req.key.clone());
                    // 提交后返回 Err 结束流（模拟 sink 关闭）
                    submit_verification_result(&req.key, "ffi-code");
                    return Err("done".to_string());
                }
                Ok(())
            })
            .await;
            submitted_key
        });

        let code = tokio::time::timeout(Duration::from_secs(10), js_result)
            .await
            .expect("JS 等待应在超时前完成")
            .unwrap()
            .expect("应拿到验证码");
        assert_eq!(code, "ffi-code");
        assert!(stream_done.await.unwrap().is_some(), "事件流应收到请求");
    }

    /// 取消流程：UI 关闭对话框 → JS 侧报「验证结果为空」
    #[tokio::test]
    async fn test_stream_cancel_flow() {
        let image_url = "http://img.com/ffi-cancel-test.png";

        let url = image_url.to_string();
        let js_result = tokio::task::spawn_blocking(move || {
            verification_channel::request_verification_code(
                "https://ffi-cancel.example.com",
                "",
                &url,
                "",
                false,
            )
        });

        let rx = verification_channel::verification_manager().subscribe();
        let key = find_event_key(&rx, image_url).expect("应收到请求事件");
        assert!(cancel_verification_request(&key));

        let err = tokio::time::timeout(Duration::from_secs(10), js_result)
            .await
            .unwrap()
            .unwrap()
            .expect_err("取消后应报错");
        assert!(err.to_string().contains("验证结果为空"));
    }

    /// 提交未知 key / 重复提交的行为
    #[test]
    fn test_submit_unknown_and_duplicate() {
        assert!(!submit_verification_result("no-such-key", "x"));

        let mgr = verification_channel::verification_manager();
        let handle = mgr.request(
            "https://ffi-dup.example.com",
            "",
            "http://img.com/ffi-dup-test.png",
            "",
            false,
        );
        let key = handle.key().to_string();
        assert!(submit_verification_result(&key, "first"));
        assert!(
            !submit_verification_result(&key, "second"),
            "已结束请求应返回 false"
        );
        assert_eq!(handle.wait(Duration::from_secs(5)).unwrap(), "first");
    }

    /// 事件 JSON 字段契约（snake_case）
    #[test]
    fn test_serialize_event_contract() {
        let req = VerificationRequest {
            key: "verif-1".to_string(),
            source_url: "https://s.example.com".to_string(),
            source_name: "测试源".to_string(),
            image_url: "http://img.example.com/c.png".to_string(),
            title: "请输入验证码".to_string(),
            use_browser: false,
            created_at_ms: 123,
        };
        let json = serialize_event(req);
        for field in [
            "\"key\"",
            "\"source_url\"",
            "\"source_name\"",
            "\"image_url\"",
            "\"title\"",
            "\"use_browser\"",
            "\"created_at_ms\"",
        ] {
            assert!(json.contains(field), "缺少字段 {field}: {json}");
        }
    }

    /// pending_requests_json 返回合法 JSON 数组
    #[test]
    fn test_pending_requests_json() {
        let json = pending_requests_json();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(parsed.is_array());
    }
}
