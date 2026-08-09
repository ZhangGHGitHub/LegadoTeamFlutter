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
    use legado_core::regex_safe::compile_regex_safe;

    /// 编译失败统一错误描述（宿主层会把 Err 降级为空串/错误文本交给 JS 侧消化，
    /// 对齐原版 Kotlin JsExtensions 行为；绝不 panic）
    fn compile_err(pattern: &str) -> String {
        let head: String = pattern.chars().take(64).collect();
        format!("Regex compile error: invalid or over-limit pattern: {}", head)
    }

    /// 正则匹配，返回指定捕获组内容
    ///
    /// 对应 Kotlin: `regExp(text, pattern, group)`
    /// - group = 0 表示整个匹配
    /// - group > 0 表示对应捕获组
    /// - 若未匹配则返回空字符串
    ///
    /// 动态 pattern 编译一律走统一安全入口 [`compile_regex_safe`]
    /// （1KB 上限 + nest_limit + 全局缓存/负缓存），禁止裸 Regex::new。
    pub fn reg_exp(text: &str, pattern: &str, group: usize) -> Result<String, String> {
        let re = compile_regex_safe(pattern).ok_or_else(|| compile_err(pattern))?;
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
        let re = compile_regex_safe(pattern).ok_or_else(|| compile_err(pattern))?;
        Ok(re.replace_all(text, replacement).to_string())
    }

    /// 查找所有匹配（整个匹配）
    ///
    /// 对应 Kotlin: `regExpFindAll(text, pattern)`
    pub fn reg_exp_find_all(text: &str, pattern: &str) -> Result<Vec<String>, String> {
        let re = compile_regex_safe(pattern).ok_or_else(|| compile_err(pattern))?;
        Ok(re.find_iter(text).map(|m| m.as_str().to_string()).collect())
    }

    /// 查找所有匹配的指定捕获组
    pub fn reg_exp_find_all_group(
        text: &str,
        pattern: &str,
        group: usize,
    ) -> Result<Vec<String>, String> {
        let re = compile_regex_safe(pattern).ok_or_else(|| compile_err(pattern))?;
        Ok(re
            .captures_iter(text)
            .filter_map(|caps| caps.get(group).map(|m| m.as_str().to_string()))
            .collect())
    }

    /// 检查文本是否匹配正则
    pub fn reg_exp_matches(text: &str, pattern: &str) -> Result<bool, String> {
        let re = compile_regex_safe(pattern).ok_or_else(|| compile_err(pattern))?;
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

    /// 深嵌套字符类病态 pattern（`[a-[b-[c-...]]]` 200 层）：
    /// regExp 宿主 API 安全降级返回 Err（由 JS 侧消化为空串），绝不 panic/崩溃
    fn nested_char_class_pattern() -> String {
        let mut p = String::from("z");
        for _ in 0..200 {
            p = format!("[a-[{}]]", p);
        }
        p
    }

    #[test]
    fn test_reg_exp_pathological_pattern_degrades() {
        let p = nested_char_class_pattern();
        assert!(reg_exp("abc", &p, 0).is_err(), "病态 pattern 应降级为 Err");
        assert!(
            reg_exp_replace("abc", &p, "x").is_err(),
            "病态 pattern 应降级为 Err"
        );
        assert!(
            reg_exp_find_all("abc", &p).is_err(),
            "病态 pattern 应降级为 Err"
        );
    }

    #[test]
    fn test_reg_exp_overlong_pattern_degrades() {
        // 超 1KB 上限 pattern：直接拒绝，不进入编译
        let p = "a|".repeat(600);
        assert!(reg_exp("abc", &p, 0).is_err());
        assert!(reg_exp_matches("abc", &p).is_err());
    }

    #[test]
    fn test_reg_exp_cache_hit_behavior_unchanged() {
        // 同一 pattern 反复调用：缓存命中，行为不变
        for _ in 0..3 {
            assert_eq!(reg_exp("abc123", r"\d+", 0).unwrap(), "123");
        }
    }
}
