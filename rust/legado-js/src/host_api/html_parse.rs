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
pub fn get_element<'js>(
    ctx: &Ctx<'js>,
    css: String,
    src: String,
) -> Result<rquickjs::Array<'js>, LegadoError> {
    let outs = resolve_element_chain(&src, &css);
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

/// `java.getString(css, mContent)` → 首条文本/属性（mContent 空=当前 src）
///
/// 支持 `selector@…` 链（如 `.btn-read@href` 取属性、`class.foo@html` 取
/// outerHTML），对齐原版 AnalyzeByJSoup.getStringList：`@` 段除末段外做
/// 链式元素选择，末段按 text/html/attr 提取。
pub fn get_string(css: String, m_content: Opt<String>, src: String) -> String {
    let html = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    resolve_get_strings(&html, &css).join("\n")
}

/// `java.getStrings(css, mContent)` → 文本/属性列表（换行连接）
pub fn get_strings(css: String, m_content: Opt<String>, src: String) -> String {
    let html = match m_content.0 {
        Some(s) if !s.is_empty() => s,
        _ => src,
    };
    resolve_get_strings(&html, &css).join("\n")
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
        let html = r#"<html><body>
            <iframe id="iframeForVideo" src="/v/1.mp4"></iframe>
            <div class="text-content"><p>正文段落</p></div>
        </body></html>"#;
        // id. 前缀 → #id，@src 取属性
        let s = get_string(
            "id.iframeForVideo@src".to_string(),
            Opt(None),
            html.to_string(),
        );
        assert_eq!(s, "/v/1.mp4");
        // class. 前缀 + @html 模式 → outerHTML（此前 "html" 被误判为标签名
        // → 整条规则进 CSS 解析器失败 → 0 结果）
        let s2 = get_string(
            "class.text-content@html".to_string(),
            Opt(None),
            html.to_string(),
        );
        assert!(s2.contains("<p>正文段落</p>"));
    }
}
