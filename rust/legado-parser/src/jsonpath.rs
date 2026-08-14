//! JsonPath 解析模块
//!
//! 参考 Kotlin `AnalyzeByJSonPath.kt`，但对齐原版 Jayway JsonPath 的完整语义：
//! 使用 `jsonpath-rust` 实现过滤器 `[?()]`、递归下降 `$..`、引号键 `$['k']`、
//! 切片步长 `[start:end:step]`、通配符、联合索引与 `length()` 函数。
//!
//! 与原版差异补齐：
//! - `jsonpath-rust` 不解析单个负索引 `[-n]`，此处预处理为等价的切片形态
//!   （`[-1] → [-1:]`、`[-n] → [-n:-(n-1)]`），对齐 Jayway 的倒数取元语义。
//! - 上层 `parse_jsonpath` 保留 Legado 的 `&&`/`||`/`%%` 多规则拆分与合并语义。

use jsonpath_rust::{JsonPath, JsonPathValue};
use legado_core::{LegadoError, LegadoResult};
use serde_json::Value;

use crate::rule_analyzer::RuleAnalyzer;

/// 单个负索引 `[-n]` → 切片形态的预处理正则
static NEG_INDEX_RE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();

/// 将 `[-n]`（单个负索引）改写为 jsonpath-rust 可解析的等价切片
///
/// - `[-1]`  → `[-1:]`（最后一个元素）
/// - `[-n]`  → `[-n:-(n-1)]`（倒数第 n 个元素，n≥2）
/// - `[-0]`  → `[0:1]`（第 0 个元素）
fn preprocess_negative_indices(path: &str) -> String {
    let re = NEG_INDEX_RE.get_or_init(|| regex::Regex::new(r"\[-([0-9]+)\]").unwrap());
    re.replace_all(path, |caps: &regex::Captures| {
        let n: i64 = caps[1].parse().unwrap_or(0);
        match n {
            0 => "[0:1]".to_string(),
            1 => "[-1:]".to_string(),
            n => format!("[-{n}:-{}]", n - 1),
        }
    })
    .into_owned()
}

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
        if path.is_empty() {
            return Ok(vec![]);
        }

        // 处理 {$...} 外层内嵌规则替换（简化版，仅剥单层花括号）
        let path = if path.starts_with("{$") && path.ends_with('}') {
            &path[2..path.len() - 1]
        } else {
            path
        };

        // 整根
        if path == "$" {
            return Ok(vec![self.value_to_string(root)]);
        }

        // 无 $ 前缀的裸字段名 → 补 $.（对齐旧手写「裸路径」语义）
        let full_path = if path.starts_with('$') {
            path.to_string()
        } else {
            format!("$.{path}")
        };

        // 负索引预处理，再交给 jsonpath-rust
        let full_path = preprocess_negative_indices(&full_path);

        // 解析失败按原版语义降级为空结果（不带错误，对齐「无效路径 → 空」）
        let query = match JsonPath::try_from(full_path.as_str()) {
            Ok(q) => q,
            Err(_) => return Ok(vec![]),
        };

        let found = query.find_slice(root);
        Ok(self.jsonpath_values_to_strings(found))
    }

    /// 将 jsonpath-rust 结果展平为字符串列表（对齐原版 getStringList 列表展开语义）
    fn jsonpath_values_to_strings(&self, values: Vec<JsonPathValue<Value>>) -> Vec<String> {
        let mut results = Vec::new();
        for v in values {
            match v {
                JsonPathValue::Slice(val, _) => self.push_flattened(val, &mut results),
                JsonPathValue::NewValue(val) => self.push_flattened(&val, &mut results),
                JsonPathValue::NoValue => {}
            }
        }
        results
    }

    /// 将单个结果值展平（数组展开为逐元素字符串）
    fn push_flattened(&self, val: &Value, results: &mut Vec<String>) {
        match val {
            Value::Array(arr) => {
                for item in arr {
                    results.push(self.value_to_string(item));
                }
            }
            Value::Null => results.push(String::new()),
            other => results.push(self.value_to_string(other)),
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

    #[test]
    fn test_negative_index_second_from_end() {
        let parser = JsonPathParser::new();
        let json = r#"{"items": ["a", "b", "c", "d"]}"#;
        let result = parser.parse_jsonpath(json, "$.items[-2]").unwrap();
        assert_eq!(result, vec!["c"]);
    }

    #[test]
    fn test_filter_comparison() {
        let parser = JsonPathParser::new();
        let json = r#"{"store":{"book":[{"title":"a","price":5},{"title":"b","price":15}]}}"#;
        let result = parser.parse_jsonpath(json, "$.store.book[?(@.price < 10)].title").unwrap();
        assert_eq!(result, vec!["a"]);
    }

    #[test]
    fn test_filter_equality_string() {
        let parser = JsonPathParser::new();
        let json = r#"{"list":[{"name":"foo","v":1},{"name":"bar","v":2}]}"#;
        let result = parser.parse_jsonpath(json, "$.list[?(@.name == 'bar')].v").unwrap();
        assert_eq!(result, vec!["2"]);
    }

    #[test]
    fn test_recursive_descent() {
        let parser = JsonPathParser::new();
        let json = r#"{"a":{"name":"deep"}}"#;
        let result = parser.parse_jsonpath(json, "$..name").unwrap();
        assert_eq!(result, vec!["deep"]);
    }

    #[test]
    fn test_quoted_key() {
        let parser = JsonPathParser::new();
        let json = r#"{"store name":"hello"}"#;
        let result = parser.parse_jsonpath(json, "$['store name']").unwrap();
        assert_eq!(result, vec!["hello"]);
    }

    #[test]
    fn test_slice_step() {
        let parser = JsonPathParser::new();
        let json = r#"{"items":["a","b","c","d","e"]}"#;
        let result = parser.parse_jsonpath(json, "$.items[0:5:2]").unwrap();
        assert_eq!(result, vec!["a", "c", "e"]);
    }

    #[test]
    fn test_union_indices() {
        let parser = JsonPathParser::new();
        let json = r#"{"items":["a","b","c"]}"#;
        let result = parser.parse_jsonpath(json, "$.items[0,2]").unwrap();
        assert_eq!(result, vec!["a", "c"]);
    }
}
