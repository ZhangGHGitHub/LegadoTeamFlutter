//! HTML 解析模块（基于 scraper）
//!
//! 参考 Kotlin `AnalyzeByJSoup.kt`，使用 `scraper` crate 实现 CSS 选择器查询。

use legado_core::LegadoResult;
use scraper::{ElementRef, Html, Selector};

use crate::rule_analyzer::RuleAnalyzer;

/// HTML 解析器
pub struct HtmlParser;

impl HtmlParser {
    pub fn new() -> Self {
        Self
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

        let document = Html::parse_document(html);

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
                self.extract_from_doc(&document, rule, default_mode)
            } else {
                // 多级链式选择器：逐级下钻（不重复解析 HTML）
                self.extract_chained(&document, &effective_rules, default_mode, last_is_attr)
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

    /// 在已解析的文档上执行选择器并提取内容
    fn extract_from_doc(&self, document: &Html, rule: &str, default_mode: &str) -> Vec<String> {
        let (selector_str, extract_mode, attr_name) = self.parse_last_rule(rule, default_mode);

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

        let Ok(selector) = Selector::parse(selector_str) else {
            return vec![];
        };

        let mut items = Vec::new();
        // 对标 Kotlin：仅属性提取路径去重，text/html 逐元素保留
        let dedup = extract_mode == "attr";
        for elem in document.select(&selector) {
            if let Some(text) = self.extract_from_element(elem, extract_mode, &attr_name) {
                if !text.is_empty() && (!dedup || !items.contains(&text)) {
                    items.push(text);
                }
            }
        }
        items
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

        // 逐级选择元素，使用 ElementRef 避免重复解析
        let first_sel_str = sub_rules[0].trim();
        let Ok(first_selector) = Selector::parse(first_sel_str) else {
            return vec![];
        };

        let mut current_elements: Vec<ElementRef> = document.select(&first_selector).collect();

        // 中间各级（不含首尾）
        for rule in sub_rules.iter().take(last_idx).skip(1) {
            let sel_str = rule.trim();
            if sel_str.is_empty() {
                continue;
            }
            let Ok(selector) = Selector::parse(sel_str) else {
                return vec![];
            };

            let mut next_elements = Vec::new();
            for elem in &current_elements {
                for child in elem.select(&selector) {
                    next_elements.push(child);
                }
            }
            current_elements = next_elements;

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

        let (selector_str, extract_mode, attr_name) = self.parse_last_rule(last_rule, default_mode);

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
        } else if Selector::parse(selector_str).is_err() {
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
            let selector = Selector::parse(selector_str).unwrap();
            for elem in &current_elements {
                for child in elem.select(&selector) {
                    if let Some(text) = self.extract_from_element(child, extract_mode, &attr_name) {
                        if !text.is_empty() && !items.contains(&text) {
                            items.push(text);
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
            "textNodes" => elem.text().collect::<Vec<_>>().join("\n"),
            "ownText" => {
                let t: String = elem.text().collect::<Vec<_>>().join(" ");
                t.trim().to_string()
            }
            "html" => elem.html(),
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

        let document = Html::parse_document(html);
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
            "allText" => Some("all"),
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
        let is_extraction_suffix = !is_tag_name
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
    fn test_get_text_by_id() {
        let parser = HtmlParser::new();
        let result = parser.get_text(SAMPLE_HTML, "#title").unwrap();
        assert_eq!(result, vec!["测试书籍"]);
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
}
