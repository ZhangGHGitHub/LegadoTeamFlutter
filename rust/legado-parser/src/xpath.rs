//! XPath 解析模块（基于 sxd-xpath + sxd-document）
//!
//! 参考 Kotlin `AnalyzeByXPath.kt`，使用 `sxd-xpath` 和 `sxd-document` 实现 XPath 查询。

use legado_core::{LegadoError, LegadoResult};
use sxd_xpath::{Factory, Value as XPathValue};

use crate::rule_analyzer::RuleAnalyzer;

/// XPath 解析器
pub struct XPathParser;

impl XPathParser {
    pub fn new() -> Self {
        Self
    }

    /// 解析 XML/HTML 并使用 XPath 表达式获取字符串列表
    pub fn parse_xpath(&self, xml: &str, xpath_expr: &str) -> LegadoResult<Vec<String>> {
        if xpath_expr.is_empty() {
            return Ok(vec![]);
        }

        // 预处理：如果以 HTML 片段结尾，包装为完整文档
        let xml = self.preprocess_xml(xml);

        // 使用 RuleAnalyzer 拆分 && || %% 规则
        let mut analyzer = RuleAnalyzer::new(xpath_expr, false);
        let rules = analyzer.split_rule(&["&&", "||", "%%"]);
        let elements_type = analyzer.elements_type.to_string();

        if rules.len() == 1 {
            return self.evaluate_xpath(&xml, rules[0]);
        }

        let mut results: Vec<Vec<String>> = Vec::new();

        for rule in &rules {
            let rule = rule.trim();
            if rule.is_empty() {
                continue;
            }

            let temp = self.evaluate_xpath(&xml, rule)?;
            if !temp.is_empty() {
                results.push(temp);
                if elements_type == "||" {
                    break;
                }
            }
        }

        Ok(self.merge_results(results, &elements_type))
    }

    /// 预处理 XML，处理不完整的 HTML 片段
    fn preprocess_xml(&self, xml: &str) -> String {
        let trimmed = xml.trim();

        // 如果已经是 XML 声明开头，直接使用
        if trimmed.starts_with("<?xml") || trimmed.starts_with("<?XML") {
            return xml.to_string();
        }

        // 如果包含 <html 或完整的 DOCTYPE，直接返回
        if trimmed.starts_with("<!DOCTYPE")
            || trimmed.starts_with("<html")
            || trimmed.starts_with("<HTML")
        {
            return xml.to_string();
        }

        // 处理表格片段：参照 Kotlin AnalyzeByXPath 的 strToJXDocument
        let mut processed = trimmed.to_string();
        if processed.ends_with("</td>") {
            processed = format!("<tr>{}</tr>", processed);
        }
        if processed.ends_with("</tr>") || processed.ends_with("</tbody>") {
            processed = format!("<table>{}</table>", processed);
        }

        // 先尝试不包装直接解析（适用于有明确根元素的内容）
        if processed.starts_with('<') && Self::has_single_root(&processed) {
            // 只有一个顶层元素，可以直接解析
            return processed;
        }

        // 包装为根元素以确保可被 XML 解析器处理
        format!("<root>{}</root>", processed)
    }

    /// 检查 XML 字符串是否只有一个顶层元素
    fn has_single_root(xml: &str) -> bool {
        let mut depth: i32 = 0;
        let mut root_count: u32 = 0;
        let mut in_tag = false;
        let mut is_closing = false;
        let mut self_closing = false;
        let mut in_quote = false;
        let mut quote_char = '"';
        let mut last_ch = '\0';

        let mut chars = xml.chars().peekable();
        while let Some(ch) = chars.next() {
            if in_quote {
                if ch == quote_char {
                    in_quote = false;
                }
                last_ch = ch;
                continue;
            }
            match ch {
                '"' | '\'' if in_tag => {
                    in_quote = true;
                    quote_char = ch;
                }
                '<' => {
                    in_tag = true;
                    is_closing = chars.peek() == Some(&'/');
                    self_closing = false;
                    if !is_closing && depth == 0 {
                        root_count += 1;
                        if root_count > 1 {
                            return false;
                        }
                    }
                    // 跳过注释和处理指令
                    if chars.peek() == Some(&'!') || chars.peek() == Some(&'?') {
                        while let Some(&next_ch) = chars.peek() {
                            chars.next();
                            if next_ch == '>' {
                                break;
                            }
                        }
                        in_tag = false;
                        last_ch = '\0';
                        continue;
                    }
                }
                '>' if in_tag => {
                    in_tag = false;
                    if is_closing {
                        depth = (depth - 1).max(0);
                    } else if self_closing || last_ch == '/' {
                        // 自闭合标签，不改变深度
                    } else {
                        depth += 1;
                    }
                }
                '/' if in_tag
                    && chars.peek() == Some(&'>') => {
                        self_closing = true;
                    }
                _ => {}
            }
            last_ch = ch;
        }

        root_count == 1
    }

    /// 执行单个 XPath 查询
    fn evaluate_xpath(&self, xml: &str, xpath_expr: &str) -> LegadoResult<Vec<String>> {
        let xpath_expr = xpath_expr.trim();
        if xpath_expr.is_empty() {
            return Ok(vec![]);
        }

        let package = sxd_document::parser::parse(xml)
            .map_err(|e| LegadoError::Parser(format!("XML parse error: {:?}", e)))?;
        let doc = package.as_document();

        let factory = Factory::new();
        let xpath = factory
            .build(xpath_expr)
            .map_err(|e| LegadoError::Parser(format!("XPath compile error: {:?}", e)))?
            .ok_or_else(|| {
                LegadoError::Parser(format!("Empty XPath expression: {}", xpath_expr))
            })?;

        let context = sxd_xpath::Context::new();
        let value = xpath
            .evaluate(&context, doc.root())
            .map_err(|e| LegadoError::Parser(format!("XPath evaluation error: {:?}", e)))?;

        let results = match value {
            XPathValue::Nodeset(nodeset) => {
                let mut results = Vec::new();
                for node in nodeset.iter() {
                    let text = self.node_to_string(&node);
                    if !text.is_empty() {
                        results.push(text);
                    }
                }
                results
            }
            XPathValue::String(s) => {
                if s.is_empty() {
                    vec![]
                } else {
                    vec![s]
                }
            }
            XPathValue::Number(n) => vec![n.to_string()],
            XPathValue::Boolean(b) => vec![b.to_string()],
        };

        Ok(results)
    }

    /// 将 XPath 节点转换为字符串
    fn node_to_string(&self, node: &sxd_xpath::nodeset::Node) -> String {
        use sxd_xpath::nodeset::Node;
        match node {
            Node::Element(elem) => {
                // 获取元素的文本内容
                let mut text = String::new();
                for child in elem.children() {
                    if let sxd_document::dom::ChildOfElement::Text(t) = child {
                        text.push_str(t.text());
                    }
                }
                text
            }
            Node::Attribute(attr) => attr.value().to_string(),
            Node::Text(text) => text.text().to_string(),
            Node::Comment(comment) => comment.text().to_string(),
            Node::ProcessingInstruction(pi) => pi.target().to_string(),
            Node::Root(root) => {
                let mut text = String::new();
                for child in root.children() {
                    if let sxd_document::dom::ChildOfRoot::Element(elem) = child {
                        text.push_str(&self.element_text_recursive(&elem));
                    }
                }
                text
            }
            _ => String::new(),
        }
    }

    /// 递归获取元素的全部文本
    fn element_text_recursive(&self, elem: &sxd_document::dom::Element) -> String {
        let mut text = String::new();
        for child in elem.children() {
            match child {
                sxd_document::dom::ChildOfElement::Text(t) => {
                    text.push_str(t.text());
                }
                sxd_document::dom::ChildOfElement::Element(e) => {
                    text.push_str(&self.element_text_recursive(&e));
                }
                _ => {}
            }
        }
        text
    }

    /// 合并多组结果
    fn merge_results(&self, results: Vec<Vec<String>>, elements_type: &str) -> Vec<String> {
        if results.is_empty() {
            return vec![];
        }

        if elements_type == "%%" {
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
            let mut merged = Vec::new();
            for group in results {
                merged.extend(group);
            }
            merged
        }
    }
}

impl Default for XPathParser {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_xpath() {
        let parser = XPathParser::new();
        let xml = "<root><item>hello</item><item>world</item></root>";
        let result = parser.parse_xpath(xml, "//item").unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"hello".to_string()));
        assert!(result.contains(&"world".to_string()));
    }

    #[test]
    fn test_table_fragment_tr() {
        let parser = XPathParser::new();
        // 以 </tr> 结尾的片段应被 <table> 包装
        let xml = "<tr><td>a</td><td>b</td></tr>";
        let result = parser.parse_xpath(xml, "//td").unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"a".to_string()));
        assert!(result.contains(&"b".to_string()));
    }

    #[test]
    fn test_table_fragment_td() {
        let parser = XPathParser::new();
        // 以 </td> 结尾的片段应被 <tr> 再 <table> 包装
        let xml = "<td>x</td><td>y</td>";
        let result = parser.parse_xpath(xml, "//td").unwrap();
        // XPath 节点集不保证顺序，只检查结果都包含
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"x".to_string()));
        assert!(result.contains(&"y".to_string()));
    }

    #[test]
    fn test_has_single_root() {
        assert!(XPathParser::has_single_root("<root><child/></root>"));
        assert!(!XPathParser::has_single_root("<a/><b/>"));
        assert!(XPathParser::has_single_root("<div><p>test</p></div>"));
    }

    #[test]
    fn test_combined_rules() {
        let parser = XPathParser::new();
        let xml = "<root><a>1</a><b>2</b></root>";
        let result = parser.parse_xpath(xml, "//a&&//b").unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"1".to_string()));
        assert!(result.contains(&"2".to_string()));
    }

    #[test]
    fn test_or_rules() {
        let parser = XPathParser::new();
        let xml = "<root><a>1</a></root>";
        let result = parser.parse_xpath(xml, "//c||//a").unwrap();
        assert_eq!(result, vec!["1"]);
    }
}
