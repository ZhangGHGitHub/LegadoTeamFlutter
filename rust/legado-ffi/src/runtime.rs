//! 异步运行时管理
//!
//! 为 FFI 层提供全局 tokio Runtime，保证异步操作可在 C ABI 边界内同步执行。

use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 获取或初始化全局 tokio runtime
///
/// 使用多线程调度器，适合 FFI 场景下的异步 IO 与并发请求。
///
/// worker 线程栈 8MB（任务 #60 ②）：默认约 2MB 栈在 spawn_blocking 池上
/// 执行 regex-syntax 深递归编译/解析时会被击穿（搜索崩溃根因），
/// 扩栈对齐原版 JVM 线程栈水位；tokio blocking 池为按需创建无法配置栈，
/// 其风险由 regex_safe 非递归预检兜底。
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
            .thread_stack_size(8 * 1024 * 1024)
            // 阻塞池扩容（2026-08-27 搜索速度对比实测）：spawn_blocking 承载单源
            // URL 构建 JS + 解析（regex/JS），默认 10 线程在 SEARCH_CONCURRENCY=32
            // 下排队 ~20s，排队时间计入单源 30s 超时 → 79 个 HTTP <1s 完成的源被误判超时。
            // 64 ≥ 2×并发上限（32 URL 构建 + 32 解析），保证搜索负载下无排队积压。
            .max_blocking_threads(64)
            // runtime 全部线程（worker + blocking 池，二者均走 after_start 回调）降权
            .on_thread_start(lower_thread_priority)
            .build()
            .expect("Failed to create tokio runtime")
    })
}

/// runtime 线程 OS 优先级降权（Unix: nice 19，其余平台 no-op）
///
/// **背景（2026-09-14 搜索起步卡顿取证）**：多源流式搜索（SEARCH_CONCURRENCY=32 +
/// blocking 池 64）在低核数设备（MuMu Test 实例 guest 仅 1 核）上把核吃满
/// （top 实测应用进程 84→100%），Flutter UI 线程与之公平竞争仅分到 ~3% CPU →
/// 起步阶段整页掉帧。对齐 Android 原版平台行为：原版后台协程运行在 Android
/// 后台 cgroup（低优调度），UI 线程（top-app cgroup）始终优先。
///
/// **机制**：nice 19 把 runtime 线程的 CFS 权重压到 UI 线程的 ~1/68，UI 有帧
/// 需渲染时立即抢占；UI 空闲时 runtime 线程仍吃满核，吞吐不受损（搜索 CPU
/// 总量不变，仅调度顺序让路）。tokio `on_thread_start` 对 worker 与
/// spawn_blocking 线程都会触发（tokio 1.52 pool.rs:504 同走 after_start），
/// 故一处挂钩全覆盖。提升 nice 值无需特权，Android/Linux 均允许。
///
/// `PRIO_PROCESS, 0` 作用于**调用线程自身**（Linux 任务级），在线程入口调用
/// 即只降该线程。
#[cfg(any(target_os = "android", target_os = "linux"))]
fn lower_thread_priority() {
    unsafe {
        // PRIO_PROCESS + who=0 = 当前线程（Linux 按任务调度）；提升 nice 无需特权
        libc::setpriority(libc::PRIO_PROCESS, 0, 19);
    }
}

#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn lower_thread_priority() {}

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
