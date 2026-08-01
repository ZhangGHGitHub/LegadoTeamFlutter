//! 异步运行时管理
//!
//! 为 FFI 层提供全局 tokio Runtime，保证异步操作可在 C ABI 边界内同步执行。

use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 获取或初始化全局 tokio runtime
///
/// 使用多线程调度器，适合 FFI 场景下的异步 IO 与并发请求。
pub fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .enable_all()
            .worker_threads(
                std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(2)
                    .clamp(2, 8),
            )
            .thread_name("legado-ffi-worker")
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// 在 FFI 中执行异步任务（阻塞等待结果）
///
/// # 示例
/// ```ignore
/// let body = block_on_async(async {
///     legado_net::http::get("https://example.com").await
/// });
/// ```
pub fn block_on_async<F: std::future::Future>(future: F) -> F::Output {
    get_runtime().block_on(future)
}

/// `block_on_async` 的别名，保留向后兼容
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    block_on_async(future)
}
