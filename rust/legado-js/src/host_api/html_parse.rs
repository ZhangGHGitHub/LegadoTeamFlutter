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

#![cfg(feature = "quickjs")]

use legado_core::LegadoError;
use rquickjs::function::Opt;
use rquickjs::Ctx;
use scraper::{Html, Selector};

/// CSS 选择：返回匹配元素的 outerHTML 字符串快照列表
///
/// 以 String 快照返回（脱离 scraper 文档生命周期），供 JS 元素对象使用。
fn select_outer_htmls(html: &str, css: &str) -> Vec<String> {
    if html.is_empty() || css.trim().is_empty() {
        return Vec::new();
    }
    let Ok(selector) = Selector::parse(css) else {
        return Vec::new();
    };
    let document = Html::parse_document(html);
    document.select(&selector).map(|e| e.html()).collect()
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

/// 拆分 `css@attr` 链（对齐原版 AnalyzeByJSoup `selector@attr` 语义）：
/// 末段以 `@` 开头且非 HTML 标签名 → 属性/文本提取；否则整体为 CSS 选择器
/// 如 `.btn-read@href` → (".btn-read", Some("href"))、`script` → ("script", None)
fn split_attr_chain(css: &str) -> (&str, Option<String>) {
    let trimmed = css.trim();
    if let Some(at_pos) = trimmed.rfind('@') {
        let after = &trimmed[at_pos + 1..];
        let before = trimmed[..at_pos].trim();
        // @ 后是属性名/提取模式（非标签选择器）：href/src/text/html/alt/title 等
        if !before.is_empty()
            && !after.is_empty()
            && !after.contains([' ', '.', '#', '[', '>', ','])
            && !matches!(
                after,
                "a" | "div"
                    | "span"
                    | "li"
                    | "p"
                    | "img"
                    | "script"
                    | "body"
                    | "html"
                    | "ul"
                    | "ol"
                    | "table"
                    | "tr"
                    | "td"
                    | "th"
            )
        {
            return (before, Some(after.to_string()));
        }
    }
    (trimmed, None)
}

/// CSS 选择 + 属性/文本提取：返回元素（selector 部分）outerHTML 快照列表
fn select_with_attr(html: &str, css: &str) -> Vec<ElementSnapshot> {
    let (selector, attr) = split_attr_chain(css);
    let snaps = snapshots_from_html(html, selector);
    match attr {
        // @text：取元素文本（对齐原版 getResultLast "text" 分支）
        Some(name) if name == "text" => snaps,
        // @allText/@ownText/@textNodes 等文本模式：退化为文本
        Some(name) if matches!(name.as_str(), "allText" | "ownText" | "textNodes") => snaps,
        // 其他 @ 后缀：属性提取（href/src/data-src 等，对齐原版默认分支）
        Some(name) => snaps
            .iter()
            .map(|s| ElementSnapshot {
                outer: s.outer.clone(),
                inner: s.inner.clone(),
                text: s.attr(&name).unwrap_or_else(|| s.text.clone()),
            })
            .collect(),
        None => snaps,
    }
}

/// 从 HTML 快照解析出元素对象（供 select 后的元素转换）
fn snapshots_from_html(html: &str, css: &str) -> Vec<ElementSnapshot> {
    select_outer_htmls(html, css)
        .into_iter()
        .map(ElementSnapshot::from_outer)
        .collect()
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
pub fn get_element<'js>(
    ctx: &Ctx<'js>,
    css: String,
    src: String,
) -> Result<rquickjs::Array<'js>, LegadoError> {
    let (selector, _attr) = split_attr_chain(&css);
    let snaps = snapshots_from_html(&src, selector);
    let arr =
        rquickjs::Array::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;
    for (idx, snap) in snaps.iter().enumerate() {
        let obj = build_element_object(ctx, snap)?;
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

/// `java.getString(css, mContent)` → 首条文本/属性（mContent 空=当前 src）
///
/// 支持 `selector@attr` 链（如 `.btn-read@href` 取属性，对齐原版
/// AnalyzeByJSoup）；纯 `@text` 后缀按文本处理
pub fn get_string(css: String, m_content: Opt<String>, src: String) -> String {
    let html = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    let snaps = select_with_attr(&html, &css);
    if snaps.is_empty() {
        return String::new();
    }
    snaps[0].text.clone()
}

/// `java.getStrings(css, mContent)` → 文本/属性列表（换行连接）
pub fn get_strings(css: String, m_content: Opt<String>, src: String) -> String {
    let html = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    let snaps = select_with_attr(&html, &css);
    let texts: Vec<String> = snaps
        .iter()
        .map(|s| s.text.clone())
        .filter(|t| !t.is_empty())
        .collect();
    texts.join("\n")
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

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
        let html = r#"<div class="btn-read"><a href="/c/1">开始阅读</a></div>"#;
        let s = get_string(".btn-read".to_string(), Opt(None), html.to_string());
        assert_eq!(s, "开始阅读");
        // 第二参覆盖当前 src
        let s2 = get_string(
            ".btn-read".to_string(),
            Opt(Some("<div class=\"btn-read\">X</div>".into())),
            String::new(),
        );
        assert_eq!(s2, "X");
        // @attr 链：取 a 的 href 属性（对齐 51漫画 java.getString(".btn-read@href", src)）
        let s3 = get_string("a@href".to_string(), Opt(None), html.to_string());
        assert_eq!(s3, "/c/1");
    }
}
