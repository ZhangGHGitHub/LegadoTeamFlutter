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

/// 在闭包执行期间临时绑定书源标识，退出时恢复原值
///
/// 供 `JsSourceEngine` 等嵌套调用场景使用，保证不破坏外层绑定。
pub fn with_current_source_tag<R>(tag: &str, f: impl FnOnce() -> R) -> R {
    let prev = CURRENT_SOURCE.with(|cell| cell.borrow().clone());
    set_current_source_tag(tag);
    let result = f();
    CURRENT_SOURCE.with(|cell| {
        *cell.borrow_mut() = prev;
    });
    result
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
        let inner = with_current_source_tag("inner", || current_source_tag());
        assert_eq!(inner.as_deref(), Some("inner"));
        assert_eq!(current_source_tag().as_deref(), Some("outer"));
        clear_current_source_tag();
    }

    #[test]
    fn test_thread_isolation() {
        set_current_source_tag("main-thread-tag");
        let child = std::thread::spawn(|| current_source_tag());
        // 子线程不应看到主线程的绑定
        assert!(child.join().unwrap().is_none());
        clear_current_source_tag();
    }
}
