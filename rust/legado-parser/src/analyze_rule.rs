//! AnalyzeRule: 统一规则解析门面
//!
//! 参考 Kotlin `AnalyzeRule.kt`，实现统一调度，根据规则前缀或内容类型
//! 自动选择 HTML(CSS)、XPath、JsonPath、正则 解析引擎。

use std::sync::Arc;

use legado_core::LegadoResult;

use crate::html::HtmlParser;
use crate::jsonpath::JsonPathParser;
use crate::regex_engine::RegexEngine;
use crate::rule_analyzer::RuleAnalyzer;
use crate::xpath::XPathParser;

/// JavaScript 执行器 trait
///
/// 由调用方注入具体实现（如 legado-js 的 QuickJS 引擎），
/// 解决 legado-parser 与 legado-js 之间的循环依赖问题。
pub trait JsExecutor: Send + Sync {
    /// 执行 JavaScript 代码，返回结果字符串
    fn execute_js(&self, js_code: &str) -> Result<String, String>;
}

/// 规则类型枚举
#[derive(Debug, Clone, PartialEq)]
pub enum RuleType {
    /// JSoup CSS 选择器
    Css,
    /// XPath
    Xpath,
    /// JsonPath
    Json,
    /// 正则表达式
    Regex,
    /// JavaScript 规则执行
    Js,
    /// 自动检测（根据 @前缀 或内容检测）
    Auto,
}

/// 统一规则解析器
pub struct AnalyzeRule {
    content: String,
    base_url: String,
    html_parser: HtmlParser,
    xpath_parser: XPathParser,
    json_parser: JsonPathParser,
    regex_engine: RegexEngine,
    /// 缓存的内容类型
    cached_content_type: Option<RuleType>,
    /// 内容是否为 JSON 的快速标志
    is_json: bool,
    /// 可选的 JS 执行器（通过回调注入模式解决跨 crate 循环依赖）
    js_executor: Option<Arc<dyn JsExecutor>>,
}

impl AnalyzeRule {
    /// 创建新的规则解析器
    pub fn new(content: String, base_url: String) -> Self {
        let content_type = Self::detect_content_type(&content);
        let is_json = content_type == RuleType::Json;
        Self {
            content,
            base_url,
            html_parser: HtmlParser::new(),
            xpath_parser: XPathParser::new(),
            json_parser: JsonPathParser::new(),
            regex_engine: RegexEngine::new(),
            cached_content_type: Some(content_type),
            is_json,
            js_executor: None,
        }
    }

    /// 创建带有 JS 执行器的规则解析器
    pub fn with_js_executor(
        content: String,
        base_url: String,
        executor: Arc<dyn JsExecutor>,
    ) -> Self {
        let mut rule = Self::new(content, base_url);
        rule.js_executor = Some(executor);
        rule
    }

    /// 设置 JS 执行器
    pub fn set_js_executor(&mut self, executor: Arc<dyn JsExecutor>) {
        self.js_executor = Some(executor);
    }

    /// 获取已注入的 JS 执行器（用于在子解析器间透传）
    pub fn js_executor(&self) -> Option<Arc<dyn JsExecutor>> {
        self.js_executor.clone()
    }

    /// 设置解析内容
    ///
    /// 设置内容后立即检测内容类型并缓存，清除解析器状态。
    pub fn set_content(&mut self, content: String) {
        self.content = content;
        // 检测并缓存内容类型
        let content_type = Self::detect_content_type(&self.content);
        self.is_json = content_type == RuleType::Json;
        self.cached_content_type = Some(content_type);
    }

    /// 内容是否为 JSON
    pub fn is_json(&self) -> bool {
        self.is_json
    }

    /// 获取基础 URL
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// 设置基础 URL
    pub fn set_base_url(&mut self, base_url: String) {
        self.base_url = base_url;
    }

    /// 获取当前内容的引用
    pub fn content(&self) -> &str {
        &self.content
    }

    /// 根据规则获取字符串列表
    ///
    /// 支持:
    /// - `@css:`, `@xpath:`, `@json:`, `@regex:` 前缀指定解析类型
    /// - 自动检测规则类型
    /// - `&&`, `||`, `%%` 组合规则
    /// - `{$.rule}` 内嵌规则替换（JsonPath 场景）
    pub fn get_strings(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        let (rule_type, actual_rule) = Self::resolve_rule_type(rule);

        match rule_type {
            RuleType::Css => self.html_parser.get_text(&self.content, actual_rule),
            RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
            RuleType::Json => self.resolve_json_with_inner(actual_rule),
            RuleType::Regex => self.regex_engine.regex_match(&self.content, actual_rule),
            RuleType::Js => self.execute_js_rule(actual_rule),
            RuleType::Auto => {
                let detected = self.detect_rule_type_for_content(actual_rule);
                match detected {
                    RuleType::Json => self.resolve_json_with_inner(actual_rule),
                    RuleType::Xpath => self.xpath_parser.parse_xpath(&self.content, actual_rule),
                    RuleType::Regex => self.regex_engine.regex_match(&self.content, actual_rule),
                    _ => self.html_parser.get_text(&self.content, actual_rule),
                }
            }
        }
    }

    /// 根据规则获取单个字符串（多个结果用换行连接）
    pub fn get_string(&self, rule: &str) -> LegadoResult<String> {
        let strings = self.get_strings(rule)?;
        if strings.is_empty() {
            return Ok(String::new());
        }
        if strings.len() == 1 {
            return Ok(strings.into_iter().next().unwrap());
        }
        Ok(strings.join("\n"))
    }

    /// 根据规则获取元素 HTML 列表（仅 CSS）
    pub fn get_elements(&self, rule: &str) -> LegadoResult<Vec<String>> {
        if rule.is_empty() {
            return Ok(vec![]);
        }

        let (rule_type, actual_rule) = Self::resolve_rule_type(rule);

        match rule_type {
            RuleType::Css | RuleType::Auto => {
                self.html_parser.get_elements(&self.content, actual_rule)
            }
            _ => self.get_strings(rule),
        }
    }

    /// 获取属性值（仅 CSS）
    pub fn get_attr(&self, rule: &str, attr: &str) -> LegadoResult<Vec<String>> {
        let (_, actual_rule) = Self::resolve_rule_type(rule);
        self.html_parser.get_attr(&self.content, actual_rule, attr)
    }

    /// 正则匹配获取捕获组
    pub fn regex_match_groups(&self, pattern: &str) -> LegadoResult<Vec<Vec<String>>> {
        self.regex_engine.regex_match_groups(&self.content, pattern)
    }

    /// 多级正则匹配
    pub fn regex_chain(&self, patterns: &[&str]) -> LegadoResult<Option<Vec<String>>> {
        self.regex_engine.regex_chain_match(&self.content, patterns)
    }

    // --- 内部方法 ---

    /// 执行 JS 规则
    ///
    /// 如果已注入 JsExecutor，则调用其执行 JS 代码；
    /// 否则降级返回空结果。
    fn execute_js_rule(&self, js_code: &str) -> LegadoResult<Vec<String>> {
        if let Some(executor) = &self.js_executor {
            match executor.execute_js(js_code) {
                Ok(result) => {
                    if result.is_empty() {
                        Ok(vec![])
                    } else {
                        Ok(vec![result])
                    }
                }
                Err(e) => Err(legado_core::LegadoError::JsEngine(format!(
                    "JS 执行失败: {}",
                    e
                ))),
            }
        } else {
            // 无执行器时降级返回空结果
            Ok(vec![])
        }
    }

    /// 解析 JsonPath 规则，支持 `{$.rule}` 内嵌规则替换
    fn resolve_json_with_inner(&self, rule: &str) -> LegadoResult<Vec<String>> {
        // 处理内嵌规则 {$...}
        let processed = self.process_inner_rules(rule)?;
        self.json_parser.parse_jsonpath(&self.content, &processed)
    }

    /// 处理规则中的 `{$.rule}` 内嵌表达式
    ///
    /// 将 `{$.some.path}` 替换为其在当前内容上的解析结果
    fn process_inner_rules(&self, rule: &str) -> LegadoResult<String> {
        if !rule.contains("{$") {
            return Ok(rule.to_string());
        }

        let mut analyzer = RuleAnalyzer::new(rule, true);
        let result = analyzer.inner_rule("{$", 1, 1, |inner_rule| {
            // 递归解析内嵌规则
            self.json_parser
                .parse_jsonpath(&self.content, inner_rule)
                .ok()
                .and_then(|v| {
                    if v.is_empty() {
                        None
                    } else if v.len() == 1 {
                        Some(v[0].clone())
                    } else {
                        Some(v.join("\n"))
                    }
                })
        });

        if result.is_empty() {
            // inner_rule 返回空表示没有成功替换任何内嵌规则
            Ok(rule.to_string())
        } else {
            Ok(result)
        }
    }

    /// 解析规则前缀，返回 (规则类型, 去掉前缀后的规则)
    fn resolve_rule_type(rule: &str) -> (RuleType, &str) {
        let (prefix, actual_rule) = RuleAnalyzer::parse_rule_prefix(rule);
        let rule_type = match prefix {
            "css" => RuleType::Css,
            "xpath" => RuleType::Xpath,
            "json" => RuleType::Json,
            "regex" => RuleType::Regex,
            "js" => RuleType::Js,
            _ => RuleType::Auto,
        };
        (rule_type, actual_rule)
    }

    /// 根据规则特征和当前内容类型自动检测规则类型
    fn detect_rule_type_for_content(&self, rule: &str) -> RuleType {
        let rule = rule.trim();

        // 1. 根据规则自身特征推断
        if rule.starts_with('$') || rule.starts_with("$.") {
            return RuleType::Json;
        }
        if rule.starts_with('/') || rule.starts_with("//") {
            return RuleType::Xpath;
        }
        if rule.contains(r"\d")
            || rule.contains(r"\w")
            || rule.contains(r"\s")
            || (rule.starts_with('(') && rule.contains(')'))
        {
            return RuleType::Regex;
        }

        // 2. 根据缓存的内容类型推断（快速路径）
        if self.is_json {
            // 内容是 JSON，规则看起来不像 CSS 时，使用 JsonPath
            // （以标签名/类名/ID 选择器开头的规则仍按 CSS 处理，
            // 避免 `span.user@text` 等 CSS 规则被误路由到 JsonPath）
            if !rule.contains('<') && !rule.contains('>') && !Self::looks_like_css_selector(rule)
            {
                return RuleType::Json;
            }
        } else if let Some(ref ct) = self.cached_content_type {
            if *ct == RuleType::Xpath {
                return RuleType::Xpath;
            }
        }

        // 默认 CSS
        RuleType::Css
    }

    /// 判断规则是否形似 CSS 选择器（用于 JSON 内容下的规则类型仲裁）
    ///
    /// 仅依据强 CSS 特征判定，避免误伤无 `$` 前缀的 JsonPath 规则（如 `data.list`）：
    /// - 以 `.` 类选择器或 `#` ID 选择器开头
    /// - 含 Legado 取值后缀 `@text` / `@html` / `@href` / `@src`
    fn looks_like_css_selector(rule: &str) -> bool {
        let head = rule.split_whitespace().next().unwrap_or("");
        if matches!(head.chars().next(), Some('.') | Some('#')) {
            return true;
        }
        rule.contains("@text")
            || rule.contains("@html")
            || rule.contains("@href")
            || rule.contains("@src")
    }

    /// 获取缓存的内容类型
    pub fn content_type(&self) -> RuleType {
        if let Some(ref cached) = self.cached_content_type {
            return cached.clone();
        }
        Self::detect_content_type(&self.content)
    }

    /// 根据内容或规则特征自动检测规则类型（静态方法）
    pub fn detect_rule_type(rule: &str) -> RuleType {
        let rule = rule.trim();

        let (prefix, _) = RuleAnalyzer::parse_rule_prefix(rule);
        match prefix {
            "css" => return RuleType::Css,
            "xpath" => return RuleType::Xpath,
            "json" => return RuleType::Json,
            "regex" => return RuleType::Regex,
            "js" => return RuleType::Js,
            _ => {}
        }

        if rule.starts_with('$') || rule.starts_with("$.") {
            return RuleType::Json;
        }
        if rule.starts_with('/') || rule.starts_with("//") {
            return RuleType::Xpath;
        }
        if rule.contains(r"\d")
            || rule.contains(r"\w")
            || rule.contains(r"\s")
            || (rule.starts_with('(') && rule.contains(')'))
        {
            return RuleType::Regex;
        }

        RuleType::Css
    }

    /// 自动检测内容类型
    pub fn detect_content_type(content: &str) -> RuleType {
        let trimmed = content.trim();

        // JSON 内容
        if ((trimmed.starts_with('{') && trimmed.ends_with('}'))
            || (trimmed.starts_with('[') && trimmed.ends_with(']')))
            && serde_json::from_str::<serde_json::Value>(trimmed).is_ok()
        {
            return RuleType::Json;
        }

        // XML/XHTML 内容
        if trimmed.starts_with("<?xml") || trimmed.starts_with("<?XML") {
            return RuleType::Xpath;
        }

        // 默认为 HTML
        RuleType::Css
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_rule_type() {
        assert_eq!(AnalyzeRule::detect_rule_type("@css:div"), RuleType::Css);
        assert_eq!(
            AnalyzeRule::detect_rule_type("@xpath://div"),
            RuleType::Xpath
        );
        assert_eq!(
            AnalyzeRule::detect_rule_type("@json:$.name"),
            RuleType::Json
        );
        assert_eq!(
            AnalyzeRule::detect_rule_type("@regex:\\d+"),
            RuleType::Regex
        );
        assert_eq!(AnalyzeRule::detect_rule_type("$.store"), RuleType::Json);
        assert_eq!(AnalyzeRule::detect_rule_type("//div"), RuleType::Xpath);
        assert_eq!(AnalyzeRule::detect_rule_type("div.content"), RuleType::Css);
    }

    #[test]
    fn test_detect_content_type() {
        assert_eq!(
            AnalyzeRule::detect_content_type(r#"{"key": "value"}"#),
            RuleType::Json
        );
        assert_eq!(
            AnalyzeRule::detect_content_type("<?xml version='1.0'?><root/>"),
            RuleType::Xpath
        );
        assert_eq!(
            AnalyzeRule::detect_content_type("<html><body>test</body></html>"),
            RuleType::Css
        );
    }

    #[test]
    fn test_get_strings_json() {
        let rule = AnalyzeRule::new(
            r#"{"name": "test", "items": [1, 2, 3]}"#.to_string(),
            String::new(),
        );
        let result = rule.get_strings("@json:$.name").unwrap();
        assert_eq!(result, vec!["test"]);
    }

    #[test]
    fn test_get_string() {
        let rule = AnalyzeRule::new(r#"{"title": "hello world"}"#.to_string(), String::new());
        let result = rule.get_string("@json:$.title").unwrap();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_auto_detect_json_content() {
        let rule = AnalyzeRule::new(r#"{"name": "auto_detect_test"}"#.to_string(), String::new());
        // 内容是 JSON，规则以 $ 开头 → 自动使用 JsonPath
        let result = rule.get_strings("$.name").unwrap();
        assert_eq!(result, vec!["auto_detect_test"]);
    }

    #[test]
    fn test_inner_rule_replacement() {
        // 内嵌规则用于动态规则组合：规则中的 {$.path} 被替换为 JSON 中的值
        let rule = AnalyzeRule::new(
            r#"{"key": "name", "name": "张三"}"#.to_string(),
            String::new(),
        );
        // {$.key} 被解析后，内嵌规则 $.key 解析为 "name"
        // 替换后规则变为 "name"，作为 JsonPath 解析为 "张三"
        let result = rule.get_string("{$.key}").unwrap();
        assert_eq!(result, "张三");

        // 测试动态路径组合：{prefix}.name 中的 {prefix} 被替换
        let rule2 = AnalyzeRule::new(
            r#"{"idx": "0", "items": ["apple", "banana"]}"#.to_string(),
            String::new(),
        );
        // $.items[{idx}] 中无 {$} 所以不会触发内嵌替换，但 {$idx} 作为独立规则可以工作
        let result2 = rule2.get_string("@json:$.items[0]").unwrap();
        assert_eq!(result2, "apple");
    }

    #[test]
    fn test_get_strings_html() {
        let html = "<div><p class=\"title\">Hello</p><p class=\"body\">World</p></div>";
        let rule = AnalyzeRule::new(html.to_string(), String::new());
        let result = rule.get_strings("@css:p.title").unwrap();
        assert!(!result.is_empty());
        assert_eq!(result[0], "Hello");
    }

    #[test]
    fn test_set_content_caches_type() {
        let mut rule = AnalyzeRule::new(String::new(), String::new());
        assert!(!rule.is_json());

        rule.set_content(r#"{"key": "value"}"#.to_string());
        assert!(rule.is_json());

        rule.set_content("<html><body>test</body></html>".to_string());
        assert!(!rule.is_json());
    }

    #[test]
    fn test_set_content_clears_and_detects() {
        let mut rule = AnalyzeRule::new(r#"{"old": "data"}"#.to_string(), String::new());
        assert!(rule.is_json());

        // 切换到 XML 内容
        rule.set_content("<?xml version=\"1.0\"?><root><item>test</item></root>".to_string());
        assert!(!rule.is_json());
        // 自动检测应使用 XPath
        let result = rule.get_strings("//item").unwrap();
        assert!(!result.is_empty());
        assert_eq!(result[0], "test");
    }

    // --- JsExecutor 测试 ---

    /// Mock JS 执行器，简单返回固定结果
    struct MockJsExecutor {
        result: String,
    }

    impl JsExecutor for MockJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            Ok(self.result.clone())
        }
    }

    /// 总是失败的 Mock JS 执行器
    struct FailingJsExecutor;

    impl JsExecutor for FailingJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            Err("模拟执行失败".to_string())
        }
    }

    #[test]
    fn test_js_rule_without_executor_returns_empty() {
        let rule = AnalyzeRule::new("some content".to_string(), String::new());
        let result = rule.get_strings("@js:result").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_js_rule_with_executor() {
        let executor = Arc::new(MockJsExecutor {
            result: "执行结果".to_string(),
        });
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result").unwrap();
        assert_eq!(result, vec!["执行结果"]);
    }

    #[test]
    fn test_js_rule_with_empty_result() {
        let executor = Arc::new(MockJsExecutor {
            result: String::new(),
        });
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_js_rule_with_failing_executor() {
        let executor = Arc::new(FailingJsExecutor);
        let rule =
            AnalyzeRule::with_js_executor("some content".to_string(), String::new(), executor);
        let result = rule.get_strings("@js:result");
        assert!(result.is_err());
    }

    #[test]
    fn test_set_js_executor() {
        let mut rule = AnalyzeRule::new("some content".to_string(), String::new());
        // 无执行器时返回空
        assert!(rule.get_strings("@js:x").unwrap().is_empty());

        // 设置执行器后正常工作
        let executor = Arc::new(MockJsExecutor {
            result: "injected".to_string(),
        });
        rule.set_js_executor(executor);
        let result = rule.get_strings("@js:x").unwrap();
        assert_eq!(result, vec!["injected"]);
    }
}
