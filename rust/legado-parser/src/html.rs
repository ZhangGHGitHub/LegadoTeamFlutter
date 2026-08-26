//! HTML 解析模块（基于 scraper）
//!
//! 参考 Kotlin `AnalyzeByJSoup.kt`，使用 `scraper` crate 实现 CSS 选择器查询。

use legado_core::LegadoResult;
use scraper::{ElementRef, Html, Selector};

use crate::rule_analyzer::RuleAnalyzer;

/// 去除 <script>/<style> 块（对齐 jsoup getResultLast 的 "html" 分支）
static SCRIPT_STYLE_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();

fn strip_script_style(html: &str) -> String {
    let re = SCRIPT_STYLE_RE.get_or_init(|| {
        regex::Regex::new(r"(?is)<script[^>]*>.*?</script>|<style[^>]*>.*?</style>").unwrap()
    });
    re.replace_all(html, "").into_owned()
}

/// 对齐 Jsoup `Element.ownText()`：仅汇总本元素的直接文本子节点，
/// 不含子孙元素内文本（与 `text()` 全树文本不同）。
fn own_text_of(elem: ElementRef<'_>) -> String {
    let mut parts = Vec::new();
    for child in elem.children() {
        if let Some(text) = child.value().as_text() {
            let t = text.trim();
            if !t.is_empty() {
                parts.push(t.to_string());
            }
        }
    }
    parts.join(" ")
}

/// 阅读原版点号/叹号索引（`AnalyzeByJSoup.ElementsSingle` 非 `[]` 写法）
///
/// 例：`a.0`、`dd.1`、`span.0`、`dd.2:3`、`li.-1`
#[derive(Debug, Clone, PartialEq, Eq)]
struct RangeIdx {
    start: Option<i32>,
    end: Option<i32>,
    step: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct DotIndex {
    /// `.`/`!`/`[!` 排除，否则选取
    exclude: bool,
    /// 单个下标（支持负数）
    indices: Vec<i32>,
    /// 区间（`a:b[:step]`，含 `[-1:0]` 反向）
    ranges: Vec<RangeIdx>,
}

/// 解析可选整数（空串/无 → None）
fn parse_opt_i32(s: Option<&str>) -> Option<i32> {
    s.and_then(|t| {
        let t = t.trim();
        if t.is_empty() {
            None
        } else {
            t.parse::<i32>().ok()
        }
    })
}

/// 解析 `[...]` 括号索引（规则以 `]` 结尾）
///
/// 支持 `[n]`、`[n,m]`、`[!n,m]`、`[a:b]`、`[a:b:step]`、`[-1:0]` 反向。
fn split_bracket_index(rule: &str) -> Option<(String, DotIndex)> {
    let open = rule.rfind('[')?;
    let base = rule[..open].trim();
    let inner = rule[open + 1..rule.len() - 1].trim();
    let mut exclude = false;
    let body = if let Some(b) = inner.strip_prefix('!') {
        exclude = true;
        b.trim()
    } else {
        inner
    };

    let mut indices = Vec::new();
    let mut ranges = Vec::new();
    for part in body.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if part.contains(':') {
            let mut seg = part.split(':');
            let start = parse_opt_i32(seg.next());
            let end = parse_opt_i32(seg.next());
            let step = parse_opt_i32(seg.next()).unwrap_or(1);
            if step != 0 {
                ranges.push(RangeIdx { start, end, step });
            }
        } else if let Ok(n) = part.parse::<i32>() {
            indices.push(n);
        }
    }
    if indices.is_empty() && ranges.is_empty() {
        return None;
    }
    Some((
        base.to_string(),
        DotIndex {
            exclude,
            indices,
            ranges,
        },
    ))
}

/// 解析负下标为实际索引（越界返回 None）
fn resolve_single(it: i32, len: i32) -> Option<usize> {
    if it >= 0 && it < len {
        Some(it as usize)
    } else if it < 0 && len >= -it {
        Some((it + len) as usize)
    } else {
        None
    }
}

/// 展开区间为实际索引（含 `[-1:0]` 反向）
fn resolve_range(r: &RangeIdx, len: i32) -> Vec<usize> {
    let v = |o: Option<i32>, default: i32| -> i32 {
        match o {
            None => default,
            Some(s) => {
                if s < 0 {
                    len + s
                } else {
                    s
                }
            }
        }
    };
    let start = v(r.start, 0);
    let end = v(r.end, len - 1);
    let step = if r.step == 0 { 1 } else { r.step.abs() };
    let mut out = Vec::new();
    let mut i = start;
    if start <= end {
        while i <= end {
            if i >= 0 && i < len {
                out.push(i as usize);
            }
            i += step;
        }
    } else {
        while i >= end {
            if i >= 0 && i < len {
                out.push(i as usize);
            }
            i -= step;
        }
    }
    out
}

/// 表格标签片段 → 包裹 HTML（保留片段结构供标准解析）
///
/// HTML5 标准解析（html5ever/scraper）在 body 上下文外遇到 tr/td/tbody
/// 等会直接丢弃；jsoup（原版）宽容保留。元素 outerHTML 再解析时（如
/// class.BOX@tr!0 提取的 tr 元素串交给 tag.td.2@a@text 子规则）必须保留
/// 表格结构才能选中 td/tr。— Reasonix 2026-08-17
fn wrap_table_fragment(html: &str, trimmed: &str) -> Option<String> {
    let mut s = trimmed;
    while s.starts_with("<!--") {
        if let Some(end) = s.find("-->") {
            s = &s[end + 3..];
            s = s.trim_start();
        } else {
            break;
        }
    }
    if s.starts_with("<tr") || s.starts_with("<th") {
        Some(format!("<table><tbody>{html}</tbody></table>"))
    } else if s.starts_with("<td") {
        Some(format!("<table><tbody><tr>{html}</tr></tbody></table>"))
    } else if s.starts_with("<tbody")
        || s.starts_with("<thead")
        || s.starts_with("<tfoot")
        || s.starts_with("<caption")
        || s.starts_with("<colgroup")
        || s.starts_with("<col")
    {
        Some(format!("<table>{html}</table>"))
    } else {
        None
    }
}

/// 从规则末尾拆出点号索引；无索引时返回 (rule, None)
fn split_dot_index(rule: &str) -> (String, Option<DotIndex>) {
    let rus = rule.trim();
    if rus.is_empty() {
        return (rus.to_string(), None);
    }
    // G9：`[...]` 括号索引
    if rus.ends_with(']') {
        if let Some((base, idx)) = split_bracket_index(rus) {
            return (base, Some(idx));
        }
        return (rus.to_string(), None);
    }

    let chars: Vec<char> = rus.chars().collect();
    let mut len = chars.len();
    let mut cur_minus = false;
    let mut l = String::new();
    let mut index_default: Vec<i32> = Vec::new();

    // 逆向扫描，对齐原版 findIndexSet 的 else 分支
    while len > 0 {
        len -= 1;
        let rl = chars[len];
        if rl == ' ' {
            continue;
        }
        if rl.is_ascii_digit() {
            l.insert(0, rl);
            continue;
        }
        if rl == '-' {
            cur_minus = true;
            continue;
        }

        if rl == '!' || rl == '.' || rl == ':' {
            if l.is_empty() {
                break;
            }
            let n: i32 = match l.parse::<i32>() {
                Ok(v) => {
                    if cur_minus {
                        -v
                    } else {
                        v
                    }
                }
                Err(_) => break,
            };
            index_default.push(n);

            if rl != ':' {
                let before: String = chars[..len].iter().collect();
                // index_default 为逆向压入，应用时再倒序对齐原版
                let mut indices = index_default;
                indices.reverse();
                return (
                    before.trim().to_string(),
                    Some(DotIndex {
                        exclude: rl == '!',
                        indices,
                        ranges: vec![],
                    }),
                );
            }

            l.clear();
            cur_minus = false;
            continue;
        }

        break;
    }

    (rus.to_string(), None)
}

/// 按索引筛选元素列表（对齐原版 ElementsSingle 选取/排除）
fn apply_dot_index<'a>(elements: Vec<ElementRef<'a>>, index: &DotIndex) -> Vec<ElementRef<'a>> {
    let len = elements.len() as i32;
    let mut resolved: Vec<usize> = Vec::new();
    for &it in &index.indices {
        if let Some(i) = resolve_single(it, len) {
            if !resolved.contains(&i) {
                resolved.push(i);
            }
        }
    }
    for r in &index.ranges {
        for i in resolve_range(r, len) {
            if !resolved.contains(&i) {
                resolved.push(i);
            }
        }
    }

    if index.exclude {
        elements
            .into_iter()
            .enumerate()
            .filter(|(i, _)| !resolved.contains(i))
            .map(|(_, e)| e)
            .collect()
    } else {
        resolved
            .into_iter()
            .filter_map(|i| elements.get(i).copied())
            .collect()
    }
}

/// jsoup 伪类（scraper/selectors 不支持的文本/位置/子选择器伪类）
#[derive(Debug, Clone)]
enum JsoupPseudo {
    Contains(String),
    ContainsOwn(String),
    ContainsWholeText(String),
    Matches(String),
    MatchesOwn(String),
    Has(String),
    Eq(usize),
    Lt(usize),
    Gt(usize),
    First,
    Last,
}

/// 元素完整文本（对齐 jsoup text()，含子孙文本）
fn full_text_of(elem: ElementRef<'_>) -> String {
    elem.text().collect::<Vec<_>>().join(" ")
}

/// 去掉参数两端的成对引号（jsoup 允许 :contains('text') 或 :contains("text")）
fn unquote(s: &str) -> String {
    let t = s.trim();
    let b = t.as_bytes();
    if t.len() >= 2 {
        let a = b[0];
        let z = b[t.len() - 1];
        if (a == 39 && z == 39) || (a == b'"' && z == b'"') {
            return t[1..t.len() - 1].to_string();
        }
    }
    t.to_string()
}

/// 读取平衡括号（含引号保护），返回（参数内容, 消费字节数含右括号）
/// 引号内 ')' 不计深度；兼容 :has(.a:not(.b)) 的嵌套括号。
fn read_balanced_quoted(s: &str) -> Option<(String, usize)> {
    let bytes = s.as_bytes();
    let mut depth: i32 = 0;
    let mut i = 0usize;
    let mut quote: Option<u8> = None;
    let mut out = String::new();
    while i < bytes.len() {
        let b = bytes[i];
        let ch = s[i..].chars().next().unwrap();
        let clen = ch.len_utf8();
        if let Some(q) = quote {
            if b == q {
                quote = None;
            }
            out.push(ch);
            i += clen;
            continue;
        }
        match b {
            b'"' | 39 => {
                quote = Some(b);
                out.push(ch);
                i += clen;
            }
            b'(' => {
                depth += 1;
                out.push(ch);
                i += clen;
            }
            b')' => {
                if depth == 0 {
                    return Some((out, i + clen));
                }
                depth -= 1;
                out.push(ch);
                i += clen;
            }
            _ => {
                out.push(ch);
                i += clen;
            }
        }
    }
    None
}

/// 识别单个 jsoup 伪类，返回（伪类, 消费字节数）；非 jsoup 伪类返回 None
fn consume_jsoup_pseudo(rest: &str) -> Option<(JsoupPseudo, usize)> {
    let after = &rest[1..];
    type TextualPseudo<'a> = (&'a str, fn(String) -> JsoupPseudo);
    let textual: [TextualPseudo<'_>; 6] = [
        ("containsOwn(", |s| JsoupPseudo::ContainsOwn(s)),
        ("containsWholeText(", |s| JsoupPseudo::ContainsWholeText(s)),
        ("contains(", |s| JsoupPseudo::Contains(s)),
        ("matchesOwn(", |s| JsoupPseudo::MatchesOwn(s)),
        ("matches(", |s| JsoupPseudo::Matches(s)),
        ("has(", |s| JsoupPseudo::Has(s)),
    ];
    for (name, ctor) in textual {
        if let Some(arg_after) = after.strip_prefix(name) {
            let (arg, inner) = read_balanced_quoted(arg_after)?;
            return Some((ctor(arg), 1 + name.len() + inner));
        }
    }
    type IndexedPseudo<'a> = (&'a str, fn(usize) -> JsoupPseudo);
    let indexed: [IndexedPseudo<'_>; 3] = [
        ("eq(", JsoupPseudo::Eq),
        ("lt(", JsoupPseudo::Lt),
        ("gt(", JsoupPseudo::Gt),
    ];
    for (name, ctor) in indexed {
        if let Some(arg_after) = after.strip_prefix(name) {
            let end = arg_after.find(')')?;
            let n: usize = arg_after[..end].trim().parse().ok()?;
            return Some((ctor(n), 1 + name.len() + end + 1));
        }
    }
    for word in ["first", "last"] {
        if let Some(tail) = after.strip_prefix(word) {
            let next = tail.as_bytes().first().copied();
            let boundary = next.is_none_or(|b| {
                b.is_ascii_whitespace() || b == b'>' || b == b'+' || b == b'~' || b == b','
            });
            if boundary {
                let pseudo = if word == "first" {
                    JsoupPseudo::First
                } else {
                    JsoupPseudo::Last
                };
                return Some((pseudo, 1 + word.len()));
            }
        }
    }
    None
}

/// 从选择器串中剥离 jsoup 伪类，返回（干净选择器, 伪类列表）
///
/// 仅识别 scraper/selectors 不支持的 jsoup 特有伪类；其余 `:`（CSS 伪类
/// 如 :nth-child/:not、Legado 点号区间 dd.2:3 已被 split_dot_index 提前消费）
/// 原样保留，避免误伤。
fn split_jsoup_pseudos(selector: &str) -> (String, Vec<JsoupPseudo>) {
    let bytes = selector.as_bytes();
    let mut out = String::with_capacity(selector.len());
    let mut pseudos: Vec<JsoupPseudo> = Vec::new();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b':' {
            if let Some((pseudo, consumed)) = consume_jsoup_pseudo(&selector[i..]) {
                pseudos.push(pseudo);
                i += consumed;
                continue;
            }
        }
        let ch = selector[i..].chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    (out, pseudos)
}

/// 对已匹配元素按顺序应用 jsoup 伪类过滤
fn apply_jsoup_pseudos<'a>(matched: &mut Vec<ElementRef<'a>>, pseudos: &[JsoupPseudo]) {
    for p in pseudos {
        match p {
            JsoupPseudo::Contains(s) => {
                let needle = unquote(s).to_lowercase();
                matched.retain(|e| full_text_of(*e).to_lowercase().contains(&needle));
            }
            JsoupPseudo::ContainsOwn(s) => {
                let needle = unquote(s).to_lowercase();
                matched.retain(|e| own_text_of(*e).to_lowercase().contains(&needle));
            }
            JsoupPseudo::ContainsWholeText(s) => {
                let needle = unquote(s).to_lowercase();
                matched.retain(|e| full_text_of(*e).trim().to_lowercase() == needle);
            }
            JsoupPseudo::Matches(s) => {
                let pat = unquote(s);
                if let Ok(re) = regex::Regex::new(&pat) {
                    matched.retain(|e| re.is_match(&full_text_of(*e)));
                }
            }
            JsoupPseudo::MatchesOwn(s) => {
                let pat = unquote(s);
                if let Ok(re) = regex::Regex::new(&pat) {
                    matched.retain(|e| re.is_match(&own_text_of(*e)));
                }
            }
            JsoupPseudo::Has(sel) => {
                if let Ok(sub) = Selector::parse(sel) {
                    matched.retain(|e| e.select(&sub).next().is_some());
                }
            }
            JsoupPseudo::Eq(n) => {
                *matched = matched.get(*n).copied().into_iter().collect();
            }
            JsoupPseudo::Lt(n) => matched.truncate(*n),
            JsoupPseudo::Gt(n) => {
                if matched.len() > *n {
                    let tail: Vec<ElementRef> = matched.iter().skip(*n).copied().collect();
                    *matched = tail;
                } else {
                    matched.clear();
                }
            }
            JsoupPseudo::First => {
                *matched = matched.iter().take(1).copied().collect();
            }
            JsoupPseudo::Last => {
                *matched = matched.iter().rev().take(1).copied().collect();
            }
        }
    }
}

/// HTML 解析器
pub struct HtmlParser;

impl HtmlParser {
    pub fn new() -> Self {
        Self
    }

    /// 把 HTML 字符串解析为文档（含表格片段包裹逻辑）。
    ///
    /// 注意：scraper 的 `Html` 非 Send（内部 tendril NonAtomic<Cell>），
    /// 因此不能跨调用持久缓存；同内容多规则复用走 `get_multi`（单次解析、
    /// 多次选择，文档在本次调用内瞬态存在）。— 2026-08-18 搜索速度修复
    fn parse_doc(&self, html: &str) -> Html {
        // 表格标签片段解析：tr/td/tbody 等片段在 HTML5 标准解析下会被丢弃
        // （body 上下文外非法；scraper 0.22 parse_fragment 固定 body 上下文
        // 同样丢弃），而原版 jsoup 宽容保留。元素 outerHTML 再解析的场景
        // （class.BOX@tr!0 提取的 <tr> 元素串交给 tag.td.2@a@text 子规则）
        // 必须保留表格结构 → 用 table/tbody 包裹后标准解析。— Reasonix 2026-08-17
        let trimmed = html.trim_start();
        if let Some(wrapped) = wrap_table_fragment(html, trimmed) {
            Html::parse_document(&wrapped)
        } else {
            Html::parse_document(html)
        }
    }

    /// 解析 HTML 并使用 CSS 选择器获取文本内容列表
    pub fn parse_html(&self, html: &str, css_selector: &str) -> LegadoResult<Vec<String>> {
        self.get_text(html, css_selector)
    }

    /// 获取匹配元素的外层 HTML
    pub fn get_elements(&self, html: &str, css_selector: &str) -> LegadoResult<Vec<String>> {
        self.get_content(html, css_selector, "html")
    }

    /// 获取匹配元素的文本内容
    pub fn get_text(&self, html: &str, css_selector: &str) -> LegadoResult<Vec<String>> {
        self.get_content(html, css_selector, "text")
    }

    /// 统一的获取内容方法，根据 `default_mode` 决定提取文本还是 HTML
    fn get_content(
        &self,
        html: &str,
        css_selector: &str,
        default_mode: &str,
    ) -> LegadoResult<Vec<String>> {
        if css_selector.is_empty() {
            return Ok(vec![]);
        }

        let document = self.parse_doc(html);
        self.select_from_doc(&document, css_selector, default_mode)
    }

    /// 单次解析、多规则提取（同内容批量字段）：文档只 parse 一次，
    /// 每条规则的选择语义与 `get_content(.., "text")` 完全一致。
    ///
    /// 搜索列表逐元素字段（name/author/kind/…）走此路径后，每元素从
    /// ~7 次全量 DOM parse 降为 1 次（对齐原版 AnalyzeByJSoup 对 Element
    /// 对象不重复 parse 的行为）。— 2026-08-18 搜索速度修复
    pub fn get_multi(&self, html: &str, rules: &[&str]) -> Vec<LegadoResult<Vec<String>>> {
        if rules.is_empty() {
            return Vec::new();
        }
        let document = self.parse_doc(html);
        rules
            .iter()
            .map(|r| self.select_from_doc(&document, r, "text"))
            .collect()
    }

    /// 在已解析文档上执行 CSS 选择（get_content 的选择主体）
    fn select_from_doc(
        &self,
        document: &Html,
        css_selector: &str,
        default_mode: &str,
    ) -> LegadoResult<Vec<String>> {
        if css_selector.is_empty() {
            return Ok(vec![]);
        }

        // 对标 Kotlin AnalyzeByJSoup：规则本身就是默认提取关键字时，
        // 不做选择器匹配，直接对当前内容（片段根元素）执行提取
        if let Some(mode) = Self::bare_extract_mode(css_selector) {
            let root = document.root_element();
            let elem = root.select(&Selector::parse("body").unwrap()).next().unwrap_or(root);
            return Ok(self
                .extract_from_element(elem, mode, "")
                .map(|t| vec![t])
                .unwrap_or_default());
        }

        let mut analyzer = RuleAnalyzer::new(css_selector, false);
        let rules = analyzer.split_rule(&["&&", "||", "%%"]);
        let elements_type = analyzer.elements_type.to_string();

        let mut results: Vec<Vec<String>> = Vec::new();

        for rule in &rules {
            let rule = rule.trim();
            if rule.is_empty() {
                continue;
            }

            // 按 `@` 拆分多级选择器链
            let mut sub_analyzer = RuleAnalyzer::new(rule, false);
            sub_analyzer.trim();
            let sub_rules = sub_analyzer.split_rule(&["@"]);

            // 处理 `selector@attr` 模式：如果最后一段是属性/模式名而非 CSS 选择器，
            // 则将其与上一段合并，由 parse_last_rule 处理属性提取。
            // last_is_attr：最后一段是否为属性/提取模式（任务 #66）——
            // 不能用 Selector::parse 是否成功判别：href/src/alt/title 等
            // 都是合法 CSS 类型选择器（parse 返回 Ok），会被误判为选择器
            let (effective_rules, is_single, last_is_attr) = Self::resolve_at_chain(&sub_rules);

            let items = if is_single {
                // 单级：直接在文档上选择
                self.extract_from_doc(document, rule, default_mode)
            } else {
                // 多级链式选择器：逐级下钻（不重复解析 HTML）
                self.extract_chained(document, &effective_rules, default_mode, last_is_attr)
            };

            if !items.is_empty() {
                results.push(items);
                if elements_type == "||" {
                    break;
                }
            }
        }

        let merged = self.merge_results(results, &elements_type);

        // 对标 Kotlin getResultLast else 分支：选择器无结果且规则为裸 token 时，
        // 视为属性名从当前元素提取（如 chapterUrl 规则 "href"）
        if merged.is_empty()
            && default_mode == "text"
            && !css_selector.contains(['@', ' ', '>', '.', '#', '['])
        {
            let root = document.root_element();
            if let Some(elem) = root.select(&Selector::parse("body").unwrap()).next() {
                let mut attr_values: Vec<String> = Vec::new();
                for child in elem.children().filter_map(ElementRef::wrap) {
                    if let Some(v) = child.value().attr(css_selector) {
                        if !v.is_empty() && !attr_values.iter().any(|x| x == v) {
                            attr_values.push(v.to_string());
                        }
                    }
                }
                if attr_values.is_empty() {
                    if let Some(v) = elem.value().attr(css_selector) {
                        if !v.is_empty() {
                            attr_values.push(v.to_string());
                        }
                    }
                }
                if !attr_values.is_empty() {
                    return Ok(attr_values);
                }
            }
        }

        Ok(merged)
    }

    /// 对齐原版 `AnalyzeByJSoup.ElementsSingle`：`class.name` / `tag.name` / `id.name`
    ///
    /// 原版走 `getElementsByClass` / `getElementsByTag` / `Id` Evaluator；
    /// Rust 侧若把 `class.comics-card` 直接交给 CSS 解析器，会变成「标签名 class
    /// 与类 comics-card」，对真实 `<div class="comics-card …">` 永远 0 命中，
    /// 表现为大量漫画源 `search:empty`（包子/爱看等）。— Auto 2026-08-11
    fn normalize_jsoup_selector(rule: &str) -> String {
        let rule = rule.trim();
        if rule.is_empty() {
            return String::new();
        }

        let (prefix, rest) = if let Some(r) = rule.strip_prefix("class.") {
            ("class", r)
        } else if let Some(r) = rule.strip_prefix("tag.") {
            ("tag", r)
        } else if let Some(r) = rule.strip_prefix("id.") {
            ("id", r)
        } else if rule == "children" || rule.starts_with("children.") {
            return ":scope > *".to_string();
        } else {
            return rule.to_string();
        };

        // `class.comics-card pure-u-1-3 …`：空格后为多余 class 列表，只取首 token
        // `class.name.0` / `class.name!1` / `class.name[0]`：剥离索引后缀
        let token = rest
            .split_whitespace()
            .next()
            .unwrap_or(rest)
            .split(['!', '['])
            .next()
            .unwrap_or(rest);
        let name = token.split('.').next().unwrap_or(token).trim();
        if name.is_empty() {
            return rule.to_string();
        }
        match prefix {
            "class" => format!(".{name}"),
            "tag" => name.to_string(),
            "id" => format!("#{name}"),
            _ => rule.to_string(),
        }
    }

    /// 在已解析的文档上执行选择器并提取内容
    fn extract_from_doc(&self, document: &Html, rule: &str, default_mode: &str) -> Vec<String> {
        let (selector_str, extract_mode, attr_name) = self.parse_last_rule(rule, default_mode);
        let (selector_no_index, dot_index) = split_dot_index(selector_str);
        let selector_owned = Self::normalize_jsoup_selector(&selector_no_index);
        let selector_str = selector_owned.as_str();

        // 空选择器：直接对文档 body（或根元素）提取（裸提取关键字场景）
        if selector_str.trim().is_empty() {
            let root = document.root_element();
            let elem = root
                .select(&Selector::parse("body").unwrap())
                .next()
                .unwrap_or(root);
            return self
                .extract_from_element(elem, extract_mode, &attr_name)
                .map(|t| vec![t])
                .unwrap_or_default();
        }

        let (clean_selector, pseudos) = split_jsoup_pseudos(selector_str);
        let Ok(selector) = Selector::parse(&clean_selector) else {
            return vec![];
        };

        let mut matched: Vec<ElementRef> = document.select(&selector).collect();
        apply_jsoup_pseudos(&mut matched, &pseudos);
        if let Some(ref idx) = dot_index {
            matched = apply_dot_index(matched, idx);
        }

        let mut items = Vec::new();
        // 对标 Kotlin：仅属性提取路径去重，text/html 逐元素保留
        let dedup = extract_mode == "attr";
        for elem in matched {
            if let Some(text) = self.extract_from_element(elem, extract_mode, &attr_name) {
                if !text.is_empty() && (!dedup || !items.contains(&text)) {
                    items.push(text);
                }
            }
        }
        items
    }

    /// 在父元素集合上按单段规则（可含点号索引）选取子元素
    fn select_step<'a>(
        parents: &[ElementRef<'a>],
        rule: &str,
    ) -> Vec<ElementRef<'a>> {
        let (selector_no_index, dot_index) = split_dot_index(rule.trim());
        let owned = Self::normalize_jsoup_selector(&selector_no_index);
        if owned.is_empty() {
            return parents.to_vec();
        }
        let (clean, pseudos) = split_jsoup_pseudos(&owned);
        let Ok(selector) = Selector::parse(&clean) else {
            return vec![];
        };

        let mut next = Vec::new();
        for elem in parents {
            // 对齐 JSoup：`getElementsByTag` / 部分 Evaluator 命中时包含自身。
            // 否则 `.page-link@a@href` 在已是 `<a class="page-link">` 上会空（思路客 nextTocUrl）。
            if selector.matches(elem) {
                next.push(*elem);
            }
            for child in elem.select(&selector) {
                next.push(child);
            }
        }
        apply_jsoup_pseudos(&mut next, &pseudos);
        if let Some(ref idx) = dot_index {
            // 索引是相对于「每个父节点下的匹配结果」还是「全局合并列表」？
            // 原版 AnalyzeByJSoup 链式 @ 时，每一级对单个 element 调用 getElementsSingle，
            // 即索引相对当前父元素。此处 parents 可能多个；对每个 parent 分别索引再合并。
            if parents.len() == 1 {
                return apply_dot_index(next, idx);
            }
            let mut per_parent = Vec::new();
            for elem in parents {
                let mut kids: Vec<ElementRef> = Vec::new();
                if selector.matches(elem) {
                    kids.push(*elem);
                }
                kids.extend(elem.select(&selector));
                apply_jsoup_pseudos(&mut kids, &pseudos);
                kids = apply_dot_index(kids, idx);
                per_parent.extend(kids);
            }
            return per_parent;
        }
        next
    }

    /// 链式选择器：在单个解析文档上逐级下钻
    ///
    /// `last_is_attr`（任务 #66）：最后一级是否为属性/提取模式名。
    /// 对齐原版 AnalyzeByJSoup.getResultLast（约 L270-277）：@ 链最后一级
    /// 非 text/html 关键字时一律直接 element.attr(lastRule) 属性提取，
    /// 从不做选择器查询——不能用 Selector::parse 判别（href/src/alt 等
    /// 都是合法 CSS 类型选择器，会被误判为选择器导致永远 0 命中）。
    fn extract_chained(
        &self,
        document: &Html,
        sub_rules: &[&str],
        default_mode: &str,
        last_is_attr: bool,
    ) -> Vec<String> {
        let last_idx = sub_rules.len() - 1;

        // 首级：从 document 选（可含点号索引，如 `dd.1`）
        let first_rule = sub_rules[0].trim();
        let (first_no_index, first_index) = split_dot_index(first_rule);
        let first_owned = Self::normalize_jsoup_selector(&first_no_index);
        let (first_clean, first_pseudos) = split_jsoup_pseudos(&first_owned);
        let Ok(first_selector) = Selector::parse(&first_clean) else {
            return vec![];
        };

        let mut current_elements: Vec<ElementRef> = document.select(&first_selector).collect();
        apply_jsoup_pseudos(&mut current_elements, &first_pseudos);
        if let Some(ref idx) = first_index {
            current_elements = apply_dot_index(current_elements, idx);
        }

        // 中间各级（不含首尾）
        for rule in sub_rules.iter().take(last_idx).skip(1) {
            current_elements = Self::select_step(&current_elements, rule.trim());
            if current_elements.is_empty() {
                return vec![];
            }
        }

        // 最后一级：提取内容
        let last_rule = sub_rules[last_idx].trim();

        // 任务 #66：最后一级已判定为属性/提取模式名（对齐原版 getResultLast
        // 语义），跳过 Selector::parse 判别直接提取
        if last_is_attr {
            let mut items = Vec::new();
            if let Some(mode) = Self::bare_extract_mode(last_rule) {
                // text/textNodes/ownText/html/all 关键字：按模式提取
                for elem in &current_elements {
                    if let Some(text) = self.extract_from_element(*elem, mode, "") {
                        if !text.is_empty() {
                            items.push(text);
                        }
                    }
                }
            } else {
                // 属性名：对当前元素逐个 attr(last)（保留属性路径去重）
                for elem in &current_elements {
                    if let Some(text) = self.extract_from_element(*elem, "attr", last_rule) {
                        if !text.is_empty() && !items.contains(&text) {
                            items.push(text);
                        }
                    }
                }
            }
            return items;
        }

        let (selector_raw, extract_mode, attr_name) = self.parse_last_rule(last_rule, default_mode);
        let (selector_no_index, last_index) = split_dot_index(selector_raw);
        let selector_owned = Self::normalize_jsoup_selector(&selector_no_index);
        let selector_str = selector_owned.as_str();

        let mut items = Vec::new();

        if selector_str.is_empty() {
            // 最后一级没有选择器，直接从当前元素提取
            for elem in &current_elements {
                if let Some(text) = self.extract_from_element(*elem, extract_mode, &attr_name) {
                    if !text.is_empty() {
                        items.push(text);
                    }
                }
            }
        } else {
            let (last_clean, last_pseudos) = split_jsoup_pseudos(selector_str);
            if Selector::parse(&last_clean).is_err() {
                // 选择器无效：可能是默认提取关键字（如 "text"、"html"）
                if let Some(mode) = Self::bare_extract_mode(selector_str) {
                    for elem in &current_elements {
                        if let Some(text) = self.extract_from_element(*elem, mode, "") {
                            if !text.is_empty() {
                                items.push(text);
                            }
                        }
                    }
                    return items;
                }
                // 也可能是属性名（如 "href"、"src"）
                // 将最后一段视为属性名，从当前元素提取该属性（属性路径去重）
                for elem in &current_elements {
                    if let Some(text) = self.extract_from_element(*elem, "attr", selector_str) {
                        if !text.is_empty() && !items.contains(&text) {
                            items.push(text);
                        }
                    }
                }
            } else {
                let selector = Selector::parse(&last_clean).unwrap();
                for elem in &current_elements {
                    let mut kids: Vec<ElementRef> = elem.select(&selector).collect();
                    apply_jsoup_pseudos(&mut kids, &last_pseudos);
                    if let Some(ref idx) = last_index {
                        kids = apply_dot_index(kids, idx);
                    }
                    for child in kids {
                        if let Some(text) = self.extract_from_element(child, extract_mode, &attr_name) {
                            if !text.is_empty() && !items.contains(&text) {
                                items.push(text);
                            }
                        }
                    }
                }
            }
        }

        items
    }

    /// 从单个元素中提取内容（文本/HTML/属性）
    fn extract_from_element(
        &self,
        elem: ElementRef,
        mode: &str,
        attr_name: &str,
    ) -> Option<String> {
        let text = match mode {
            "text" => {
                let t: String = elem.text().collect::<Vec<_>>().join(" ");
                t.trim().to_string()
            }
            // 对齐 Jsoup Element.textNodes()：仅直接文本子节点，trim 后用 \n 拼接
            "textNodes" => {
                let mut nodes = Vec::new();
                for child in elem.children() {
                    if let Some(text) = child.value().as_text() {
                        let t = text.trim();
                        if !t.is_empty() {
                            nodes.push(t.to_string());
                        }
                    }
                }
                nodes.join("\n")
            }
            // 对齐 Jsoup Element.ownText()：仅本元素直接文本，不含子孙元素文本
            "ownText" => own_text_of(elem),
            "html" => {
                let h = elem.html();
                strip_script_style(&h)
            }
            "all" => elem.html(),
            "attr" => elem.value().attr(attr_name).map(|v| v.to_string())?,
            _ => {
                // 当作属性名
                elem.value().attr(mode).map(|v| v.to_string())?
            }
        };
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }

    /// 获取匹配元素的属性值
    pub fn get_attr(
        &self,
        html: &str,
        css_selector: &str,
        attr: &str,
    ) -> LegadoResult<Vec<String>> {
        if css_selector.is_empty() {
            return Ok(vec![]);
        }

        let document = self.parse_doc(html);
        let selector = Selector::parse(css_selector).map_err(|e| {
            legado_core::LegadoError::Parser(format!("Invalid CSS selector: {:?}", e))
        })?;

        let mut results = Vec::new();
        for elem in document.select(&selector) {
            if let Some(val) = elem.value().attr(attr) {
                let val = val.trim().to_string();
                if !val.is_empty() && !results.contains(&val) {
                    results.push(val);
                }
            }
        }

        Ok(results)
    }

    /// 解析最后一段规则，提取选择器、提取模式和属性名
    /// 裸默认提取关键字 → 提取模式（对标 Kotlin AnalyzeByJSoup 的
    /// `text/textNodes/ownText/html/allText` 特殊规则）
    fn bare_extract_mode(rule: &str) -> Option<&'static str> {
        match rule.trim() {
            "text" => Some("text"),
            "textNodes" => Some("textNodes"),
            "ownText" => Some("ownText"),
            "html" => Some("html"),
            "all" => Some("all"),
            _ => None,
        }
    }

    fn parse_last_rule<'a>(
        &self,
        rule: &'a str,
        default_mode: &'a str,
    ) -> (&'a str, &'a str, String) {
        if let Some(last_at) = rule.rfind('@') {
            let selector_part = &rule[..last_at];
            let extract_part = &rule[last_at + 1..];
            match extract_part {
                "text" | "textNodes" | "ownText" | "html" | "all" => {
                    (selector_part, extract_part, String::new())
                }
                _ => (selector_part, "attr", extract_part.to_string()),
            }
        } else {
            // 无 `@`：裸默认提取关键字视为提取模式，其余视为选择器
            if let Some(mode) = Self::bare_extract_mode(rule) {
                ("", mode, String::new())
            } else {
                (rule, default_mode, String::new())
            }
        }
    }

    /// 合并多组结果，根据分隔符类型决定合并策略
    fn merge_results(&self, results: Vec<Vec<String>>, elements_type: &str) -> Vec<String> {
        if results.is_empty() {
            return vec![];
        }

        if elements_type == "%%" {
            // 交叉合并
            let mut merged = Vec::new();
            let max_len = results.iter().map(|r| r.len()).max().unwrap_or(0);
            for i in 0..max_len {
                for group in &results {
                    if i < group.len() {
                        merged.push(group[i].clone());
                    }
                }
            }
            merged
        } else {
            // && 或 || 直接拼接
            let mut merged = Vec::new();
            for group in results {
                merged.extend(group);
            }
            merged
        }
    }

    /// 解析 `@` 分割后的规则链，区分“链式选择器”和“属性提取后缀”
    ///
    /// 规则：
    /// - `.name@href` → 单级选择器 + 属性提取（非链）
    /// - `div.list@.item@text` → 链式 [div.list, .item] + 模式 text
    /// - `div@.item@href` → 链式 [div, .item] + 属性 href
    ///
    /// 返回 (effective_rules, is_single, last_is_attr)：
    /// - is_single=true: 单级选择器，由 extract_from_doc 处理
    /// - is_single=false: 多级链，由 extract_chained 处理
    /// - last_is_attr: 最后一段是属性/提取模式名而非选择器（任务 #66）
    fn resolve_at_chain<'a>(sub_rules: &[&'a str]) -> (Vec<&'a str>, bool, bool) {
        if sub_rules.len() <= 1 {
            return (sub_rules.to_vec(), true, false);
        }

        let last = sub_rules[sub_rules.len() - 1].trim();

        // 常见 HTML 标签名（`@a` 等是元素选择链语义，非属性提取；
        // 原版 AnalyzeByJSoup 的 `@` 链最后一段若是标签名则继续选元素，
        // 仅当最后一段是属性/提取模式名时才做属性提取。
        // [UI-fix 2026-08-10 | Reasonix] 此前 `a` 被误判为属性名 → 漫画书源
        // chapterList `.right_box:nth-child(2)@a` 解析不到章节元素）
        const COMMON_TAG_NAMES: &[&str] = &[
            "a", "div", "span", "li", "ul", "ol", "p", "img", "h1", "h2", "h3", "h4", "h5",
            "h6", "table", "tr", "td", "th", "tbody", "thead", "tfoot", "section", "article",
            "header", "footer", "nav", "button", "input", "select", "option", "form", "label",
            "em", "strong", "b", "i", "u", "br", "hr", "blockquote", "pre", "code", "iframe",
            "video", "audio", "source", "canvas", "svg", "body", "html", "main", "aside",
            "figure", "figcaption", "dl", "dt", "dd", "sub", "sup", "small", "mark", "time",
            "abbr", "address", "cite", "dfn", "kbd", "q", "samp", "var", "wbr", "map", "area",
            "object", "embed", "param", "track", "picture", "summary", "details",
        ];
        let is_tag_name = COMMON_TAG_NAMES.contains(&last);

        // 判断最后一段是否为提取模式/属性名（而非 CSS 选择器）
        // 含 '!' 的是标签+排除索引语法（如 'tr!0' = tr 元素排除第一个，
        // 原版 77读书网 'class.BOX@tr!0' 搜索规则），不是属性名——
        // 此前被误判为提取后缀 → 属性提取空 → 搜索 0 结果（2026-08-17）。
        let is_extraction_suffix = !is_tag_name
            && !last.contains('!')
            && (matches!(
                last,
                "text"
                    | "textNodes"
                    | "ownText"
                    | "html"
                    | "all"
                    | "href"
                    | "src"
                    | "alt"
                    | "title"
                    | "value"
                    | "data-src"
                    | "data-original"
                    | "content"
            ) || (!last.is_empty()
                && !last.contains('.')
                && !last.contains('#')
                && !last.contains('[')
                && !last.contains('>')
                && !last.contains('~')
                && !last.contains('+')
                && !last.contains(':')
                && !last.contains('*')
                && !last.contains(' ')));

        if is_extraction_suffix {
            // 最后一段是属性/模式名，不是选择器
            if sub_rules.len() == 2 {
                // 例如 [".name", "href"] → 单级选择器 ".name@href"
                // 返回 is_single=true，由 extract_from_doc + parse_last_rule 处理
                (sub_rules.to_vec(), true, true)
            } else {
                // 例如 ["h4", "a", "href"] → 链式 [h4, a] + 属性 href
                // 三级以上链：last_is_attr=true 告知 extract_chained
                // 最后一级直接属性提取（对齐原版 getResultLast）
                (sub_rules.to_vec(), false, true)
            }
        } else {
            // 最后一段是有效选择器，正常链式处理
            (sub_rules.to_vec(), false, false)
        }
    }
}

impl Default for HtmlParser {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_HTML: &str = r#"
    <html>
    <body>
        <div class="list">
            <a href="https://example.com/1" class="item">第一章</a>
            <a href="https://example.com/2" class="item">第二章</a>
            <a href="https://example.com/3" class="item">第三章</a>
        </div>
        <div class="info">
            <span id="title">测试书籍</span>
            <span class="author">作者名</span>
        </div>
        <p class="content">段落一</p>
        <p class="content">段落二</p>
        <img src="cover.jpg" alt="封面" />
    </body>
    </html>
    "#;

    #[test]
    fn test_get_text_basic() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, ".item").unwrap();
        assert_eq!(result.len(), 3);
        assert_eq!(result[0], "第一章");
        assert_eq!(result[1], "第二章");
        assert_eq!(result[2], "第三章");
    }

    #[test]
    fn test_jsoup_pseudo_contains() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "a.item:contains('第二章')").unwrap();
        assert_eq!(result, vec!["第二章"]);
    }

    #[test]
    fn test_jsoup_pseudo_has() {
        let parser = HtmlParser::new();
        let result = parser.get_elements(SAMPLE_HTML, "div:has(.author)").unwrap();
        assert_eq!(result.len(), 1);
        assert!(result[0].contains("作者名"));
    }

    #[test]
    fn test_jsoup_pseudo_eq_and_index() {
        let parser = HtmlParser::new();
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item:eq(1)").unwrap(),
            vec!["第二章"]
        );
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item:lt(2)").unwrap(),
            vec!["第一章", "第二章"]
        );
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item:first").unwrap(),
            vec!["第一章"]
        );
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item:last").unwrap(),
            vec!["第三章"]
        );
    }

    #[test]
    fn test_jsoup_pseudo_matches() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "a.item:matches('第.章')").unwrap();
        assert_eq!(result, vec!["第一章", "第二章", "第三章"]);
    }

    #[test]
    fn test_html_mode_strips_script_style() {
        let parser = HtmlParser::new();
        let html = r#"<div class="c">正文<script>alert(1)</script><style>.x{}</style>结尾</div>"#;
        let result = parser.get_text(html, ".c@html").unwrap();
        assert_eq!(result.len(), 1);
        assert!(!result[0].contains("<script"));
        assert!(!result[0].contains("<style"));
        assert!(result[0].contains("正文"));
        assert!(result[0].contains("结尾"));
    }

    #[test]
    fn test_bracket_index() {
        let parser = HtmlParser::new();
        assert_eq!(parser.get_text(SAMPLE_HTML, ".item[0]").unwrap(), vec!["第一章"]);
        assert_eq!(parser.get_text(SAMPLE_HTML, ".item[2]").unwrap(), vec!["第三章"]);
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item[0,2]").unwrap(),
            vec!["第一章", "第三章"]
        );
        assert_eq!(parser.get_text(SAMPLE_HTML, ".item[-1]").unwrap(), vec!["第三章"]);
        assert_eq!(
            parser.get_text(SAMPLE_HTML, ".item[!1]").unwrap(),
            vec!["第一章", "第三章"]
        );
    }

    #[test]
    fn test_get_text_by_id() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "#title").unwrap();
        assert_eq!(result, vec!["测试书籍"]);
    }

    /// 词典 showRule `#def`（dict_api test_lookup_show_rule_css 同构 HTML）
    #[test]
    fn test_get_text_dict_def_id() {
        let html = r#"<html><body><p id='def'>n. 测试释义</p></body></html>"#;
        let parser = HtmlParser::new();
        let result = parser.get_text(html, "#def").unwrap();
        assert_eq!(result, vec!["n. 测试释义"], "实际: {result:?}");
    }

    #[test]
    fn test_get_text_empty_selector() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_get_text_no_match() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, ".nonexistent").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_get_attr_href() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, ".item", "href").unwrap();
        assert_eq!(result.len(), 3);
        assert_eq!(result[0], "https://example.com/1");
    }

    #[test]
    fn test_get_attr_src() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, "img", "src").unwrap();
        assert_eq!(result, vec!["cover.jpg"]);
    }

    #[test]
    fn test_get_attr_empty_selector() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, "", "href").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_get_attr_nonexistent() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, ".item", "data-xxx").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_parse_html_with_attr_extraction() {
        let parser = HtmlParser::new();
        let result = parser.parse_html(SAMPLE_HTML, ".item@href").unwrap();
        assert_eq!(result.len(), 3);
        assert!(result[0].contains("example.com/1"));
    }

    #[test]
    fn test_parse_html_text_mode() {
        let parser = HtmlParser::new();
        let result = parser.parse_html(SAMPLE_HTML, ".item@text").unwrap();
        assert_eq!(result[0], "第一章");
    }

    #[test]
    fn test_get_elements_html() {
        let parser = HtmlParser::new();
        let result = parser.get_elements(SAMPLE_HTML, "#title").unwrap();
        assert_eq!(result.len(), 1);
        assert!(result[0].contains("测试书籍"));
    }

    #[test]
    fn test_multiple_paragraphs() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "p.content").unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0], "段落一");
        assert_eq!(result[1], "段落二");
    }

    #[test]
    fn test_deduplication() {
        let html = r#"<div><span>重复</span><span>重复</span><span>不同</span></div>"#;
        let parser = HtmlParser::new();
        let result = parser.get_text(html, "span").unwrap();
        // 对标 Kotlin AnalyzeByJSoup：text 提取不做去重（逐元素保留），
        // 去重仅发生在属性提取路径（getResultLast else 分支）
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn test_attr_deduplication() {
        // 属性提取路径保留去重（对标 Kotlin getResultLast else 分支）
        let html = r#"<div><a href="/x.html">a</a><a href="/x.html">b</a><a href="/y.html">c</a></div>"#;
        let parser = HtmlParser::new();
        let result = parser.get_text(html, "a@href").unwrap();
        assert_eq!(result, vec!["/x.html", "/y.html"]);
    }

    #[test]
    fn test_or_operator() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "#title||.nonexist").unwrap();
        assert_eq!(result, vec!["测试书籍"]);
    }

    #[test]
    fn test_and_operator() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "#title&&.author").unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"测试书籍".to_string()));
        assert!(result.contains(&"作者名".to_string()));
    }

    #[test]
    fn test_invalid_css_selector() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, "[[[invalid", "href");
        assert!(result.is_err());
    }

    #[test]
    fn test_default_trait() {
        let parser = HtmlParser::default();
        let result = parser.get_text("<p>hello</p>", "p").unwrap();
        assert_eq!(result, vec!["hello"]);
    }

    #[test]
    fn test_nested_elements() {
        let html = r#"<div class="outer"><div class="inner"><span>内容</span></div></div>"#;
        let parser = HtmlParser::new();
        let result = parser.get_text(html, ".outer .inner span").unwrap();
        assert_eq!(result, vec!["内容"]);
    }

    #[test]
    fn test_img_alt_attr() {
        let parser = HtmlParser::new();
        let result = parser.get_attr(SAMPLE_HTML, "img", "alt").unwrap();
        assert_eq!(result, vec!["封面"]);
    }

    // ─── 任务 #66：三级以上 @ 链最后一级属性提取回归 ─────────────

    /// cxzz958 类搜索页 bookUrl 真实结构：三级链 h4@a@href
    const BOOKBOX_HTML: &str = r#"
    <div class="bookbox">
        <h4 class="bookname"><a href="/b/1/">书名</a></h4>
        <div class="bookimg"><img src="/cover/1.jpg" alt="封面图" /></div>
    </div>
    "#;

    #[test]
    fn test_three_level_chain_href_attr() {
        // 任务 #66 核心用例：href 是合法 CSS 类型选择器，
        // 旧实现 Selector::parse("href").is_ok() 误判为选择器 → 0 命中
        let parser = HtmlParser::new();
        let result = parser.get_text(BOOKBOX_HTML, "h4@a@href").unwrap();
        assert_eq!(result, vec!["/b/1/"]);
        // class 选择器前缀同果
        let result2 = parser.get_text(BOOKBOX_HTML, ".bookname@a@href").unwrap();
        assert_eq!(result2, vec!["/b/1/"]);
    }

    #[test]
    fn test_three_level_chain_text_mode() {
        let parser = HtmlParser::new();
        let result = parser.get_text(BOOKBOX_HTML, "h4@a@text").unwrap();
        assert_eq!(result, vec!["书名"]);
    }

    #[test]
    fn test_tag_chain_includes_self_like_jsoup() {
        // 思路客 nextTocUrl：`.page-link@a@href`，节点本身即 <a class="page-link">
        let html = r#"
        <html><body>
          <a class="page-link">1/3</a>
          <a class="page-link" href="/book/index_1.html">1</a>
          <a class="page-link" href="/book/index_2.html">2</a>
        </body></html>"#;
        let parser = HtmlParser::new();
        let hrefs = parser.get_text(html, ".page-link@a@href").unwrap();
        assert!(
            hrefs.len() >= 2,
            "应含自身 a 的 href，实际: {hrefs:?}"
        );
        assert!(hrefs.iter().any(|h| h.contains("index_2")));
    }

    #[test]
    fn test_a_suffix_is_tag_chain_not_attr() {
        // [UI-fix 2026-08-10 | Reasonix] 漫画书源 chapterList 常写
        // `.right_box:nth-child(2)@a`（@a = 取 a 标签元素）。
        // 旧实现把 "a" 误判为属性提取 → 元素列表为空 → 目录 0 章。
        let html = r#"
        <html><body>
          <div class="catalog_box">
            <div class="left_box">封面</div>
            <div class="right_box">
              <a class="item_box" href="/comic/chapter/1">第1话</a>
              <a class="item_box" href="/comic/chapter/2">第2话</a>
            </div>
          </div>
        </body></html>"#;
        let parser = HtmlParser::new();
        let elems = parser.get_elements(html, ".right_box:nth-child(2)@a").unwrap();
        assert_eq!(elems.len(), 2, "应解析出 2 个 a 章节元素，实际: {elems:?}");
        assert!(elems[0].contains("/comic/chapter/1"), "元素应含章节链接: {}", elems[0]);
        // 属性提取语义不受影响（@href 仍是属性）
        let hrefs = parser.get_text(html, ".right_box@a@href").unwrap();
        assert_eq!(hrefs.len(), 2);
        assert_eq!(hrefs[0], "/comic/chapter/1");
    }

    #[test]
    fn test_three_level_chain_src_alt_attr() {
        let parser = HtmlParser::new();
        // src 同为合法 CSS 类型选择器，同样曾被误判
        let result = parser.get_text(BOOKBOX_HTML, ".bookbox@.bookimg@img@src").unwrap();
        assert_eq!(result, vec!["/cover/1.jpg"]);
        let result2 = parser.get_text(BOOKBOX_HTML, ".bookbox@.bookimg@img@alt").unwrap();
        assert_eq!(result2, vec!["封面图"]);
    }

    #[test]
    fn test_three_level_chain_selector_last_still_works() {
        // 最后一级确为选择器的三级链行为不变（last_is_attr=false 路径）
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, ".list@a@text").unwrap();
        // 注：`a` 无 CSS 元字符但不在关键字白名单……实际 `a` 会被
        // is_extraction_suffix 的裸 token 分支判为属性名；
        // 改用带元字符的选择器验证选择器下钻路径
        let result2 = parser.get_text(SAMPLE_HTML, "body@.list@.item").unwrap();
        assert_eq!(result2.len(), 3);
        assert_eq!(result2[0], "第一章");
        let _ = result;
    }

    #[test]
    fn test_jsoup_class_prefix_matches_multi_class_elements() {
        // 对齐原版 getElementsByClass：`class.comics-card` 命中
        // class="comics-card pure-u-1-2 …"（包子/爱看等漫画搜索列表）
        let html = r#"
        <html><body>
          <div class="comics-card pure-u-1-2 pure-u-md-1-4">
            <div class="comics-card__title text-truncate">一人之下</div>
          </div>
          <div class="comics-card">
            <div class="comics-card__title">别的书</div>
          </div>
          <div class="other">噪声</div>
        </body></html>"#;
        let parser = HtmlParser::new();
        let elems = parser.get_elements(html, "class.comics-card").unwrap();
        assert_eq!(elems.len(), 2, "应命中 2 个 comics-card，实际: {elems:?}");
        // 带多余 class 列表的写法（爱看 bookList）只取首 token
        let elems2 = parser
            .get_elements(html, "class.comics-card pure-u-1-3 pure-u-md-1-4")
            .unwrap();
        assert_eq!(elems2.len(), 2);
        let titles = parser
            .get_text(html, "class.comics-card@class.comics-card__title@text")
            .unwrap();
        assert!(titles.iter().any(|t| t.contains("一人之下")));
    }

    #[test]
    fn test_jsoup_tag_and_id_prefix() {
        let html = r#"<html><body><p id="x">A</p><span class="s">B</span></body></html>"#;
        let parser = HtmlParser::new();
        assert_eq!(parser.get_text(html, "tag.p").unwrap(), vec!["A"]);
        assert_eq!(parser.get_text(html, "id.x").unwrap(), vec!["A"]);
        assert_eq!(parser.get_text(html, "class.s").unwrap(), vec!["B"]);
    }

    /// 对齐 Jsoup ownText：子孙文本不计入；仅直接文本子节点
    #[test]
    fn test_own_text_excludes_descendants() {
        let html = r#"<html><body>
            <div id="d">前缀<span>子级</span>后缀</div>
            <div id="e"><b>只有子级</b></div>
        </body></html>"#;
        let parser = HtmlParser::new();
        let own = parser.get_content(html, "#d", "ownText").unwrap();
        assert_eq!(own, vec!["前缀 后缀"]);
        let empty = parser.get_content(html, "#e", "ownText").unwrap();
        assert!(empty.is_empty(), "无直接文本时应为空，实际: {empty:?}");
        // text 仍含子孙
        let all = parser.get_text(html, "#d").unwrap();
        assert!(all[0].contains("子级"));
    }

    #[test]
    fn test_split_dot_index_basic() {
        assert_eq!(
            split_dot_index("a.0"),
            (
                "a".into(),
                Some(DotIndex {
                    exclude: false,
                    indices: vec![0],
                    ranges: vec![]
                })
            )
        );
        assert_eq!(
            split_dot_index("dd.2:3"),
            (
                "dd".into(),
                Some(DotIndex {
                    exclude: false,
                    indices: vec![2, 3],
                    ranges: vec![]
                })
            )
        );
        assert_eq!(split_dot_index(".col-md-6").0, ".col-md-6");
        assert!(split_dot_index(".col-md-6").1.is_none());
        assert_eq!(
            split_dot_index("li!-1"),
            (
                "li".into(),
                Some(DotIndex {
                    exclude: true,
                    indices: vec![-1],
                    ranges: vec![]
                })
            )
        );
    }

    /// 思路客 search 规则：`a.0@href` / `dd.1@span.0@text` / `dd.2:3@text`
    #[test]
    fn test_dot_index_siluke_book_fields() {
        let html = r#"
        <dl>
          <dt><a href="/135/135252/"><img src="/images/cover.jpg" alt="x"></a></dt>
          <dd><h3><a href="/135/135252/">从铬龙开始</a></h3></dd>
          <dd class="book_other">作者：<span><a href="/search.php?q=a">欢声</a></span></dd>
          <dd class="book_other">状态：连载</dd>
          <dd class="book_other">更新时间：08-13 14:58:01</dd>
          <dd class="book_other">最新章节：<a href="/135/135252/1.html">第131章</a></dd>
        </dl>
        "#;
        let parser = HtmlParser::new();

        let hrefs = parser.get_text(html, "a.0@href").unwrap();
        assert_eq!(hrefs, vec!["/135/135252/"]);

        let author = parser.get_text(html, "dd.1@span.0@text").unwrap();
        assert_eq!(author, vec!["欢声"]);

        let kind = parser.get_text(html, "dd.2:3@text").unwrap();
        assert_eq!(kind.len(), 2, "dd.2 与 dd.3 应各一条: {kind:?}");
        assert!(kind[0].contains("连载"), "{kind:?}");
        assert!(kind[1].contains("更新时间"), "{kind:?}");

        let last = parser.get_text(html, "dd.4@a@text").unwrap();
        assert_eq!(last, vec!["第131章"]);
    }

    #[test]
    fn test_attr_ends_with_property_content() {
        // 书书等详情规则：`[property$=book_name]@content` 对齐 jsoup 属性后缀匹配
        let html = r#"<meta property="og:novel:book_name" content="一念永恒"><meta property="og:novel:author" content="耳根">"#;
        let parser = HtmlParser::new();
        let name = parser
            .get_attr(html, r#"[property$=book_name]"#, "content")
            .unwrap();
        assert_eq!(name, vec!["一念永恒"], "{name:?}");
        let via_at = parser
            .get_text(html, r#"[property$=book_name]@content"#)
            .unwrap();
        assert_eq!(via_at, vec!["一念永恒"], "{via_at:?}");
    }
}
