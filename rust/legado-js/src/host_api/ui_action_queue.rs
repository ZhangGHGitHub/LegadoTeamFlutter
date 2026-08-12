//! 中途 UI 副作用队列（SourceCallBack / SourceLoginJsExtensions 桥）
//!
//! Kotlin `callBackBtn` 在 JS 求值过程中可通过 `java.showBrowser` /
//! `java.refreshBookInfo` 等触发 Activity 侧副作用；无头 QuickJS 无法同步弹 UI，
//! 因此在求值期间收集结构化 action，由 FFI 结果一并回传 Flutter 执行。
//!
//! 用法：
//! 1. [`begin_collect`] 清空并开启收集
//! 2. 执行 callBackJs（宿主 API 经 [`push_action`] / [`push_payload_json`] 入队）
//! 3. [`end_collect`] 关闭收集并取出全部 action

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use serde_json::Value;

static COLLECTING: AtomicBool = AtomicBool::new(false);
static QUEUE: Mutex<Vec<Value>> = Mutex::new(Vec::new());

/// 开启收集并清空旧队列（对齐一次 `callBackBtn` 会话）
pub fn begin_collect() {
    COLLECTING.store(true, Ordering::SeqCst);
    if let Ok(mut q) = QUEUE.lock() {
        q.clear();
    }
}

/// 是否正在收集（供宿主 API 决定是否入队）
pub fn is_collecting() -> bool {
    COLLECTING.load(Ordering::SeqCst)
}

/// 入队一个结构化 action（仅在收集开启时生效）
pub fn push_action(action: Value) {
    if !is_collecting() {
        return;
    }
    if let Ok(mut q) = QUEUE.lock() {
        q.push(action);
    }
}

/// 将平台桥接 JSON 字符串解析后入队（失败则忽略）
pub fn push_payload_json(payload_json: &str) {
    if !is_collecting() {
        return;
    }
    if let Ok(v) = serde_json::from_str::<Value>(payload_json) {
        push_action(v);
    }
}

/// 结束收集并取出全部 action
pub fn end_collect() -> Vec<Value> {
    COLLECTING.store(false, Ordering::SeqCst);
    QUEUE
        .lock()
        .map(|mut q| q.drain(..).collect())
        .unwrap_or_default()
}

/// 丢弃队列并关闭收集（求值失败时调用）
pub fn discard_collect() {
    COLLECTING.store(false, Ordering::SeqCst);
    if let Ok(mut q) = QUEUE.lock() {
        q.clear();
    }
}

/// SourceLoginJsExtensions 中途 UI 动作构造
pub mod source_login_ext {
    use super::push_action;
    use serde_json::json;

    pub fn refresh_book_info() {
        push_action(json!({ "action": "refreshBookInfo" }));
    }

    pub fn refresh_book_toc() {
        push_action(json!({ "action": "refreshBookToc" }));
    }

    pub fn refresh_content() {
        push_action(json!({ "action": "refreshContent" }));
    }

    pub fn copy_text(text: &str) {
        push_action(json!({ "action": "copyText", "text": text }));
    }

    pub fn clear_tts_cache() {
        push_action(json!({ "action": "clearTtsCache" }));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collect_drain_and_ignore_when_off() {
        // 单测串行：全局队列不可与 discard 并发交错
        discard_collect();
        push_action(serde_json::json!({"action":"copyText","text":"a"}));
        assert!(end_collect().is_empty());

        begin_collect();
        push_action(serde_json::json!({"action":"refreshBookInfo"}));
        push_payload_json(r#"{"action":"openBrowser","url":"http://x"}"#);
        let actions = end_collect();
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0]["action"], "refreshBookInfo");
        assert_eq!(actions[1]["action"], "openBrowser");
        assert!(end_collect().is_empty());
    }
}
