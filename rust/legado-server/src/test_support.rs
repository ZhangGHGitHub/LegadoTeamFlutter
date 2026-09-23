//! `#[cfg(test)]` 测试支撑：全局 cookie store 的进程级状态锁
//!
//! `legado_js::host_api::cookie_store` 的 `GLOBAL_COOKIES` 是进程级全局
//! 状态：本测试二进制内多线程并行执行时，「写/清回环域名键（127.0.0.1）
//! 再读回」的测试（loginCheckJs 顶层 `java.ajax` 回环用例）会互相踩键
//!（与 legado-ffi 的 P2-1 / P2-9 全局变量表事故同类）。
//!
//! 每个 test 二进制是独立进程（各自一份 `GLOBAL_COOKIES` 实例）：按 crate
//! 持锁即正确粒度，与其他 crate 的测试锁**无嵌套关系**（各自进程内
//! 独立，不构成跨 crate 死锁）。
//!
//! 用法（测试函数体首行，变量名沿用既有 `_lock` 约定）：
//! ```ignore
//! let _lock = crate::test_support::lock_cookie_store_test();
//! ```

/// 全局 cookie store 的进程级状态锁（quickjs 档：回环域名键 `127.0.0.1`
/// 被回环 cookie 用例共用；默认档无此类用例，锁项按 quickjs 门控防
/// dead_code）
#[cfg(feature = "quickjs")]
pub(crate) static COOKIE_STORE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 便捷持锁函数：取得 [`COOKIE_STORE_TEST_LOCK`] 的守卫直至测试结束。
///
/// 守卫存于测试局部（如 `let _lock = ...`），离开作用域自动释放；
/// 中毒恢复语义同 `legado_js::host_api::cookie_store::lock_cookie_store_test`
/// （测试锁不携带需保留的状态）。
#[cfg(feature = "quickjs")]
pub(crate) fn lock_cookie_store_test() -> std::sync::MutexGuard<'static, ()> {
    COOKIE_STORE_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}
