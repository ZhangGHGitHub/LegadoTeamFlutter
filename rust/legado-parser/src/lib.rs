//! legado-parser: HTML/XPath/JsonPath/Regex 规则解析引擎
//!
//! 提供完整的书源规则解析能力，支持多种解析引擎：
//!
//! - [`AnalyzeRule`] — 统一规则解析门面，自动检测规则类型并调度对应解析器
//! - [`AnalyzeUrl`] — URL 模板引擎，支持变量替换/分页/编码管道
//! - [`HtmlParser`] — CSS 选择器解析（基于 scraper）
//! - [`XPathParser`] — XPath 解析（基于 sxd-xpath）
//! - [`JsonPathParser`] — JsonPath 解析
//! - [`RegexEngine`] — 正则表达式引擎
//! - [`RuleAnalyzer`] — 规则语法分析器（拆分/合并/转义）
//!
//! # Examples
//!
//! ```rust
//! use legado_parser::{AnalyzeRule, RuleType};
//!
//! // 创建规则解析器
//! let html = r#"<div class="content"><p>第一章</p></div>"#;
//! let mut rule = AnalyzeRule::new(html.to_string(), "https://example.com".to_string());
//!
//! // 使用 CSS 选择器提取内容
//! let results = rule.get_elements("div.content p").unwrap();
//! assert_eq!(results.len(), 1);
//! ```

pub mod analyze_rule;
pub mod analyze_url;
pub mod html;
pub mod jsonpath;
pub mod regex_engine;
pub mod rule_analyzer;
pub mod rule_complete;
pub mod xpath;

pub use analyze_rule::{AnalyzeRule, JsExecutor, RuleType};
pub use analyze_url::{AnalyzeUrl, RequestMethod, UrlOption};
pub use html::HtmlParser;
pub use jsonpath::JsonPathParser;
pub use regex_engine::RegexEngine;
pub use rule_analyzer::RuleAnalyzer;
pub use xpath::XPathParser;
