//! 当前书源上下文（线程局部）
//!
//! JS 引擎按书源分桶执行（引擎池以 `source_tag` 为键），
//! 宿主 API 钩子（如 `getVerificationCode`）需要知道「当前正在执行
//! 的是哪个书源」。对齐 Kotlin `JsExtensions.getSource()` 的语义：
//! Kotlin 侧 source 由 Rhino 执行上下文携带，Rust 侧以线程局部变量承载。
//!
//! # 设置时机
//! - `legado-ffi::js_executor::QuickJsExecutor::execute_js`（规则解析链路）
//! - `JsSourceEngine::call_function`（JS 书源调用链路）
//!
//! 钩子在同一线程同步执行（rquickjs 原生函数），因此线程局部即可正确传递。

use std::cell::RefCell;

thread_local! {
    /// 当前执行线程正在求值的书源标识（一般为 book_source_url）
    static CURRENT_SOURCE: RefCell<Option<String>> = const { RefCell::new(None) };
}

/// 设置当前线程的书源标识（eval 前调用）
pub fn set_current_source_tag(tag: &str) {
    CURRENT_SOURCE.with(|cell| {
        *cell.borrow_mut() = Some(tag.to_string());
    });
}

/// 清除当前线程的书源标识（eval 结束后调用，避免跨调用串扰）
pub fn clear_current_source_tag() {
    CURRENT_SOURCE.with(|cell| {
        *cell.borrow_mut() = None;
    });
}

/// 读取当前线程的书源标识（钩子调用）
pub fn current_source_tag() -> Option<String> {
    CURRENT_SOURCE.with(|cell| cell.borrow().clone())
}

/// 书源标识作用域护栏：进入时保存原值并绑定新 tag，退出（含 panic
/// 展开）时由 `Drop` 恢复原值。
///
/// P2-7：改前 `with_current_source_tag` 在闭包正常返回后才恢复，
/// 闭包 panic 时恢复被跳过；tokio blocking 线程复用后 tag 残留，
/// 后续请求的 `global_headers`、验证码钩子、cookie 写侧门控会错源。
/// 模式同 `ui_action_queue::ScopeGuard`。
struct SourceTagGuard {
    prev: Option<String>,
}

impl SourceTagGuard {
    fn new(tag: &str) -> Self {
        let prev = CURRENT_SOURCE.with(|cell| cell.borrow().clone());
        set_current_source_tag(tag);
        Self { prev }
    }
}

impl Drop for SourceTagGuard {
    fn drop(&mut self) {
        let prev = self.prev.take();
        // 线程销毁阶段 TLS 可能已不可用；`try_with` 避免 Drop 内二次 panic
        let _ = CURRENT_SOURCE.try_with(|cell| {
            *cell.borrow_mut() = prev;
        });
    }
}

/// 在闭包执行期间临时绑定书源标识，退出时恢复原值
///
/// 供 `JsSourceEngine` 等嵌套调用场景使用，保证不破坏外层绑定。
/// 恢复经 RAII [`SourceTagGuard`] 完成：闭包 panic 展开时同样恢复，
/// 不会在复用的 blocking 线程上残留错误书源。
///
/// 注意（2026-09-23 上游同步，用户裁决）：P2-19 曾以该绑定承载 JS cookie 取用
/// scope（按书源 tag 维度过滤 `GLOBAL_COOKIES`）；同步上游后 cookie 取用改按
/// **请求 URL 属域**（`cookie_store::cookies_for_url`，cookie 属于域名而非书源），
/// 本绑定**不再承载 cookie scope**。保留不动，仍服务于全局请求头
/// （`global_headers`，按 tag 隔离）与书源上下文（引擎分桶、验证码钩子等）。
pub fn with_current_source_tag<R>(tag: &str, f: impl FnOnce() -> R) -> R {
    let _guard = SourceTagGuard::new(tag);
    f()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_set_get_clear() {
        assert!(current_source_tag().is_none());
        set_current_source_tag("https://source.example.com");
        assert_eq!(
            current_source_tag().as_deref(),
            Some("https://source.example.com")
        );
        clear_current_source_tag();
        assert!(current_source_tag().is_none());
    }

    #[test]
    fn test_with_restores_previous() {
        set_current_source_tag("outer");
        let inner = with_current_source_tag("inner", current_source_tag);
        assert_eq!(inner.as_deref(), Some("inner"));
        assert_eq!(current_source_tag().as_deref(), Some("outer"));
        clear_current_source_tag();
    }

    /// P2-7：闭包 panic 展开后 tag 必须恢复原值（RAII Drop 护栏），
    /// 否则复用 blocking 线程上会残留错误书源。
    #[test]
    fn test_with_restores_after_panic() {
        // 外层已绑定 → panic 后恢复为外层值
        set_current_source_tag("outer");
        let result = std::panic::catch_unwind(|| {
            with_current_source_tag("inner", || -> () { panic!("boom-with-outer") })
        });
        assert!(result.is_err());
        assert_eq!(current_source_tag().as_deref(), Some("outer"));

        // 无外层绑定 → panic 后恢复为 None
        clear_current_source_tag();
        let result = std::panic::catch_unwind(|| {
            with_current_source_tag("inner", || -> () { panic!("boom-with-none") })
        });
        assert!(result.is_err());
        assert!(current_source_tag().is_none());
    }

    #[test]
    fn test_thread_isolation() {
        set_current_source_tag("main-thread-tag");
        let child = std::thread::spawn(current_source_tag);
        // 子线程不应看到主线程的绑定
        assert!(child.join().unwrap().is_none());
        clear_current_source_tag();
    }
}
