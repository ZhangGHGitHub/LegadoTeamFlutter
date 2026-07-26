//! 正则表达式引擎模块
//!
//! 参考 Kotlin `AnalyzeByRegex.kt`，使用 `regex` crate 实现正则匹配。

use legado_core::{LegadoError, LegadoResult};
use regex::Regex;

/// 正则引擎
pub struct RegexEngine;

impl RegexEngine {
    pub fn new() -> Self {
        Self
    }

    /// 使用正则表达式匹配文本，返回所有匹配的完整字符串列表
    pub fn regex_match(&self, text: &str, pattern: &str) -> LegadoResult<Vec<String>> {
        if pattern.is_empty() {
            return Ok(vec![]);
        }

        let re = Regex::new(pattern)
            .map_err(|e| LegadoError::Parser(format!("Invalid regex pattern: {}", e)))?;

        let results: Vec<String> = re.find_iter(text).map(|m| m.as_str().to_string()).collect();

        Ok(results)
    }

    /// 使用正则表达式匹配文本，返回所有匹配的捕获组
    /// 每个匹配返回一个 Vec<String>，其中第一个元素是完整匹配，后续是各捕获组
    pub fn regex_match_groups(&self, text: &str, pattern: &str) -> LegadoResult<Vec<Vec<String>>> {
        if pattern.is_empty() {
            return Ok(vec![]);
        }

        let re = Regex::new(pattern)
            .map_err(|e| LegadoError::Parser(format!("Invalid regex pattern: {}", e)))?;

        let mut results = Vec::new();

        for captures in re.captures_iter(text) {
            let mut groups = Vec::new();
            for i in 0..captures.len() {
                groups.push(
                    captures
                        .get(i)
                        .map(|m| m.as_str().to_string())
                        .unwrap_or_default(),
                );
            }
            results.push(groups);
        }

        Ok(results)
    }

    /// 多级正则匹配（参考 AnalyzeByRegex.kt 的 getElement）
    /// 依次应用多个正则模式，最后一个返回捕获组，之前的仅用于筛选文本
    pub fn regex_chain_match(
        &self,
        text: &str,
        patterns: &[&str],
    ) -> LegadoResult<Option<Vec<String>>> {
        if patterns.is_empty() {
            return Ok(None);
        }

        self.regex_chain_inner(text, patterns, 0)
    }

    fn regex_chain_inner(
        &self,
        text: &str,
        patterns: &[&str],
        index: usize,
    ) -> LegadoResult<Option<Vec<String>>> {
        let re = Regex::new(patterns[index])
            .map_err(|e| LegadoError::Parser(format!("Invalid regex pattern: {}", e)))?;

        if index + 1 == patterns.len() {
            // 最后一个模式：返回第一个匹配的所有捕获组
            if let Some(captures) = re.captures(text) {
                let mut groups = Vec::new();
                for i in 0..captures.len() {
                    groups.push(
                        captures
                            .get(i)
                            .map(|m| m.as_str().to_string())
                            .unwrap_or_default(),
                    );
                }
                Ok(Some(groups))
            } else {
                Ok(None)
            }
        } else {
            // 中间模式：收集所有匹配文本，传递给下一级
            let combined: String = re
                .find_iter(text)
                .map(|m| m.as_str())
                .collect::<Vec<_>>()
                .join("");

            if combined.is_empty() {
                Ok(None)
            } else {
                self.regex_chain_inner(&combined, patterns, index + 1)
            }
        }
    }

    /// 多级正则匹配，返回所有结果列表（参考 AnalyzeByRegex.kt 的 getElements）
    pub fn regex_chain_match_all(
        &self,
        text: &str,
        patterns: &[&str],
    ) -> LegadoResult<Vec<Vec<String>>> {
        if patterns.is_empty() {
            return Ok(vec![]);
        }

        self.regex_chain_all_inner(text, patterns, 0)
    }

    fn regex_chain_all_inner(
        &self,
        text: &str,
        patterns: &[&str],
        index: usize,
    ) -> LegadoResult<Vec<Vec<String>>> {
        let re = Regex::new(patterns[index])
            .map_err(|e| LegadoError::Parser(format!("Invalid regex pattern: {}", e)))?;

        if index + 1 == patterns.len() {
            // 最后一个模式：返回所有匹配的捕获组
            let mut results = Vec::new();
            for captures in re.captures_iter(text) {
                let mut groups = Vec::new();
                for i in 0..captures.len() {
                    groups.push(
                        captures
                            .get(i)
                            .map(|m| m.as_str().to_string())
                            .unwrap_or_default(),
                    );
                }
                results.push(groups);
            }
            Ok(results)
        } else {
            let combined: String = re
                .find_iter(text)
                .map(|m| m.as_str())
                .collect::<Vec<_>>()
                .join("");

            if combined.is_empty() {
                Ok(vec![])
            } else {
                self.regex_chain_all_inner(&combined, patterns, index + 1)
            }
        }
    }
}

impl Default for RegexEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_regex_match() {
        let engine = RegexEngine::new();
        let result = engine.regex_match("hello world 123", r"\d+").unwrap();
        assert_eq!(result, vec!["123"]);
    }

    #[test]
    fn test_regex_match_groups() {
        let engine = RegexEngine::new();
        let result = engine
            .regex_match_groups("2024-01-15", r"(\d{4})-(\d{2})-(\d{2})")
            .unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], vec!["2024-01-15", "2024", "01", "15"]);
    }

    #[test]
    fn test_regex_chain() {
        let engine = RegexEngine::new();
        let text = "<a>hello</a><a>world</a>";
        let result = engine
            .regex_chain_match(text, &[r"<a>(.*?)</a>", r"(hello)"])
            .unwrap();
        assert!(result.is_some());
        let groups = result.unwrap();
        assert_eq!(groups[1], "hello");
    }
}
