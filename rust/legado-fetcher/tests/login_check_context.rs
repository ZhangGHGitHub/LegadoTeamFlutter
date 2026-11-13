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
//!
//! 批29 审查补强：
//! ③ P2-4：jsLib 自身求值失败 ≠ 未登录（须 `LegadoError::JsEngine` 上抛）；
//! ④ 防过度上抛：正常 jsLib + checkJs 判定未登录仍 `LoginRequired`；
//! ⑤ P3-7：生产接线（`FetcherDeps::setup_script_for` →
//!    `login_check_setup_script`）确实把 setup 传进 loginCheckJs
//!    （既有用例直接传 `Some(setup)`，漏接某调用点时仍绿）。

#![cfg(feature = "quickjs")]

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use legado_core::models::BookSource;
use legado_core::web_book::BookSourceFetcher;
use legado_core::LegadoError;
use legado_fetcher::deps::FetcherDeps;
use legado_fetcher::source_setup::book_source_js_setup_script;
use legado_fetcher::web_book::RealBookSourceFetcher;
use legado_net::{LegadoClient, LegadoClientConfig};

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

/// ③ [P2-4 批29 审查] jsLib 自身求值失败 ≠ 未登录
///
/// 回归形态：checkJs 上下文接入后，执行前先加载 jsLib。若 jsLib 本身坏了，
/// `execute_js` 在跑 checkJs **之前**就返回 `jsLib 求值失败: …`；首检/二次
/// errResponse 均失败 → 旧实现映射 `LoginRequired("书源需要登录…")`，把
/// 「共享库坏了」误报成「请先登录」，且搜索路径按源静默吞掉 LoginRequired，
/// 用户只看到源消失（修复前该子集——checkJs 不引用 jsLib——本可通过登录检测）。
///
/// 期望：错误分类为 [`LegadoError::JsEngine`] 且保留 jsLib 根因。
#[test]
fn broken_js_lib_reports_js_engine_not_login_required() {
    let source = BookSource {
        book_source_url: "https://p29-broken-lib.example.com".to_string(),
        // 语法错误：加载即失败（不依赖 checkJs 是否引用库函数）
        js_lib: Some("function {".to_string()),
        // checkJs 自身合法且不引用 jsLib：旧实现误报 LoginRequired 的最小子集
        login_check_js: Some("result".to_string()),
        ..BookSource::default()
    };
    let setup = setup_script(&source);

    let err = RealBookSourceFetcher::execute_login_check(
        &source,
        "正常内容",
        "https://p29-broken-lib.example.com/search?q=x",
        200,
        Some(&setup),
    )
    .expect_err("jsLib 求值失败必须整源失败，不得当作未登录放行");

    assert!(
        matches!(err, LegadoError::JsEngine(_)),
        "坏 jsLib 必须归类为 JsEngine（修复前误报 LoginRequired）: {err:?}"
    );
    assert!(
        err.to_string().contains("jsLib"),
        "错误文案须保留 jsLib 根因（不得只剩「请先登录」）: {err}"
    );
}

/// ④ [P2-4 防过度上抛] 正常 jsLib + checkJs 自身判定未登录 → 仍 LoginRequired
///
/// checkJs 在首检（code 200）抛「未登录」→ JsFailed；二次 errResponse
/// （code 500）返回 `result`（方法形直通 → `{}` → code 500）→ 二次 code 500
/// = 判定未登录 → `LoginRequired`。若把二次 500 也归为 JsEngine 即过度上抛。
#[test]
fn genuine_login_wall_still_reports_login_required() {
    let source = BookSource {
        book_source_url: "https://p29-login-wall.example.com".to_string(),
        js_lib: Some("function p29WallLib() { return true; }".to_string()),
        login_check_js: Some(
            "if (result.code() === 500) { result } else { throw new Error('p29 未登录') }"
                .to_string(),
        ),
        ..BookSource::default()
    };
    let setup = setup_script(&source);

    let err = RealBookSourceFetcher::execute_login_check(
        &source,
        "登录页内容",
        "https://p29-login-wall.example.com/s",
        200,
        Some(&setup),
    )
    .expect_err("checkJs 判定未登录应整源失败");

    assert!(
        matches!(err, LegadoError::LoginRequired(_)),
        "checkJs 自身判定未登录仍须 LoginRequired（防过度上抛）: {err:?}"
    );
}

/// 回环 HTTP mock：任意请求返回固定响应体（`Connection: close`；
/// 单线程循环接受连接，够搜索链一次 GET 使用）
fn spawn_static_http_mock(body: &'static str) -> std::net::SocketAddr {
    use std::io::{Read, Write};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
            let mut buf = [0u8; 1024];
            let mut req = Vec::new();
            loop {
                match sock.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        req.extend_from_slice(&buf[..n]);
                        if req.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = sock.write_all(resp.as_bytes());
        }
    });
    addr
}

/// ⑤ [P3-7 批29 审查] 生产接线必须把 setup 传进 loginCheckJs
///
/// 既有用例直接调 `execute_login_check(..., Some(setup))`，无法发现
/// `search`/详情/目录/正文某调用点漏传 `self.login_check_setup_script(..)`
/// （漏传时用例仍绿）。本用例经生产入口 `BookSourceFetcher::search` 驱动：
/// - deps 注入**计数闭包**：断言生产路径确实经 `FetcherDeps::setup_script_for`
///   请求了 setup（非同测试内手搓字符串）；
/// - checkJs 读 `source.getVariable()` 并与响应体比对：login-check 调用点
///   漏传 setup → `source is not defined` → JsFailed → 二次 → LoginRequired
///   → `search` 返回 Err（用例红）。
#[tokio::test]
async fn search_production_path_passes_setup_to_login_check() {
    let addr = spawn_static_http_mock("p29-token");
    let source_url = format!("http://{addr}");
    let var_key = format!("sourceVariable_{source_url}");
    legado_js::host_api::variable_store::set_variable(&var_key, "p29-token").expect("seed 变量");

    let source = BookSource {
        book_source_url: source_url.clone(),
        search_url: Some(format!("http://{addr}/search?q={{key}}")),
        // 仅当 setup（source 绑定）传入时成立；否则 ReferenceError
        login_check_js: Some("result.body() === source.getVariable() ? result : false".to_string()),
        rule_search: Some(legado_core::models::SearchRule::default()),
        ..BookSource::default()
    };

    let calls = Arc::new(AtomicUsize::new(0));
    let calls_deps = Arc::clone(&calls);
    let client = LegadoClient::new(LegadoClientConfig {
        no_proxy: true,
        ..LegadoClientConfig::default()
    })
    .expect("test http client");
    let deps =
        FetcherDeps::new(client).with_source_context(Arc::new(move |source: &BookSource| {
            calls_deps.fetch_add(1, Ordering::SeqCst);
            book_source_js_setup_script(source, &HashMap::new(), None, None).ok()
        }));
    let fetcher = RealBookSourceFetcher::with_deps(deps);

    let result = BookSourceFetcher::search(&fetcher, &source, "kw", 1).await;
    legado_js::host_api::variable_store::remove_variable(&var_key).ok();

    assert!(
        result.is_ok(),
        "login-check 调用点漏传 setup 时 checkJs 会 `source is not defined` → \
         LoginRequired（生产接线缺口的红信号）: {result:?}"
    );
    assert!(
        calls.load(Ordering::SeqCst) >= 2,
        "生产路径应至少两次经 FetcherDeps 取 setup（searchUrl 构建 + loginCheckJs \
         上下文），实际 {}",
        calls.load(Ordering::SeqCst)
    );
}
