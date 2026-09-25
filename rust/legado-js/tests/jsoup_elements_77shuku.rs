//! ⚡📂77读书（http://www.77shuku.info）jsoup Elements 能力端到端测试（quickjs 档）
//!
//! 夹具（verbatim 原文，来源/提取时间见各夹具头部注释）：
//! - `tests/fixtures/js_lib/77shuku_rule_search.js` — ruleSearch.bookList；
//! - `tests/fixtures/js_lib/77shuku_rule_content.js` — ruleContent.content。
//!
//! 定性结论（2026-09-25，用户实测报错 `not a function (at <eval> (<input>:1:246))`）：
//! 报错点 1:246 精确落在搜索规则首个 `rows.size()` 调用位（规则单行化后
//! `for (var i = 0; i < rows.size(); i++)` 起始列 ≈ 246-248）——修复前
//! `JSOUP_BRIDGE_JS` 的 Elements 模拟层缺集合 API（`size()/isEmpty()/each()`），
//! 整条搜索规则失败。**定性：我方宿主 jsoup 模拟层缺口，非源 JS bug**。
//! 正文规则同族依赖的 `Element.remove()` 与
//! `Packages.org.jsoup.parser.Parser.unescapeEntities` 此前亦缺。
//!
//! 红→绿（本批次）：
//! - **红态（回归守卫）**：`shuku77_search_rule_legacy_bridge_reproduces_not_a_function`
//!   把 `Packages.org.jsoup` 覆写为修复前 legacy 形态（无 `size()`）→ 复现
//!   `not a function`；
//! - **绿态**：修复后桥下搜索/正文规则跑通，断言覆盖行过滤（`td.size()<7`、
//!   非 `/novel/` 链接）、`K→000` 字数替换、实体解码、tip 移除、广告行过滤、
//!   `txt下载地址` 截断、U+00A0 归一。
//!
//! 引擎搭建与生产 `QuickJsExecutor`（`rust/legado-ffi/src/js_executor.rs`
//! fresh 路径）同源：`SandboxConfig::default().with_allow_script_run(true)`，
//! 64MB 内存上限，`with_current_source_tag`。HTTP 响应体以绑定注入
//! 全局 `result`（生产规则执行在求值规则脚本前注入，本处模拟同一注入点）。

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

fn load_fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/js_lib")
        .join(name);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("规则夹具读取失败: {}: {e}", path.display()))
}

/// 搜索响应 mock（单行表格，4 行）：
/// 行 1/2 = 8 td 书行（末列 `1200K`/`88K` 走 `K→000` 字数替换）；
/// 行 3 = 1 td 短行（`td.size() < 7` 过滤）；
/// 行 4 = 7 td 非书行（href 无 `/novel/`，规则内过滤）。
const SEARCH_MOCK: &str = "<table><tr><td>1</td><td>[玄幻]</td><td><a href=\"/novel/1001\">剑来</a></td><td><a href=\"/chapter/1001\">第一章</a></td><td>今日更新</td><td><span>单测作者</span></td><td>新书</td><td>1200K</td></tr><tr><td>2</td><td>[都市]</td><td><a href=\"/novel/1002\">凡人修仙</a></td><td><a href=\"/chapter/1002\">第二章</a></td><td>今日更新</td><td><span>单测作者</span></td><td>完结</td><td>88K</td></tr><tr><td>短行</td></tr><tr><td>4</td><td>[其他]</td><td><a href=\"/other/9\">不是书</a></td><td><a href=\"/chapter/9\">第四章</a></td><td>今日更新</td><td>作者九</td><td>连载</td></tr></table>";

/// 正文响应 mock：`div#ChapterContents` 内含
/// - `div#content_tip`（规则 `remove()` 后不得再出现）；
/// - 排版实体 `&mdash;`/`&#27665;`/`&nbsp;`/`&quot;`（html5ever 解析时解码为
///   真实字符，`&nbsp;` 由规则 U+00A0 归一为普通空格）；
/// - 广告行「请记住77读书最新网址」（规则 27 词 ads 过滤命中）；
/// - `txt下载地址` 截断线（其后内容整段截断，含「请访问我们的最新网址」）。
const CONTENT_MOCK: &str = "<div id=\"ChapterContents\"><div id=\"content_tip\"><p>点击按钮复制我们的最新域名</p></div><p>第一段正文&mdash;民&#27665;&nbsp;说&quot;好&quot;<br></p><p>第二句在同段外<br></p><p>请记住77读书最新网址<br></p><p>第二段正文内容<br></p><p>txt下载地址：点我</p><p>请访问我们的最新网址</p></div>";

/// 修复前 legacy 形态的 jsoup 模拟层：Elements 集合**无** `size()/isEmpty()/each()`
/// （单元素对象与 `select` 后代并集近似为修复前既有语义）。用于红态回归：
/// 覆写 `Packages.org.jsoup` 后跑搜索规则，`rows.size()` 应抛 `not a function`。
const LEGACY_JSOUPL_BRIDGE: &str = r#"
(function () {
  function __legacyEl(html, css, i) {
    var h = String(html == null ? '' : html);
    var c = String(css || '');
    return {
      attr: function (name) { return java.jsoupAttrN(h, c, i, String(name)); },
      text: function () { return java.jsoupTextN(h, c, i); },
      html: function () { return java.jsoupHtmlN(h, c, i); },
      select: function (sub) { return __legacySet(h, (c ? c + ' ' : '') + String(sub || '')); },
      toString: function () { return java.jsoupHtmlN(h, c, i); }
    };
  }
  function __legacySet(html, css) {
    var h = String(html == null ? '' : html);
    var c = String(css || '');
    return {
      attr: function (name) { return java.jsoupAttrN(h, c, 0, String(name)); },
      text: function () { return java.jsoupTextN(h, c, 0); },
      html: function () { return java.jsoupHtmlN(h, c, 0); },
      first: function () { return __legacyEl(h, c, 0); },
      get: function (i) { return __legacyEl(h, c, i); },
      select: function (sub) { return __legacySet((c ? c + ' ' : '') + String(sub || '')); },
      toString: function () { return java.jsoupHtmlN(h, c, 0); }
    };
  }
  var Jsoup = {
    parse: function (html) {
      var h = String(html == null ? '' : html);
      return {
        select: function (css) { return __legacySet(h, String(css || '')); },
        body: function () { return __legacyEl(h, 'body', 0); },
        toString: function () { return h; }
      };
    }
  };
  if (globalThis.Packages) {
    globalThis.Packages.org = globalThis.Packages.org || {};
    globalThis.Packages.org.jsoup = {
      Jsoup: Jsoup,
      parser: { Parser: { unescapeEntities: function (s) { return String(s); } } }
    };
  }
  globalThis.org = globalThis.org || {};
  globalThis.org.jsoup = {
    Jsoup: Jsoup,
    parser: { Parser: { unescapeEntities: function (s) { return String(s); } } }
  };
})();
"#;

/// 绿态：搜索规则（jsoup Elements 集合 API + 行作用域索引访问）跑通，
/// 完成值 `out`（JSON 字符串数组）经 `result_to_string` 字符串化后
/// （数组元素双引号转义一层）断言转义子串：两条书行命中、过滤生效、K→000。
#[test]
fn shuku77_search_rule_jsoup_elements_roundtrip() {
    let engine = production_engine();
    let rule = load_fixture("77shuku_rule_search.js");

    current_source::with_current_source_tag("e2e.77shuku.search", || {
        // 生产顺序：引擎建立后（Packages/jsoup shim 已就绪）重注入桥（幂等）。
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);

        let out: String = JsEngine::eval_with_bindings(
            &engine,
            &rule,
            &[("result", JsValue::String(SEARCH_MOCK.to_string()))],
        )
        .expect("77读书搜索规则求值失败（Elements 集合能力缺失?）");
        assert!(
            out.contains(r#"\"name\":\"剑来\""#),
            "行 1 应命中（剑来）；观测: {out}"
        );
        assert!(
            out.contains(r#"\"bookUrl\":\"/novel/1001\""#),
            "bookUrl 应取首个 a 的 href；观测: {out}"
        );
        assert!(
            out.contains(r#"\"wordCount\":\"1200000\""#),
            "1200K 应替换为 1200000（K→000）；观测: {out}"
        );
        assert!(
            out.contains(r#"\"name\":\"凡人修仙\""#),
            "行 2 应命中（凡人修仙）；观测: {out}"
        );
        assert!(
            out.contains(r#"\"wordCount\":\"88000\""#),
            "88K 应替换为 88000（K→000）；观测: {out}"
        );
        assert!(
            !out.contains("/other/9"),
            "href 无 /novel/ 的行应被过滤；观测: {out}"
        );
        assert!(
            !out.contains("短行"),
            "td.size()<7 的短行应被过滤；观测: {out}"
        );
    });
}

/// 绿态：正文规则（`Element.remove()` + `Parser.unescapeEntities` +
/// 实体解码/广告过滤/截断/U+00A0 归一）跑通。
#[test]
fn shuku77_content_rule_remove_and_unescape_roundtrip() {
    let engine = production_engine();
    let rule = load_fixture("77shuku_rule_content.js");

    current_source::with_current_source_tag("e2e.77shuku.content", || {
        let _ = JsEngine::eval(&engine, JSOUP_BRIDGE_JS);

        let out: String = JsEngine::eval_with_bindings(
            &engine,
            &rule,
            &[("result", JsValue::String(CONTENT_MOCK.to_string()))],
        )
        .expect("77读书正文规则求值失败（remove/unescapeEntities 缺失?）");

        // 正文保留
        assert!(out.contains("民"), "&#27665; 应解码为「民」；观测: {out}");
        assert!(
            out.contains('\u{2014}'),
            "&mdash; 应解码为长破折号；观测: {out}"
        );
        assert!(out.contains("说\"好\""), "&quot; 应解码为引号；观测: {out}");
        assert!(out.contains("第二句在同段外"), "正文行应保留；观测: {out}");
        assert!(out.contains("第二段正文内容"), "正文行应保留；观测: {out}");
        // tip 移除（Element.remove 生效）
        assert!(
            !out.contains("点击按钮复制"),
            "div#content_tip 移除后不得再含其文本；观测: {out}"
        );
        // 广告行过滤（27 词 ads 命中「记住77」/「最新网址」）
        assert!(!out.contains("记住77"), "广告行应被 ads 过滤；观测: {out}");
        assert!(
            !out.contains("最新网址"),
            "广告/截断行均不应含「最新网址」；观测: {out}"
        );
        // txt下载地址 截断（其后「点我」与尾部提示行整段消失）
        assert!(
            !out.contains("txt下载地址"),
            "截断线之后应被移除；观测: {out}"
        );
        // U+00A0 归一（&nbsp; 解码后由规则 split/join 归一为普通空格）
        assert!(
            !out.contains('\u{a0}'),
            "U+00A0 应被归一为普通空格；观测: {out}"
        );
    });
}

/// 红态（回归守卫）：修复前 legacy 形态（Elements 无 `size()`）下，
/// 搜索规则在 `rows.size()` 处复现用户实测的 `not a function`。
/// 该测试证明报错根因是宿主 jsoup 模拟层缺口（而非源 JS bug），
/// 且修复后桥（绿态测试）与 legacy 形态的差异恰为集合 API。
#[test]
fn shuku77_search_rule_legacy_bridge_reproduces_not_a_function() {
    let engine = production_engine();
    let rule = load_fixture("77shuku_rule_search.js");

    current_source::with_current_source_tag("e2e.77shuku.search.legacy-red", || {
        // 覆写 Packages.org.jsoup / org.jsoup 为修复前 legacy 形态
        // （集合无 size/isEmpty/each；引擎建立时注入的修复桥被替换）。
        JsEngine::eval(&engine, LEGACY_JSOUPL_BRIDGE).expect("legacy 形态注入失败");

        let err = JsEngine::eval_with_bindings(
            &engine,
            &rule,
            &[("result", JsValue::String(SEARCH_MOCK.to_string()))],
        )
        .expect_err("legacy 形态（无 size()）应复现用户实测的 not a function");
        let msg = err.to_string();
        assert!(
            msg.contains("not a function"),
            "legacy 形态应在 rows.size() 处抛 not a function（对齐用户报错 \
             <input>:1:246）；观测: {msg}"
        );
    });
}
