//! BackstageWebView DOM 执行通道（SOURCE_DIFF P1 完整 DOM WebView）
//!
//! 对齐 Kotlin `BackstageWebView.getStrResponse` 的挂起-唤醒机制：
//! Rust 解析/JS 宿主发起请求 → 生成 key 入队并阻塞等待 →
//! Flutter 订阅事件流用真实 WebView 执行 → `submit` 回传结果唤醒。
//!
//! # 语义与边界
//! - 默认超时 60s（对齐 `BackstageWebView` withTimeout）；规则级 Mode.WebJs 用 10s
//! - 无订阅者时请求方应走无头 QuickJS 回退（本模块 `has_subscribers`）
//! - 空结果允许唤醒（对齐原版 evaluateJavascript 返回 `""`/`null` 的可空语义）
//! - **边界**：DOM `document`/`window`/`result` 可用；Android 页内经原生
//!   Backstage 注入 `java`/`source`/`cache` JavascriptInterface；`cacheFirst`
//!   → `LOAD_CACHE_ELSE_NETWORK`

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{LegadoError, LegadoResult};

/// 默认超时：60s（对齐 Kotlin BackstageWebView）
pub const DEFAULT_WEBVIEW_TIMEOUT: Duration = Duration::from_secs(60);

/// 规则级 Mode.WebJs / `@webjs` 超时：10s（对齐 AnalyzeRule.getWebJsResult）
pub const RULE_WEBVIEW_TIMEOUT: Duration = Duration::from_secs(10);

/// WebView 执行请求事件（推送给 Flutter 的载荷）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WebViewRequest {
    /// 请求唯一标识（回传结果时使用）
    pub key: String,
    /// 动作：webView / webViewGetSource / webViewGetOverrideUrl
    pub action: String,
    pub html: String,
    pub url: String,
    pub js: String,
    #[serde(default)]
    pub source_regex: String,
    #[serde(default)]
    pub override_url_regex: String,
    #[serde(default)]
    pub cache_first: bool,
    #[serde(default)]
    pub delay_time: i64,
    /// 规则级 Mode.WebJs：注入 window.result，timeout 更短
    #[serde(default)]
    pub is_rule: bool,
    /// 规则级注入的 result JSON/文本（对齐 CacheManager webview_result）
    #[serde(default)]
    pub result: String,
    pub created_at_ms: u64,
}

enum Outcome {
    Done(String),
}

struct Attempt {
    request: WebViewRequest,
    outcome: Mutex<Option<Outcome>>,
    cond: Condvar,
}

/// WebView 请求管理器（全局单例）
pub struct WebViewManager {
    attempts: Mutex<HashMap<String, Arc<Attempt>>>,
    subscribers: Mutex<Vec<Sender<WebViewRequest>>>,
    seq: AtomicU64,
}

impl WebViewManager {
    fn new_leaked() -> &'static Self {
        Box::leak(Box::new(Self::new()))
    }

    fn new() -> Self {
        Self {
            attempts: Mutex::new(HashMap::new()),
            subscribers: Mutex::new(Vec::new()),
            seq: AtomicU64::new(0),
        }
    }

    fn new_key(&self) -> String {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        format!("webview-{ts}-{seq}")
    }

    /// 是否有 Flutter 侧订阅者（无订阅则调用方应无头回退）
    pub fn has_subscribers(&self) -> bool {
        let mut subs = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
        // 顺带清理断开的发送端
        subs.retain(|s| {
            // 空探测：不发送实际请求；用 try 无法探测，保留长度
            let _ = s;
            true
        });
        // 更可靠：广播前 retain send ok；此处仅看是否非空
        !subs.is_empty()
    }

    pub fn request(&'static self, mut req: WebViewRequest) -> WebViewHandle {
        let key = self.new_key();
        req.key = key.clone();
        if req.created_at_ms == 0 {
            req.created_at_ms = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
        }
        let attempt = Arc::new(Attempt {
            request: req.clone(),
            outcome: Mutex::new(None),
            cond: Condvar::new(),
        });
        {
            let mut attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
            attempts.insert(key, attempt.clone());
        }
        self.broadcast(req);
        WebViewHandle {
            attempt,
            manager: self,
        }
    }

    pub fn submit(&self, key: &str, result: &str) -> bool {
        self.finish(key, Outcome::Done(result.to_string()))
    }

    pub fn cancel(&self, key: &str) -> bool {
        self.finish(key, Outcome::Done(String::new()))
    }

    fn finish(&self, key: &str, outcome: Outcome) -> bool {
        let attempt = {
            let mut attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
            attempts.remove(key)
        };
        match attempt {
            Some(attempt) => {
                let mut guard = attempt.outcome.lock().unwrap_or_else(|e| e.into_inner());
                if guard.is_none() {
                    *guard = Some(outcome);
                }
                attempt.cond.notify_all();
                true
            }
            None => false,
        }
    }

    pub fn subscribe(&self) -> Receiver<WebViewRequest> {
        let (tx, rx) = channel();
        {
            let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
            subscribers.push(tx.clone());
        }
        for req in self.pending() {
            let _ = tx.send(req);
        }
        rx
    }

    pub fn pending(&self) -> Vec<WebViewRequest> {
        let attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
        let mut list: Vec<WebViewRequest> = attempts
            .values()
            .filter(|a| a.outcome.lock().unwrap_or_else(|e| e.into_inner()).is_none())
            .map(|a| a.request.clone())
            .collect();
        list.sort_by(|a, b| a.key.cmp(&b.key));
        list
    }

    fn broadcast(&self, request: WebViewRequest) {
        let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
        subscribers.retain(|s| s.send(request.clone()).is_ok());
    }
}

/// 请求句柄
pub struct WebViewHandle {
    attempt: Arc<Attempt>,
    manager: &'static WebViewManager,
}

impl WebViewHandle {
    pub fn key(&self) -> &str {
        &self.attempt.request.key
    }

    /// 阻塞等待 WebView 执行结果（可空串）
    pub fn wait(self, timeout: Duration) -> LegadoResult<String> {
        let deadline = Instant::now() + timeout;
        let mut guard = self
            .attempt
            .outcome
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(outcome) = guard.as_ref() {
                let result = match outcome {
                    Outcome::Done(c) => c.clone(),
                };
                return Ok(result);
            }
            let now = Instant::now();
            if now >= deadline {
                drop(guard);
                self.manager.cancel(self.attempt.request.key.as_str());
                return Err(LegadoError::Timeout(
                    "webview execution timed out".to_string(),
                ));
            }
            let (next, _) = self
                .attempt
                .cond
                .wait_timeout(guard, deadline - now)
                .unwrap_or_else(|e| e.into_inner());
            guard = next;
        }
    }
}

static MANAGER: OnceLock<&'static WebViewManager> = OnceLock::new();

pub fn webview_manager() -> &'static WebViewManager {
    *MANAGER.get_or_init(WebViewManager::new_leaked)
}

pub fn has_subscribers() -> bool {
    webview_manager().has_subscribers()
}

/// 发起并等待 WebView 执行
pub fn request_and_wait(req: WebViewRequest, timeout: Duration) -> LegadoResult<String> {
    let handle = webview_manager().request(req);
    handle.wait(timeout)
}

pub fn submit_webview_result(key: &str, result: &str) -> bool {
    webview_manager().submit(key, result)
}

pub fn cancel_webview_request(key: &str) -> bool {
    webview_manager().cancel(key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn submit_wakes_waiter() {
        let mgr = WebViewManager::new_leaked();
        let rx = mgr.subscribe();
        let handle = mgr.request(WebViewRequest {
            key: String::new(),
            action: "webView".into(),
            html: "<p>hi</p>".into(),
            url: "https://example.com".into(),
            js: "document.body.innerText".into(),
            source_regex: String::new(),
            override_url_regex: String::new(),
            cache_first: true,
            delay_time: 0,
            is_rule: true,
            result: "\"x\"".into(),
            created_at_ms: 0,
        });
        let key = handle.key().to_string();
        let waiter = thread::spawn(move || handle.wait(Duration::from_secs(5)));
        let evt = rx.recv_timeout(Duration::from_secs(2)).expect("event");
        assert_eq!(evt.key, key);
        assert!(mgr.submit(&key, "from-dom"));
        assert_eq!(waiter.join().unwrap().unwrap(), "from-dom");
    }
}
