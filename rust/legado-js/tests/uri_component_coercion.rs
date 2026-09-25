//! `encodeURIComponent` 非字符串入参的 JS 语义强转回归测试（quickjs 档）
//!
//! 背景（MessageDigest 批次 2026-09-25 附带发现）：七猫 jsLib 的
//! `qmUrl` 对非字符串值（`page: 1` 为 JS int）调用
//! `encodeURIComponent(params[k])`。Rhino / JS 原生 `encodeURIComponent(1)`
//! 会按 JS 规范 `ToString` 强转为 `"1"`；而宿主此前以严格 `String` 签名挂载，
//! 收到 JS `int` 时抛 `Error converting from js 'int' into type 'string'`，
//! 致 `qmSearch('测试', 1)` 整条 searchUrl 失败。
//!
//! 修复：`encodeURIComponent` 入参改用 `rquickjs::Coerced<std::string::String>`
//! （QuickJS `JS_ToString`，JS 规范强转）。本测试锁定该行为：
//! int / bool / null / undefined 均按 JS 语义强转后编码，字符串行为不变。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// int / bool / null / undefined 入参按 JS 语义强转（对齐 Rhino 原生 encodeURIComponent）
#[test]
fn encode_uri_component_coerces_non_string_values() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.uri-coercion", || {
        // JS int 1 → "1"（七猫 qmUrl 的 page 入参形态）
        let one: String = JsEngine::eval(&engine, "encodeURIComponent(1)")
            .expect("encodeURIComponent(1) 求值失败（int 强转缺失?）");
        assert_eq!(one, "1", "JS int 1 应强转为 \"1\"；观测: {one}");

        // 含保留字符的 int 拼接场景（对齐 qmUrl 的 k + '=' + enc(v)）
        let kv: String =
            JsEngine::eval(&engine, "'page=' + encodeURIComponent(1)").expect("拼接求值失败");
        assert_eq!(kv, "page=1", "query 片段应为 page=1；观测: {kv}");

        // bool / null / undefined 的 JS 规范强转
        let b: String = JsEngine::eval(&engine, "encodeURIComponent(true)").expect("bool 求值失败");
        assert_eq!(b, "true", "JS true 应强转为 \"true\"；观测: {b}");
        let n: String = JsEngine::eval(&engine, "encodeURIComponent(null)").expect("null 求值失败");
        assert_eq!(n, "null", "JS null 应强转为 \"null\"；观测: {n}");
        let u: String =
            JsEngine::eval(&engine, "encodeURIComponent(undefined)").expect("undefined 求值失败");
        assert_eq!(
            u, "undefined",
            "JS undefined 应强转为 \"undefined\"；观测: {u}"
        );

        // 字符串行为不变（既有语义：保留 -_.!~*'()，中文 UTF-8 百分号编码）
        let s: String =
            JsEngine::eval(&engine, "encodeURIComponent('重生')").expect("字符串求值失败");
        assert_eq!(
            s, "%E9%87%8D%E7%94%9F",
            "中文应按 UTF-8 百分号编码；观测: {s}"
        );
        let keep: String = JsEngine::eval(&engine, "encodeURIComponent('a-b_c.d!e~f*g(h)i')")
            .expect("保留字符求值失败");
        assert_eq!(
            keep, "a-b_c.d!e~f*g(h)i",
            "encodeURIComponent 应保留 -_.!~*'() 不编码；观测: {keep}"
        );
    });
}
