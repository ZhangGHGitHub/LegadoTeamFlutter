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

            let items = if sub_rules.len() <= 1 {
                // 单级：直接在文档上选择
                self.extract_from_doc(&document, rule, default_mode)
            } else {
                // 多级链式选择器：逐级下钻（不重复解析 HTML）
                self.extract_chained(&document, &sub_rules, default_mode)
            };

            if !items.is_empty() {
                results.push(items);
                if elements_type == "||" {
                    break;
                }
            }
        }

        Ok(self.merge_results(results, &elements_type))
    }

    /// 在已解析的文档上执行选择器并提取内容
    fn extract_from_doc(&self, document: &Html, rule: &str, default_mode: &str) -> Vec<String> {
        let (selector_str, extract_mode, attr_name) = self.parse_last_rule(rule, default_mode);
        let Ok(selector) = Selector::parse(selector_str) else {
            return vec![];
        };

        let mut items = Vec::new();
        for elem in document.select(&selector) {
            if let Some(text) = self.extract_from_element(elem, extract_mode, &attr_name) {
                if !text.is_empty() && !items.contains(&text) {
                    items.push(text);
                }
            }
        }
        items
    }

    /// 链式选择器：在单个解析文档上逐级下钻
    fn extract_chained(
        &self,
        document: &Html,
        sub_rules: &[&str],
        default_mode: &str,
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
        let (selector_str, extract_mode, attr_name) = self.parse_last_rule(last_rule, default_mode);

        let mut items = Vec::new();

        if selector_str.is_empty() {
            // 最后一级没有选择器，直接从当前元素提取
            for elem in &current_elements {
                if let Some(text) = self.extract_from_element(*elem, extract_mode, &attr_name) {
                    if !text.is_empty() && !items.contains(&text) {
                        items.push(text);
                    }
                }
            }
        } else {
            let Ok(selector) = Selector::parse(selector_str) else {
                return items;
            };
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
            (rule, default_mode, String::new())
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
}

impl Default for HtmlParser {
    fn default() -> Self {
        Self::new()
    }
}
