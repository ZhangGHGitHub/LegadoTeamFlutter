//! `#[cfg(test)]` 测试支撑：全局变量兜底读取器的进程级状态锁
//!
//! `analyze_rule::set_global_variable_reader` 注册的是进程级 `@get` 兜底
//! 读取器（`GLOBAL_VAR_FALLBACK`）：本 crate 测试二进制内多线程并行执行时，
//! 任何「注册 / 复位」读取器的测试都会踩掉并行 `get()` 测试注册的读取器
//! （P2-9 ③ 事故族）。本模块提供 crate 级唯一锁与便捷持锁函数
//! （仅测试编译）：所有注册/复位全局读取器、或依赖其兜底语义的测试，
//! 都必须在本测试函数体首行持锁，串行执行。
//!
//! 用法（测试函数体首行）：
//! ```ignore
//! let _lock = crate::test_support::lock_global_reader();
//! ```
//!
//! 落位历史：锁原声明于 `analyze_rule` 测试模块内（模块私有，其它测试
//! 模块无法引用）。本次提升为 crate 级 `#[cfg(test)]` 共享模块：语义与
//! 用法不变，仅改可见性/位置——任何本 crate 测试模块都能拿到同一把锁。
//!
//! 注：本锁与 `legado-ffi` 的 `crate::test_support::GLOBAL_STORE_TEST_LOCK`
//! 分属两个测试二进制（独立进程），各自串行各自的 store / 读取器状态；
//! 无跨进程共享需求。

/// 全局变量兜底读取器（`GLOBAL_VAR_FALLBACK`）的进程级状态锁。
///
/// 持有者：本 crate 内所有注册/复位全局读取器、或依赖其兜底语义的
/// 测试。锁中毒时经 `into_inner` 恢复（测试锁不携带需保留的状态）。
pub(crate) static GLOBAL_READER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 便捷持锁函数：取得 `GLOBAL_READER_TEST_LOCK` 的守卫直至测试结束。
///
/// 守卫存于测试局部（如 `let _lock = ...`），离开作用域自动释放；
/// 中毒恢复语义与原 `lock().unwrap_or_else(|p| p.into_inner())` 一致。
///
/// 注：返回的 `MutexGuard` 本身即 `#[must_use]`，无需在函数上重复标注。
pub(crate) fn lock_global_reader() -> std::sync::MutexGuard<'static, ()> {
    GLOBAL_READER_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}
