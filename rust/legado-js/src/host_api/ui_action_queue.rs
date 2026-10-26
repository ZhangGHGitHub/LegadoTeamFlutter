//! 中途 UI 副作用队列（SourceCallBack / SourceLoginJsExtensions / 段评 legacy 桥）
//!
//! Kotlin `callBackBtn` 在 JS 求值过程中可通过 `java.showBrowser` /
//! `java.refreshBookInfo` 等触发 Activity 侧副作用；无头 QuickJS 无法同步弹 UI，
//! 因此在求值期间收集结构化 action，由 FFI 结果一并回传 Flutter 执行。
//!
//! # 隔离语义（审查批4 P2-3）
//!
//! 原版（upstream `ReviewController.executeLegacyReviewScript`）每次求值新建
//! `LegacyReviewJsExtensions(source, onShowBrowser)`，`browserPage` 是该次调用的
//! **局部变量**；`SourceLoginJsExtensions` 亦随 `callBackBtn` 的求值上下文创建。
//! 即收集容器生命周期 = 一次 JS 求值，天然并发隔离。
//!
//! 旧实现用「进程级全局队列 + 全局开关」，HTTP 服务并发处理 `/openLegacyReview`、
//! `/runLegacyReview` 或与 App 自身 FFI explore/callBackBtn 并发时，会互相清空/
//! 偷取 action（A 请求拿到 B 的 `showBrowser` 页面）。现改为**线程局部会话栈**：
//!
//! - 每次求值用 [`with_collect`] 包住（进入时压入独立容器，退出时弹栈并返回）；
//! - 宿主 API（[`push_action`] / [`push_payload_json`] / `source_login_ext`）
//!   只写入**当前线程栈顶**会话，互不串流；
//! - 作用域外栈为空：`push_*` 静默丢弃（与旧实现 `is_collecting() == false`
//!   时的行为一致，宿主 API 无需分支），读取接口返回默认值；
//! - 嵌套求值按栈 LIFO 隔离，内层结束不影响外层（对照测试见模块测试与
//!   `tests/ui_action_queue_isolation.rs`）。
//!
//! 为什么用线程局部而非 tokio `task_local`（批13 `DEBUG_SINK` 范式）：
//! rquickjs 宿主 API 是**同步原生函数**，action 入队发生在 `engine.eval` 的
//! 调用线程内；三处收集点（ffi explore / ffi callBackBtn / server 段评）都在
//! 同步求值块中，server 侧整个求值还包在 `spawn_blocking` 里（`task_local`
//! 不随 `spawn_blocking` 传递），FFI 同步入口亦无 tokio 运行时上下文。
//! 因此统一用线程局部栈单一实现，避免同步/异步双份语义漂移。
//!
//! # 用法
//!
//! ```ignore
//! let (raw, collected) = ui_action_queue::with_collect(|| engine.eval(js));
//! // collected.actions / collected.refresh_explore
//! ```
//!
//! 旧 API [`begin_collect`] / [`end_collect`] 保留为同线程兼容包装（等价于
//! 手工压栈/弹栈），新代码请使用 [`with_collect`]。

use std::cell::RefCell;

use serde_json::Value;

/// 单次求值会话的收集结果
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CollectedActions {
    /// 按入队顺序排列的结构化 action
    pub actions: Vec<Value>,
    /// 是否请求刷新发现页（`java.refreshExplore` / `reLoginView`）
    pub refresh_explore: bool,
}

/// 单次求值会话（线程局部栈元素）
#[derive(Default)]
struct Session {
    actions: Vec<Value>,
    refresh_explore: bool,
}

thread_local! {
    /// 当前线程的收集会话栈（栈顶 = 正在求值的会话）
    ///
    /// 空栈表示当前线程不在任何求值作用域内：宿主 API 调用不产生收集开销，
    /// 也不会跨调用残留（线程复用场景由 [`with_collect`] 的 RAII 护栏保证）。
    static SESSIONS: RefCell<Vec<Session>> = const { RefCell::new(Vec::new()) };
}

/// 弹出一个会话并转换为收集结果（空栈返回默认值）
fn pop_session() -> CollectedActions {
    SESSIONS.with(|sessions| {
        sessions
            .borrow_mut()
            .pop()
            .map(|session| CollectedActions {
                actions: session.actions,
                refresh_explore: session.refresh_explore,
            })
            .unwrap_or_default()
    })
}

/// 会话作用域护栏：正常路径由 [`Self::finish`] 弹栈；panic 展开时由 `Drop`
/// 兜底弹栈，避免复用线程（如 tokio blocking 线程池）残留半开会话。
struct ScopeGuard {
    finished: bool,
}

impl ScopeGuard {
    fn begin() -> Self {
        SESSIONS.with(|sessions| sessions.borrow_mut().push(Session::default()));
        Self { finished: false }
    }

    fn finish(mut self) -> CollectedActions {
        self.finished = true;
        pop_session()
    }
}

impl Drop for ScopeGuard {
    fn drop(&mut self) {
        if !self.finished {
            let _ = pop_session();
        }
    }
}

/// 在独立收集容器内执行一次同步求值（每次求值一个容器，对齐原版
/// `LegacyReviewJsExtensions` / `SourceLoginJsExtensions` 的调用生命周期）
///
/// 返回 `(求值结果, 收集结果)`：闭包内所有宿主 API 入队只进本次会话；
/// 返回后栈恢复原状（嵌套调用时外层会话继续接收后续 action）。
pub fn with_collect<R>(f: impl FnOnce() -> R) -> (R, CollectedActions) {
    let guard = ScopeGuard::begin();
    let result = f();
    let collected = guard.finish();
    (result, collected)
}

/// 兼容旧 API：开启一次收集（同线程压栈；配对 [`end_collect`] / [`discard_collect`]）
///
/// 与旧语义的差异：不再清空进程级共享队列，而是压入新会话——嵌套/并发调用
/// 各自隔离。旧调用面均为「begin → 同步求值 → end」的顶层顺序用法，语义等价。
pub fn begin_collect() {
    SESSIONS.with(|sessions| sessions.borrow_mut().push(Session::default()));
}

/// 是否正在收集（当前线程栈非空）
pub fn is_collecting() -> bool {
    SESSIONS.with(|sessions| !sessions.borrow().is_empty())
}

/// 入队一个结构化 action（仅在收集作用域内生效，否则静默丢弃）
pub fn push_action(action: Value) {
    SESSIONS.with(|sessions| {
        if let Some(session) = sessions.borrow_mut().last_mut() {
            session.actions.push(action);
        }
    });
}

/// 将平台桥接 JSON 字符串解析后入队（作用域外不解析、不收集；解析失败忽略）
pub fn push_payload_json(payload_json: &str) {
    if !is_collecting() {
        return;
    }
    if let Ok(v) = serde_json::from_str::<Value>(payload_json) {
        push_action(v);
    }
}

/// 兼容旧 API：结束收集并取出当前线程栈顶会话的全部 action
pub fn end_collect() -> Vec<Value> {
    pop_session().actions
}

/// 发现页 `java.refreshExplore` / `reLoginView` 是否被请求（读取并清除栈顶会话标记）
pub fn take_refresh_explore_requested() -> bool {
    SESSIONS.with(|sessions| {
        sessions
            .borrow_mut()
            .last_mut()
            .map(|session| std::mem::take(&mut session.refresh_explore))
            .unwrap_or(false)
    })
}

fn request_refresh_explore() {
    SESSIONS.with(|sessions| {
        if let Some(session) = sessions.borrow_mut().last_mut() {
            session.refresh_explore = true;
        }
    });
}

/// 兼容旧 API：丢弃栈顶会话并关闭收集（求值失败时调用；作用域外为无操作）
pub fn discard_collect() {
    let _ = pop_session();
}

/// SourceLoginJsExtensions 中途 UI 动作构造
pub mod source_login_ext {
    use super::push_action;
    use serde_json::json;

    pub fn refresh_book_info() {
        push_action(json!({ "action": "refreshBookInfo" }));
    }

    pub fn refresh_book_toc() {
        push_action(json!({ "action": "refreshBookToc" }));
    }

    pub fn refresh_content() {
        push_action(json!({ "action": "refreshContent" }));
    }

    pub fn copy_text(text: &str) {
        push_action(json!({ "action": "copyText", "text": text }));
    }

    pub fn clear_tts_cache() {
        push_action(json!({ "action": "clearTtsCache" }));
    }

    /// 对齐 Kotlin `SourceLoginJsExtensions.refreshExplore` / `reLoginView`
    pub fn refresh_explore() {
        super::request_refresh_explore();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 兼容包装：顺序 begin → push → end，结束即弹栈；作用域外不收集
    #[test]
    fn collect_drain_and_ignore_when_off() {
        assert!(!is_collecting());
        push_action(json!({"action":"copyText","text":"off"}));
        assert!(end_collect().is_empty());

        begin_collect();
        assert!(is_collecting());
        push_action(json!({"action":"refreshBookInfo"}));
        push_payload_json(r#"{"action":"openBrowser","url":"http://x"}"#);
        let actions = end_collect();
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0]["action"], "refreshBookInfo");
        assert_eq!(actions[1]["action"], "openBrowser");
        assert!(!is_collecting());
        assert!(end_collect().is_empty());
    }

    /// 作用域内收集、作用域外零收集（作用域结束后无残留）
    #[test]
    fn scoped_collect_isolated_from_outside() {
        push_action(json!({"action":"outside-before"}));
        let (value, collected) = with_collect(|| {
            push_action(json!({"action":"inside"}));
            assert!(is_collecting());
            42
        });
        assert_eq!(value, 42);
        assert_eq!(collected.actions, vec![json!({"action":"inside"})]);
        assert!(!collected.refresh_explore);
        assert!(!is_collecting());

        push_action(json!({"action":"outside-after"}));
        let (_, again) = with_collect(|| {});
        assert!(again.actions.is_empty(), "顺序复用不得残留上一次 action");
    }

    /// 嵌套作用域 LIFO 隔离：内层只收自己的 action，外层不受影响
    #[test]
    fn nested_scopes_do_not_leak() {
        let (_, outer) = with_collect(|| {
            push_action(json!({"action":"outer-1"}));

            let (_, inner) = with_collect(|| {
                push_action(json!({"action":"inner"}));
                source_login_ext::refresh_explore();
            });
            assert_eq!(inner.actions, vec![json!({"action":"inner"})]);
            assert!(inner.refresh_explore);
            assert!(!take_refresh_explore_requested(), "内层标记不应泄漏到外层");

            push_action(json!({"action":"outer-2"}));
        });
        assert_eq!(
            outer.actions,
            vec![json!({"action":"outer-1"}), json!({"action":"outer-2"})]
        );
        assert!(!outer.refresh_explore);
    }

    /// refreshExplore 标记随会话隔离（结束即取走，不残留）
    #[test]
    fn refresh_explore_flag_is_per_session() {
        assert!(!take_refresh_explore_requested());
        let (_, collected) = with_collect(|| {
            source_login_ext::refresh_explore();
        });
        assert!(collected.refresh_explore);
        assert!(!take_refresh_explore_requested());
    }
}
