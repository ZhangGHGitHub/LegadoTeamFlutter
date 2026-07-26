//! JSON 工具 API
//!
//! 提供 JSON 处理函数，对应 Kotlin 端 `JsExtensions` 中的 JSON 方法：
//! - jsonPath — JsonPath 查询
//! - jsonGetString — 获取 JSON 字符串字段
//! - toJson — 对象转 JSON 字符串

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_json_utils {
    use jsonpath_rust::{JsonPath, JsonPathValue};
    use serde_json::Value;

    /// JsonPath 查询
    ///
    /// 对应 Kotlin: `jsonPath(json, path)`
    /// 返回查询结果数组（多个匹配项序列化为 JSON 字符串数组）
    pub fn json_path(json_str: &str, path: &str) -> Result<Vec<String>, String> {
        let value: Value =
            serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {}", e))?;
        let query = JsonPath::try_from(path).map_err(|e| format!("JsonPath parse error: {}", e))?;
        let results: Vec<JsonPathValue<Value>> = query.find_slice(&value);
        Ok(results
            .into_iter()
            .map(|jpv| match jpv {
                JsonPathValue::Slice(v, _) => match v {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                },
                JsonPathValue::NewValue(v) => match v {
                    Value::String(s) => s,
                    other => other.to_string(),
                },
                JsonPathValue::NoValue => "null".to_string(),
            })
            .collect())
    }

    /// 获取 JSON 字符串字段
    ///
    /// 对应 Kotlin: `jsonGetString(json, key)`
    /// 从 JSON 对象中获取指定 key 的字符串值
    pub fn json_get_string(json_str: &str, key: &str) -> Result<String, String> {
        let value: Value =
            serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {}", e))?;
        match value.get(key) {
            Some(Value::String(s)) => Ok(s.clone()),
            Some(other) => Ok(other.to_string()),
            None => Err(format!("Key '{}' not found", key)),
        }
    }

    /// 将任意 JSON 值转为 JSON 字符串
    ///
    /// 对应 Kotlin: `GSON.toJson(obj)`
    pub fn to_json(json_str: &str) -> Result<String, String> {
        let value: Value =
            serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {}", e))?;
        serde_json::to_string(&value).map_err(|e| format!("JSON serialize error: {}", e))
    }

    /// 将 JSON 值转为格式化的 JSON 字符串
    pub fn to_json_pretty(json_str: &str) -> Result<String, String> {
        let value: Value =
            serde_json::from_str(json_str).map_err(|e| format!("JSON parse error: {}", e))?;
        serde_json::to_string_pretty(&value).map_err(|e| format!("JSON serialize error: {}", e))
    }
}

#[cfg(feature = "quickjs")]
pub use impl_json_utils::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_json_utils {
    fn not_available() -> String {
        "json_utils not available: build with --features quickjs".to_string()
    }

    pub fn json_path(_json_str: &str, _path: &str) -> Result<Vec<String>, String> {
        Err(not_available())
    }
    pub fn json_get_string(_json_str: &str, _key: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn to_json(_json_str: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn to_json_pretty(_json_str: &str) -> Result<String, String> {
        Err(not_available())
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_json_utils::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    const TEST_JSON: &str = r#"{"name":"Alice","age":30,"address":{"city":"Beijing","zip":"100000"},"tags":["a","b","c"]}"#;

    #[test]
    fn test_json_get_string_existing_key() {
        assert_eq!(json_get_string(TEST_JSON, "name").unwrap(), "Alice");
    }

    #[test]
    fn test_json_get_string_missing_key() {
        assert!(json_get_string(TEST_JSON, "missing").is_err());
    }

    #[test]
    fn test_json_get_string_numeric_field() {
        // numeric field serialized as string
        let result = json_get_string(TEST_JSON, "age").unwrap();
        assert_eq!(result, "30");
    }

    #[test]
    fn test_json_path_root_field() {
        let results = json_path(TEST_JSON, "$.name").unwrap();
        assert_eq!(results, vec!["Alice"]);
    }

    #[test]
    fn test_json_path_nested_field() {
        let results = json_path(TEST_JSON, "$.address.city").unwrap();
        assert_eq!(results, vec!["Beijing"]);
    }

    #[test]
    fn test_json_path_array_elements() {
        let results = json_path(TEST_JSON, "$.tags[*]").unwrap();
        assert_eq!(results, vec!["a", "b", "c"]);
    }

    #[test]
    fn test_to_json_roundtrip() {
        let result = to_json(r#"{"a":1}"#).unwrap();
        assert_eq!(result, r#"{"a":1}"#);
    }

    #[test]
    fn test_to_json_pretty() {
        let result = to_json_pretty(r#"{"a":1}"#).unwrap();
        assert!(result.contains('\n'));
    }

    #[test]
    fn test_invalid_json() {
        assert!(json_get_string("not json", "key").is_err());
    }
}
