//! tokio 运行时桥接层
//!
//! JS 宿主函数在独立 OS 线程同步执行，通过此桥接层
//! 调用 legado-net 的异步 LegadoClient（基于 reqwest/tokio）。

use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

/// 全局共享 tokio Runtime（懒初始化）
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 获取或创建全局 tokio Runtime
///
/// 任务 #60 ②：原 `Runtime::new()` 无 thread_name 且 worker 栈为默认约 2MB，
/// 是搜索崩溃（regex-syntax 深递归击穿 worker 栈）的主要宿主。
/// 改为 Builder 显式配置：worker 栈扩到 8MB（对齐原版 JVM 线程栈水位）
/// + thread_name 便于崩溃诊断。tokio blocking 池为按需创建无法配置栈，
/// 其风险由 regex_safe 非递归预检兜底。
pub fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .enable_all()
            .thread_name("legado-js-worker")
            .thread_stack_size(8 * 1024 * 1024)
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// 在 JS 线程中同步执行异步操作
///
/// # 安全约束
/// 此函数只能在非 tokio worker 线程中调用（即 JS 专用 OS 线程）。
/// 在 tokio worker 中调用 block_on 会导致死锁。
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    get_runtime().block_on(future)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_runtime_creation() {
        let rt = get_runtime();
        // 验证 runtime 可用：能在其上执行简单任务
        let result = rt.block_on(async { 1 + 1 });
        assert_eq!(result, 2);
    }

    #[test]
    fn test_block_on_simple() {
        let result = block_on(async { 42 });
        assert_eq!(result, 42);
    }
}
