//! 能力对账批次 2 | 任务 1：prologue 变量冲突最小复现测试（先红后绿）
//!
//! 背景（生产事故）：
//! - #702 乐乎 searchUrl：`redeclaration of 'baseUrl'` —— setup 脚本 `var baseUrl`
//!   （全局脚本顶层 var → QuickJS 注册全局 var 条目）与书源块顶层 `let baseUrl`
//!   跨 eval 冲突（运行时 redeclaration）。
//! - #850 爱巴士 searchUrl：`invalid redefinition of global identifier 'key'` ——
//!   变量前导 `var key` 与块内 `let key` 同脚本冲突（解析期错误）。
//! - 同族问题（引擎池复用）：块自身顶层 `let` 会跨 eval 残留（QuickJS 全局
//!   词法环境），翻页后同块再求值即 `redeclaration`。
//!
//! 测试执行器刻意使用「单共享引擎 + 预 eval setup 脚本」（模拟池化缓存引擎，
//! 无 LEXICAL 新引擎兜底），确保冲突必现：
//!
//! RED（修复前）：
//! - test_lofter_702：err = Some("...redeclaration of 'baseUrl'...")
//! - test_aibus_850：err = Some("...invalid redefinition of global identifier...")
//! - test_repeated_eval：第 2 次 err = Some("...redeclaration of 'marker'...")
//!
//! GREEN（修复后：prologue var→globalThis 属性注入 + 块级 Function-eval 作用域隔离）：
//! - #702 块正常求值出 default 分支 URL；#850 引擎侧 redefinition 消除（剩余为
//!   规范 TDZ 自引用错误，属源侧问题，另行报告）；跨 eval 重复求值两次均 Ok。
//!
//! 运行：cargo test -p legado-ffi --features quickjs --test prologue_collision

#![cfg(feature = "quickjs")]

use std::collections::HashMap;
use std::sync::Arc;

use legado_ffi::api::source_js_bindings::book_source_js_setup_script;
use legado_ffi::legado_core::models::BookSource;
use legado_ffi::legado_js::engine::JsEngine;
use legado_ffi::legado_js::sandbox::SandboxConfig;
use legado_ffi::legado_js::QuickJsEngine;
use legado_ffi::legado_parser::analyze_rule::JsExecutor;
use legado_ffi::legado_parser::AnalyzeUrl;

/// 模拟池化缓存引擎：单共享引擎 + 预 eval 的 setup 脚本，无 LEXICAL 兜底。
struct PooledExecutor {
    engine: Arc<QuickJsEngine>,
}

impl JsExecutor for PooledExecutor {
    fn execute_js(&self, code: &str) -> Result<String, String> {
        self.engine.eval(code).map_err(|e| e.to_string())
    }
}

fn shared_engine(setup_source: &BookSource) -> Arc<QuickJsEngine> {
    let engine = QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("引擎创建失败");
    let engine = Arc::new(engine);
    let setup = book_source_js_setup_script(setup_source).expect("setup 脚本生成失败");
    engine.eval(&setup).expect("setup eval 失败");
    engine
}

fn minimal_source(url: &str, name: &str) -> BookSource {
    BookSource {
        book_source_url: url.to_string(),
        book_source_name: name.to_string(),
        ..Default::default()
    }
}

fn key_page_vars() -> HashMap<String, String> {
    let mut vars = HashMap::new();
    vars.insert("key".to_string(), "测试".to_string());
    vars.insert("page".to_string(), "1".to_string());
    vars
}

/// #702 乐乎 searchUrl @js: 块（语料 .tmp/corpus/yckceo_1283.json idx 702 逐字提取）。
/// 顶层 `let baseUrl` 与 setup 脚本 `var baseUrl` 构成跨 eval 冲突；
/// key=「测试」→ prefix=「测」→ default 分支（纯字符串构造 + java.put/
/// java.androidId/JSON.stringify，无网络），完成值应为 post.json URL。
const LOFTER_702_SEARCH_URL: &str = r#"@js:
let prefix = key.charAt(0);
java.put("prefix",prefix);
let offset = '{\{(page-1) *' + (prefix === '%' ? '10}' : (prefix === '@' ? '10}' : '20}')) + '}';
let baseUrl = "https://api.lofter.com/newsearch/"
switch(prefix) {
    case '@':
        result = baseUrl+'blog.json?key=' + key.slice(1)+ '&limit=10&offset=' + offset;
        break;
    case '#':
    case '＃':
        result = baseUrl+'collection.json?key=' + key.slice(1) + '&limit=20&offset=' + offset;
        break;
    case '%':
        result = baseUrl+'grain.json?key='+key.slice(1)+'&limit=10&offset=' + offset;
        break;
    default:
        let header = {
            "headers": {
                "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
                "deviceid": java.androidId(),
                "if-modified-since": String(new Date()).replace(/(.*?)\s(.*?)\s(.*?)\s(.*?)GMT.*/,'$1, $3 $2 $4 GMT')
            }
        };
        result = baseUrl+'post.json?key=' + key + '&sortType=0&offset=' + offset + '&limit=20,' + JSON.stringify(header);
}
"#;

/// #702：乐乎 searchUrl 块在共享引擎（setup 已 eval）上求值不得报
/// `redeclaration of 'baseUrl'`，且完成值应为 default 分支的 post.json URL。
#[test]
fn test_lofter_702_search_block_no_redeclaration() {
    let engine = shared_engine(&minimal_source("https://www.lofter.com", "乐乎文章（优）"));
    let executor = PooledExecutor { engine };
    let (out, err) =
        AnalyzeUrl::analyze_js_with_error(LOFTER_702_SEARCH_URL, &executor, &key_page_vars());
    assert!(
        err.is_none(),
        "#702 乐乎 searchUrl 块不应再报 redeclaration of 'baseUrl'：{err:?}"
    );
    assert!(
        out.contains("https://api.lofter.com/newsearch/post.json"),
        "完成值应为 default 分支 URL：{out}"
    );
}

/// #850：爱巴士 `let key = java.encodeURI(key)` 自引用最小复现。
/// 修复前：同脚本 `var key`（变量前导）+ `let key` → 解析期
/// `invalid redefinition of global identifier 'key'`。
/// 修复后：前导改属性注入 + 块级隔离 → 引擎侧冲突消除；剩余为规范 TDZ
/// （自引用读自身；V8 报 "Cannot access 'key' before initialization"，
/// QuickJS-ng 报 "key is not initialized"，两者均为规范 TDZ 语义；
/// Rhino 的宽容是源侧隐性依赖），错误文本必须从 redefinition 变为 TDZ。
#[test]
fn test_aibus_850_self_reference_is_tdz_not_redefinition() {
    let engine = shared_engine(&minimal_source("https://www.ibusrm.com", "爱巴士"));
    let executor = PooledExecutor { engine };
    let (_, err) = AnalyzeUrl::analyze_js_with_error(
        "@js:\nlet key = java.encodeURI(key);",
        &executor,
        &key_page_vars(),
    );
    let msg = err.expect("#850 自引用块应报错（引擎侧冲突消除后剩余 TDZ）");
    assert!(
        !msg.contains("redefinition") && !msg.contains("redeclaration"),
        "引擎侧 var/let 冲突应已消除：{msg}"
    );
    // V8 措辞 "before initialization"；QuickJS-ng 措辞 "not initialized"
    // （TDZ 语义一致，引擎措辞不同）
    assert!(
        msg.contains("before initialization") || msg.contains("not initialized"),
        "剩余错误应为规范 TDZ（'key' 初始化前自引用）：{msg}"
    );
}

/// 跨 eval：引擎池复用场景同一块连续求值两次（翻页 1→2），块内顶层 let
/// 不得残留全局条目导致第二次 `redeclaration of 'marker'`。
#[test]
fn test_repeated_eval_block_isolation() {
    let engine = shared_engine(&minimal_source("https://example.com", "example"));
    let executor = PooledExecutor { engine };
    let vars = key_page_vars();
    let rule = "@js:\nlet marker = 42;\nresult = String(marker);";

    let (out1, err1) = AnalyzeUrl::analyze_js_with_error(rule, &executor, &vars);
    assert!(err1.is_none(), "首次求值（第 1 页）：{err1:?}");
    assert_eq!(out1, "42", "完成值应为 marker 字符串：{out1}");

    let (out2, err2) = AnalyzeUrl::analyze_js_with_error(rule, &executor, &vars);
    assert!(
        err2.is_none(),
        "同引擎重复求值（第 2 页）不应再报 redeclaration of 'marker'：{err2:?}"
    );
    assert_eq!(out2, "42");
}
