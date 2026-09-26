//! getElements 元素对象 select()/length/size 回归测试（quickjs 档）
//!
//! 定性结论（取证，久久漫画 bookList 混淆体）：
//! `_0x139d2 = java.getElements('.book-list li')` 后
//! `for (i=0x0; i<_0x139d2['length']; i++)
//! _0x139d2[i]['select'](_0x24fc10)['text']()` ——
//! `java.getElements` 返回的元素对象（Rust 侧 `build_element_object`）
//! 仅有 `toString/html/text/attr` 面，缺 `select` 方法，混淆体
//! `els[i].select('a')` 抛 `not a function`，整条 bookList 规则失败。
//!
//! 红→绿（本批次，修复面）：
//! - 元素对象补 `select(sub)`：作用域 = 该元素 outerHTML 快照，返回
//!   Elements 面集合对象（面与 JSOUP_BRIDGE_JS `__set` 对齐 + 数字下标键
//!   "0"/"1"/… + `length` 属性），各方法委托既有 `jsoup_text_n/
//!   jsoup_html_n/jsoup_attr_n/jsoup_size`；
//! - `getElements` 返回数组补挂 `size()` 方法（`length` 为原生数组属性，
//!   两者并存——久久混淆体直读 `length`，部分书源读 `size()`）。

#![cfg(feature = "quickjs")]

use legado_js::engine::{JsEngine, JsValue};
use legado_js::host_api::current_source;
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

/// 久久漫画 bookList 场景的本地 HTML 夹具（书源实际页面结构同形）
const BOOK_LIST_HTML: &str = r#"<html><body><ul class="book-list"><li data-id="1"><a href="/b/1/">书一</a><span class="author">作者A</span></li><li data-id="2"><a href="/b/2/">书二</a><span class="author">作者B</span></li></ul></body></html>"#;

/// 绿态：`els[i].select('a').text()` 链式调用 + 数组 `length`/`size()`
/// 双面 + for 循环遍历（久久漫画混淆体原形还原）
#[test]
fn get_elements_select_chained_text_and_length_face() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.get_elements.select.jiujiu", || {
        // 久久混淆体原形（变量名还原；html 经 src 绑定注入 ——
        // java.getElements 读当前 src 全局）
        let script = r#"
var _0x139d2 = java.getElements('ul.book-list li');
var loop = '';
for (var i = 0x0; i < _0x139d2['length']; i++) {
  loop += _0x139d2[i]['select']('a')['text']();
}
JSON.stringify({
  firstSelText: _0x139d2[0].select('a').text(),
  secondSelText: _0x139d2[1].select('a').text(),
  len: _0x139d2['length'],
  size: _0x139d2.size(),
  selSize: _0x139d2[0].select('a').size(),
  selLen: _0x139d2[0].select('a').length,
  selAttr: _0x139d2[0].select('a').attr('href'),
  idxText: _0x139d2[0].select('span')[0].text(),
  loop: loop
})
"#;
        let out: String = JsEngine::eval_with_bindings(
            &engine,
            script,
            &[("src", JsValue::String(BOOK_LIST_HTML.to_string()))],
        )
        .expect("getElements select 链执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["firstSelText"], "书一",
            "els[0].select('a').text() 应命中首项"
        );
        assert_eq!(
            v["secondSelText"], "书二",
            "els[1].select('a').text() 应命中次项"
        );
        assert_eq!(v["len"], 2, "数组 length（原生属性）应为 2");
        assert_eq!(v["size"], 2, "数组 size()（补挂方法）应为 2");
        assert_eq!(v["selSize"], 1, "集合 size() 应为 1");
        assert_eq!(v["selLen"], 1, "集合 length 属性（久久混淆体直读面）应为 1");
        assert_eq!(v["selAttr"], "/b/1/", "集合 attr('href') 应取首匹配属性");
        assert_eq!(v["idxText"], "作者A", "集合数字下标 [0].text() 应命中");
        assert_eq!(
            v["loop"], "书一书二",
            "for 循环按 length 遍历逐项 select 应全中"
        );
    });
}

/// 绿态：嵌套 select（选择器链续接）+ 集合方法面
/// （toArray/each/get/first/last/isEmpty/toString）与 `__set` 面一致
#[test]
fn get_elements_nested_select_and_collection_face() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.get_elements.select.face", || {
        let script = r#"
var els = java.getElements('ul.book-list li');
var a = els[0].select('a');
JSON.stringify({
  nested: els[0].select('span.author').text(),
  firstText: a.first().text(),
  lastText: a.last().text(),
  get0: a.get(0).text(),
  isEmpty: a.isEmpty(),
  toArrayLen: a.toArray().length,
  eachSum: (function () { var s = ''; a.each(function (el, i) { s += i + el.text(); }); return s; })(),
  toStringSnap: a.toString()
})
"#;
        let out: String = JsEngine::eval_with_bindings(
            &engine,
            script,
            &[("src", JsValue::String(BOOK_LIST_HTML.to_string()))],
        )
        .expect("集合方法面执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["nested"], "作者A",
            "嵌套 select('span.author').text() 应命中"
        );
        assert_eq!(v["firstText"], "书一", "first().text() 应取首匹配");
        assert_eq!(v["lastText"], "书一", "单匹配集合 last() 同 first()");
        assert_eq!(v["get0"], "书一", "get(0).text() 应取首匹配");
        assert_eq!(v["isEmpty"], false, "单匹配集合 isEmpty() 应为 false");
        assert_eq!(v["toArrayLen"], 1, "toArray().length 应为 1");
        assert_eq!(
            v["eachSum"], "0书一",
            "each(fn) 按 (element, index) 逐元素回调应命中"
        );
        assert_eq!(
            v["toStringSnap"], "<a href=\"/b/1/\">书一</a>",
            "toString() 应为首匹配元素快照（自包含，含包裹标签，既有语义）"
        );
    });
}

/// 回归守护：元素对象既有面（toString/html/text/attr）不受 select 补挂影响
#[test]
fn get_elements_existing_element_face_unchanged() {
    let engine = production_engine();
    current_source::with_current_source_tag("e2e.get_elements.select.guard", || {
        let script = r#"
var els = java.getElements('ul.book-list li');
var e = els[1];
JSON.stringify({
  text: e.text(),
  html: e.html(),
  outer: String(e),
  attr: e.attr('data-id')
})
"#;
        let out: String = JsEngine::eval_with_bindings(
            &engine,
            script,
            &[("src", JsValue::String(BOOK_LIST_HTML.to_string()))],
        )
        .expect("既有元素面执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(v["text"], "书二作者B", "text() 既有语义应保持");
        assert_eq!(
            v["html"],
            "<li data-id=\"2\"><a href=\"/b/2/\">书二</a><span class=\"author\">作者B</span></li>",
            "html() 既有语义应保持（快照 inner 字段 = 片段根完整自包含标记）"
        );
        assert!(
            v["outer"].as_str().unwrap().contains("<li data-id=\"2\">"),
            "toString() outerHTML 既有语义应保持；观测: {}",
            v["outer"]
        );
        assert_eq!(v["attr"], "2", "attr('data-id') 既有语义应保持");
    });
}
