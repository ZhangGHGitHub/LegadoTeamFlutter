//! JsonPath 解析模块
//!
//! 参考 Kotlin `AnalyzeByJSonPath.kt`，使用 `serde_json` 实现基本的 JSON 路径查询。
//! 支持点号路径（`$.store.book`）、数组索引（`[0]`、`[-1]`）、通配符（`*`）。

use legado_core::{LegadoError, LegadoResult};
use serde_json::Value;

use crate::rule_analyzer::RuleAnalyzer;

/// JsonPath 解析器
pub struct JsonPathParser;

impl JsonPathParser {
    pub fn new() -> Self {
        Self
    }

    /// 解析 JSON 并使用路径表达式获取字符串列表
    pub fn parse_jsonpath(&self, json: &str, path: &str) -> LegadoResult<Vec<String>> {
        if path.is_empty() {
            return Ok(vec![]);
        }

        let value: Value = serde_json::from_str(json)
            .map_err(|e| LegadoError::Parser(format!("JSON parse error: {}", e)))?;

        // 使用 RuleAnalyzer 拆分 && || %% 规则（代码平衡组模式）
        let mut analyzer = RuleAnalyzer::new(path, true);
        let rules = analyzer.split_rule(&["&&", "||", "%%"]);
        let elements_type = analyzer.elements_type.to_string();

        if rules.len() == 1 {
            return self.evaluate_path(&value, rules[0]);
        }

        let mut results: Vec<Vec<String>> = Vec::new();

        for rule in &rules {
            let rule = rule.trim();
            if rule.is_empty() {
                continue;
            }

            let temp = self.evaluate_path(&value, rule)?;
            if !temp.is_empty() {
                results.push(temp);
                if elements_type == "||" {
                    break;
                }
            }
        }

        Ok(self.merge_results(results, &elements_type))
    }

    /// 对单个路径表达式求值
    fn evaluate_path(&self, root: &Value, path: &str) -> LegadoResult<Vec<String>> {
        let path = path.trim();

        // 处理 {$...} 内嵌规则替换（简化版）
        let path = if path.starts_with("{$") {
            // 去掉外层 { }
            let inner = path.trim_start_matches('{').trim_end_matches('}');
            inner
        } else {
            path
        };

        // 去掉开头的 $ 或 $.
        let normalized = if let Some(stripped) = path.strip_prefix("$.") {
            stripped
        } else if path == "$" {
            return Ok(vec![self.value_to_string(root)]);
        } else if let Some(stripped) = path.strip_prefix('$') {
            stripped
        } else {
            path
        };

        let result = self.navigate(root, normalized);
        Ok(self.values_to_strings(&result))
    }

    /// 按路径片段导航 JSON 结构
    fn navigate<'a>(&self, value: &'a Value, path: &str) -> Vec<&'a Value> {
        if path.is_empty() {
            return vec![value];
        }

        let segments = self.split_path_segments(path);
        let mut current = vec![value];

        for segment in &segments {
            let mut next = Vec::new();

            for val in &current {
                self.apply_segment(val, segment, &mut next);
            }

            current = next;
            if current.is_empty() {
                break;
            }
        }

        current
    }

    /// 拆分路径片段，处理 `.` 分隔和 `[...]` 索引
    fn split_path_segments(&self, path: &str) -> Vec<String> {
        let mut segments = Vec::new();
        let mut current = String::new();
        let mut in_bracket = false;
        let chars = path.chars().peekable();

        for ch in chars {
            match ch {
                '[' => {
                    if !current.is_empty() {
                        segments.push(current.clone());
                        current.clear();
                    }
                    in_bracket = true;
                    current.push(ch);
                }
                ']' => {
                    current.push(ch);
                    in_bracket = false;
                    segments.push(current.clone());
                    current.clear();
                }
                '.' if !in_bracket => {
                    if !current.is_empty() {
                        segments.push(current.clone());
                        current.clear();
                    }
                }
                _ => {
                    current.push(ch);
                }
            }
        }

        if !current.is_empty() {
            segments.push(current);
        }

        segments
    }

    /// 对单个值应用路径片段
    fn apply_segment<'a>(&self, value: &'a Value, segment: &str, result: &mut Vec<&'a Value>) {
        if segment.starts_with('[') && segment.ends_with(']') {
            // 数组索引
            let inner = &segment[1..segment.len() - 1].trim();

            if *inner == "*" {
                // 通配符：获取所有元素
                if let Value::Array(arr) = value {
                    for item in arr {
                        result.push(item);
                    }
                }
                return;
            }

            // 处理逗号分隔的多索引
            if inner.contains(',') {
                let indices: Vec<&str> = inner.split(',').collect();
                for idx_str in indices {
                    let idx_str = idx_str.trim();
                    if let Some(v) = self.get_array_index(value, idx_str) {
                        result.push(v);
                    }
                }
                return;
            }

            // 单个索引或范围
            if inner.contains(':') {
                // 范围索引
                if let Value::Array(arr) = value {
                    let parts: Vec<&str> = inner.split(':').collect();
                    let len = arr.len() as i64;

                    let start = if parts.is_empty() || parts[0].is_empty() {
                        0i64
                    } else {
                        self.parse_index(parts[0], len)
                    };

                    let end = if parts.len() < 2 || parts[1].is_empty() {
                        len - 1
                    } else {
                        self.parse_index(parts[1], len)
                    };

                    let start = start.max(0).min(len - 1) as usize;
                    let end = end.max(0).min(len - 1) as usize;

                    if start <= end {
                        for item in arr.iter().take(end + 1).skip(start) {
                            result.push(item);
                        }
                    }
                }
                return;
            }

            if let Some(v) = self.get_array_index(value, inner) {
                result.push(v);
            }
        } else if segment == "*" {
            // 通配符
            match value {
                Value::Object(map) => {
                    for (_, v) in map {
                        result.push(v);
                    }
                }
                Value::Array(arr) => {
                    for item in arr {
                        result.push(item);
                    }
                }
                _ => {}
            }
        } else if segment.contains('[') {
            // 形如 "key[0]" 的混合写法
            if let Some(bracket_pos) = segment.find('[') {
                let key = &segment[..bracket_pos];
                let index_part = &segment[bracket_pos..];

                if let Value::Object(map) = value {
                    if let Some(v) = map.get(key) {
                        self.apply_segment(v, index_part, result);
                    }
                }
            }
        } else {
            // 普通键名
            if let Value::Object(map) = value {
                if let Some(v) = map.get(segment) {
                    result.push(v);
                }
            }
        }
    }

    /// 获取数组索引对应的值
    fn get_array_index<'a>(&self, value: &'a Value, idx_str: &str) -> Option<&'a Value> {
        if let Value::Array(arr) = value {
            let len = arr.len() as i64;
            let idx = self.parse_index(idx_str, len);
            if idx >= 0 && (idx as usize) < arr.len() {
                return Some(&arr[idx as usize]);
            }
        }
        None
    }

    /// 解析索引字符串，支持负数索引
    fn parse_index(&self, s: &str, len: i64) -> i64 {
        let s = s.trim();
        if let Ok(n) = s.parse::<i64>() {
            if n < 0 {
                len + n
            } else {
                n
            }
        } else {
            0
        }
    }

    /// 将 JSON Value 转换为字符串
    fn value_to_string(&self, value: &Value) -> String {
        match value {
            Value::String(s) => s.clone(),
            Value::Null => String::new(),
            Value::Bool(b) => b.to_string(),
            Value::Number(n) => n.to_string(),
            _ => value.to_string(),
        }
    }

    /// 将值列表转换为字符串列表
    fn values_to_strings(&self, values: &[&Value]) -> Vec<String> {
        let mut results = Vec::new();
        for v in values {
            match v {
                Value::Array(arr) => {
                    for item in arr {
                        results.push(self.value_to_string(item));
                    }
                }
                _ => {
                    results.push(self.value_to_string(v));
                }
            }
        }
        results
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

impl Default for JsonPathParser {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_path() {
        let parser = JsonPathParser::new();
        let json = r#"{"name": "test", "value": 42}"#;
        let result = parser.parse_jsonpath(json, "$.name").unwrap();
        assert_eq!(result, vec!["test"]);
    }

    #[test]
    fn test_array_index() {
        let parser = JsonPathParser::new();
        let json = r#"{"items": ["a", "b", "c"]}"#;
        let result = parser.parse_jsonpath(json, "$.items[0]").unwrap();
        assert_eq!(result, vec!["a"]);
    }

    #[test]
    fn test_negative_index() {
        let parser = JsonPathParser::new();
        let json = r#"{"items": ["a", "b", "c"]}"#;
        let result = parser.parse_jsonpath(json, "$.items[-1]").unwrap();
        assert_eq!(result, vec!["c"]);
    }
}
