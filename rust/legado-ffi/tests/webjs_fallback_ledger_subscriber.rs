//! [P2-2 回归] @webjs 有订阅者时走 DOM 通道且不登记回退台账
//!
//! 独立测试二进制的缘由：`webview_channel::subscribe()` 的 Sender 注册是
//! 进程级永久态（manager 侧 retain 为空桩、无退订 API），若与本仓其他
//! 测试同进程并行执行，会让「无订阅者」前置条件永久失效。故本用例独占
//! 一个测试进程。
//!
//! 依赖访问路径：legado-ffi 顶层 re-export `legado_core` / `legado_parser`
//! （集成测试不可见普通依赖，经 re-export 访问，无需 Cargo.toml 变更）。

use legado_ffi::legado_core::webview_channel;
use legado_ffi::legado_parser::analyze_rule::webjs_no_subscriber_ledger;
use legado_ffi::legado_parser::AnalyzeRule;

#[test]
fn webjs_with_subscriber_uses_dom_channel_and_skips_ledger() {
    // 前置：本进程无既有订阅者（独立二进制保证）
    assert!(
        !webview_channel::has_subscribers(),
        "独立测试进程不应有既有 WebView 订阅者"
    );

    // 注册订阅者（Receiver 须保活——虽然 Sender 注册即永久，仍显式持有）
    let rx = webview_channel::webview_manager().subscribe();
    assert!(webview_channel::has_subscribers(), "订阅后应有订阅者");

    // 响应线程：收到规则解析请求即回传结果（模拟 Flutter 侧真实 WebView）
    let responder = std::thread::spawn(move || {
        let req = rx
            .recv_timeout(std::time::Duration::from_secs(8))
            .expect("应收到 @webjs 规则的 WebView 请求");
        assert!(req.is_rule, "规则级请求应带 is_rule 标记");
        webview_channel::submit_webview_result(&req.key, "dom-result");
    });

    // 有订阅者：走 DOM 通道（BackstageWebView 语义），不进无头回退
    let rule = AnalyzeRule::new(
        "<html><body>x</body></html>".into(),
        "https://dom.example".into(),
    );
    let out = rule
        .get_string("@webjs:return document.title;")
        .expect("DOM 通道应返回结果");
    responder.join().unwrap();

    assert_eq!(out, "dom-result", "结果应来自订阅者回传（DOM 通道）");
    assert!(
        webjs_no_subscriber_ledger::records().is_empty(),
        "有订阅者时不得登记回退台账"
    );
}
