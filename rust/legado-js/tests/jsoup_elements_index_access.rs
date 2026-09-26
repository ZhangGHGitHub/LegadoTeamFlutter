//! Elements 数字下标访问端到端测试（quickjs 档）
//!
//! 定性结论（2026-09-26，语料 🎬艾格动漫 agedm.org searchUrl @js: 实测报错
//! `cannot read property 'select' of undefined (at <eval> (<input>:5:73))`）：
//! 报错点 5:73 精确落在
//! `select('#nice').select('#nice').select("blockquote")[0].select("p a")[0]`
//! 的第三个 `.select`——上游 Rhino 的 select 返回 Java List（NativeJavaList
//! 支持数字下标访问），我方桥的 Elements 模拟对象无下标能力 → `[0]` 得
//! undefined → 链式 `.select` 失败。**定性：我方宿主 jsoup 模拟层缺口**。
//!
//! 红→绿（本批次）：
//! - **绿态**：`__set`（select 返回值）与 `__jsoupElementsFromList`（链式
//!   Elements 绑定构造器）逐下标挂惰性 getter——`[0]`/`[i]` 可用，
//!   既有 `size()/first()/toArray()/select/text` 面不变。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, JsValue};
use legado_js::host_api::current_source;
use legado_js::host_api::quickjs_impl::JSOUP_BRIDGE_JS;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 绿态：select 返回值数字下标访问（艾格动漫 searchUrl 同款链式形态，
/// 嵌套 `#nice` 双层 + blockquote + p a，逐级 `[0]` 索引）。
#[test]
fn select_result_supports_numeric_index_access() {
    let engine = production_engine();
    let html = r#"<html><body><div id="nice"><div id="nice"><blockquote><p><a href="/search?q=x">入口</a></p></blockquote></div></div></body></html>"#;
    current_source::with_current_source_tag("e2e.jsoup.index.set", || {
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);
        // 艾格动漫 searchUrl 同款表达式（变量名还原；html 经绑定注入）
        let script = r#"
var soUrl = org.jsoup.Jsoup.parse(html).select('#nice').select('#nice').select("blockquote")[0].select("p a")[0].html()
soUrl
"#;
        let out: String = JsEngine::eval_with_bindings(
            &engine,
            script,
            &[("html", JsValue::String(html.to_string()))],
        )
        .expect("select 下标访问失败（Elements 模拟层缺 [i] 能力?）");
        assert!(
            out.contains("/search?q=x"),
            "blockquote[0] → p a[0] 应命中入口链接；观测: {out}"
        );
    });
}

/// 绿态：`__jsoupElementsFromList` 构造的链式 Elements 同样支持下标访问，
/// 且既有方法面（size/first/toArray）不受影响。
#[test]
fn elements_from_list_supports_numeric_index_access() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.jsoup.index.fromlist", || {
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);
        let script = r#"
var list = __jsoupElementsFromList(['<div class="zw_txt"><a href="/a1/">安定此心</a></div>', '<div class="zw_txt"><a href="/a2/">其他书</a></div>']);
var sizeOk = list.size() === 2;
var idxText = list[1].text();
var firstText = list.first().text();
var toArrayLen = list.toArray().length;
JSON.stringify([sizeOk, idxText, firstText, toArrayLen])
"#;
        let out: String = JsEngine::eval(&engine, script).expect("Elements 构造器下标访问失败");
        assert_eq!(
            out, r#"[true,"其他书","安定此心",2]"#,
            "下标访问与方法面应并存；观测: {out}"
        );
    });
}

/// 绿态（回归守护）：77读书搜索规则依赖的集合 API（`size()`/下标混用）
/// 与既有行为不变——下标 getter 挂载不得破坏原方法面。
#[test]
fn index_getters_do_not_break_existing_face() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.jsoup.index.face", || {
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);
        let script = r#"
var set = org.jsoup.Jsoup.parse('<ul><li>a</li><li>b</li></ul>').select('li');
var a = set.size();
var b = set.isEmpty();
var c = set[0].text();
var d = set.get(1).text();
var e = set.toString();
JSON.stringify([a, b, c, d, e.indexOf('<li>a</li>') >= 0])
"#;
        let out: String = JsEngine::eval(&engine, script).expect("既有方法面受下标 getter 影响");
        assert_eq!(
            out, r#"[2,false,"a","b",true]"#,
            "size/isEmpty/get/toString 面应保持；观测: {out}"
        );
    });
}
