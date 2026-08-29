//! preUpdateJs 宿主钩子（对齐原版 `AnalyzeRule.reGetBook` / `refreshTocUrl`）
//!
//! 仅在 `preUpdateJs` 执行期间由 legado-ffi 注入回调；其它 JS 调用时报错。
//! 回调实现放在 ffi 层（需访问 precise_search / get_book_info），本模块只做线程局部调度。

use std::cell::RefCell;
use std::sync::{Arc, Mutex};

/// 钩子函数：返回更新后的 book JSON（供 JS `Object.assign(book, …)`），失败返回 Err 文案
pub type PreUpdateHook = Arc<Mutex<dyn FnMut() -> Result<String, String> + Send>>;

thread_local! {
    static ACTIVE: RefCell<bool> = const { RefCell::new(false) };
    static RE_GET_BOOK: RefCell<Option<PreUpdateHook>> = const { RefCell::new(None) };
    static REFRESH_TOC_URL: RefCell<Option<PreUpdateHook>> = const { RefCell::new(None) };
}

/// 在闭包期间启用钩子（嵌套时外层会被覆盖，退出时清空）
pub fn with_hooks<R>(
    re_get_book: PreUpdateHook,
    refresh_toc_url: PreUpdateHook,
    f: impl FnOnce() -> R,
) -> R {
    ACTIVE.with(|c| *c.borrow_mut() = true);
    RE_GET_BOOK.with(|c| *c.borrow_mut() = Some(re_get_book));
    REFRESH_TOC_URL.with(|c| *c.borrow_mut() = Some(refresh_toc_url));
    let out = f();
    RE_GET_BOOK.with(|c| *c.borrow_mut() = None);
    REFRESH_TOC_URL.with(|c| *c.borrow_mut() = None);
    ACTIVE.with(|c| *c.borrow_mut() = false);
    out
}

fn ensure_active() -> Result<(), String> {
    let active = ACTIVE.with(|c| *c.borrow());
    if active {
        Ok(())
    } else {
        Err("只能在 preUpdateJs 中调用".into())
    }
}

/// `java.reGetBook()` / 全局同名
pub fn call_re_get_book() -> Result<String, String> {
    ensure_active()?;
    RE_GET_BOOK.with(|c| {
        let mut guard = c.borrow_mut();
        let hook = guard
            .as_mut()
            .ok_or_else(|| "reGetBook 钩子未注入".to_string())?;
        let mut f = hook
            .lock()
            .map_err(|_| "reGetBook 钩子锁失败".to_string())?;
        f()
    })
}

/// `java.refreshTocUrl()` / 全局同名
pub fn call_refresh_toc_url() -> Result<String, String> {
    ensure_active()?;
    REFRESH_TOC_URL.with(|c| {
        let mut guard = c.borrow_mut();
        let hook = guard
            .as_mut()
            .ok_or_else(|| "refreshTocUrl 钩子未注入".to_string())?;
        let mut f = hook
            .lock()
            .map_err(|_| "refreshTocUrl 钩子锁失败".to_string())?;
        f()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inactive_rejects() {
        assert!(call_re_get_book().unwrap_err().contains("preUpdateJs"));
        assert!(call_refresh_toc_url().unwrap_err().contains("preUpdateJs"));
    }

    #[test]
    fn test_with_hooks_invokes() {
        let re: PreUpdateHook = Arc::new(Mutex::new(|| Ok(r#"{"bookUrl":"https://a"}"#.into())));
        let rf: PreUpdateHook = Arc::new(Mutex::new(|| Ok(r#"{"tocUrl":"https://t"}"#.into())));
        let (a, b) = with_hooks(re, rf, || {
            (call_re_get_book().unwrap(), call_refresh_toc_url().unwrap())
        });
        assert!(a.contains("bookUrl"));
        assert!(b.contains("tocUrl"));
        assert!(call_re_get_book().is_err());
    }
}
