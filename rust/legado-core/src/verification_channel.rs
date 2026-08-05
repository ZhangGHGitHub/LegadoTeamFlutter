//! 验证码交互通道（Task #90）
//!
//! 对齐 Kotlin `SourceVerificationHelp` 的挂起-唤醒机制：
//! 书源 JS 经 `getVerificationCode(imageUrl)` 钩子发起请求 →
//! 生成 resultKey 入队并挂起等待 → UI 订阅事件流弹验证码对话框 →
//! 用户输入后 `submit_verification_result(key, code)` 唤醒等待方。
//!
//! # 语义对齐（Kotlin SourceVerificationHelp）
//! - 默认超时 5 分钟（`flightWaitTime = 5.minutes`）
//! - `setResult` 无论值是否为空都会唤醒等待方，空值判定在等待侧
//!   （`waitForVerification` 抛 "验证结果为空"）
//! - UI 关闭对话框（未提交）等价于 `checkResult`：以空结果唤醒
//! - 同 sourceUrl 并发请求共享结果（复用 Kotlin `VerificationFlightRegistry`
//!   的航班去重思想，见 `legado-net::verification::VerificationFlightRegistry`）
//!
//! # 线程模型
//! - 等待侧（JS 工作线程）：condvar 阻塞，仅使用 std 同步原语，
//!   不依赖 tokio runtime，可安全运行于 spawn_blocking / 任意工作线程
//! - 提交侧（FFI/UI 线程）：`submit` / `cancel` 无阻塞，condvar notify 唤醒
//! - 订阅侧（FFI 流）：std::sync::mpsc，跨线程接收请求事件

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::error::{LegadoError, LegadoResult};

/// 默认挂起等待超时：5 分钟（对齐 Kotlin `SourceVerificationHelp.flightWaitTime`）
pub const DEFAULT_VERIFICATION_TIMEOUT: Duration = Duration::from_secs(300);

/// 验证码请求事件（推送给 UI 订阅方的载荷）
///
/// 字段契约（JSON snake_case）：
/// - `key` — 本次请求的唯一标识（回传结果时使用）
/// - `source_url` — 发起请求的书源 URL
/// - `source_name` — 书源名称（可能为空，FFI 层按 source_url 补全）
/// - `image_url` — 验证码图片地址
/// - `title` — 对话框标题（对齐 Kotlin title 参数）
/// - `use_browser` — 是否需要浏览器交互（桌面端一律 false，浏览器模式已降级）
/// - `created_at_ms` — 请求创建时间（毫秒时间戳）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VerificationRequest {
    /// 请求唯一标识（resultKey）
    pub key: String,
    /// 书源 URL
    pub source_url: String,
    /// 书源名称（可为空）
    pub source_name: String,
    /// 验证码图片 URL
    pub image_url: String,
    /// 对话框标题
    pub title: String,
    /// 是否需要浏览器（桌面端降级，恒为 false）
    pub use_browser: bool,
    /// 创建时间（毫秒时间戳）
    pub created_at_ms: u64,
}

/// 等待结局（对齐 Kotlin `VerificationAttempt.result: Pair<url, code>`）
///
/// 注意：Kotlin `setResult` 空值也会唤醒，空值校验在等待侧完成，
/// 因此这里不区分「空结果」与「取消」，统一以 `Done(code)` 承载。
enum Outcome {
    /// 已提交（code 可能为空字符串，由等待侧判定「验证结果为空」）
    Done(String),
}

/// 单次验证尝试（共享给航班内所有等待方）
struct Attempt {
    /// 请求载荷
    request: VerificationRequest,
    /// 结局槽位（None = 等待中）
    outcome: Mutex<Option<Outcome>>,
    /// 唤醒条件变量
    cond: Condvar,
}

/// 验证请求管理器
///
/// 全局单例，承载请求表 / 航班去重索引 / 事件订阅者列表。
pub struct VerificationManager {
    /// 请求表：key → 尝试
    attempts: Mutex<HashMap<String, Arc<Attempt>>>,
    /// 航班索引：source_url → key（同书源并发请求去重共享结果）
    flights: Mutex<HashMap<String, String>>,
    /// 事件订阅者（FFI 流）
    subscribers: Mutex<Vec<Sender<VerificationRequest>>>,
    /// key 自增序号
    seq: AtomicU64,
}

impl VerificationManager {
    /// 创建泄漏的 `'static` 管理器（全局单例与测试隔离实例共用）
    fn new_leaked() -> &'static Self {
        Box::leak(Box::new(Self {
            attempts: Mutex::new(HashMap::new()),
            flights: Mutex::new(HashMap::new()),
            subscribers: Mutex::new(Vec::new()),
            seq: AtomicU64::new(0),
        }))
    }

    fn new() -> Self {
        Self {
            attempts: Mutex::new(HashMap::new()),
            flights: Mutex::new(HashMap::new()),
            subscribers: Mutex::new(Vec::new()),
            seq: AtomicU64::new(0),
        }
    }

    /// 生成唯一 resultKey（对齐 Kotlin `UUID.randomUUID().toString()` 的用途）
    fn new_key(&self) -> String {
        let seq = self.seq.fetch_add(1, Ordering::Relaxed);
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        format!("verif-{ts}-{seq}")
    }

    /// 发起验证码请求
    ///
    /// - 同 `source_url` 已有进行中的请求时：加入既有航班（不重复推送事件），
    ///   所有等待方共享同一结果（对齐 Kotlin 航班去重语义）
    /// - 否则：创建新请求并向所有订阅者广播事件
    pub fn request(
        &'static self,
        source_url: &str,
        source_name: &str,
        image_url: &str,
        title: &str,
        use_browser: bool,
    ) -> VerificationHandle {
        // 锁序约定：attempts → flights（全局一致，避免死锁）
        let mut attempts = self
            .attempts
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let mut flights = self
            .flights
            .lock()
            .unwrap_or_else(|e| e.into_inner());

        // 航班去重：同书源并发请求共享结果（匿名请求不参与去重，避免跨书源串扰）
        if !source_url.is_empty() {
            if let Some(key) = flights.get(source_url) {
                if let Some(attempt) = attempts.get(key) {
                    return VerificationHandle {
                        attempt: attempt.clone(),
                        joined: true,
                        is_owner: false,
                        manager: self,
                    };
                }
            }
        }

        let key = self.new_key();
        let request = VerificationRequest {
            key: key.clone(),
            source_url: source_url.to_string(),
            source_name: source_name.to_string(),
            image_url: image_url.to_string(),
            title: title.to_string(),
            use_browser,
            created_at_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0),
        };
        let attempt = Arc::new(Attempt {
            request: request.clone(),
            outcome: Mutex::new(None),
            cond: Condvar::new(),
        });
        attempts.insert(key.clone(), attempt.clone());
        if !source_url.is_empty() {
            flights.insert(source_url.to_string(), key);
        }
        drop(flights);
        drop(attempts);

        // 广播新请求事件（订阅者断开时自动清理）
        self.broadcast(request.clone());

        VerificationHandle {
            attempt,
            joined: false,
            is_owner: true,
            manager: self,
        }
    }

    /// 提交验证码结果，唤醒等待方（对齐 Kotlin `setResult`）
    ///
    /// 空字符串同样唤醒（对齐 Kotlin：空值判定在等待侧）。
    /// 返回 `true` 表示命中了一个进行中的请求。
    pub fn submit(&self, key: &str, code: &str) -> bool {
        self.finish(key, Outcome::Done(code.to_string()))
    }

    /// 取消请求（对齐 Kotlin `checkResult`：UI 关闭对话框未提交时以空结果唤醒）
    ///
    /// 返回 `true` 表示命中了一个进行中的请求。
    pub fn cancel(&self, key: &str) -> bool {
        self.finish(key, Outcome::Done(String::new()))
    }

    /// 结束请求：移出注册表并唤醒所有等待方
    fn finish(&self, key: &str, outcome: Outcome) -> bool {
        let attempt = {
            let mut attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
            let mut flights = self.flights.lock().unwrap_or_else(|e| e.into_inner());
            // 同步清理航班索引（仅当仍指向本 key）
            flights.retain(|_, k| k != key);
            attempts.remove(key)
        };
        match attempt {
            Some(attempt) => {
                let mut guard = attempt.outcome.lock().unwrap_or_else(|e| e.into_inner());
                // 幂等：已有结局时保留首次结果（对齐 Kotlin compareAndSet(null, ...)）
                if guard.is_none() {
                    *guard = Some(outcome);
                }
                attempt.cond.notify_all();
                true
            }
            None => false,
        }
    }

    /// 订阅验证码请求事件流
    ///
    /// 返回的 Receiver 跨线程可用；订阅时先回放当前所有进行中的请求
    /// （避免晚订阅的 UI 错过已弹出的验证），之后实时接收新请求。
    pub fn subscribe(&self) -> Receiver<VerificationRequest> {
        let (tx, rx) = channel();
        {
            let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
            subscribers.push(tx.clone());
        }
        // 回放进行中的请求（对齐 Kotlin：UI 恢复时能看到仍挂起的验证）
        for req in self.pending() {
            let _ = tx.send(req);
        }
        rx
    }

    /// 当前进行中的请求列表（按 key 排序，便于稳定回放）
    pub fn pending(&self) -> Vec<VerificationRequest> {
        let attempts = self.attempts.lock().unwrap_or_else(|e| e.into_inner());
        let mut list: Vec<VerificationRequest> = attempts
            .values()
            .filter(|a| a.outcome.lock().unwrap_or_else(|e| e.into_inner()).is_none())
            .map(|a| a.request.clone())
            .collect();
        list.sort_by(|a, b| a.key.cmp(&b.key));
        list
    }

    /// 进行中的请求数量
    pub fn pending_count(&self) -> usize {
        self.pending().len()
    }

    /// 广播事件给所有订阅者（断开的订阅者自动移除）
    fn broadcast(&self, request: VerificationRequest) {
        let mut subscribers = self.subscribers.lock().unwrap_or_else(|e| e.into_inner());
        subscribers.retain(|s| s.send(request.clone()).is_ok());
    }
}

impl Default for VerificationManager {
    fn default() -> Self {
        Self::new()
    }
}

/// 请求句柄：由 [`VerificationManager::request`] 返回，供等待方挂起
pub struct VerificationHandle {
    attempt: Arc<Attempt>,
    /// 是否加入了既有航班（true = 与并发请求共享结果）
    pub joined: bool,
    /// 是否为航班 owner（owner 超时负责清理悬挂状态）
    is_owner: bool,
    /// 所属管理器（超时清理需回到同一实例，避免测试隔离实例误走全局单例）
    manager: &'static VerificationManager,
}

impl VerificationHandle {
    /// 请求 key（resultKey）
    pub fn key(&self) -> &str {
        &self.attempt.request.key
    }

    /// 请求载荷
    pub fn request(&self) -> &VerificationRequest {
        &self.attempt.request
    }

    /// 阻塞等待验证结果（对齐 Kotlin `waitForVerification` 挂起语义）
    ///
    /// 必须在后台线程调用（对齐 Kotlin `check(!isMainThread)`），
    /// 内部使用 std condvar，不会阻塞 tokio runtime 工作者。
    ///
    /// - 提交非空结果 → `Ok(code)`
    /// - 提交空结果 / 取消 → `Err`（"验证结果为空"，对齐 Kotlin）
    /// - 超时 → `Err`（"source verification timed out"，对齐 Kotlin）
    pub fn wait(self, timeout: Duration) -> LegadoResult<String> {
        let deadline = Instant::now() + timeout;
        let mut guard = self
            .attempt
            .outcome
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(outcome) = guard.as_ref() {
                let code = match outcome {
                    Outcome::Done(c) => c.clone(),
                };
                drop(guard);
                // 空值判定在等待侧（对齐 Kotlin：result.second.isEmpty() → 抛错）
                if code.is_empty() {
                    return Err(LegadoError::Internal("验证结果为空".to_string()));
                }
                return Ok(code);
            }
            let now = Instant::now();
            if now >= deadline {
                drop(guard);
                // owner 超时：以空结局收尾，清理注册表并唤醒同航班等待方
                //（对齐 Kotlin 超时后 abandon/fail 航班的语义）
                if self.is_owner {
                    self.manager.cancel(self.attempt.request.key.as_str());
                }
                return Err(LegadoError::Timeout(
                    "source verification timed out".to_string(),
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

// ─── 全局单例与便捷入口 ───────────────────────────────────────────────────────

/// 全局管理器单例
static MANAGER: OnceLock<&'static VerificationManager> = OnceLock::new();

/// 获取全局验证码请求管理器
pub fn verification_manager() -> &'static VerificationManager {
    *MANAGER.get_or_init(VerificationManager::new_leaked)
}

/// 便捷入口：发起验证码请求并以默认超时（5 分钟）阻塞等待结果
///
/// 供 JS 钩子（`getVerificationCode`）直接调用。
pub fn request_verification_code(
    source_url: &str,
    source_name: &str,
    image_url: &str,
    title: &str,
    use_browser: bool,
) -> LegadoResult<String> {
    let handle = verification_manager().request(source_url, source_name, image_url, title, use_browser);
    handle.wait(DEFAULT_VERIFICATION_TIMEOUT)
}

/// 便捷入口：提交验证码结果（对齐 Kotlin `SourceVerificationHelp.setResult`）
pub fn submit_verification_result(key: &str, code: &str) -> bool {
    verification_manager().submit(key, code)
}

/// 便捷入口：取消验证码请求（对齐 Kotlin `SourceVerificationHelp.checkResult`）
pub fn cancel_verification_request(key: &str) -> bool {
    verification_manager().cancel(key)
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// 独立管理器（避免全局单例跨测试串扰）
    fn isolated_manager() -> &'static VerificationManager {
        VerificationManager::new_leaked()
    }

    #[test]
    fn test_request_subscribe_submit_flow() {
        let mgr = isolated_manager();

        // 后台线程发起请求并挂起（模拟 JS 工作线程）
        let js_side = mgr;
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let handle = js_side.request(
                "https://source.example.com",
                "测试源",
                "https://img.example.com/captcha.png",
                "请输入验证码",
                false,
            );
            let _ = ready_tx.send(handle.key().to_string());
            handle.wait(Duration::from_secs(5))
        });

        // UI 侧订阅并收到事件
        let rx = mgr.subscribe();
        let req = rx.recv_timeout(Duration::from_secs(2)).expect("应收到请求事件");
        assert_eq!(req.key, ready_rx.recv_timeout(Duration::from_secs(2)).unwrap());
        assert_eq!(req.source_url, "https://source.example.com");
        assert_eq!(req.source_name, "测试源");
        assert_eq!(req.image_url, "https://img.example.com/captcha.png");
        assert_eq!(req.title, "请输入验证码");
        assert!(!req.use_browser);

        // 提交结果 → JS 侧拿到验证码
        assert!(mgr.submit(&req.key, "abcd"));
        let code = waiter.join().unwrap().expect("等待方应拿到结果");
        assert_eq!(code, "abcd");
    }

    #[test]
    fn test_submit_wakes_waiter_then_waiter_rejects_empty() {
        // 对齐 Kotlin：setResult 空值也唤醒，空值判定在等待侧
        let mgr = isolated_manager();
        let js_side = mgr;
        let waiter = std::thread::spawn(move || {
            let handle = js_side.request("https://s1.example.com", "", "img", "", false);
            handle.wait(Duration::from_secs(5))
        });

        let rx = mgr.subscribe();
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        // 空提交（模拟 UI 关闭对话框 checkResult）
        assert!(mgr.submit(&req.key, ""));
        let err = waiter.join().unwrap().expect_err("空结果应报错");
        assert!(err.to_string().contains("验证结果为空"));
    }

    #[test]
    fn test_cancel_wakes_waiter_with_empty_error() {
        let mgr = isolated_manager();
        let js_side = mgr;
        let waiter = std::thread::spawn(move || {
            let handle = js_side.request("https://s2.example.com", "", "img", "", false);
            handle.wait(Duration::from_secs(5))
        });

        let rx = mgr.subscribe();
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(mgr.cancel(&req.key));
        let err = waiter.join().unwrap().expect_err("取消应报错");
        assert!(err.to_string().contains("验证结果为空"));
        // 取消后请求已出队
        assert_eq!(mgr.pending_count(), 0);
    }

    #[test]
    fn test_timeout_returns_error_and_cleans_up() {
        let mgr = isolated_manager();
        let js_side = mgr;
        let waiter = std::thread::spawn(move || {
            let handle = js_side.request("https://s3.example.com", "", "img", "", false);
            handle.wait(Duration::from_millis(150))
        });

        let err = waiter.join().unwrap().expect_err("超时应报错");
        assert!(err.to_string().contains("timed out"));
        // owner 超时后应清理注册表
        assert_eq!(mgr.pending_count(), 0);
    }

    #[test]
    fn test_flight_dedup_same_source_shares_result() {
        let mgr = isolated_manager();
        let rx = mgr.subscribe();

        // 等待方 A：入队后先通知主线程，避免与 B 产生入队竞态
        let (a_ready_tx, a_ready_rx) = std::sync::mpsc::channel();
        let side_a = mgr;
        let waiter_a = std::thread::spawn(move || {
            let h = side_a.request("https://dup.example.com", "", "img", "", false);
            let _ = a_ready_tx.send(());
            (h.joined, h.wait(Duration::from_secs(5)))
        });
        // 确保 A 先入队
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(req.source_url, "https://dup.example.com");
        a_ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        let side_b = mgr;
        let (b_ready_tx, b_ready_rx) = std::sync::mpsc::channel();
        let waiter_b = std::thread::spawn(move || {
            let h = side_b.request("https://dup.example.com", "", "img", "", false);
            let _ = b_ready_tx.send(());
            (h.joined, h.wait(Duration::from_secs(5)))
        });
        // 确保 B 已入队（加入航班）后再提交，避免提交抢先导致 B 另起航班
        b_ready_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        // 提交一次 → 两个等待方共享结果
        assert!(mgr.submit(&req.key, "6666"));
        let (joined_a, res_a) = waiter_a.join().unwrap();
        let (joined_b, res_b) = waiter_b.join().unwrap();

        assert!(!joined_a, "首个请求应为 owner");
        assert!(joined_b, "同书源并发请求应加入既有航班");
        assert_eq!(res_a.unwrap(), "6666");
        assert_eq!(res_b.unwrap(), "6666");

        // 第二个请求不应再广播事件（只收到一条）
        assert!(rx.try_recv().is_err(), "加入航班不应重复推送事件");
    }

    #[test]
    fn test_late_subscribe_replays_pending() {
        let mgr = isolated_manager();
        let handle = mgr.request("https://late.example.com", "", "img", "", false);
        // 晚订阅：应立即回放进行中的请求
        let rx = mgr.subscribe();
        let req = rx.recv_timeout(Duration::from_secs(1)).expect("应回放进行中请求");
        assert_eq!(req.key, handle.key());
        // 收尾清理
        mgr.submit(&req.key, "done");
    }

    #[test]
    fn test_submit_unknown_key_returns_false() {
        let mgr = isolated_manager();
        assert!(!mgr.submit("no-such-key", "1234"));
        assert!(!mgr.cancel("no-such-key"));
    }

    #[test]
    fn test_submit_is_idempotent_first_result_wins() {
        // 对齐 Kotlin compareAndSet(null, ...)：首次结果生效
        let mgr = isolated_manager();
        let js_side = mgr;
        let waiter = std::thread::spawn(move || {
            let h = js_side.request("https://idem.example.com", "", "img", "", false);
            h.wait(Duration::from_secs(5))
        });
        let rx = mgr.subscribe();
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(mgr.submit(&req.key, "first"));
        // 重复提交不覆盖
        mgr.submit(&req.key, "second");
        assert_eq!(waiter.join().unwrap().unwrap(), "first");
    }

    #[test]
    fn test_global_helpers() {
        // 全局入口冒烟（唯一 key，避免与其他测试冲突）
        let mgr = verification_manager();
        let rx = mgr.subscribe();
        let handle = mgr.request("https://global.example.com", "", "img", "", false);
        let req = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(req.key, handle.key());
        assert!(submit_verification_result(&req.key, "g0"));
        assert_eq!(handle.wait(Duration::from_secs(5)).unwrap(), "g0");
        assert!(!cancel_verification_request(&req.key), "已结束的请求取消应返回 false");
    }
}
