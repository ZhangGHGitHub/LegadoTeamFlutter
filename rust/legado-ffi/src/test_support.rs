//! `#[cfg(test)]` 测试支撑：全局变量 store / 桥读取器 / flow scope 的进程级状态锁
//!
//! `legado_js::host_api::variable_store` 的全局变量表、
//! `legado_parser::set_global_variable_reader` 注册的 `@get` 回退读取器、
//! flow scope（`lgflow::` 会话层）都是进程级全局状态：本 crate 的测试
//! 二进制内多线程并行执行时，任何「写全局表 / 清 flow scope / 重注册读取器」
//! 的测试都会踩掉并行测试正在读的数据（P2-9 ③ / P2-1 事故，CI 35712966198
//! `test_shoujixiaoshuo_tocurl_bridge_before_after` 串表翻车即此）。
//!
//! 本模块是全 crate 唯一的 store 串行锁（`pub(crate)`，仅测试编译）：
//! **所有**读写全局变量表、切 flow scope、或调用会触发 `begin_book_flow`
//! 生产入口（webbook_search / webbook_info / webbook_chapters / webbook_content /
//! refresh_toc / explore_fetch_books / switch_book_source(_with) / search_books /
//! multi_source_search 等）的测试，都必须在本测试函数体首行持锁，串行执行。
//!
//! 用法（测试函数体首行，变量名沿用既有 `_lock` 约定）：
//! ```ignore
//! let _lock = crate::test_support::lock_global_store();
//! ```
//!
//! 落位历史：锁原声明于 `api::web_book` 模块（P2-1 时由该文件测试模块提升至
//! 模块级 `pub(crate)`，经 `crate::api::web_book::` 路径供 reader / explore_api /
//! source_switch 引用）。本次提升为 crate 级 `#[cfg(test)]` 共享模块：语义与
//! 用法不变，仅改可见性/位置——任何本 crate 测试模块（含 search、pre_update 等
//! 此前无法引用的模块）都能拿到同一把锁。

/// 全局变量 store / 桥读取器 / flow scope 的进程级状态锁。
///
/// 持有者：本 crate 内所有触碰全局变量表或流程作用域的测试（含 book 绑定
/// 走 webbook_chapters / webbook_content 的书山回归、换源链路、探索/搜索
/// 链路）。锁中毒时经 `into_inner` 恢复（测试锁不携带需保留的状态）。
pub(crate) static GLOBAL_STORE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 便捷持锁函数：取得 `GLOBAL_STORE_TEST_LOCK` 的守卫直至测试结束。
///
/// 守卫存于测试局部（如 `let _lock = ...`），离开作用域自动释放；
/// 中毒恢复语义与原 `lock().unwrap_or_else(|p| p.into_inner())` 一致。
#[must_use]
pub(crate) fn lock_global_store() -> std::sync::MutexGuard<'static, ()> {
    GLOBAL_STORE_TEST_LOCK
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}
