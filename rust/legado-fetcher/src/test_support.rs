//! `#[cfg(test)]` 测试支撑（本 crate 测试二进制内）
//!
//! `legado_js::host_api::variable_store` 的全局变量表与 flow scope 是进程级
//! 全局状态：测试并行执行时，任何「写全局表 / 清 flow scope / 重注册读取器」
//! 的测试都会踩掉并行测试正在读的数据。本模块提供全 crate 唯一的 store 串行
//! 锁（语义与 legado-ffi `test_support::GLOBAL_STORE_TEST_LOCK` 一致；因测试
//! 进程独立，本 crate 自持一把，不跨 crate 共享）。
//!
//! 另提供多线程 runtime 驱动 [`block_on`]（等价 legado-ffi `runtime::block_on`，
//! 供 async 测试驱动入口/分页链）。

/// 全局变量 store / flow scope 的进程级状态锁（仅测试）
pub(crate) static GLOBAL_STORE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 便捷持锁函数（中毒恢复语义同 legado-ffi）
///
/// 仅部分用例（触碰全局变量表者）使用；非 quickjs 档这些用例被门控，
/// 故按 dead_code 放行以免默认构建告警。
#[allow(dead_code)]
pub(crate) fn lock_global_store() -> std::sync::MutexGuard<'static, ()> {
    GLOBAL_STORE_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

/// 多线程 runtime 驱动（等价 legado-ffi `runtime::block_on` 的测试替代）
pub(crate) fn block_on<F: std::future::Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("test runtime")
        .block_on(future)
}
