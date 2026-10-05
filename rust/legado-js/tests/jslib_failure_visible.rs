//! P0-B（iOS 实机搜索失败 1/2 号，禁漫天堂 API / 雨鹿小说）：jsLib 求值失败
//! 不再静默降级，改为**带原因上抛**
//!
//! 现状根因：书源 jsLib 求值失败时我方「降级继续」，缺失的库函数推迟到主脚本
//! 引用点才爆出，错误点位后移且文案失真（实机报 `source is not defined`，
//! 实际根因是 jsLib 未加载）。原版 `SharedJsScope.evaluateJsLib`
//! （`app/src/main/java/io/legado/app/model/SharedJsScope.kt:231-260`）失败
//! **直接抛**——URL 映射 jsLib 下载失败抛「下载jsLib-xx失败」(:251)，eval
//! 异常上抛 (:258)；`AnalyzeUrl.evalJS` 调 `getShareScope` 时异常即终止该次
//! 搜索。本批选 B1（对齐原版硬失败），理由：
//! - 原版语义即硬失败，无「jsLib 有错但书源不用库函数仍能跑」的路径；
//! - 我方已有同口径先例 `legado_ffi::js_executor::validate_js_lib`
//!   （队列④ favcomic 口径：`js_lib_ok == Some(false)` 时带台账原因上抛）；
//! - 降级路径引入的 Rhino 语法归一化兜底（`jslib_normalize`）在上抛前保留，
//!   归一化救回成功的 jsLib 仍正常加载（见末条测试）。
//!
//! 本测试覆盖：① 缓存路径；② fresh（词法脚本回退）路径；③ 脚本不使用库函数
//! 时同样上抛（B1 决策的显式契约）；④ 正常 jsLib 不受影响。

#![cfg(feature = "quickjs")]

use legado_js::engine_cache;
use legado_js::executor::QuickJsExecutor;
use legado_parser::JsExecutor;

/// 缓存锁守卫：测试失败不应把锁毒化（同 capability_ledger 的恢复口径），
/// 否则并行测试会以 PoisonError 掩盖真实断言失败
fn cache_guard() -> std::sync::MutexGuard<'static, ()> {
    engine_cache::TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

/// 合法语法 + 运行时 ReferenceError（对齐实机 jsLib 求值失败形态：
/// 语法检查能过，故不会走 Rhino 宽容归一化兜底）
fn bad_lib() -> String {
    "var __p0b_probe = __p0b_missing_lib__();".to_string()
}

/// ① 缓存路径（非词法脚本）：`get_or_create` 构造期 jsLib 失败 → 上抛
#[test]
fn jslib_runtime_failure_surfaces_with_reason_cached_path() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let exec = QuickJsExecutor::new("p0b-cached").with_js_lib(Some(bad_lib()));
    let err = exec
        .execute_js("1 + 1")
        .expect_err("jsLib 求值失败应上抛（不得静默降级后报 `xxx is not defined`）");
    assert!(
        err.contains("jsLib 求值失败"),
        "错误应带根因前缀「jsLib 求值失败」: {err}"
    );
    assert!(
        err.contains("__p0b_missing_lib__"),
        "错误应保留原始失败原因（实机 1/2 号失真链的修复点）: {err}"
    );
}

/// ② fresh 路径（顶层 const 触发词法回退）：`run_fresh` 内 jsLib 失败同样上抛
#[test]
fn jslib_runtime_failure_surfaces_with_reason_fresh_path() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    // 先用同源码 + 正常 jsLib 走两遍（首遍重声明触发回退并标记为词法脚本）
    let code = "const p0b_fresh_probe = 41; p0b_fresh_probe + 1";
    let good = QuickJsExecutor::new("p0b-fresh-mark")
        .with_js_lib(Some("function ok() { return 1; }".to_string()));
    assert_eq!(good.execute_js(code).unwrap(), "42");
    assert_eq!(good.execute_js(code).unwrap(), "42");

    let bad = QuickJsExecutor::new("p0b-fresh").with_js_lib(Some(bad_lib()));
    let err = bad
        .execute_js(code)
        .expect_err("fresh 路径 jsLib 求值失败同样应上抛");
    assert!(
        err.contains("jsLib 求值失败"),
        "fresh 路径错误应带根因前缀: {err}"
    );
}

/// ③ B1 决策契约：jsLib 失败 + 主脚本不引用任何库函数 → 仍上抛
/// （原版 `evaluateJsLib` 失败直接抛，与书源是否使用库函数无关）
#[test]
fn jslib_failure_surfaces_even_when_script_does_not_use_library() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let exec = QuickJsExecutor::new("p0b-unused-lib").with_js_lib(Some(bad_lib()));
    // 脚本与 jsLib 完全无关（纯算术）
    let err = exec
        .execute_js("6 * 7")
        .expect_err("B1：jsLib 失败硬上抛，不因脚本未引用库函数而放行");
    assert!(err.contains("jsLib 求值失败"), "错误文案: {err}");
}

/// ④ 正常 jsLib 不受上抛改动影响（含跨实例缓存复用）
#[test]
fn valid_jslib_still_loads_and_runs() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let first = QuickJsExecutor::new("p0b-ok")
        .with_js_lib(Some("function marker(){ return 'ok'; }".to_string()));
    assert_eq!(first.execute_js("marker()").unwrap(), "ok");
    let second = QuickJsExecutor::new("p0b-ok")
        .with_js_lib(Some("function marker(){ return 'ok'; }".to_string()));
    assert_eq!(second.execute_js("marker()").unwrap(), "ok");
}

/// ⑤ URL 映射形态 jsLib（值为 URL 的 JSON 对象）必须走 fresh 路径的加载器，
/// 不得进缓存路径的「原始 JSON eval」——映射 JSON 不是合法 JS，B1 硬上抛后
/// 会被误放大成整源失败（上游语义是逐条拉取映射，SharedJsScope.parseJsLibMap）。
/// 本用例用非 URL 值（原样内联 JS）避免网络，锁定映射条目可用性。
#[test]
fn url_map_jslib_routes_to_fresh_path() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let lib = r#"{"inline":"function urlMapLib(){ return 'from-map'; }"}"#;
    let exec = QuickJsExecutor::new("p0b-urlmap").with_js_lib(Some(lib.to_string()));
    assert_eq!(
        exec.execute_js("urlMapLib()")
            .expect("URL 映射 jsLib 不应被缓存路径的原始 JSON eval 误判为求值失败（B1 放大点）"),
        "from-map"
    );
}

/// ⑥ W2（审查建议项 2，2026-10-06）：JS 源链构造（`JsSourceEngine::new_quickjs`
/// ← `build_js_orchestrator`）此前丢弃 js_lib_ok 静默降级；对齐上游
/// `JsSourceEngine.buildScope` → `getShareScope` → `evaluateJsLib` 失败直接抛，
/// 现与主链同口径带原因上抛。
#[test]
fn js_source_engine_construction_surfaces_jslib_failure() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let config = legado_js::JsSourceConfig::new(
        "p0b-js-source".to_string(),
        "function search() { return 'x'; }".to_string(),
    )
    .with_js_lib(bad_lib());
    let err = match legado_js::JsSourceEngine::new_quickjs(config) {
        Ok(_) => panic!("JS 源构造期 jsLib 求值失败应上抛（不得静默降级）"),
        Err(e) => e,
    };
    let msg = err.to_string();
    assert!(
        msg.contains("jsLib 求值失败"),
        "错误应带根因前缀「jsLib 求值失败」: {msg}"
    );
    assert!(
        msg.contains("__p0b_missing_lib__"),
        "错误应保留原始失败原因（台账 last_jslib_error）: {msg}"
    );
}

/// ⑥b 对照组（同一修复面）：JS 源 jsLib 正常时构造不受上抛改动影响
#[test]
fn js_source_engine_valid_jslib_still_constructs() {
    let _guard = cache_guard();
    engine_cache::clear_for_tests();
    let config = legado_js::JsSourceConfig::new(
        "p0b-js-source-ok".to_string(),
        "function search() { return libMarker(); }".to_string(),
    )
    .with_js_lib("function libMarker(){ return 'ok'; }".to_string());
    let engine =
        legado_js::JsSourceEngine::new_quickjs(config).expect("正常 jsLib 的 JS 源构造不得受影响");
    assert!(engine.is_main_js_loaded(), "构造期 mainJs 应已 eval 成功");
}
