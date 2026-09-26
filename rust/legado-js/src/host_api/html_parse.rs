//! HTML 解析桥（java.getElement/getString 等）
//!
//! 对齐原版 JsExtensions（AnalyzeRule.evalJS 注入 `bindings["java"] = this`）：
//! 漫画/图片书源目录与正文规则大量使用
//! `java.getElement(css)` / `java.getElements(css)` / `java.getString(css, html)`
//! 在页面 HTML 上做 CSS 选择（51漫画 `java.getElement("script")`、
//! `java.getString(".btn-read@href", src)` 等）。重构版此前 java 命名空间
//! 仅有工具函数，缺 HTML 元素桥 → 这些书源目录/正文 ReferenceError →
//! 「暂无章节」（2026-08-11 用户反馈 51漫画/Nhentai/快看 全失败）。
//!
//! 语义对齐原版：
//! - `getElement(css)`：对当前解析内容（execute_js_rule 注入的
//!   `globalThis.src`）执行 CSS 选择，返回**元素数组**；每个元素对象
//!   提供 `html()`（innerHTML）/ `text()`（纯文本）/ `toString()`
//!   （outerHTML），对应 JSoup Element 的 html()/text()/toString()
//! - `getString(css, mContent)`：对 mContent（第二参，可空=当前内容）
//!   执行 CSS 选择取**文本**，返回首条（对齐原版 getString 合并语义）
//! - `getStrings(css, mContent)`：文本列表
//!
//! 实现基于 scraper（与 legado-parser 同版本 0.22）— Reasonix 2026-08-11
//!
//! 规则类型分派（台账 P2-6(e) 2026-09-17）：
//! 上游 `java.getString(rule)` == `AnalyzeRule.getString`，支持全规则类型
//! （`$.`/`$[`→JSONPath、`//`→XPath、`@css:`/`@xpath:`/`@json:`/`@regex:`/
//! `@js:`/`@webjs:` 前缀、`@@` 强制 CSS、无前缀按形态/内容自动识别）。
//! 此前绑定层只做 CSS 解析 → JSON 书源 `java.getString('$.x')` 全空
//! （松鹤 kind 恒 `0.0万字`、免费章全加 🔒 等）。现增 [`dispatch_rule`]
//! 分派层：CSS 分支保留既有 [`resolve_get_strings`]（HTML+CSS 行为不变），
//! 其余分支只读复用 `legado-parser` 公开 API（JsonPathParser/XPathParser/
//! RegexEngine），不修改 parser。

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;
use legado_parser::{
    AnalyzeRule, JsonPathParser, RegexEngine, RuleAnalyzer, RuleType, XPathParser,
};
use rquickjs::function::Opt;
use rquickjs::Ctx;
use scraper::{Html, Selector};

/// CSS 选择：返回匹配元素的 outerHTML 字符串快照列表
///
/// 以 String 快照返回（脱离 scraper 文档生命周期），供 JS 元素对象使用。
///
/// 选择段先做 jsoup 前缀归一化（对齐原版 `AnalyzeByJSoup.ElementsSingle`）：
/// `class.foo` → `.foo`、`tag.foo` → `foo`、`id.foo` → `#foo`，其余原样。
/// 否则 `class.comic-contain` 会被 CSS 解析器当成「标签 class + 类 comic-contain」
/// → 永远 0 命中（包子漫画正文 `java.getElements('class.comic-contain@amp-img')`）。
/// 表格族片段的表格上下文包裹（html5ever 按规范丢弃顶层孤立表格标签）
///
/// HTML5 解析器（html5ever）按规范丢弃顶层孤立的表格标签（`tr/td/tbody/…`
/// 作为文档顶层起始时整段丢弃）：元素作用域重解析（JS 桥
/// `rows.get(i).select('td')` → 以行 innerHTML 快照再选子元素）会因此丢失
/// 结构，`td` 选择命中 0 个 → 77读书表格规则整行被 `td.size() < 7` 过滤。
/// 表格族片段必须先裹上表格上下文（显式 `<tbody>`，不依赖隐式节点插入）：
/// - `<td>/<th>` 起始 → `<table><tbody><tr>…</tr></tbody></table>`；
/// - `<tr` 起始 → `<table><tbody>…</tbody></table>`；
/// - `<tbody>/<thead>/<tfoot>/<caption>` 起始 → `<table>…</table>`；
/// - 完整文档 / `<table` / `<body` / 普通元素起始的快照自包含 → 原样解析。
///
/// 返回 (文档, 下钻层数)：下钻层数 = 从 body 首个元素子到片段根元素的层数
/// （0 = 无需包裹）；壳层仅承载结构、不承载业务属性，元素自身定位需按壳层数
/// 下钻（见 `fragment_root` / `ElementSnapshot::attr`）。
fn parse_document_wrapped(html: &str) -> (Html, u8) {
    match leading_tag(html).as_str() {
        "td" | "th" => (
            Html::parse_document(&format!("<table><tbody><tr>{html}</tr></tbody></table>")),
            3,
        ),
        "tr" => (
            Html::parse_document(&format!("<table><tbody>{html}</tbody></table>")),
            2,
        ),
        "tbody" | "thead" | "tfoot" | "caption" => {
            (Html::parse_document(&format!("<table>{html}</table>")), 1)
        }
        _ => (Html::parse_document(html), 0),
    }
}

/// 片段起始标签的标签名（小写；非标签起始返回空串）
///
/// 用精确标签名匹配（而非 `starts_with("<th")` 之类前缀）避免把
/// `<thead` 误判为 `<th` 单元格、`<track` 误判为 `<tr` 行。
fn leading_tag(frag: &str) -> String {
    let lower = frag.trim_start().to_ascii_lowercase();
    if !lower.starts_with('<') {
        return String::new();
    }
    let rest = &lower[1..];
    let end = rest
        .find(|c: char| c == '>' || c.is_ascii_whitespace())
        .unwrap_or(rest.len());
    rest[..end].to_string()
}

fn select_outer_htmls(html: &str, css: &str) -> Vec<String> {
    if html.is_empty() {
        return Vec::new();
    }
    // [艾格修正 | 2026-09-26] 空 css = 元素自身（恒等选择）：链式规则引擎
    // `__jsoupElementsFromList` 的元素对象以 css='' 构造（每项自身即元素，
    // 对齐上游 Element 对象直接取 text/html），此前空 css 一律返回空集 →
    // 文学小说链 toArray 后 `re.test(list[i])` 恒 false、取值全空
    if css.trim().is_empty() {
        return vec![html.to_string()];
    }
    let normalized = legado_parser::HtmlParser::normalize_jsoup_selector(css);
    let Ok(selector) = Selector::parse(&normalized) else {
        return Vec::new();
    };
    let (document, _) = parse_document_wrapped(html);
    document.select(&selector).map(|e| e.html()).collect()
}

/// 链式元素选择（对齐原版 `AnalyzeByJSoup.getElements`）：
/// 规则按 `@` 拆成多段，每段是一次元素选择，下一步在前一步结果内继续选。
///
/// 如 `class.comic-contain@amp-img` → 先选 `.comic-contain`，再在每个内部
/// 选 `amp-img` 标签（包子漫画正文图片）；单段规则退化为一次 CSS 选择。
fn resolve_element_chain(html: &str, rule: &str) -> Vec<String> {
    let segments: Vec<&str> = rule
        .split('@')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if segments.is_empty() {
        return Vec::new();
    }
    let mut current: Vec<String> = vec![html.to_string()];
    for seg in &segments {
        let next: Vec<String> = current
            .iter()
            .flat_map(|h| select_outer_htmls(h, seg))
            .collect();
        if next.is_empty() {
            return Vec::new();
        }
        current = next;
    }
    current
}

/// 末段提取（对齐原版 `AnalyzeByJSoup.getResultLast`）：
/// `text`/`ownText`/`textNodes` → 文本；`html`/`all` → outerHTML；其余 → 属性值
fn extract_last(snaps: &[ElementSnapshot], last: &str) -> Vec<String> {
    match last {
        "text" | "ownText" | "textNodes" => snaps
            .iter()
            .map(|s| s.text.clone())
            .filter(|t| !t.is_empty())
            .collect(),
        "html" | "all" => snaps
            .iter()
            .map(|s| s.outer.clone())
            .filter(|o| !o.is_empty())
            .collect(),
        _ => {
            let mut out = Vec::new();
            for s in snaps {
                let v = s.attr(last).unwrap_or_else(|| s.text.clone());
                if !v.is_empty() && !out.contains(&v) {
                    out.push(v);
                }
            }
            out
        }
    }
}

/// 从单个 outerHTML 快照重建元素，提取 innerHTML / text / 属性
struct ElementSnapshot {
    outer: String,
    inner: String,
    text: String,
}

impl ElementSnapshot {
    fn from_outer(outer: String) -> Self {
        // parse_fragment 的根选择器不可靠（:root 匹配不到 fragment 根），
        // 改用 parse_document + 下钻至片段根元素（表格上下文包裹见
        // parse_document_wrapped；下钻层数由壳层数决定）
        let (doc, drill) = parse_document_wrapped(&outer);
        let root = fragment_root(&doc, drill);
        // inner 取片段根的 outerHTML（与非表格快照 body.inner_html() 单元素时
        // 等价），text 取片段根全部后代文本
        let inner = root.as_ref().map(|e| e.html()).unwrap_or_default();
        let text = root
            .as_ref()
            .map(|e| e.text().collect::<Vec<_>>().join(""))
            .unwrap_or_default();
        Self { outer, inner, text }
    }

    fn attr(&self, name: &str) -> Option<String> {
        let (doc, drill) = parse_document_wrapped(&self.outer);
        fragment_root(&doc, drill)?
            .value()
            .attr(name)
            .map(|v| v.to_string())
    }
}

/// body 首个元素子，再下钻 `drill` 层（表格包裹壳层）至片段根元素
fn fragment_root<'a>(doc: &'a Html, drill: u8) -> Option<scraper::ElementRef<'a>> {
    let body_sel = Selector::parse("body").ok()?;
    let body = doc.select(&body_sel).next()?;
    let mut elem = body.children().find_map(scraper::ElementRef::wrap)?;
    for _ in 0..drill {
        elem = elem.children().find_map(scraper::ElementRef::wrap)?;
    }
    Some(elem)
}

/// 从 HTML 快照解析出元素对象（供 select 后的元素转换）
fn snapshots_from_html(html: &str, css: &str) -> Vec<ElementSnapshot> {
    select_outer_htmls(html, css)
        .into_iter()
        .map(ElementSnapshot::from_outer)
        .collect()
}

/// getString 链式解析（对齐原版 `AnalyzeByJSoup.getStringList`）：
/// `@` 拆段后除末段外全部做链式元素选择，末段按提取模式取值；
/// 无 `@` 时直接 CSS 选择取文本（如 `java.getString("script")`）。
fn resolve_get_strings(html: &str, css: &str) -> Vec<String> {
    let segments: Vec<&str> = css
        .split('@')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if segments.is_empty() {
        return Vec::new();
    }
    if segments.len() == 1 {
        return snapshots_from_html(html, segments[0])
            .iter()
            .map(|s| s.text.clone())
            .filter(|t| !t.is_empty())
            .collect();
    }
    let mut current: Vec<String> = vec![html.to_string()];
    for seg in &segments[..segments.len() - 1] {
        let next: Vec<String> = current
            .iter()
            .flat_map(|h| select_outer_htmls(h, seg))
            .collect();
        if next.is_empty() {
            return Vec::new();
        }
        current = next;
    }
    let snaps: Vec<ElementSnapshot> = current
        .into_iter()
        .map(ElementSnapshot::from_outer)
        .collect();
    extract_last(&snaps, segments.last().unwrap())
}

// ─── 规则类型分派（对齐上游 AnalyzeRule.getString 单步分派）────────────────

/// 规则分派结果（载荷为剥掉前缀后的实际规则体）
///
/// 镜像上游 Kotlin `AnalyzeRule` 单步分派（analyze_rule.rs `get_strings_single_step`）：
/// 显式前缀（`@css:`/`@xpath:`/`@json:`/`@regex:`/`@regexp:`/`@js:`/`@webjs:`、
/// `@@` 强制 CSS）优先；无前缀先按规则形态（`$`→Json、`/`→Xpath、
/// `\d`/`\w`/`\s`/`()`→Regex），再按内容类型（JSON→Json、XML→Xpath，
/// 默认 CSS——HTML+CSS 既有行为保持不变）。
enum RuleDispatch {
    /// CSS 选择器（既有 `resolve_*` 路径，行为不变）
    Css(String),
    /// JSONPath 路径
    Json(String),
    /// XPath 表达式
    Xpath(String),
    /// 正则模式（可为 `&&` 多级链）
    Regex(String),
    /// `@js:` JS 代码
    Js(String),
    /// `@webjs:` JS 代码（无头近似，对齐上游无头回退）
    WebJs(String),
}

/// 判定规则分派类型
fn dispatch_rule(rule: &str, content: &str) -> RuleDispatch {
    // `@@` 前缀强制 CSS 并剥 2 字符（对齐上游 resolve_rule_type G7）
    if let Some(r) = rule.strip_prefix("@@") {
        return RuleDispatch::Css(r.to_string());
    }
    let (prefix, rest) = RuleAnalyzer::parse_rule_prefix(rule);
    match prefix {
        "css" => RuleDispatch::Css(rest.to_string()),
        "xpath" => RuleDispatch::Xpath(rest.to_string()),
        "json" => RuleDispatch::Json(rest.to_string()),
        "regex" => RuleDispatch::Regex(rest.to_string()),
        "js" => RuleDispatch::Js(rest.to_string()),
        "webjs" => RuleDispatch::WebJs(rest.to_string()),
        _ => {
            // 无显式前缀：先按规则自身形态推断
            // （对齐 detect_rule_type_for_content 第 1 步）
            if rule.starts_with('$') {
                RuleDispatch::Json(rule.to_string())
            } else if rule.starts_with('/') {
                RuleDispatch::Xpath(rule.to_string())
            } else if rule.contains(r"\d")
                || rule.contains(r"\w")
                || rule.contains(r"\s")
                || (rule.starts_with('(') && rule.contains(')'))
            {
                RuleDispatch::Regex(rule.to_string())
            } else {
                // 再按内容类型推断（对齐 detect_rule_type_for_content 第 2 步：
                // is_json → Json——JSON 内容下无前缀规则按 JsonPath 解析）
                match AnalyzeRule::detect_content_type(content) {
                    RuleType::Json => RuleDispatch::Json(rule.to_string()),
                    RuleType::Xpath => RuleDispatch::Xpath(rule.to_string()),
                    _ => RuleDispatch::Css(rule.to_string()),
                }
            }
        }
    }
}

/// 正则提取（对齐上游 `AnalyzeRule::regex_extract`）：
/// 单级 → 所有完整匹配（group 0）；多级 `&&` 链 → 逐级筛取后取各组完整匹配
fn regex_extract(content: &str, rule: &str) -> Vec<String> {
    let engine = RegexEngine::new();
    let patterns: Vec<&str> = rule
        .split("&&")
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();
    if patterns.len() <= 1 {
        return engine.regex_match(content, rule).unwrap_or_default();
    }
    match engine.regex_chain_match_all(content, &patterns) {
        Ok(groups) => groups
            .into_iter()
            .map(|g| g.first().cloned().unwrap_or_default())
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// 嵌套 JS 求值的类型化结果（P2-11 ④ §196：`get_string_list` 的
/// null 语义需要区分「字符串 / 数组 / 标量 / 空」——旧字符串化版本把它们
/// 坍缩为同一字符串无法区分，上游 `AnalyzeRule.kt:275/276-278/292` 分别
/// 对 null / String（按 `\n` 拆分）/ 非 List 类型有不同归宿）
enum JsNestedValue {
    /// JS null/undefined 或执行错误（上游 AnalyzeRule.kt:275
    /// `if (result == null) return null`）
    Null,
    /// JS 字符串结果（上游 L276-278：`result.split("\n")`）
    String(String),
    /// JS 数组结果——逐元素保留（P2-6(e) 展开语义；上游 WebJs L253-254
    /// `GSON.fromJsonArray(...).getOrNull()`）。元素经逐元素字符串化
    /// （null/undefined → 空串、对象 → JSON.stringify，与旧 join 路径一致）
    Array(Vec<String>),
    /// JS 数字/布尔/对象结果——已字符串化（上游 L292
    /// `result as? List<String>`：非 List → null；值保留供 `get_string`
    /// 字符串化兼容路径使用）
    Scalar(String),
}

/// 嵌套 `@js:`/`@webjs:` 求值（无头近似，对齐上游 `execute_js_rule`）
///
/// 复用当前引擎全局环境（执行器 prologue 已注入 result/src/baseUrl）：
/// `new Function` 包装得独立词法作用域（与 parser 执行器同款包装，规避
/// 规则顶层 let/const 与全局 var 重声明冲突），临时把 result/src/html
/// 重绑为当前内容（覆盖 mContent ≠ src 的场景）并在 finally 恢复。
/// 执行失败/结果为 null|undefined → 空串（对齐上游 JS 规则错误吞掉 → 空）。
///
/// 求值方式（P2-11 ④ 修正，对齐上游 Rhino 对书源 `@js: return ...` 的
/// 执行语义）：规则代码先按**函数体**求值——`new Function(code)()`，
/// 顶层 `return` 在函数体中合法（书源 `@js:` 规则惯用写法）；函数体结果
/// 为 undefined 时回退**脚本 eval** 取表达式完成值，兼容无 `return` 的
/// 表达式式规则（如 `@js: result.substring(0, 10)`）。旧实现直接脚本
/// eval：顶层 `return` 是语法错误（`return not in a function`），所有
/// `@js: return ...` 规则被静默吞成空——`get_string_list` 的字符串/数组
/// 结果因此全部丢失（④ 配对实验暴露的既有缺陷，非本次引入）。
///
/// 边界：不新建独立沙箱引擎（架构改动过大）；嵌套死循环依赖外层 eval
/// 的超时约束被杀。若 `result`/`src`/`html` 原值为字面 null，恢复时会
/// 删除属性（读取从 null 变 undefined）——极端边界，可接受。
///
/// 实现：包装器返回带标签 JSON（`{"t":"n"|"s"|"a"|"o", "v":...}`），
/// Rust 侧按标签解码为 [`JsNestedValue`]；字符串化视图对非 return 语句
/// 规则与旧实现逐项等价（null/错误 → 空串、字符串原样、数组 `\n` 连接、
/// 对象 JSON 串、数字/布尔 String() 化）。
fn eval_js_nested_typed<'js>(ctx: &Ctx<'js>, content: &str, code: &str) -> JsNestedValue {
    let content_json = serde_json::to_string(content).unwrap_or_else(|_| "\"\"".to_string());
    let code_json = serde_json::to_string(code).unwrap_or_else(|_| "\"\"".to_string());
    let wrapper = format!(
        "(function () {{\n\
         var __prevResult = (typeof result === 'undefined') ? null : result;\n\
         var __prevSrc = (typeof src === 'undefined') ? null : src;\n\
         var __prevHtml = (typeof html === 'undefined') ? null : html;\n\
         globalThis.result = {content_json};\n\
         globalThis.src = {content_json};\n\
         globalThis.html = {content_json};\n\
         var __r;\n\
         try {{\n\
         __r = new Function('__legadoCode', 'var __v = (new Function(__legadoCode))(); if (__v !== undefined) {{ return __v; }} return eval(__legadoCode);')({code_json});\n\
         }} catch (e) {{\n\
         return JSON.stringify({{ t: 'n' }});\n\
         }} finally {{\n\
         if (__prevResult === null) {{ delete globalThis.result; }} else {{ globalThis.result = __prevResult; }}\n\
         if (__prevSrc === null) {{ delete globalThis.src; }} else {{ globalThis.src = __prevSrc; }}\n\
         if (__prevHtml === null) {{ delete globalThis.html; }} else {{ globalThis.html = __prevHtml; }}\n\
         }}\n\
         if (__r === undefined || __r === null) {{ return JSON.stringify({{ t: 'n' }}); }}\n\
         if (typeof __r === 'string') {{ return JSON.stringify({{ t: 's', v: __r }}); }}\n\
         if (Array.isArray(__r)) {{\n\
         return JSON.stringify({{ t: 'a', v: __r.map(function (x) {{\n\
         if (x === null || x === undefined) {{ return ''; }}\n\
         return (typeof x === 'object') ? JSON.stringify(x) : String(x);\n\
         }}) }});\n\
         }}\n\
         if (typeof __r === 'object') {{\n\
         var __s;\n\
         try {{ __s = JSON.stringify(__r); }} catch (e) {{ __s = String(__r); }}\n\
         return JSON.stringify({{ t: 'o', v: __s }});\n\
         }}\n\
         return JSON.stringify({{ t: 'o', v: String(__r) }});\n\
         }})()"
    );
    let out = ctx.eval::<String, _>(wrapper.as_str()).unwrap_or_default();
    let parsed: serde_json::Value = serde_json::from_str(&out).unwrap_or(serde_json::Value::Null);
    match parsed.get("t").and_then(|t| t.as_str()) {
        Some("s") => JsNestedValue::String(
            parsed
                .get("v")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
        ),
        Some("a") => JsNestedValue::Array(
            parsed
                .get("v")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .map(|item| match item {
                            serde_json::Value::String(s) => s.clone(),
                            other => other.to_string(),
                        })
                        .collect()
                })
                .unwrap_or_default(),
        ),
        Some("o") => JsNestedValue::Scalar(
            parsed
                .get("v")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string(),
        ),
        _ => JsNestedValue::Null,
    }
}

/// 字符串化视图（[`get_string`]/[`get_strings`]/[`get_element`] 等既有路径）
fn eval_js_nested<'js>(ctx: &Ctx<'js>, content: &str, code: &str) -> String {
    match eval_js_nested_typed(ctx, content, code) {
        JsNestedValue::Null => String::new(),
        JsNestedValue::String(s) | JsNestedValue::Scalar(s) => s,
        JsNestedValue::Array(elems) => elems.join("\n"),
    }
}

/// 按分派结果执行规则（字符串族：`get_string`/`get_strings`/`get_element` 共用）
///
/// - CSS：既有 `resolve_get_strings`（行为不变，大量书源依赖）
/// - JSON：`JsonPathParser`（非 JSON 内容解析失败 → 空，不 panic/不报错）
/// - XPath：`XPathParser`（解析失败 → 空）
/// - Regex：多级 `&&` 链（对齐上游 regex_extract）
/// - JS/WebJs：嵌套求值；结果为 JSON 数组时展开为多元素
///   （对齐上游 `expand_js_json_array_result` 的展开语义，省略模板残留过滤）
fn resolve_dispatched_strings<'js>(ctx: &Ctx<'js>, content: &str, rule: &str) -> Vec<String> {
    match dispatch_rule(rule, content) {
        RuleDispatch::Css(selector) => resolve_get_strings(content, &selector),
        RuleDispatch::Json(path) => JsonPathParser::new()
            .parse_jsonpath(content, &path)
            .unwrap_or_default(),
        RuleDispatch::Xpath(expr) => XPathParser::new()
            .parse_xpath(content, &expr)
            .unwrap_or_default(),
        RuleDispatch::Regex(pattern) => regex_extract(content, &pattern),
        RuleDispatch::Js(code) | RuleDispatch::WebJs(code) => {
            let out = eval_js_nested(ctx, content, &code);
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&out) {
                if let Some(arr) = v.as_array() {
                    return arr
                        .iter()
                        .map(|item| match item {
                            serde_json::Value::String(s) => s.clone(),
                            other => other.to_string(),
                        })
                        .collect();
                }
            }
            if out.is_empty() {
                Vec::new()
            } else {
                vec![out]
            }
        }
    }
}

/// 构建带 html()/text()/attr()/toString()/select() 方法的元素 JS 对象
///
/// `select(sub)` 返回 Elements 面集合对象（作用域 = 本元素 outerHTML
/// 快照，委托 `jsoup_text_n/jsoup_html_n/jsoup_attr_n/jsoup_size`）——
/// 久久漫画混淆体 `els[i].select('a').text()`（此前元素对象无 select
/// 方法，抛 `not a function`，整条 bookList 规则失败）。
fn build_element_object<'js>(
    ctx: &Ctx<'js>,
    snap: &ElementSnapshot,
) -> Result<rquickjs::Object<'js>, LegadoError> {
    let obj =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // toString() → outerHTML
    let outer_clone = snap.outer.clone();
    obj.set(
        "toString",
        rquickjs::Function::new(ctx.clone(), move || outer_clone.clone())
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // html() → innerHTML
    let inner_clone = snap.inner.clone();
    obj.set(
        "html",
        rquickjs::Function::new(ctx.clone(), move || inner_clone.clone())
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // text() → 纯文本
    let text_clone = snap.text.clone();
    obj.set(
        "text",
        rquickjs::Function::new(ctx.clone(), move || text_clone.clone())
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // attr(name) → 属性值（对齐 JSoup Element.attr）
    let outer_snap = snap.outer.clone();
    obj.set(
        "attr",
        rquickjs::Function::new(ctx.clone(), move |name: String| -> Option<String> {
            ElementSnapshot::from_outer(outer_snap.clone()).attr(&name)
        })
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    // select(sub) → Elements 面集合对象（作用域 = 本元素 outerHTML 快照，
    // 与 JSOUP_BRIDGE_JS `__element.select` 委托语义一致）
    let outer_sel = snap.outer.clone();
    obj.set(
        "select",
        rquickjs::Function::new(
            ctx.clone(),
            move |ctx: Ctx<'js>, sub: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                build_elements_collection(&ctx, outer_sel.clone(), sub.trim_start().to_string())
                    .map_err(js_err)
            },
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

    Ok(obj)
}

/// 宿主错误 → QuickJS 错误（宿主桥 fallible 闭包统一映射，
/// 对齐 asymmetric_crypto `js_err` 形态）
fn js_err(e: LegadoError) -> rquickjs::Error {
    rquickjs::Error::FromJs {
        from: "String",
        to: "HtmlParse",
        message: Some(e.to_string()),
    }
}

/// 第 i 个匹配元素的元素对象（越界 → 空元素对象：取值全空串，对齐
/// JSOUP_BRIDGE_JS `__set` 空集合 `get/first` 宽松语义）
fn element_object_at<'js>(
    ctx: &Ctx<'js>,
    scope_html: &str,
    css: &str,
    i: i64,
) -> Result<rquickjs::Object<'js>, LegadoError> {
    let snaps = snapshots_from_html(scope_html, css);
    let snap = match snaps.get(i.max(0) as usize) {
        Some(s) => s,
        None => &ElementSnapshot {
            outer: String::new(),
            inner: String::new(),
            text: String::new(),
        },
    };
    build_element_object(ctx, snap)
}

/// 选择器链拼接（对齐 `__set.select`：`c ? c + ' ' + sub : sub`，
/// 结果去前导空白）
fn join_css_chain(c: &str, sub: &str) -> String {
    let mut next = if c.is_empty() {
        String::new()
    } else {
        format!("{c} ")
    };
    next.push_str(sub);
    next.trim_start().to_string()
}

/// 构建 Elements 面集合 JS 对象（元素对象 `select(sub)` 返回值）
///
/// 作用域为 `scope_html`（元素 outerHTML 快照或父级 HTML），`css` 为选择器
/// 链（可为空）。各方法委托既有 `jsoup_text_n/jsoup_html_n/jsoup_attr_n/
/// jsoup_size`（与 `java.jsoup*` 宿主桥同一计算路径），面与
/// JSOUP_BRIDGE_JS `__set` 对齐并补：
/// - **数字下标键**（"0"/"1"/… → 元素对象，上游 Java List 下标语义）；
/// - **`length` 属性**（久久漫画混淆体 `_0x139d2['length']` 直读；与
///   `size()` 并存，两者缺一不可）。
fn build_elements_collection<'js>(
    ctx: &Ctx<'js>,
    scope_html: String,
    css: String,
) -> Result<rquickjs::Object<'js>, LegadoError> {
    let obj =
        rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    let snaps = snapshots_from_html(&scope_html, &css);
    let n = snaps.len() as u32;

    // text() → 首匹配语义（对齐 __set 的 attr/text/html 三方法）
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "text",
            rquickjs::Function::new(ctx.clone(), move || jsoup_text_n(&s, &c, 0))
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // html() → 首匹配元素 innerHTML
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "html",
            rquickjs::Function::new(ctx.clone(), move || jsoup_html_n(&s, &c, 0))
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // attr(name) → 首匹配元素属性
    {
        let s = scope_html.clone();
        let c = css.clone();
        obj.set(
            "attr",
            rquickjs::Function::new(ctx.clone(), move |name: String| {
                jsoup_attr_n(&s, &c, 0, &name)
            })
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // size()/isEmpty()/length 属性（length 为久久混淆体直读面）
    obj.set("size", rquickjs::Function::new(ctx.clone(), move || n))
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    obj.set(
        "isEmpty",
        rquickjs::Function::new(ctx.clone(), move || n == 0),
    )
    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    obj.set("length", n)
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    // toString() → 首匹配元素 innerHTML（对齐 __set）
    {
        let s = scope_html.clone();
        let c = css.clone();
        obj.set(
            "toString",
            rquickjs::Function::new(ctx.clone(), move || jsoup_html_n(&s, &c, 0))
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // first()/last()/get(i) → 元素对象（越界 → 空元素对象）
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "first",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>| -> rquickjs::Result<rquickjs::Object<'js>> {
                    element_object_at(&ctx, &s, &c, 0).map_err(js_err)
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "last",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>| -> rquickjs::Result<rquickjs::Object<'js>> {
                    element_object_at(&ctx, &s, &c, (n.saturating_sub(1)) as i64).map_err(js_err)
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "get",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>, i: i64| -> rquickjs::Result<rquickjs::Object<'js>> {
                    element_object_at(&ctx, &s, &c, i).map_err(js_err)
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // toArray() → 元素对象数组（对齐 __set）
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "toArray",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>| -> rquickjs::Result<rquickjs::Array<'js>> {
                    let arr = rquickjs::Array::new(ctx.clone())?;
                    for i in 0..n {
                        let el = element_object_at(&ctx, &s, &c, i as i64).map_err(js_err)?;
                        arr.set(i as usize, el)?;
                    }
                    Ok(arr)
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // each(fn) → 逐元素回调（对齐 __set：fn(element, index)）
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "each",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>, cb: rquickjs::Function<'js>| -> rquickjs::Result<()> {
                    for i in 0..n {
                        let el = element_object_at(&ctx, &s, &c, i as i64).map_err(js_err)?;
                        // 显式标注结果类型：Function::call 的 R 泛型不可推断
                        // （never_type_fallback，2024 版将变硬错误）
                        let _v: rquickjs::Value<'js> = cb.call((el, i as i32))?;
                    }
                    Ok(())
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // select(sub) → 嵌套集合（选择器链续接，对齐 __set）
    {
        let (s, c) = (scope_html.clone(), css.clone());
        obj.set(
            "select",
            rquickjs::Function::new(
                ctx.clone(),
                move |ctx: Ctx<'js>, sub: String| -> rquickjs::Result<rquickjs::Object<'js>> {
                    build_elements_collection(&ctx, s.clone(), join_css_chain(&c, &sub))
                        .map_err(js_err)
                },
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // 数字下标键 "0"/"1"/… → 元素对象（上游 Java List 下标语义，
    // 预建快照逐下标挂载，避免逐下标重复解析）
    for (i, snap) in snaps.iter().enumerate() {
        let el = build_element_object(ctx, snap)?;
        obj.set(i.to_string(), el)
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    Ok(obj)
}

/// `java.getElement(css)` → 元素对象数组（对当前 src 解析）
///
/// 51漫画等脚本 `Array.from(java.getElement("script"))` 迭代后
/// 用 `String(e)`（outerHTML）与 `e.html()`（innerHTML）筛选/解析。
///
/// `@` 段按原版 `AnalyzeByJSoup.getElements` 做链式元素选择
/// （包子漫画正文 `class.comic-contain@amp-img`）。
///
/// 规则类型分派（P2-6(e)）：CSS 规则走链式元素选择（既有行为不变）；
/// JSON/XPath/Regex/JS 规则经 [`resolve_dispatched_strings`] 取值，
/// 每个结果字符串构建元素对象（`toString()` 返回原始值，对齐上游
/// getElements 返回元素字符串列表的语义）。
pub fn get_element<'js>(
    ctx: &Ctx<'js>,
    css: String,
    src: String,
) -> Result<rquickjs::Array<'js>, LegadoError> {
    let outs = match dispatch_rule(&css, &src) {
        RuleDispatch::Css(selector) => resolve_element_chain(&src, &selector),
        _ => resolve_dispatched_strings(ctx, &src, &css),
    };
    let arr =
        rquickjs::Array::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    for (idx, outer) in outs.iter().enumerate() {
        let snap = ElementSnapshot::from_outer(outer.clone());
        let obj = build_element_object(ctx, &snap)?;
        arr.set(idx, obj)
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    }
    // 久久漫画混淆体：`els['length']`（原生数组属性）+ `els.size()`（上游
    // Elements 面）——数组对象补挂 size 方法（rquickjs::Array 无原生
    // size 方法；length 为原生属性，两者并存）
    let total = outs.len();
    // rquickjs::Array 自身 set 仅接受 usize 下标，挂字符串键需经 as_object
    arr.as_object()
        .set(
            "size",
            rquickjs::Function::new(ctx.clone(), move || total)
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
        )
        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    Ok(arr)
}

/// `java.getElements(css)` → 同 getElement（元素数组）
pub fn get_elements<'js>(
    ctx: &Ctx<'js>,
    css: String,
    src: String,
) -> Result<rquickjs::Array<'js>, LegadoError> {
    get_element(ctx, css, src)
}

/// `java.jsoupAttr(html, css, attr)` → 首个匹配元素的属性（对齐 Jsoup Elements.attr）
pub fn jsoup_attr(html: &str, css: &str, attr: &str) -> String {
    snapshots_from_html(html, css)
        .first()
        .and_then(|s| s.attr(attr))
        .unwrap_or_default()
}

/// `java.jsoupText(html, css)` → 首个匹配元素文本
pub fn jsoup_text(html: &str, css: &str) -> String {
    snapshots_from_html(html, css)
        .first()
        .map(|s| s.text.clone())
        .unwrap_or_default()
}

/// `java.jsoupHtml(html, css)` → 首个匹配元素 innerHTML
pub fn jsoup_html(html: &str, css: &str) -> String {
    snapshots_from_html(html, css)
        .first()
        .map(|s| s.inner.clone())
        .unwrap_or_default()
}

/// `java.jsoupSize(html, css)` → 匹配元素数量
///
/// 对齐 `org.jsoup.select.Elements#size`（77读书等书源搜索规则
/// `doc.select('tr')` 后按 `rows.size()` / `rows.get(i)` 遍历表格行；
/// 此前 JSOUP_BRIDGE_JS 的 Elements 模拟层无集合 API，`rows.size()`
/// 抛 `not a function`，整条搜索规则失败）。
pub fn jsoup_size(html: &str, css: &str) -> u32 {
    select_outer_htmls(html, css).len() as u32
}

/// `java.jsoupAttrN(html, css, i, attr)` → 第 i 个匹配元素的属性
///
/// `i` 为 i64（JS 侧可能传负数，负数按 0 处理）；越界 → 空串
/// （宽松偏离 JDK `List.get` 抛 IndexOutOfBounds：书源侧普遍先
/// `size()` 守卫，宿主侧取空串避免整条规则因个别越界中断）。
pub fn jsoup_attr_n(html: &str, css: &str, i: i64, attr: &str) -> String {
    snapshots_from_html(html, css)
        .get(i.max(0) as usize)
        .and_then(|s| s.attr(attr))
        .unwrap_or_default()
}

/// `java.jsoupTextN(html, css, i)` → 第 i 个匹配元素文本（越界 → 空串）
pub fn jsoup_text_n(html: &str, css: &str, i: i64) -> String {
    snapshots_from_html(html, css)
        .get(i.max(0) as usize)
        .map(|s| s.text.clone())
        .unwrap_or_default()
}

/// `java.jsoupHtmlN(html, css, i)` → 第 i 个匹配元素 innerHTML（越界 → 空串）
pub fn jsoup_html_n(html: &str, css: &str, i: i64) -> String {
    snapshots_from_html(html, css)
        .get(i.max(0) as usize)
        .map(|s| s.inner.clone())
        .unwrap_or_default()
}

/// `java.jsoupHtmlNExcluded(html, css, i, excludes)` → 第 i 个元素
/// innerHTML 并移除指定子元素
///
/// 对齐 `org.jsoup.Element#remove` 的移除后视图（77读书正文规则：
/// `e.select('div#content_tip').get(0).remove()` 后 `e.html()` 不得
/// 再含被移除子块）。`excludes` 为换行分隔的子选择器列表，逐个在
/// 当前 HTML 上做字符串级近似移除（匹配元素 outerHTML 快照 →
/// `replacen` 首次出现）。
///
/// 近似说明：字符串级移除无法区分「节点」与「文本中恰好出现的同形
/// 标记」（如正文文本里原样写了 `<div>x</div>` 字面量会被一并移除）；
/// 书源正文场景几乎不存在该形态，属已文档化的取舍。
pub fn jsoup_html_n_excluded(html: &str, css: &str, i: i64, excludes: &str) -> String {
    let mut out = jsoup_html_n(html, css, i);
    if out.is_empty() {
        return out;
    }
    for sub in excludes
        .split('\n')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        for matched in select_outer_htmls(&out, sub) {
            if !matched.is_empty() {
                out = out.replacen(&matched, "", 1);
            }
        }
    }
    out
}

/// jsoup 常用命名实体表（HTML4 基础集 + 全 Latin-1 重音字符 +
/// 书源正文高频排版标点；jsoup `Html4Entities`/`Html5Entities` 核心子集）
const NAMED_ENTITIES: &[(&str, &str)] = &[
    ("amp", "&"),
    ("lt", "<"),
    ("gt", ">"),
    ("quot", "\""),
    ("apos", "'"),
    ("nbsp", "\u{a0}"),
    ("iexcl", "\u{a1}"),
    ("cent", "\u{a2}"),
    ("pound", "\u{a3}"),
    ("curren", "\u{a4}"),
    ("yen", "\u{a5}"),
    ("brvbar", "\u{a6}"),
    ("sect", "\u{a7}"),
    ("uml", "\u{a8}"),
    ("copy", "\u{a9}"),
    ("laquo", "\u{ab}"),
    ("not", "\u{ac}"),
    ("shy", "\u{ad}"),
    ("reg", "\u{ae}"),
    ("macr", "\u{af}"),
    ("deg", "\u{b0}"),
    ("plusmn", "\u{b1}"),
    ("sup2", "\u{b2}"),
    ("sup3", "\u{b3}"),
    ("acute", "\u{b4}"),
    ("micro", "\u{b5}"),
    ("para", "\u{b6}"),
    ("middot", "\u{b7}"),
    ("cedil", "\u{b8}"),
    ("sup1", "\u{b9}"),
    ("ordf", "\u{aa}"),
    ("ordm", "\u{ba}"),
    ("frac14", "\u{bc}"),
    ("frac12", "\u{bd}"),
    ("frac34", "\u{be}"),
    ("iquest", "\u{bf}"),
    ("Agrave", "\u{c0}"),
    ("Aacute", "\u{c1}"),
    ("Acirc", "\u{c2}"),
    ("Atilde", "\u{c3}"),
    ("Auml", "\u{c4}"),
    ("Aring", "\u{c5}"),
    ("AElig", "\u{c6}"),
    ("Ccedil", "\u{c7}"),
    ("Egrave", "\u{c8}"),
    ("Eacute", "\u{c9}"),
    ("Ecirc", "\u{ca}"),
    ("Euml", "\u{cb}"),
    ("Igrave", "\u{cc}"),
    ("Iacute", "\u{cd}"),
    ("Icirc", "\u{ce}"),
    ("Iuml", "\u{cf}"),
    ("ETH", "\u{d0}"),
    ("Ntilde", "\u{d1}"),
    ("Ograve", "\u{d2}"),
    ("Oacute", "\u{d3}"),
    ("Ocirc", "\u{d4}"),
    ("Otilde", "\u{d5}"),
    ("Ouml", "\u{d6}"),
    ("Oslash", "\u{d8}"),
    ("Ugrave", "\u{d9}"),
    ("Uacute", "\u{da}"),
    ("Ucirc", "\u{db}"),
    ("Uuml", "\u{dc}"),
    ("Yacute", "\u{dd}"),
    ("THORN", "\u{de}"),
    ("szlig", "\u{df}"),
    ("agrave", "\u{e0}"),
    ("aacute", "\u{e1}"),
    ("acirc", "\u{e2}"),
    ("atilde", "\u{e3}"),
    ("auml", "\u{e4}"),
    ("aring", "\u{e5}"),
    ("aelig", "\u{e6}"),
    ("ccedil", "\u{e7}"),
    ("egrave", "\u{e8}"),
    ("eacute", "\u{e9}"),
    ("ecirc", "\u{ea}"),
    ("euml", "\u{eb}"),
    ("igrave", "\u{ec}"),
    ("iacute", "\u{ed}"),
    ("icirc", "\u{ee}"),
    ("iuml", "\u{ef}"),
    ("eth", "\u{f0}"),
    ("ntilde", "\u{f1}"),
    ("ograve", "\u{f2}"),
    ("oacute", "\u{f3}"),
    ("ocirc", "\u{f4}"),
    ("otilde", "\u{f5}"),
    ("ouml", "\u{f6}"),
    ("oslash", "\u{f8}"),
    ("ugrave", "\u{f9}"),
    ("uacute", "\u{fa}"),
    ("ucirc", "\u{fb}"),
    ("uuml", "\u{fc}"),
    ("yacute", "\u{fd}"),
    ("thorn", "\u{fe}"),
    ("yuml", "\u{ff}"),
    ("ndash", "\u{2013}"),
    ("mdash", "\u{2014}"),
    ("lsquo", "\u{2018}"),
    ("rsquo", "\u{2019}"),
    ("sbquo", "\u{201a}"),
    ("ldquo", "\u{201c}"),
    ("rdquo", "\u{201d}"),
    ("bdquo", "\u{201e}"),
    ("dagger", "\u{2020}"),
    ("Dagger", "\u{2021}"),
    ("bull", "\u{2022}"),
    ("hellip", "\u{2026}"),
    ("permil", "\u{2030}"),
    ("prime", "\u{2032}"),
    ("Prime", "\u{2033}"),
    ("lsaquo", "\u{2039}"),
    ("rsaquo", "\u{203a}"),
    ("oline", "\u{203e}"),
    ("euro", "\u{20ac}"),
    ("trade", "\u{2122}"),
    ("larr", "\u{2190}"),
    ("uarr", "\u{2191}"),
    ("rarr", "\u{2192}"),
    ("darr", "\u{2193}"),
];

/// `java.jsoupUnescapeEntities(s)` → 反转义 HTML 实体
///
/// 对齐 `org.jsoup.parser.Parser#unescapeEntities(s, base)` 的常用面
/// （77读书正文规则 `Parser.unescapeEntities(htm, true)`，`base` 参数
/// 宿主侧忽略——书源仅传 HTML base，不传 XML base）：
/// - `#ddd` 十进制 / `#xhh` 十六进制数字实体 → 对应字符，非法码点原样保留；
/// - 命名实体查 [`NAMED_ENTITIES`] 内置表；
/// - 未知命名实体 / 无 `;` 终止的片段 → 原样保留（对齐 jsoup 不改写
///   未知实体的行为，非静默丢弃）。
pub fn jsoup_unescape_entities(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] != '&' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        // 12 字符窗口内找 `;` 终止（对齐 jsoup Parser 的实体长度上限）
        let mut end: Option<usize> = None;
        let mut j = i + 1;
        while j < chars.len() && j - i <= 12 {
            if chars[j] == ';' {
                end = Some(j);
                break;
            }
            if chars[j].is_ascii_alphanumeric() || chars[j] == '#' {
                j += 1;
            } else {
                break;
            }
        }
        let Some(e_end) = end else {
            out.push('&');
            i += 1;
            continue;
        };
        let entity: String = chars[(i + 1)..e_end].iter().collect();
        let replacement = if let Some(hex) = entity
            .strip_prefix("#x")
            .or_else(|| entity.strip_prefix("#X"))
        {
            u32::from_str_radix(hex, 16)
                .ok()
                .and_then(std::char::from_u32)
                .map(|c| c.to_string())
        } else if let Some(dec) = entity.strip_prefix('#') {
            dec.parse::<u32>()
                .ok()
                .and_then(std::char::from_u32)
                .map(|c| c.to_string())
        } else {
            NAMED_ENTITIES
                .iter()
                .find(|(name, _)| **name == entity)
                .map(|(_, rep)| rep.to_string())
        };
        match replacement {
            Some(r) => out.push_str(&r),
            None => out.push_str(&chars[i..=e_end].iter().collect::<String>()),
        }
        i = e_end + 1;
    }
    out
}

/// `java.getString(rule, mContent)` → 多值换行连接（mContent 空=当前 src）
///
/// 规则类型分派（P2-6(e)，对齐上游 `AnalyzeRule.getString`）：
/// `$.`/`$[`/`@json:` → JSONPath；`//`/`@xpath:` → XPath；
/// `@regex:`/`@regexp:`/形态正则 → Regex；`@js:`/`@webjs:` → 嵌套 JS；
/// 无前缀按内容类型自动识别（JSON→JsonPath、XML→XPath，默认 CSS）。
/// CSS 分支保留既有 [`resolve_get_strings`]：`selector@…` 链（如
/// `.btn-read@href` 取属性、`class.foo@html` 取 outerHTML）行为不变。
pub fn get_string<'js>(
    ctx: &Ctx<'js>,
    rule: String,
    m_content: Opt<String>,
    src: String,
) -> String {
    let content = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    resolve_dispatched_strings(ctx, &content, &rule).join("\n")
}

/// `java.getStrings(rule, mContent)` → 文本/属性列表（换行连接）
///
/// 分派语义同 [`get_string`]（同族对齐：此前同缺 JSONPath 分派）。
pub fn get_strings<'js>(
    ctx: &Ctx<'js>,
    rule: String,
    m_content: Opt<String>,
    src: String,
) -> String {
    get_string(ctx, rule, m_content, src)
}

/// `java.getStringList(rule, mContent)` → 多值列表（不连接，可空）
///
/// P2-11 ④（§196）对齐上游 `AnalyzeRule.kt:202-293` getStringList 的
/// null 语义（JS 宿主面即 `java.getStringList` 走此路径）：
/// - L203 `rule.isNullOrEmpty()` → null（宿主面：空规则 → None；JS
///   绑定为 String 型，仅空串分支可达，null/undefined 规则不可达）
/// - L275 `result == null` → null：JS 求值错误 / 结果 null|undefined → None
/// - L276-278 `result is String` → `result.split("\n")`：JS 字符串结果
///   按 `\n` 拆分（Kotlin split 保留尾部空段：`"a\nb\n"` → `["a","b",""]`、
///   `""` → `[""]`）
/// - L292 `result as? List<String>`：JS 数字/布尔/对象结果非 List → None
/// - JS 原生数组 / JSON 数组字符串：保留 P2-6(e) 展开语义（上游 WebJs
///   L253-254 `GSON.fromJsonArray(...).getOrNull()`），元素逐个保留
///   （元素内含 `\n` 不被拆分）
/// - CSS/JSONPath/XPath/Regex：结果本身即 List（上游 L257-259），不做
///   `\n` 拆分；零命中 → 空列表（非 null，上游 `AnalyzeByJSoup.kt:76`
///   空规则/零命中均返回空 List）
pub fn get_string_list<'js>(
    ctx: &Ctx<'js>,
    rule: String,
    m_content: Opt<String>,
    src: String,
) -> Option<Vec<String>> {
    if rule.is_empty() {
        return None; // 上游 L203 isNullOrEmpty → null（不 trim，对齐 isNullOrEmpty）
    }
    let content = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    match dispatch_rule(&rule, &content) {
        RuleDispatch::Js(code) | RuleDispatch::WebJs(code) => {
            match eval_js_nested_typed(ctx, &content, &code) {
                // L275：结果 null（错误 / null / undefined）→ null
                JsNestedValue::Null => None,
                // L276-278：字符串结果按 \n 拆分；JSON 数组字符串先走
                // P2-6(e) 展开（元素逐个保留，非数组串才 \n 拆分）
                JsNestedValue::String(s) => {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&s) {
                        if let Some(arr) = v.as_array() {
                            return Some(
                                arr.iter()
                                    .map(|item| match item {
                                        serde_json::Value::String(x) => x.clone(),
                                        other => other.to_string(),
                                    })
                                    .collect(),
                            );
                        }
                    }
                    Some(s.split('\n').map(String::from).collect())
                }
                // P2-6(e)：JS 原生数组逐元素保留
                JsNestedValue::Array(items) => Some(items),
                // L292：数字/布尔/对象非 List → null
                JsNestedValue::Scalar(_) => None,
            }
        }
        // List 结果（上游 L257-259）：不做 \n 拆分，零命中 → 空列表
        _ => Some(resolve_dispatched_strings(ctx, &content, &rule)),
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 纯 rquickjs 上下文（CSS/JSON/XPath/Regex 分支不依赖沙箱注册的全局桥）
    fn bare_ctx() -> (rquickjs::Runtime, rquickjs::Context) {
        let runtime = rquickjs::Runtime::new().unwrap();
        let context = rquickjs::Context::full(&runtime).unwrap();
        (runtime, context)
    }

    #[test]
    fn test_select_outer_htmls_css() {
        let html = r#"<html><body><script>var a = '目录';</script><a class="btn-read" href="/comic/1">阅读</a></body></html>"#;
        let scripts = select_outer_htmls(html, "script");
        assert_eq!(scripts.len(), 1);
        assert!(scripts[0].contains("目录"));

        let btns = select_outer_htmls(html, ".btn-read");
        assert_eq!(btns.len(), 1);
        let snap = ElementSnapshot::from_outer(btns[0].clone());
        assert_eq!(snap.attr("href").as_deref(), Some("/comic/1"));
        assert_eq!(snap.text, "阅读");
    }

    #[test]
    fn test_select_empty_and_invalid() {
        // [艾格修正 | 2026-09-26] 空 css = 元素自身（恒等选择，非空 html 返回
        // 自身单元素）；非法选择器仍返回空集
        assert_eq!(
            select_outer_htmls("<html></html>", ""),
            vec!["<html></html>".to_string()]
        );
        assert!(select_outer_htmls("", "").is_empty());
        assert!(select_outer_htmls("<html></html>", "!!invalid!!").is_empty());
    }

    #[test]
    fn test_get_string_with_content() {
        let (_runtime, context) = bare_ctx();
        let html = r#"<div class="btn-read"><a href="/c/1">开始阅读</a></div>"#;
        let s = context
            .with(|ctx| get_string(&ctx, ".btn-read".to_string(), Opt(None), html.to_string()));
        assert_eq!(s, "开始阅读");
        // 第二参覆盖当前 src
        let s2 = context.with(|ctx| {
            get_string(
                &ctx,
                ".btn-read".to_string(),
                Opt(Some("<div class=\"btn-read\">X</div>".into())),
                String::new(),
            )
        });
        assert_eq!(s2, "X");
        // @attr 链：取 a 的 href 属性（对齐 51漫画 java.getString(".btn-read@href", src)）
        let s3 =
            context.with(|ctx| get_string(&ctx, "a@href".to_string(), Opt(None), html.to_string()));
        assert_eq!(s3, "/c/1");
    }

    /// P2-9 ①：`java.getStringList` 底层——多值列表（不连接，区别于 get_string）
    /// P2-11 ④：返回值改 `Option`（JS 分支 null 语义；List 分支恒 Some）
    #[test]
    fn test_get_string_list_unjoined_multi_values() {
        let (_runtime, context) = bare_ctx();
        let json = r#"{"list": ["a", "b", "c"]}"#;
        // JSONPath 多值 → 逐项保留（上游 AnalyzeByJSoup.getStringList 语义）
        let v = context.with(|ctx| {
            get_string_list(&ctx, "$.list[*]".to_string(), Opt(None), json.to_string())
        });
        assert_eq!(
            v,
            Some(vec!["a".to_string(), "b".to_string(), "c".to_string()])
        );
        // 第二参覆盖当前 src
        let v2 = context.with(|ctx| {
            get_string_list(
                &ctx,
                "$.list[*]".to_string(),
                Opt(Some(json.to_string())),
                String::new(),
            )
        });
        assert_eq!(
            v2,
            Some(vec!["a".to_string(), "b".to_string(), "c".to_string()])
        );
        // CSS 多值 → 逐项保留（不 join）
        let html = r#"<div><a class="x" href="/1">一</a><a class="x" href="/2">二</a></div>"#;
        let v3 = context
            .with(|ctx| get_string_list(&ctx, "a.x@href".to_string(), Opt(None), html.to_string()));
        assert_eq!(v3, Some(vec!["/1".to_string(), "/2".to_string()]));
        // 零命中 → Some(空列表)（非 null，上游 L259 List 结果）
        let v4 = context.with(|ctx| {
            get_string_list(&ctx, "a.miss@href".to_string(), Opt(None), html.to_string())
        });
        assert_eq!(v4, Some(Vec::new()));
    }

    /// P2-11 ④（§196）：`get_string_list` null 语义 + `\n` 拆分
    ///
    /// 配对实验（上游依据 `AnalyzeRule.kt:202-293`；旧实现 → 新实现）：
    /// - 空规则：旧 `[]` → 新 `None`（L203 `rule.isNullOrEmpty()` → null）
    /// - `@js: return null`：旧 `[]` → 新 `None`（L275 `result == null`）
    /// - `@js: return 42`：旧 `["42"]` → 新 `None`（L292 `42 as? List` → null）
    /// - `@js: return "a\nb\n"`：旧 `["a\nb\n"]`（单元素含换行）→ 新
    ///   `["a","b",""]`（L276-278 `result.split("\n")` 保留尾部空段）
    /// - `@js: return ""`：旧 `[]` → 新 `[""]`（Kotlin `"".split("\n")` → `[""]`）
    /// - `@js: return ["a\nb","c"]`：旧 `["a\nb\nc"]`（join 后单元素）→ 新
    ///   `["a\nb","c"]`（P2-6(e) 展开逐元素保留，元素内 `\n` 不拆分）
    /// - CSS 零命中：`Some([])`（List 分支零命中非 null，行为不变）
    #[test]
    fn test_get_string_list_null_semantics_and_newline_split() {
        let (_runtime, context) = bare_ctx();
        // L203：空规则 → None（isNullOrEmpty → null，不 trim）
        let empty_rule =
            context.with(|ctx| get_string_list(&ctx, String::new(), Opt(None), "x".to_string()));
        assert_eq!(empty_rule, None);
        // L275：JS 结果 null / 求值错误 → None
        let js_null = context
            .with(|ctx| get_string_list(&ctx, "@js: return null".into(), Opt(None), "x".into()));
        assert_eq!(js_null, None);
        let js_err = context.with(|ctx| {
            get_string_list(&ctx, "@js: return missingVar".into(), Opt(None), "x".into())
        });
        assert_eq!(js_err, None);
        // L292：JS 数字/布尔/对象结果非 List → None
        let js_num = context
            .with(|ctx| get_string_list(&ctx, "@js: return 42".into(), Opt(None), "x".into()));
        assert_eq!(js_num, None);
        let js_obj = context
            .with(|ctx| get_string_list(&ctx, "@js: return {a:1}".into(), Opt(None), "x".into()));
        assert_eq!(js_obj, None);
        // L276-278：JS 字符串结果按 \n 拆分（保留尾部空段）
        let split = context.with(|ctx| {
            get_string_list(&ctx, "@js: return 'a\\nb\\n'".into(), Opt(None), "x".into())
        });
        assert_eq!(split, Some(vec!["a".into(), "b".into(), String::new()]));
        // "" → [""]（Kotlin "".split("\n") → [""]）
        let empty_str = context
            .with(|ctx| get_string_list(&ctx, "@js: return ''".into(), Opt(None), "x".into()));
        assert_eq!(empty_str, Some(vec![String::new()]));
        // P2-6(e)：JS 原生数组逐元素保留（元素内 \n 不拆分）
        let js_arr = context.with(|ctx| {
            get_string_list(
                &ctx,
                "@js: return ['a\\nb','c']".into(),
                Opt(None),
                "x".into(),
            )
        });
        assert_eq!(js_arr, Some(vec!["a\nb".into(), "c".into()]));
        // P2-6(e)：JSON 数组字符串展开（上游 WebJs L253-254 GSON.fromJsonArray）保持
        let json_arr = context.with(|ctx| {
            get_string_list(
                &ctx,
                "@js: return JSON.stringify(['p','q'])".into(),
                Opt(None),
                "x".into(),
            )
        });
        assert_eq!(json_arr, Some(vec!["p".into(), "q".into()]));
        // CSS 零命中 → Some(空列表)（上游 L259 List 结果，零命中非 null）
        let html = r#"<div><a class="x" href="/1">一</a></div>"#;
        let zero = context
            .with(|ctx| get_string_list(&ctx, "a.miss@href".into(), Opt(None), html.to_string()));
        assert_eq!(zero, Some(Vec::new()));
    }

    /// 包子漫画正文：`java.getElements('class.comic-contain@amp-img')`
    /// —— jsoup 前缀归一化 + `@` 段链式元素选择（此前 class. 前缀原样进 CSS
    /// 解析器 → 0 命中，正文「Content empty」）
    #[test]
    fn test_element_chain_jsoup_prefix() {
        let html = r#"<html><body>
            <div class="comic-contain">
                <amp-img src="x" data-src="/img/1.jpg"></amp-img>
                <amp-img src="x" data-src="/img/2.jpg"></amp-img>
            </div>
            <div class="other"><amp-img data-src="/img/3.jpg"></amp-img></div>
        </body></html>"#;
        let outs = resolve_element_chain(html, "class.comic-contain@amp-img");
        assert_eq!(outs.len(), 2);
        assert!(outs[0].contains("data-src=\"/img/1.jpg\""));
        // 链式：只在 .comic-contain 内选，.other 里的 amp-img 不入选
        assert!(!outs.iter().any(|o| o.contains("/img/3.jpg")));

        // get_element 走同一链路；元素对象 attr() 是包子正文 JS 的实际取图路径
        let runtime = rquickjs::Runtime::new().unwrap();
        let context = rquickjs::Context::full(&runtime).unwrap();
        let attr_val: String = context
            .with(|ctx| -> Result<String, LegadoError> {
                let arr = get_element(&ctx, "class.comic-contain@amp-img".into(), html.into())?;
                assert_eq!(arr.len(), 2);
                // 元素对象 attr('data-src')——包子正文 JS 的实际取图路径
                let to_err = |e: rquickjs::Error| LegadoError::JsEngine(e.to_string());
                let elem: rquickjs::Object = arr.get::<rquickjs::Object>(0).map_err(to_err)?;
                let attr_fn: rquickjs::Function =
                    elem.get::<_, rquickjs::Function>("attr").map_err(to_err)?;
                let s: String = attr_fn.call(("data-src",)).map_err(to_err)?;
                Ok(s)
            })
            .unwrap();
        assert_eq!(attr_val, "/img/1.jpg");
    }

    /// jsoup 前缀归一化：`id.iframeForVideo@src`（艾格动漫）、
    /// `class.text-content@html`（单本阅读 @html 模式取 outerHTML）
    #[test]
    fn test_get_string_jsoup_prefix_and_html_mode() {
        let (_runtime, context) = bare_ctx();
        let html = r#"<html><body>
            <iframe id="iframeForVideo" src="/v/1.mp4"></iframe>
            <div class="text-content"><p>正文段落</p></div>
        </body></html>"#;
        // id. 前缀 → #id，@src 取属性
        let s = context.with(|ctx| {
            get_string(
                &ctx,
                "id.iframeForVideo@src".to_string(),
                Opt(None),
                html.to_string(),
            )
        });
        assert_eq!(s, "/v/1.mp4");
        // class. 前缀 + @html 模式 → outerHTML（此前 "html" 被误判为标签名
        // → 整条规则进 CSS 解析器失败 → 0 结果）
        let s2 = context.with(|ctx| {
            get_string(
                &ctx,
                "class.text-content@html".to_string(),
                Opt(None),
                html.to_string(),
            )
        });
        assert!(s2.contains("<p>正文段落</p>"));
    }

    // ─── 规则类型分派回归（台账 P2-6(e)）──────────────────────────────────────

    /// 回归 1：JSON 内容 + `$.a` → JSONPath 结果（此前 CSS 路径恒空）
    #[test]
    fn test_dispatch_json_top_level() {
        let (_rt, context) = bare_ctx();
        let json = r#"{"a":"v1","n":42,"ok":true}"#;
        let s = context.with(|ctx| get_string(&ctx, "$.a".into(), Opt(None), json.into()));
        assert_eq!(s, "v1");
        // 数值/布尔值字符串化（对齐 JsonPath value_to_string）
        let n = context.with(|ctx| get_string(&ctx, "$.n".into(), Opt(None), json.into()));
        assert_eq!(n, "42");
        let ok = context.with(|ctx| get_string(&ctx, "$.ok".into(), Opt(None), json.into()));
        assert_eq!(ok, "true");
    }

    /// 回归 2：JSON 内容 + `$.a.b` 嵌套路径
    #[test]
    fn test_dispatch_json_nested() {
        let (_rt, context) = bare_ctx();
        let json = r#"{"a":{"b":{"c":"deep"}},"list":[{"k":"x"},{"k":"y"}]}"#;
        let s = context.with(|ctx| get_string(&ctx, "$.a.b.c".into(), Opt(None), json.into()));
        assert_eq!(s, "deep");
        // 数组展平为多值（\n 连接）
        let s2 = context.with(|ctx| get_string(&ctx, "$.list[*].k".into(), Opt(None), json.into()));
        assert_eq!(s2, "x\ny");
    }

    /// 回归 3（反回归）：HTML 内容 + CSS 选择器 → 既有 CSS 路径行为不变
    #[test]
    fn test_dispatch_html_css_unchanged() {
        let (_rt, context) = bare_ctx();
        let html = r#"<html><body><div class="title">书名</div>
            <a class="btn-read" href="/c/9">阅读</a></body></html>"#;
        let s = context.with(|ctx| get_string(&ctx, ".title".into(), Opt(None), html.into()));
        assert_eq!(s, "书名");
        // CSS `@attr` 链不变
        let s2 =
            context.with(|ctx| get_string(&ctx, ".btn-read@href".into(), Opt(None), html.into()));
        assert_eq!(s2, "/c/9");
    }

    /// 回归 4：HTML（非 JSON）内容 + `$.x` → 按上游 JSONPath 无结果 → 空，
    /// 不 panic、不报错（绑定层返回 String，解析失败静默降级为空）
    #[test]
    fn test_dispatch_jsonpath_on_html_yields_empty() {
        let (_rt, context) = bare_ctx();
        let html = r#"<html><body><p>纯 HTML</p></body></html>"#;
        let s = context.with(|ctx| get_string(&ctx, "$.x".into(), Opt(None), html.into()));
        assert_eq!(s, "");
        // @json: 显式前缀同样在 HTML 内容下取空
        let s2 = context.with(|ctx| get_string(&ctx, "@json:$.x".into(), Opt(None), html.into()));
        assert_eq!(s2, "");
    }

    /// 内容类型自动识别：JSON 内容 + 无前缀裸规则 → JsonPath（补 `$.`）
    #[test]
    fn test_dispatch_auto_content_json() {
        let (_rt, context) = bare_ctx();
        let json = r#"{"data":{"name":"丁丁"}}"#;
        let s = context.with(|ctx| get_string(&ctx, "data.name".into(), Opt(None), json.into()));
        assert_eq!(s, "丁丁");
    }

    /// `@json:`/`@xpath:`/`@regex:`/`@@` 前缀分支
    #[test]
    fn test_dispatch_explicit_prefixes() {
        let (_rt, context) = bare_ctx();
        let json = r#"{"x":7}"#;
        let s = context.with(|ctx| get_string(&ctx, "@json:$.x".into(), Opt(None), json.into()));
        assert_eq!(s, "7");

        // parse_xpath 对元素节点返回外层 XML（与 parser get_strings_single_step
        // Xpath 分支语义一致——绑定层只读复用，归一与既有实现保持一致）
        let xml = r#"<?xml version="1.0"?><root><item>甲</item><item>乙</item></root>"#;
        let x = context.with(|ctx| get_string(&ctx, "@xpath://item".into(), Opt(None), xml.into()));
        assert_eq!(x, "<item>甲</item>\n<item>乙</item>");
        // XML 内容 + `//` 形态规则（无前缀）同样走 XPath
        let x2 = context.with(|ctx| get_string(&ctx, "//item[2]".into(), Opt(None), xml.into()));
        assert_eq!(x2, "<item>乙</item>");

        let text = "章节 12 与 34";
        let r = context.with(|ctx| get_string(&ctx, "@regex:\\d+".into(), Opt(None), text.into()));
        assert_eq!(r, "12\n34");
        // 形态自动识别（含 \d）→ 正则
        let r2 = context.with(|ctx| get_string(&ctx, "\\d+".into(), Opt(None), text.into()));
        assert_eq!(r2, "12\n34");
        // @@ 前缀强制 CSS
        let html = r#"<div class="t">T</div>"#;
        let c = context.with(|ctx| get_string(&ctx, "@@.t".into(), Opt(None), html.into()));
        assert_eq!(c, "T");
    }

    /// `@js:` 嵌套求值：复用当前 ctx 全局环境，独立词法作用域，失败 → 空
    #[test]
    fn test_dispatch_js_nested() {
        let (_rt, context) = bare_ctx();
        let json = r#"{"a":21}"#;
        // 字符串结果原样返回
        let s = context.with(|ctx| {
            get_string(
                &ctx,
                "@js:java.getString('$'.replace('$','$')+'a') || 'nope'".into(),
                Opt(None),
                json.into(),
            )
        });
        // 无 java 桥的裸 ctx 中嵌套 @js 内再调 java.getString → ReferenceError
        // 被捕获 → 空（验证失败降级路径）
        assert_eq!(s, "");
        // 纯 JS 表达式：数值结果字符串化
        let n = context.with(|ctx| get_string(&ctx, "@js:6*7".into(), Opt(None), json.into()));
        assert_eq!(n, "42");
        // JS 返回 JSON 数组 → 展开为多元素（对齐 expand_js_json_array_result）
        let arr = context.with(|ctx| {
            get_string(
                &ctx,
                "@js:JSON.stringify([1,2,3])".into(),
                Opt(None),
                json.into(),
            )
        });
        assert_eq!(arr, "1\n2\n3");
    }

    /// getElements 同族分派：JSON 内容 + `$.` 规则 → 元素对象（toString=原始值）
    #[test]
    fn test_get_elements_dispatch_json() {
        let (_runtime, context) = bare_ctx();
        let json = r#"{"items":["a","b"]}"#;
        context
            .with(|ctx| -> Result<(), LegadoError> {
                let arr = get_element(&ctx, "$.items[*]".into(), json.into())?;
                assert_eq!(arr.len(), 2);
                let to_err = |e: rquickjs::Error| LegadoError::JsEngine(e.to_string());
                let e0: rquickjs::Object = arr.get::<rquickjs::Object>(0).map_err(to_err)?;
                let to_str: rquickjs::Function = e0
                    .get::<_, rquickjs::Function>("toString")
                    .map_err(to_err)?;
                let s0: String = to_str.call(()).map_err(to_err)?;
                let e1: rquickjs::Object = arr.get::<rquickjs::Object>(1).map_err(to_err)?;
                let to_str1: rquickjs::Function = e1
                    .get::<_, rquickjs::Function>("toString")
                    .map_err(to_err)?;
                let s1: String = to_str1.call(()).map_err(to_err)?;
                assert_eq!(s0, "a");
                assert_eq!(s1, "b");
                Ok(())
            })
            .unwrap();
    }

    /// Elements 集合 API（77读书搜索规则 `rows.size()` / `rows.get(i)`）：
    /// 表格行计数与按索引取元素（attr/text/html 三级）
    #[test]
    fn test_jsoup_elements_indexed_access() {
        let html = "<table><tr><td>列0</td><td>[玄幻]</td><td><a href=\"/novel/1\">书名A</a></td><td><a>章A</a></td><td>c4</td><td><span>作者甲</span></td><td>c6</td><td>1200K</td></tr><tr><td>列0</td><td>[都市]</td><td><a href=\"/novel/2\">书名B</a></td><td><a>章B</a></td><td>c4</td><td><span>作者乙</span></td><td>c6</td><td>88K</td></tr><tr><td>短行</td></tr></table>";
        assert_eq!(jsoup_size(html, "tr"), 3);
        assert_eq!(jsoup_size(html, "tr td"), 17);
        // 行集合内按索引取元素（text/html 三级）
        let row1 = jsoup_html_n(html, "tr", 1);
        assert!(row1.contains("书名B"));
        assert_eq!(
            jsoup_text_n(html, "tr", 0),
            "列0[玄幻]书名A章Ac4作者甲c61200K"
        );
        // 元素作用域内再选子元素（对齐 JS 桥 `rows.get(i).select('a')`：
        // 集合 scope = 元素自身 html 快照）
        let row0 = jsoup_html_n(html, "tr", 0);
        assert!(row0.contains("<td>列0</td>"));
        assert_eq!(jsoup_size(&row0, "a"), 2);
        assert_eq!(jsoup_attr_n(&row0, "a", 0, "href"), "/novel/1");
        assert_eq!(jsoup_attr_n(&row0, "a", 1, "href"), ""); // 章A 的 a 无 href → 空串
                                                             // 越界 → 空串（宽松语义）
        assert_eq!(jsoup_text_n(html, "tr", 99), "");
        assert_eq!(jsoup_attr_n(html, "tr", 99, "x"), "");
        assert_eq!(jsoup_html_n(html, "tr", 99), "");
    }

    /// `jsoup_html_n_excluded`：移除子元素后的元素视图（77读书正文
    /// `tp.get(0).remove()` 后 `e.html()` 不得再含被移除块）
    #[test]
    fn test_jsoup_html_n_excluded() {
        let html = "<div id=\"ChapterContents\"><p>正文第一段</p><div id=\"content_tip\">提示框广告</div><p>正文第二段</p><div class=\"tip2\">尾部块</div></div>";
        // 不移除：原样
        let base = jsoup_html_n(html, "div#ChapterContents", 0);
        assert!(base.contains("提示框广告"));
        // 单选择器移除
        let r1 = jsoup_html_n_excluded(html, "div#ChapterContents", 0, "div#content_tip");
        assert!(!r1.contains("提示框广告"));
        assert!(r1.contains("正文第一段") && r1.contains("正文第二段"));
        assert!(r1.contains("<div class=\"tip2\">尾部块</div>"));
        // 多选择器移除（换行分隔）
        let r2 = jsoup_html_n_excluded(html, "div#ChapterContents", 0, "div#content_tip\ndiv.tip2");
        assert!(!r2.contains("提示框广告") && !r2.contains("尾部块"));
        assert!(r2.contains("正文第一段") && r2.contains("正文第二段"));
        // 空 excludes → 等价 base
        assert_eq!(
            jsoup_html_n_excluded(html, "div#ChapterContents", 0, ""),
            base
        );
        // 越界 i → 空串
        assert_eq!(
            jsoup_html_n_excluded(html, "div#ChapterContents", 9, "div#content_tip"),
            ""
        );
    }

    /// 实体反转义：数字实体（十/十六）+ 命名实体 + 未知实体原样保留
    #[test]
    fn test_jsoup_unescape_entities() {
        // 数字实体（十进制 + 十六进制；用可见字符避免空白字面量歧义）
        assert_eq!(jsoup_unescape_entities("&#65;&#x42;"), "AB");
        assert_eq!(jsoup_unescape_entities("&#32;"), "\u{20}"); // 空格
        assert_eq!(jsoup_unescape_entities("&#27665;"), "\u{6c11}"); // 民
                                                                     // 命名实体（书源正文高频）
        assert_eq!(
            jsoup_unescape_entities("&lt;div&gt;&amp;&quot;&apos;&nbsp;"),
            "<div>&\"'\u{a0}"
        );
        assert_eq!(
            jsoup_unescape_entities("&mdash;&hellip;&ldquo;x&rdquo;"),
            "\u{2014}\u{2026}\u{201c}x\u{201d}"
        );
        // 未知命名实体 / 无分号终止 → 原样保留（非静默丢弃）
        assert_eq!(
            jsoup_unescape_entities("&bogus; &amp &xzzz1;"),
            "&bogus; &amp &xzzz1;"
        );
        // 非法数字码点（0x110000 超 u32 范围不成立；用非法代理区 0xD800）
        assert_eq!(jsoup_unescape_entities("&#55296;"), "&#55296;");
        // 普通文本原样
        assert_eq!(jsoup_unescape_entities("no entities"), "no entities");
        // 无 `;` 时只保留 `&` 本身并继续扫描
        assert_eq!(jsoup_unescape_entities("a & b"), "a & b");
    }
}
