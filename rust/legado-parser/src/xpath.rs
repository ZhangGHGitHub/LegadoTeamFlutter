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
                '/' if in_tag && chars.peek() == Some(&'>') => {
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

        // 先按严格 XML 解析；真实 HTML 页面（无引号属性、未闭合 void 标签等）
        // 会解析失败，回退 html5ever 宽容解析→XHTML（对标原版
        // AnalyzeByXPath.strToJXDocument 的 Jsoup 宽容解析语义）
        let package = match sxd_document::parser::parse(xml) {
            Ok(p) => p,
            Err(primary_err) => {
                let xhtml = Self::html_to_xhtml(xml)?;
                sxd_document::parser::parse(&xhtml).map_err(|e| {
                    LegadoError::Parser(format!(
                        "XML parse error: {:?} (HTML fallback: {:?})",
                        primary_err, e
                    ))
                })?
            }
        };
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
                // 按文档序返回（对标原版 JXDocument 的文档顺序，
                // 保证 bookList 等列表结果顺序稳定）
                for node in nodeset.document_order() {
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
    ///
    /// 元素节点序列化为外层标记（对标原版 AnalyzeByXPath getElements 返回
    /// JXNode 元素、后续规则在其上继续解析的语义），供 bookList 等
    /// 子规则二次解析；文本/属性节点返回其值。
    fn node_to_string(&self, node: &sxd_xpath::nodeset::Node) -> String {
        use sxd_xpath::nodeset::Node;
        match node {
            Node::Element(elem) => Self::element_outer_xml(elem),
            Node::Attribute(attr) => attr.value().to_string(),
            Node::Text(text) => text.text().to_string(),
            Node::Comment(comment) => comment.text().to_string(),
            Node::ProcessingInstruction(pi) => pi.target().to_string(),
            Node::Root(root) => {
                let mut out = String::new();
                for child in root.children() {
                    if let sxd_document::dom::ChildOfRoot::Element(elem) = child {
                        out.push_str(&Self::element_outer_xml(&elem));
                    }
                }
                out
            }
            _ => String::new(),
        }
    }

    /// 将 sxd 元素序列化为外层 XML 标记
    fn element_outer_xml(elem: &sxd_document::dom::Element) -> String {
        let mut out = String::new();
        Self::write_element_xml(&mut out, elem);
        out
    }

    fn write_element_xml(out: &mut String, elem: &sxd_document::dom::Element) {
        let name = elem.name().local_part();
        out.push('<');
        out.push_str(name);
        for attr in elem.attributes() {
            out.push(' ');
            out.push_str(attr.name().local_part());
            out.push_str("=\"");
            out.push_str(&Self::escape_xml_text(attr.value()));
            out.push('"');
        }
        out.push('>');
        for child in elem.children() {
            match child {
                sxd_document::dom::ChildOfElement::Text(t) => {
                    out.push_str(&Self::escape_xml_text(t.text()));
                }
                sxd_document::dom::ChildOfElement::Element(e) => {
                    Self::write_element_xml(out, &e);
                }
                _ => {}
            }
        }
        out.push_str("</");
        out.push_str(name);
        out.push('>');
    }

    /// XML 文本/属性值转义
    fn escape_xml_text(text: &str) -> String {
        text.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
    }

    /// HTML 回退：html5ever 宽容解析（对标原版 Jsoup）后序列化为良构 XHTML，
    /// 供 sxd-xpath 求值。跳过 doctype/注释/PI，void 元素自闭合，
    /// script/style 文本按 CDATA 包裹。
    fn html_to_xhtml(html: &str) -> LegadoResult<String> {
        let document = scraper::Html::parse_document(html);
        let mut out = String::new();
        Self::write_node_xhtml(&mut out, &document.tree.root(), false);
        if out.trim().is_empty() {
            return Err(LegadoError::Parser(
                "HTML→XHTML 转换结果为空".into(),
            ));
        }
        Ok(out)
    }

    fn write_node_xhtml(
        out: &mut String,
        node: &ego_tree::NodeRef<'_, scraper::node::Node>,
        raw_text: bool,
    ) {
        match node.value() {
            // 文档根节点：递归子节点
            scraper::node::Node::Document => {
                for child in node.children() {
                    Self::write_node_xhtml(out, &child, false);
                }
            }
            scraper::node::Node::Element(elem) => {
                let name = elem.name();
                out.push('<');
                out.push_str(name);
                for (qname, value) in elem.attrs.iter() {
                    // [UI-fix v2.0.9 | 2026-08-10] 跳过 xmlns / xmlns:* 声明：
                    // 页面自带 xmlns 若被原样输出，sxd-document 解析后全部元素
                    // 进入该命名空间，无前缀 XPath（//dd、//a 等）全部失配
                    //（仅 //* 与谓词字符串比较可命中）——实测思兔 sto66 等
                    // 声明 xmlns 的页面目录/正文/详情规则整体失效 — Reasonix
                    if qname.local.as_ref() == "xmlns"
                        || qname.prefix.as_ref().map(|p| p.as_ref()) == Some("xmlns")
                    {
                        continue;
                    }
                    out.push(' ');
                    out.push_str(&qname.local);
                    out.push_str("=\"");
                    out.push_str(&Self::escape_xml_text(value));
                    out.push('"');
                }
                if Self::is_void_element(name) {
                    out.push_str("/>");
                    return;
                }
                out.push('>');
                let raw = matches!(name, "script" | "style");
                for child in node.children() {
                    Self::write_node_xhtml(out, &child, raw);
                }
                out.push_str("</");
                out.push_str(name);
                out.push('>');
            }
            scraper::node::Node::Text(text) => {
                let t: &str = text;
                if raw_text {
                    if t.contains('<') || t.contains('&') {
                        out.push_str("<![CDATA[");
                        out.push_str(&t.replace("]]>", "]]]]><![CDATA[>"));
                        out.push_str("]]>");
                    } else {
                        out.push_str(t);
                    }
                } else {
                    out.push_str(&Self::escape_xml_text(t));
                }
            }
            // doctype/注释/PI 跳过，保证输出为良构 XML
            _ => {}
        }
    }

    /// HTML void 元素（无闭合标签，XHTML 序列化时自闭合）
    fn is_void_element(name: &str) -> bool {
        matches!(
            name,
            "area"
                | "base"
                | "br"
                | "col"
                | "embed"
                | "hr"
                | "img"
                | "input"
                | "link"
                | "meta"
                | "param"
                | "source"
                | "track"
                | "wbr"
        )
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
        // 元素节点返回外层标记（供子规则二次解析，对标原版 getElements）
        assert!(result.contains(&"<item>hello</item>".to_string()));
        assert!(result.contains(&"<item>world</item>".to_string()));
        // 文本节点仍返回文本值
        let texts = parser.parse_xpath(xml, "//item/text()").unwrap();
        assert!(texts.contains(&"hello".to_string()));
        assert!(texts.contains(&"world".to_string()));
    }

    #[test]
    fn test_table_fragment_tr() {
        let parser = XPathParser::new();
        // 以 </tr> 结尾的片段应被 <table> 包装
        let xml = "<tr><td>a</td><td>b</td></tr>";
        let result = parser.parse_xpath(xml, "//td").unwrap();
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"<td>a</td>".to_string()));
        assert!(result.contains(&"<td>b</td>".to_string()));
    }

    #[test]
    fn test_table_fragment_td() {
        let parser = XPathParser::new();
        // 以 </td> 结尾的片段应被 <tr> 再 <table> 包装
        let xml = "<td>x</td><td>y</td>";
        let result = parser.parse_xpath(xml, "//td").unwrap();
        // 结果按文档序返回
        assert_eq!(result.len(), 2);
        assert!(result.contains(&"<td>x</td>".to_string()));
        assert!(result.contains(&"<td>y</td>".to_string()));
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
        assert!(result.contains(&"<a>1</a>".to_string()));
        assert!(result.contains(&"<b>2</b>".to_string()));
    }

    #[test]
    fn test_xmlns_declaration_does_not_break_prefixed_xpath() {
        // [UI-fix v2.0.9 | 2026-08-10] 回归：页面自带 xmlns 声明时，
        // HTML→XHTML 回退必须跳过 xmlns 属性，否则 sxd-document 将全部
        // 元素归入该命名空间，无前缀 XPath（//dd、//a 等）全部失配，
        // 仅 //* 与谓词字符串比较可命中 —— 实测思兔 sto66 等声明 xmlns
        // 的页面目录/正文/详情规则整体失效 — Reasonix
        let parser = XPathParser::new();
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"zh-CN\">\
            <head><meta charset=\"utf-8\"></head>\
            <body><div id=\"allchapter\">\
            <dd data-num=\"1\"><a href=\"/chapter/1.html\">第一章</a></dd>\
            <dd data-num=\"2\"><a href=\"/chapter/2.html\">第二章</a></dd>\
            </div></body></html>";
        // 严格 XML 解析失败（<meta> 无闭合 → HTML5 宽容标签）→ html5ever 回退路径
        let result = parser.parse_xpath(html, "//*[@id='allchapter']//dd[a]//a/@href").unwrap();
        assert_eq!(result.len(), 2, "带 xmlns 页面的无前缀 XPath 应正常匹配");
        assert!(result.contains(&"/chapter/1.html".to_string()));
        assert!(result.contains(&"/chapter/2.html".to_string()));
        let dds = parser.parse_xpath(html, "//*[@id='allchapter']//dd").unwrap();
        assert_eq!(dds.len(), 2);
    }

    #[test]
    fn test_or_rules() {
        let parser = XPathParser::new();
        let xml = "<root><a>1</a></root>";
        let result = parser.parse_xpath(xml, "//c||//a").unwrap();
        assert_eq!(result, vec!["<a>1</a>"]);
    }

    /// 真实 HTML 页面（无引号属性、未闭合 void 标签、脚本）严格 XML 解析必败，
    /// 应回退 html5ever 宽容解析→XHTML 后正常求值（对标原版 Jsoup+JXDocument）。
    #[test]
    fn test_html_document_xpath_fallback() {
        let parser = XPathParser::new();
        let html = "<!DOCTYPE html>\n<html lang=\"zh-CN\"><head>\
            <meta charset=\"utf-8\">\
            <link rel=\"icon\" href=\"/favicon.ico\">\
            <script>if (a < b && c > d) { var x = 1; }</script>\
            </head><body>\
            <div class=header-left><a href=\"/\">首页</a></div>\
            <div class=\"bookbox\"><h2 class=\"bookname\"><a href=\"/book/a.html\">书名A</a></h2>\
            <div class=\"author\">作者：甲</div></div>\
            <div class=\"bookbox\"><h2 class=\"bookname\"><a href=\"/book/b.html\">书名B</a></h2>\
            <div class=\"author\">作者：乙</div></div>\
            </body></html>";
        let list = parser
            .parse_xpath(html, "//*[contains(@class, 'bookbox')]")
            .unwrap();
        assert_eq!(list.len(), 2, "bookbox 列表应解析出 2 条: {:?}", list);
        assert!(list[0].contains("bookname"));

        // 子规则相对 XPath：在元素外层标记上二次解析
        let name = parser
            .parse_xpath(
                &list[0],
                ".//*[contains(@class, 'bookname')]/a/text()",
            )
            .unwrap();
        assert_eq!(name.len(), 1);
        assert!(
            name[0] == "书名A" || name[0] == "书名B",
            "书名应为书名A/书名B，实际: {:?}",
            name
        );

        // 属性提取
        let href = parser
            .parse_xpath(
                &list[0],
                ".//*[contains(@class, 'bookname')]/a/@href",
            )
            .unwrap();
        assert_eq!(href.len(), 1);
        assert!(href[0].starts_with("/book/"));
    }

    /// AnalyzeRule 全链路：XPath bookList → 元素外层标记 → 子规则提取字段
    #[test]
    fn test_analyze_rule_xpath_booklist_pipeline() {
        use crate::AnalyzeRule;
        let html = "<html><body>\
            <div class=\"bookbox\"><h2 class=\"bookname\"><a href=\"/book/x.html\">测试书名</a></h2>\
            <div class=\"author\">作者：测试作者</div>\
            <div class=\"update\"><span>简介：</span>这是简介</div></div>\
            </body></html>";
        let analyzer = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
        let elements = analyzer
            .get_elements("//*[contains(@class, 'bookbox')]")
            .unwrap();
        assert_eq!(elements.len(), 1);

        let item = AnalyzeRule::new(elements[0].clone(), "https://example.com".to_string());
        let name = item
            .get_string("@XPath:.//*[contains(@class, 'bookname')]/a/text()")
            .unwrap();
        assert_eq!(name, "测试书名");
        let url = item
            .get_string("@XPath:.//*[contains(@class, 'bookname')]/a/@href")
            .unwrap();
        assert_eq!(url, "/book/x.html");
    }
}
