//! 正则工具 API
//!
//! 提供正则处理函数，对应 Kotlin 端 `JsExtensions` 中的正则方法：
//! - regExp — 正则匹配返回指定组
//! - regExpReplace — 正则替换
//! - regExpFindAll — 查找所有匹配

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_regex_utils {
    use regex::Regex;

    /// 正则匹配，返回指定捕获组内容
    ///
    /// 对应 Kotlin: `regExp(text, pattern, group)`
    /// - group = 0 表示整个匹配
    /// - group > 0 表示对应捕获组
    /// - 若未匹配则返回空字符串
    pub fn reg_exp(text: &str, pattern: &str, group: usize) -> Result<String, String> {
        let re = Regex::new(pattern).map_err(|e| format!("Regex compile error: {}", e))?;
        match re.captures(text) {
            Some(caps) => caps
                .get(group)
                .map(|m| m.as_str().to_string())
                .ok_or_else(|| format!("Group {} not found", group)),
            None => Ok(String::new()),
        }
    }

    /// 正则替换
    ///
    /// 对应 Kotlin: `regExpReplace(text, pattern, replacement)`
    pub fn reg_exp_replace(text: &str, pattern: &str, replacement: &str) -> Result<String, String> {
        let re = Regex::new(pattern).map_err(|e| format!("Regex compile error: {}", e))?;
        Ok(re.replace_all(text, replacement).to_string())
    }

    /// 查找所有匹配（整个匹配）
    ///
    /// 对应 Kotlin: `regExpFindAll(text, pattern)`
    pub fn reg_exp_find_all(text: &str, pattern: &str) -> Result<Vec<String>, String> {
        let re = Regex::new(pattern).map_err(|e| format!("Regex compile error: {}", e))?;
        Ok(re.find_iter(text).map(|m| m.as_str().to_string()).collect())
    }

    /// 查找所有匹配的指定捕获组
    pub fn reg_exp_find_all_group(
        text: &str,
        pattern: &str,
        group: usize,
    ) -> Result<Vec<String>, String> {
        let re = Regex::new(pattern).map_err(|e| format!("Regex compile error: {}", e))?;
        Ok(re
            .captures_iter(text)
            .filter_map(|caps| caps.get(group).map(|m| m.as_str().to_string()))
            .collect())
    }

    /// 检查文本是否匹配正则
    pub fn reg_exp_matches(text: &str, pattern: &str) -> Result<bool, String> {
        let re = Regex::new(pattern).map_err(|e| format!("Regex compile error: {}", e))?;
        Ok(re.is_match(text))
    }
}

#[cfg(feature = "quickjs")]
pub use impl_regex_utils::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_regex_utils {
    fn not_available() -> String {
        "regex_utils not available: build with --features quickjs".to_string()
    }

    pub fn reg_exp(_text: &str, _pattern: &str, _group: usize) -> Result<String, String> {
        Err(not_available())
    }
    pub fn reg_exp_replace(
        _text: &str,
        _pattern: &str,
        _replacement: &str,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn reg_exp_find_all(_text: &str, _pattern: &str) -> Result<Vec<String>, String> {
        Err(not_available())
    }
    pub fn reg_exp_find_all_group(
        _text: &str,
        _pattern: &str,
        _group: usize,
    ) -> Result<Vec<String>, String> {
        Err(not_available())
    }
    pub fn reg_exp_matches(_text: &str, _pattern: &str) -> Result<bool, String> {
        Err(not_available())
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_regex_utils::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    #[test]
    fn test_reg_exp_whole_match() {
        assert_eq!(reg_exp("abc123def", r"\d+", 0).unwrap(), "123");
    }

    #[test]
    fn test_reg_exp_capture_group() {
        let text = "name=Alice,age=30";
        assert_eq!(reg_exp(text, r"name=(\w+)", 1).unwrap(), "Alice");
    }

    #[test]
    fn test_reg_exp_no_match() {
        assert_eq!(reg_exp("hello", r"\d+", 0).unwrap(), "");
    }

    #[test]
    fn test_reg_exp_replace_basic() {
        assert_eq!(
            reg_exp_replace("abc123def456", r"\d+", "X").unwrap(),
            "abcXdefX"
        );
    }

    #[test]
    fn test_reg_exp_replace_with_backreference() {
        assert_eq!(
            reg_exp_replace("hello world", r"(\w+)", "[$1]").unwrap(),
            "[hello] [world]"
        );
    }

    #[test]
    fn test_reg_exp_find_all_basic() {
        let results = reg_exp_find_all("abc123def456ghi789", r"\d+").unwrap();
        assert_eq!(results, vec!["123", "456", "789"]);
    }

    #[test]
    fn test_reg_exp_find_all_empty() {
        let results = reg_exp_find_all("hello", r"\d+").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_reg_exp_find_all_group_basic() {
        let text = "id=1,name=Alice,id=2,name=Bob";
        let results = reg_exp_find_all_group(text, r"name=(\w+)", 1).unwrap();
        assert_eq!(results, vec!["Alice", "Bob"]);
    }

    #[test]
    fn test_reg_exp_matches_true() {
        assert!(reg_exp_matches("hello123", r"\d+").unwrap());
    }

    #[test]
    fn test_reg_exp_matches_false() {
        assert!(!reg_exp_matches("hello", r"\d+").unwrap());
    }

    #[test]
    fn test_invalid_regex() {
        assert!(reg_exp("hello", r"[invalid", 0).is_err());
    }
}
