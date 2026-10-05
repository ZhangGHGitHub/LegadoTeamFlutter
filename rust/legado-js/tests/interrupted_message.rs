//! P1-C（iOS 实机搜索失败 11 号，八一中文网）：超时中断文案可读化
//!
//! 现状：5s wall-clock 预算耗尽后 rquickjs 侧异常非标准 Error 实例，
//! `take_exception_message` 退化输出裸词 `"interrupted"`（实机错误文本）。
//! 修复：`engine.rs` 检测中断 AtomicBool 后输出可读文案，保留 `interrupted`
//! 关键字便于日志检索；**预算值不变**（分析报告 §四判定 5s 按设计正确）。
//!
//! 与原版语义差异（已登记）：原版 Rhino 引擎无单次求值时间预算
//! （`RhinoScriptEngine.kt:294` 观察点仅作协程取消检查、`RhinoContext.kt:336-343`
//! ensureActive），同段死循环会挂到外层搜索超时（30s 口径）；我方 5s 主动中断。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::sandbox::SandboxConfig;
use std::time::Duration;

/// 与生产书源路径同源配置（default + allow_script_run + 64MB），仅把
/// 预算压到 100ms 以便秒级测试；文案中的预算是运行时读配置值。
fn engine_with_budget(ms: u64) -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024)
            .with_timeout(Duration::from_millis(ms)),
    )
    .expect("引擎创建失败")
}

/// 死循环中断 → 文案可读且保留 interrupted 关键字（修复前为裸 `interrupted`）
#[test]
fn timeout_message_is_readable_and_keeps_interrupted_keyword() {
    let engine = engine_with_budget(100);
    let err = JsEngine::eval(&engine, "while(true){}")
        .map(|v| panic!("死循环应被中断，实际返回: {v}"))
        .unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("interrupted"),
        "文案应保留 interrupted 关键字（日志检索）: {msg}"
    );
    assert!(
        msg.contains("脚本执行超时被中断"),
        "文案应可读（修复前为裸 interrupted，11 号实机形态）: {msg}"
    );
    assert!(
        msg.contains("100 ms"),
        "文案应带实际预算值（对齐配置而非硬编码 5s）: {msg}"
    );
    assert_ne!(msg.trim(), "interrupted", "不得退化为裸词");
}

/// 正则回溯爆炸/超长匹配同样走中断通道（11 号实机 `[Symbol.match]` 栈帧形态）
#[test]
fn catastrophic_regex_backtracking_reports_readable_timeout() {
    let engine = engine_with_budget(200);
    let script = "var s = 'a'.repeat(2000000) + 'b'; /(a+)+$/.test(s);";
    let err = JsEngine::eval(&engine, script)
        .map(|v| panic!("回溯爆炸应被中断，实际返回: {v}"))
        .unwrap_err();
    assert!(
        err.to_string().contains("脚本执行超时被中断"),
        "正则回溯中断应输出可读文案: {}",
        err
    );
}

/// 正常脚本不受中断文案影响（每次 eval 前 reset_deadline 复位标志）
#[test]
fn normal_script_after_interrupt_is_not_misreported() {
    let engine = engine_with_budget(100);
    assert!(JsEngine::eval(&engine, "while(true){}").is_err());
    assert_eq!(
        JsEngine::eval(&engine, "1 + 1").expect("中断后引擎应可恢复"),
        "2"
    );
}
