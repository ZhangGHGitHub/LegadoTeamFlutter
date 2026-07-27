//! 内容处理管线
//! 移植自 Kotlin ContentProcessor.kt (224行)
//!
//! 编排完整的内容后处理管线：
//! 去重复标题 → 段落重排 → 简繁转换 → 替换规则 → 段落缩进

use serde::{Deserialize, Serialize};

/// 处理管线配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessorConfig {
    /// 是否去除重复标题
    pub remove_duplicate_title: bool,
    /// 是否重新分段
    pub re_segment: bool,
    /// 简繁转换: None / "t2s" / "s2t"
    pub chinese_convert: Option<String>,
    /// 是否应用替换规则
    pub apply_replace_rules: bool,
    /// 段落首行缩进（空格数，0=不缩进）
    pub indent_spaces: usize,
    /// 是否去除多余空行
    pub trim_empty_lines: bool,
}

impl Default for ProcessorConfig {
    fn default() -> Self {
        Self {
            remove_duplicate_title: true,
            re_segment: true,
            chinese_convert: None,
            apply_replace_rules: true,
            indent_spaces: 2,
            trim_empty_lines: true,
        }
    }
}

/// 内容处理器
pub struct ContentProcessor {
    config: ProcessorConfig,
}

impl ContentProcessor {
    pub fn new(config: ProcessorConfig) -> Self {
        Self { config }
    }

    pub fn with_defaults() -> Self {
        Self::new(ProcessorConfig::default())
    }

    /// 获取当前配置
    pub fn config(&self) -> &ProcessorConfig {
        &self.config
    }

    /// 执行完整处理管线
    pub fn process(
        &self,
        content: &str,
        chapter_name: &str,
        replace_rules: &[ReplaceRuleEntry],
    ) -> String {
        let mut result = content.to_string();

        // Step 1: 去除重复标题
        if self.config.remove_duplicate_title {
            result = self.remove_duplicate_title(&result, chapter_name);
        }

        // Step 2: 段落重排
        if self.config.re_segment {
            result = self.re_segment(&result, chapter_name);
        }

        // Step 3: 简繁转换
        if let Some(ref direction) = self.config.chinese_convert {
            result = self.chinese_convert(&result, direction);
        }

        // Step 4: 替换规则
        if self.config.apply_replace_rules && !replace_rules.is_empty() {
            result = self.apply_replace_rules(&result, replace_rules);
        }

        // Step 5: 段落缩进
        if self.config.indent_spaces > 0 {
            result = self.add_indent(&result, self.config.indent_spaces);
        }

        // Step 6: 去除多余空行
        if self.config.trim_empty_lines {
            result = self.trim_empty_lines(&result);
        }

        result
    }

    /// 执行处理并返回统计信息
    pub fn process_with_stats(
        &self,
        content: &str,
        chapter_name: &str,
        replace_rules: &[ReplaceRuleEntry],
    ) -> (String, ProcessResult) {
        let original_length = content.len();
        let processed = self.process(content, chapter_name, replace_rules);
        let paragraphs_count = processed.lines().filter(|l| !l.trim().is_empty()).count();
        let rules_applied = if self.config.apply_replace_rules {
            replace_rules.len()
        } else {
            0
        };

        let stats = ProcessResult {
            original_length,
            processed_length: processed.len(),
            paragraphs_count,
            rules_applied,
        };
        (processed, stats)
    }

    /// 去除重复标题（章节内容开头的与标题相同的文本）
    fn remove_duplicate_title(&self, content: &str, chapter_name: &str) -> String {
        if chapter_name.is_empty() {
            return content.to_string();
        }
        let trimmed = content.trim_start();
        if let Some(after) = trimmed.strip_prefix(chapter_name) {
            // 去除标题后紧跟的空白和标点
            let after =
                after.trim_start_matches(|c: char| c.is_whitespace() || c == '\n' || c == '\r');
            after.to_string()
        } else {
            content.to_string()
        }
    }

    /// 段落重排（委托 content_help 模块）
    fn re_segment(&self, content: &str, chapter_name: &str) -> String {
        crate::content_help::re_segment(content, chapter_name)
    }

    /// 简繁转换
    fn chinese_convert(&self, content: &str, direction: &str) -> String {
        match direction {
            "t2s" => Self::traditional_to_simplified(content),
            "s2t" => Self::simplified_to_traditional(content),
            _ => content.to_string(),
        }
    }

    /// 繁体转简体（桩实现，后续集成 chinese_utils）
    fn traditional_to_simplified(content: &str) -> String {
        // TODO: 集成 chinese_utils::t2s
        content.to_string()
    }

    /// 简体转繁体（桩实现，后续集成 chinese_utils）
    fn simplified_to_traditional(content: &str) -> String {
        // TODO: 集成 chinese_utils::s2t
        content.to_string()
    }

    /// 应用替换规则
    fn apply_replace_rules(&self, content: &str, rules: &[ReplaceRuleEntry]) -> String {
        let mut result = content.to_string();
        for rule in rules {
            if rule.pattern.is_empty() {
                continue;
            }
            if rule.is_regex {
                if let Ok(re) = regex::Regex::new(&rule.pattern) {
                    result = re
                        .replace_all(&result, rule.replacement.as_str())
                        .to_string();
                }
            } else {
                result = result.replace(&rule.pattern, &rule.replacement);
            }
        }
        result
    }

    /// 段落首行缩进
    fn add_indent(&self, content: &str, spaces: usize) -> String {
        // 使用全角空格进行缩进（与 Kotlin 版 ReadBookConfig.paragraphIndent 一致）
        let indent: String = " ".repeat(spaces);
        content
            .lines()
            .map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    String::new()
                } else if trimmed.starts_with("  ") || trimmed.starts_with('\t') {
                    // 已有缩进，不重复添加
                    trimmed.to_string()
                } else {
                    format!("{}{}", indent, trimmed)
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// 去除多余空行（连续 3 个以上空行合并为 2 个）
    fn trim_empty_lines(&self, content: &str) -> String {
        let mut result = Vec::new();
        let mut empty_count = 0;

        for line in content.lines() {
            if line.trim().is_empty() {
                empty_count += 1;
                if empty_count <= 2 {
                    result.push(line.to_string());
                }
            } else {
                empty_count = 0;
                result.push(line.to_string());
            }
        }
        result.join("\n")
    }
}

/// 替换规则条目（简化版，供 ContentProcessor 使用）
#[derive(Debug, Clone)]
pub struct ReplaceRuleEntry {
    pub pattern: String,
    pub replacement: String,
    pub is_regex: bool,
}

impl ReplaceRuleEntry {
    /// 从 models::ReplaceRule 转换
    pub fn from_replace_rule(rule: &crate::models::ReplaceRule) -> Self {
        Self {
            pattern: rule.pattern.clone(),
            replacement: rule.replacement.clone(),
            is_regex: rule.is_regex,
        }
    }

    /// 批量从 models::ReplaceRule 转换
    pub fn from_replace_rules(rules: &[crate::models::ReplaceRule]) -> Vec<Self> {
        rules.iter().map(Self::from_replace_rule).collect()
    }
}

/// 处理结果统计
#[derive(Debug, Clone)]
pub struct ProcessResult {
    pub original_length: usize,
    pub processed_length: usize,
    pub paragraphs_count: usize,
    pub rules_applied: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_rules() -> Vec<ReplaceRuleEntry> {
        vec![]
    }

    fn text_rule(pattern: &str, replacement: &str) -> ReplaceRuleEntry {
        ReplaceRuleEntry {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex: false,
        }
    }

    fn regex_rule(pattern: &str, replacement: &str) -> ReplaceRuleEntry {
        ReplaceRuleEntry {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex: true,
        }
    }

    /// 无处理配置（所有步骤关闭）
    fn noop_config() -> ProcessorConfig {
        ProcessorConfig {
            remove_duplicate_title: false,
            re_segment: false,
            chinese_convert: None,
            apply_replace_rules: false,
            indent_spaces: 0,
            trim_empty_lines: false,
        }
    }

    #[test]
    fn test_default_pipeline() {
        let processor = ContentProcessor::with_defaults();
        let content = "第一章 开始\n这是正文内容。\n第二段内容。";
        let result = processor.process(content, "第一章 开始", &no_rules());
        // 标题被去除，段落被缩进
        assert!(!result.starts_with("第一章 开始"));
        assert!(result.contains("这是正文内容。"));
        assert!(result.contains("第二段内容。"));
    }

    #[test]
    fn test_remove_duplicate_title() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一章 测试\n正文内容";
        let result = processor.process(content, "第一章 测试", &no_rules());
        assert_eq!(result, "正文内容");
    }

    #[test]
    fn test_remove_duplicate_title_no_match() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "这是正文内容";
        let result = processor.process(content, "第一章 测试", &no_rules());
        assert_eq!(result, "这是正文内容");
    }

    #[test]
    fn test_remove_duplicate_title_empty_chapter_name() {
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "这是正文内容";
        let result = processor.process(content, "", &no_rules());
        assert_eq!(result, "这是正文内容");
    }

    #[test]
    fn test_replace_rules_text() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("广告", ""), text_rule("test", "测试")];
        let content = "这是广告内容test";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "这是内容测试");
    }

    #[test]
    fn test_replace_rules_regex() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![regex_rule(r"\d+", "NUM")];
        let content = "abc 123 def 456";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "abc NUM def NUM");
    }

    #[test]
    fn test_replace_rules_invalid_regex_skipped() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![regex_rule(r"[invalid", "X")];
        let content = "hello world";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_replace_rules_empty_pattern_skipped() {
        let config = ProcessorConfig {
            apply_replace_rules: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("", "X")];
        let content = "hello";
        let result = processor.process(content, "", &rules);
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_add_indent() {
        let config = ProcessorConfig {
            indent_spaces: 2,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n第二段";
        let result = processor.process(content, "", &no_rules());
        assert!(result.starts_with("  第一段"));
        assert!(result.contains("  第二段"));
    }

    #[test]
    fn test_add_indent_preserves_existing() {
        let config = ProcessorConfig {
            indent_spaces: 2,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "  已有缩进\n无缩进";
        let result = processor.process(content, "", &no_rules());
        // 已有全角空格缩进的不重复添加
        assert!(result.contains("已有缩进"));
        assert!(result.contains("  无缩进"));
    }

    #[test]
    fn test_trim_empty_lines() {
        let config = ProcessorConfig {
            trim_empty_lines: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n\n\n\n\n第二段";
        let result = processor.process(content, "", &no_rules());
        // 连续5个空行应合并为2个
        let empty_count = result.lines().filter(|l| l.trim().is_empty()).count();
        assert_eq!(empty_count, 2);
    }

    #[test]
    fn test_trim_empty_lines_preserves_normal() {
        let config = ProcessorConfig {
            trim_empty_lines: true,
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "第一段\n\n第二段";
        let result = processor.process(content, "", &no_rules());
        // 单个空行保留
        assert_eq!(result, "第一段\n\n第二段");
    }

    #[test]
    fn test_empty_content() {
        let processor = ContentProcessor::with_defaults();
        let result = processor.process("", "章节", &no_rules());
        assert!(result.is_empty() || result.trim().is_empty());
    }

    #[test]
    fn test_config_switches() {
        // 所有开关关闭时内容不变
        let processor = ContentProcessor::new(noop_config());
        let content = "第一章\n正文内容";
        let result = processor.process(content, "第一章", &no_rules());
        assert_eq!(result, content);
    }

    #[test]
    fn test_chinese_convert_stub() {
        let config = ProcessorConfig {
            chinese_convert: Some("t2s".to_string()),
            ..noop_config()
        };
        let processor = ContentProcessor::new(config);
        let content = "測試內容";
        let result = processor.process(content, "", &no_rules());
        // 桩实现返回原文
        assert_eq!(result, "測試內容");
    }

    #[test]
    fn test_process_with_stats() {
        let config = ProcessorConfig {
            re_segment: false,
            ..ProcessorConfig::default()
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("a", "b")];
        let content = "段落一\n段落二\n段落三";
        let (result, stats) = processor.process_with_stats(content, "", &rules);
        assert_eq!(stats.original_length, content.len());
        assert_eq!(stats.processed_length, result.len());
        assert_eq!(stats.paragraphs_count, 3);
        assert_eq!(stats.rules_applied, 1);
    }

    #[test]
    fn test_replace_rule_entry_from_model() {
        let rule = crate::models::ReplaceRule {
            pattern: "hello".to_string(),
            replacement: "world".to_string(),
            is_regex: false,
            ..crate::models::ReplaceRule::default()
        };
        let entry = ReplaceRuleEntry::from_replace_rule(&rule);
        assert_eq!(entry.pattern, "hello");
        assert_eq!(entry.replacement, "world");
        assert!(!entry.is_regex);
    }

    #[test]
    fn test_full_pipeline_order() {
        // 验证管线执行顺序：去标题 → 替换 → 缩进 → 空行
        let config = ProcessorConfig {
            remove_duplicate_title: true,
            re_segment: false,
            chinese_convert: None,
            apply_replace_rules: true,
            indent_spaces: 2,
            trim_empty_lines: true,
        };
        let processor = ContentProcessor::new(config);
        let rules = vec![text_rule("广告", "")];
        let content = "测试章节\n广告正文第一段\n\n\n\n\n正文第二段";
        let result = processor.process(content, "测试章节", &rules);
        // 标题去除
        assert!(!result.contains("测试章节"));
        // 替换生效
        assert!(!result.contains("广告"));
        // 缩进生效
        assert!(result.contains("  正文第一段"));
        // 空行修剪（不超过2个）
        let empty_count = result.lines().filter(|l| l.trim().is_empty()).count();
        assert!(empty_count <= 2);
    }
}
