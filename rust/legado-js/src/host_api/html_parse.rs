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
fn select_outer_htmls(html: &str, css: &str) -> Vec<String> {
    if html.is_empty() || css.trim().is_empty() {
        return Vec::new();
    }
    let normalized = legado_parser::HtmlParser::normalize_jsoup_selector(css);
    let Ok(selector) = Selector::parse(&normalized) else {
        return Vec::new();
    };
    let document = Html::parse_document(html);
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
        // 改用 parse_document + body 内首个元素
        let doc = Html::parse_document(&outer);
        let body_sel = Selector::parse("body").ok();
        let inner = body_sel
            .as_ref()
            .and_then(|s| doc.select(s).next())
            .map(|body| body.inner_html())
            .unwrap_or_default();
        let text = body_sel
            .as_ref()
            .and_then(|s| doc.select(s).next())
            .map(|body| body.text().collect::<Vec<_>>().join(""))
            .unwrap_or_default();
        Self { outer, inner, text }
    }

    fn attr(&self, name: &str) -> Option<String> {
        let doc = Html::parse_document(&self.outer);
        let body_sel = Selector::parse("body").ok()?;
        let body = doc.select(&body_sel).next()?;
        // body 内首个元素（原 fragment 的根元素）
        let elem = body.children().find_map(scraper::ElementRef::wrap)?;
        elem.value().attr(name).map(|v| v.to_string())
    }
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

/// 嵌套 `@js:`/`@webjs:` 求值（无头近似，对齐上游 `execute_js_rule`）
///
/// 复用当前引擎全局环境（执行器 prologue 已注入 result/src/baseUrl）：
/// `new Function` 包装得独立词法作用域（与 parser 执行器同款包装，规避
/// 规则顶层 let/const 与全局 var 重声明冲突），临时把 result/src/html
/// 重绑为当前内容（覆盖 mContent ≠ src 的场景）并在 finally 恢复。
/// 执行失败/结果为 null|undefined → 空串（对齐上游 JS 规则错误吞掉 → 空）。
///
/// 边界：不新建独立沙箱引擎（架构改动过大）；嵌套死循环依赖外层 eval
/// 的超时约束被杀。若 `result`/`src`/`html` 原值为字面 null，恢复时会
/// 删除属性（读取从 null 变 undefined）——极端边界，可接受。
fn eval_js_nested<'js>(ctx: &Ctx<'js>, content: &str, code: &str) -> String {
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
         __r = new Function('__legadoCode', 'return eval(__legadoCode);')({code_json});\n\
         }} catch (e) {{\n\
         return '';\n\
         }} finally {{\n\
         if (__prevResult === null) {{ delete globalThis.result; }} else {{ globalThis.result = __prevResult; }}\n\
         if (__prevSrc === null) {{ delete globalThis.src; }} else {{ globalThis.src = __prevSrc; }}\n\
         if (__prevHtml === null) {{ delete globalThis.html; }} else {{ globalThis.html = __prevHtml; }}\n\
         }}\n\
         if (__r === undefined || __r === null) {{ return ''; }}\n\
         if (typeof __r === 'string') {{ return __r; }}\n\
         if (Array.isArray(__r)) {{\n\
         return __r.map(function (x) {{\n\
         if (x === null || x === undefined) {{ return ''; }}\n\
         return (typeof x === 'object') ? JSON.stringify(x) : String(x);\n\
         }}).join('\\n');\n\
         }}\n\
         if (typeof __r === 'object') {{\n\
         try {{ return JSON.stringify(__r); }} catch (e) {{ return String(__r); }}\n\
         }}\n\
         return String(__r);\n\
         }})()"
    );
    ctx.eval::<String, _>(wrapper.as_str()).unwrap_or_default()
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

/// 构建带 html()/text()/attr()/toString() 方法的元素 JS 对象
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
        assert!(select_outer_htmls("<html></html>", "").is_empty());
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
}
