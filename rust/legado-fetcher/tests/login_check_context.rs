//! P2-8（引擎链审查 2026-11-13）：loginCheckJs 必须携带书源上下文
//!
//! 上游 `WebBook.kt:74-99` 的 `analyzeUrl.evalJS(checkJs, it)` 经
//! `AnalyzeUrl.evalJS`（AnalyzeUrl.kt:395-421）绑定 `source`/`cookie`/`cache`
//! 并挂载书源 jsLib（SharedJsScope）。修复前 Rust 侧只 `QuickJsExecutor::new`
//! 注入 `result`，故 checkJs 引用 jsLib 函数或 `source.getVariable()` 时
//! 抛 `ReferenceError` → 首检/二次 errResponse 均 JsFailed → 整源失败。
//!
//! 本测试锁定：
//! ① jsLib 函数可用（修复前 `execute_login_check` 返回 LoginRequired）；
//! ② `source.getVariable()` 可用（修复前同样整源失败）。

#![cfg(feature = "quickjs")]

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_fetcher::source_setup::book_source_js_setup_script;
use legado_fetcher::web_book::RealBookSourceFetcher;

/// 与生产同源的 setup 入口（宿主数据为空：loginCheckJs 用例不依赖 infoMap/
/// 登录缓存，仅验证 source/cookie/cache 绑定）
fn setup_script(source: &BookSource) -> String {
    book_source_js_setup_script(source, &HashMap::new(), None, None).expect("setup 脚本生成")
}

/// ① loginCheckJs 调用 jsLib 函数：修复前 `p28LoggedIn is not defined` →
/// JsFailed → 二次 errResponse 仍失败 → LoginRequired
#[test]
fn login_check_js_can_call_js_lib_function() {
    let source = BookSource {
        book_source_url: "https://p28-jslib.example.com".to_string(),
        js_lib: Some(
            "function p28LoggedIn(body) { return String(body).indexOf('未登录') < 0; }".to_string(),
        ),
        login_check_js: Some(
            "({ code: p28LoggedIn(result.body()) ? 200 : 401, \
             body: result.body(), url: result.url() })"
                .to_string(),
        ),
        ..BookSource::default()
    };
    let setup = setup_script(&source);

    let ok = RealBookSourceFetcher::execute_login_check(
        &source,
        "正常内容",
        "https://p28-jslib.example.com/s",
        200,
        Some(&setup),
    )
    .expect("loginCheckJs 引用 jsLib 函数应成功（修复前 JsFailed → LoginRequired）");
    assert_eq!(ok.code, 200);
    assert_eq!(ok.body, "正常内容");

    let walled = RealBookSourceFetcher::execute_login_check(
        &source,
        "未登录内容",
        "https://p28-jslib.example.com/s",
        200,
        Some(&setup),
    )
    .expect("jsLib 判定未登录时应返回可 cast 的响应对象");
    assert_eq!(walled.code, 401, "jsLib 判定逻辑应生效");
}

/// ② loginCheckJs 读取 `source.getVariable()`：修复前 `source is not defined`
/// → JsFailed → 整源失败
#[test]
fn login_check_js_can_read_source_variable() {
    const SOURCE_URL: &str = "https://p28-variable.example.com";
    let key = format!("sourceVariable_{SOURCE_URL}");
    legado_js::host_api::variable_store::set_variable(&key, "p28-token").expect("seed 变量");

    let source = BookSource {
        book_source_url: SOURCE_URL.to_string(),
        login_check_js: Some(
            "result.body() === source.getVariable() \
             ? { code: 200, body: 'var-ok', url: result.url() } \
             : false"
                .to_string(),
        ),
        ..BookSource::default()
    };
    let setup = setup_script(&source);

    let result = RealBookSourceFetcher::execute_login_check(
        &source,
        "p28-token",
        "https://p28-variable.example.com/s",
        200,
        Some(&setup),
    );
    legado_js::host_api::variable_store::remove_variable(&key).ok();

    let resp = result.expect("source.getVariable() 应可用（修复前 source is not defined）");
    assert_eq!(resp.code, 200);
    assert_eq!(resp.body, "var-ok");
    assert_eq!(resp.url, "https://p28-variable.example.com/s");
}
