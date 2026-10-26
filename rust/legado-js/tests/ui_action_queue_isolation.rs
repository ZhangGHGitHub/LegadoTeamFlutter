//! 中途 UI 动作队列并发隔离回归（审查批4 P2-3）
//!
//! 红→绿用例：旧实现为进程级全局队列 + 全局开关，两个并发求值会话会互相
//! 清空/偷取 action（A 请求拿到 B 的 `showBrowser` 页面）。作用域化后每个
//! 求值会话拥有独立收集容器，互不串流。

use std::sync::{mpsc, Arc, Barrier};
use std::thread;

use legado_js::host_api::ui_action_queue::{
    begin_collect, end_collect, is_collecting, push_action, with_collect,
};

fn browser(page: &str) -> serde_json::Value {
    serde_json::json!({"action": "openBrowser", "url": page})
}

/// 两个并发会话（旧 begin/end 兼容包装）互不串流
///
/// 交错顺序固定：A 开启收集 → B 开启收集（旧实现会清空全局队列）→
/// B 入队并结束 → A 入队并结束。旧全局实现下 A 的 action 被 B 的
/// `end_collect` 偷走，用例必失败（改造前实测 A 取到空队列、B 取到两条）。
#[test]
fn concurrent_compat_sessions_do_not_interfere() {
    let (a_started_tx, a_started_rx) = mpsc::channel::<()>();
    let (b_started_tx, b_started_rx) = mpsc::channel::<()>();
    let (b_done_tx, b_done_rx) = mpsc::channel::<()>();

    let a = thread::spawn(move || {
        begin_collect();
        a_started_tx.send(()).unwrap();
        b_started_rx.recv().unwrap();
        push_action(browser("http://page-a"));
        b_done_rx.recv().unwrap();
        end_collect()
    });
    let b = thread::spawn(move || {
        a_started_rx.recv().unwrap();
        begin_collect();
        b_started_tx.send(()).unwrap();
        push_action(browser("http://page-b"));
        let actions = end_collect();
        b_done_tx.send(()).unwrap();
        actions
    });

    let a_actions = a.join().unwrap();
    let b_actions = b.join().unwrap();

    assert_eq!(
        b_actions,
        vec![browser("http://page-b")],
        "B 会话应只取到自己的 action"
    );
    assert_eq!(
        a_actions,
        vec![browser("http://page-a")],
        "A 会话应只取到自己的 action（旧全局实现下会被 B 清空/偷取）"
    );
}

/// 两个并发作用域求值（`with_collect`）互不串流，交错点落在作用域内部
#[test]
fn concurrent_scoped_sessions_do_not_interfere() {
    let barrier = Arc::new(Barrier::new(2));

    let a_barrier = Arc::clone(&barrier);
    let a = thread::spawn(move || {
        with_collect(|| {
            push_action(browser("http://page-a-1"));
            a_barrier.wait();
            push_action(browser("http://page-a-2"));
        })
        .1
    });
    let b_barrier = Arc::clone(&barrier);
    let b = thread::spawn(move || {
        with_collect(|| {
            push_action(browser("http://page-b-1"));
            b_barrier.wait();
            push_action(browser("http://page-b-2"));
        })
        .1
    });

    let a_actions = a.join().unwrap().actions;
    let b_actions = b.join().unwrap().actions;

    assert_eq!(
        a_actions,
        vec![browser("http://page-a-1"), browser("http://page-a-2")],
        "A 作用域应只含自己的 action（保持入队顺序）"
    );
    assert_eq!(
        b_actions,
        vec![browser("http://page-b-1"), browser("http://page-b-2")],
        "B 作用域应只含自己的 action（保持入队顺序）"
    );
}

/// 作用域外入队被静默丢弃（与旧实现 `is_collecting() == false` 行为一致）
#[test]
fn outside_scope_push_is_dropped() {
    assert!(!is_collecting());
    push_action(browser("http://outside"));
    assert!(!is_collecting());

    let (_, collected) = with_collect(|| {});
    assert!(
        collected.actions.is_empty(),
        "作用域外 action 不得泄漏进后续会话"
    );
}

/// 顺序复用不残留：每次 `with_collect` 都是全新容器
#[test]
fn sequential_scoped_reuse_has_no_residue() {
    let (_, first) = with_collect(|| push_action(browser("http://first")));
    assert_eq!(first.actions, vec![browser("http://first")]);

    let (_, second) = with_collect(|| {});
    assert!(second.actions.is_empty(), "第二次求值不得残留上一次 action");
    assert!(!is_collecting());
}
