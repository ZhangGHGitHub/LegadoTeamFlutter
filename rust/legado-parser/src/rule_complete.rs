//! 规则自动补全
//!
//! 移植自 Kotlin RuleComplete.kt (89行)
//! 对 JSOUP/XPath 规则自动添加尾部属性选择器，简化书源规则编写。

/// 规则类型
#[derive(Debug, Clone, PartialEq)]
pub enum CompleteRuleType {
    /// CSS/JSoup 选择器
    JSoup,
    /// XPath 表达式
    XPath,
    /// 正则表达式
    Regex,
    /// JsonPath 表达式
    JsonPath,
    /// 默认（不补全）
    Default,
}

/// 不能补全的模式（含 js/json/{{xx}} 的复杂情况）
const NOT_COMPLETE_PREFIXES: &[&str] = &[":", "##", "{{", "@js:", "<js>", "@Json:", "$."];

/// 判断规则是否需要补全
///
/// 如果规则已经以属性选择器结尾，或包含复杂语法，则不需要补全。
pub fn not_complete(rule: &str) -> bool {
    if rule.is_empty() {
        return true;
    }

    // 不能补全的复杂规则
    for prefix in NOT_COMPLETE_PREFIXES {
        if rule.starts_with(prefix) || rule.contains(prefix) {
            return false;
        }
    }

    // 已有属性选择器结尾
    let trimmed = rule.trim_end();
    if trimmed.ends_with("@text")
        || trimmed.ends_with("@href")
        || trimmed.ends_with("@src")
        || trimmed.ends_with("@html")
        || trimmed.ends_with("@alt")
        || trimmed.ends_with("@value")
        || trimmed.ends_with("@content")
        || trimmed.ends_with("/text()")
        || trimmed.ends_with("text()")
        || trimmed.ends_with("@ownText")
        || trimmed.ends_with("@all")
    {
        return false;
    }

    true
}

/// 补全规则（根据类型自动添加尾部）
///
/// - JSoup: 添加 `@text`
/// - XPath: 添加 `/text()`
/// - JsonPath/Regex/Default: 不补全
pub fn complete_rule(rule: &str, rule_type: CompleteRuleType) -> String {
    if rule.is_empty() {
        return rule.to_string();
    }
    if !not_complete(rule) {
        return rule.to_string();
    }
    match rule_type {
        CompleteRuleType::JSoup => format!("{rule}@text"),
        CompleteRuleType::XPath => format!("{rule}/text()"),
        CompleteRuleType::JsonPath => rule.to_string(),
        CompleteRuleType::Regex => rule.to_string(),
        CompleteRuleType::Default => rule.to_string(),
    }
}

/// 按类型补全（链接）
pub fn complete_link(rule: &str, rule_type: CompleteRuleType) -> String {
    if rule.is_empty() || !not_complete(rule) {
        return rule.to_string();
    }
    match rule_type {
        CompleteRuleType::JSoup => format!("{rule}@href"),
        CompleteRuleType::XPath => format!("{rule}/@href"),
        _ => rule.to_string(),
    }
}

/// 按类型补全（图片 src）
pub fn complete_img(rule: &str, rule_type: CompleteRuleType) -> String {
    if rule.is_empty() || !not_complete(rule) {
        return rule.to_string();
    }
    match rule_type {
        CompleteRuleType::JSoup => format!("{rule}@src"),
        CompleteRuleType::XPath => format!("{rule}/@src"),
        _ => rule.to_string(),
    }
}

/// 修复图片信息规则
///
/// 如果规则选择 img 元素但没有 @src，自动添加。
pub fn fix_img_info(rule: &str) -> String {
    if rule.contains("img") && !rule.contains("@src") && !rule.contains("src") {
        if rule.ends_with("img") {
            format!("{rule}@src")
        } else {
            rule.to_string()
        }
    } else {
        rule.to_string()
    }
}

/// 检测规则类型
pub fn detect_rule_type(rule: &str) -> CompleteRuleType {
    if rule.starts_with("$.") || rule.starts_with("@Json:") {
        CompleteRuleType::JsonPath
    } else if rule.starts_with("//") || rule.starts_with("@XPath:") || rule.contains("::") {
        CompleteRuleType::XPath
    } else if rule.contains('(') && rule.contains(')') && !rule.contains('@') {
        CompleteRuleType::Regex
    } else {
        CompleteRuleType::JSoup
    }
}

/// 自动补全入口（模拟 Kotlin autoComplete）
///
/// - `rule`: 需要补全的规则
/// - `complete_type`: 1=文字, 2=链接, 3=图片
pub fn auto_complete(rule: &str, complete_type: u8) -> String {
    if rule.is_empty() {
        return rule.to_string();
    }

    // 不补全复杂规则
    for prefix in NOT_COMPLETE_PREFIXES {
        if rule.starts_with(prefix) || rule.contains(prefix) {
            return rule.to_string();
        }
    }

    let rule_type = detect_rule_type(rule);

    match complete_type {
        1 => {
            let completed = complete_rule(rule, rule_type.clone());
            fix_img_info(&completed)
        }
        2 => complete_link(rule, rule_type),
        3 => complete_img(rule, rule_type),
        _ => rule.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_not_complete_empty() {
        assert!(not_complete(""));
    }

    #[test]
    fn test_not_complete_already_has_text() {
        assert!(!not_complete("div.title@text"));
        assert!(!not_complete("a@href"));
        assert!(!not_complete("img@src"));
        assert!(!not_complete("div@html"));
    }

    #[test]
    fn test_not_complete_xpath_text() {
        assert!(!not_complete("//div/text()"));
        assert!(!not_complete("//a/text()"));
    }

    #[test]
    fn test_not_complete_complex_rules() {
        // 含 js/json 的不补全
        assert!(!not_complete("@js:java.get()"));
        assert!(!not_complete("$.store.book"));
        assert!(!not_complete("{{variable}}"));
    }

    #[test]
    fn test_not_complete_needs_completion() {
        assert!(not_complete("div.title"));
        assert!(not_complete("a.link"));
        assert!(not_complete("//div[@class='content']"));
    }

    #[test]
    fn test_complete_rule_jsoup() {
        assert_eq!(
            complete_rule("div.title", CompleteRuleType::JSoup),
            "div.title@text"
        );
    }

    #[test]
    fn test_complete_rule_xpath() {
        assert_eq!(
            complete_rule("//div[@class='c']", CompleteRuleType::XPath),
            "//div[@class='c']/text()"
        );
    }

    #[test]
    fn test_complete_rule_no_change() {
        // 已有属性选择器，不变
        assert_eq!(
            complete_rule("div@text", CompleteRuleType::JSoup),
            "div@text"
        );
    }

    #[test]
    fn test_fix_img_info() {
        assert_eq!(fix_img_info("div.img"), "div.img@src");
        assert_eq!(fix_img_info("img@src"), "img@src"); // 已有不修改
        assert_eq!(fix_img_info("div.content"), "div.content"); // 无 img
    }

    #[test]
    fn test_detect_rule_type() {
        assert_eq!(detect_rule_type("$.store"), CompleteRuleType::JsonPath);
        assert_eq!(detect_rule_type("//div"), CompleteRuleType::XPath);
        assert_eq!(detect_rule_type("div.title"), CompleteRuleType::JSoup);
        assert_eq!(detect_rule_type("(\\d+)"), CompleteRuleType::Regex);
    }

    #[test]
    fn test_auto_complete_text() {
        assert_eq!(auto_complete("div.title", 1), "div.title@text");
    }

    #[test]
    fn test_auto_complete_link() {
        assert_eq!(auto_complete("a.link", 2), "a.link@href");
    }

    #[test]
    fn test_auto_complete_img() {
        assert_eq!(auto_complete("div.cover", 3), "div.cover@src");
    }

    #[test]
    fn test_auto_complete_no_change_for_js() {
        assert_eq!(auto_complete("@js:java.get()", 1), "@js:java.get()");
    }
}
