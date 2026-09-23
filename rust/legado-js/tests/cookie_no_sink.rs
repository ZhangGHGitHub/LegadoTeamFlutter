//! sink=None（未注册持久化 sink）时的默认行为钉死：**纯内存、与现状一致**
//!
//! `legado-js` 不依赖 DB：未注入 sink 时（测试 / 无 DB 环境）cookie 存储
//! 行为必须与改造前完全一致——进程内存态，重启即失。本测试二进制内**不注册**
//! 任何 sink，独立于 [`cookie_persistence`] 的注册型用例运行。

use std::sync::Mutex;

use legado_js::host_api::cookie_store;

static TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn test_default_no_sink_is_pure_memory() {
    let _g = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    const URL: &str = "https://nosink.test/";
    cookie_store::set_cookie(URL, "k", "v");
    // 同进程内可读（内存态，与现状一致）
    assert_eq!(cookie_store::get_cookie(URL), "k=v");
    // 模拟重启（丢弃内存 store）→ 必失（未注入 sink，无持久层）
    cookie_store::clear_all_cookies();
    assert_eq!(cookie_store::get_cookie(URL), "");
}
