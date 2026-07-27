//! JS 源数据序列化/反序列化
//! 移植自 Kotlin JsSourceMarshaller.kt (160行)

use serde_json::Value;

/// 将 JS 引擎返回的原始 JSON 字符串转换为标准实体
pub struct JsSourceMarshaller;

impl JsSourceMarshaller {
    /// 解析搜索结果为标准格式
    ///
    /// 参考 Kotlin `parseSearchBooks`：
    /// - 输入必须是 JSON 数组
    /// - 丢弃缺少 name/bookUrl 的条目
    pub fn marshal_search(raw_json: &str) -> Result<Vec<Value>, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        let array = parsed
            .as_array()
            .ok_or_else(|| "search/explore 返回值不是数组".to_string())?;
        let results: Vec<Value> = array
            .iter()
            .filter(|item| {
                item.is_object()
                    && item
                        .get("name")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
                    && item
                        .get("bookUrl")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
            })
            .cloned()
            .collect();
        Ok(results)
    }

    /// 解析书籍详情
    ///
    /// 参考 Kotlin `mergeBookInfo`：输入必须是 JSON 对象
    pub fn marshal_book_info(raw_json: &str) -> Result<Value, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Err("getBookInfo 返回值为空".to_string());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        if !parsed.is_object() {
            return Err("getBookInfo 返回值不是对象".to_string());
        }
        Ok(parsed)
    }

    /// 解析章节列表
    ///
    /// 参考 Kotlin `parseChapters`：
    /// - 输入必须是 JSON 数组
    /// - 丢弃缺少 title/url 的章节
    pub fn marshal_chapters(raw_json: &str) -> Result<Vec<Value>, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        let array = parsed
            .as_array()
            .ok_or_else(|| "getChapters 返回值不是数组".to_string())?;
        let results: Vec<Value> = array
            .iter()
            .filter(|item| {
                item.is_object()
                    && item
                        .get("title")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
                    && item
                        .get("url")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
            })
            .cloned()
            .collect();
        Ok(results)
    }

    /// 解析正文内容（去除首尾空白，保留原始 HTML/文本）
    pub fn marshal_content(raw_html: &str) -> String {
        raw_html.trim().to_string()
    }

    /// 通用 JSON 字段提取
    pub fn extract_field(json: &Value, field: &str) -> Option<String> {
        json.get(field).and_then(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            Value::Bool(b) => Some(b.to_string()),
            Value::Null => None,
            _ => Some(v.to_string()),
        })
    }

    /// 验证书籍类型是否合法（参考 Kotlin validateBookType）
    ///
    /// type == 0 或含非法位时返回 None
    pub fn validate_book_type(raw: i32) -> Option<i32> {
        // BookType.allBookType 掩码（text=1, audio=2, image=4, file=8）
        const ALL_BOOK_TYPE: i32 = 0x0F;
        if raw == 0 || (raw & !ALL_BOOK_TYPE) != 0 {
            return None;
        }
        Some(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_marshal_search_valid() {
        let json =
            r#"[{"name":"书A","bookUrl":"http://a.com"},{"name":"书B","bookUrl":"http://b.com"}]"#;
        let results = JsSourceMarshaller::marshal_search(json).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_marshal_search_filters_invalid_entries() {
        let json = r#"[{"name":"","bookUrl":"http://a.com"},{"name":"有效","bookUrl":"http://b.com"},{"name":"无URL","bookUrl":""}]"#;
        let results = JsSourceMarshaller::marshal_search(json).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["name"], "有效");
    }

    #[test]
    fn test_marshal_search_not_array() {
        let json = r#"{"name":"不是数组"}"#;
        let result = JsSourceMarshaller::marshal_search(json);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不是数组"));
    }

    #[test]
    fn test_marshal_search_empty() {
        let results = JsSourceMarshaller::marshal_search("").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_marshal_book_info_valid() {
        let json = r#"{"name":"测试","author":"作者","intro":"简介"}"#;
        let info = JsSourceMarshaller::marshal_book_info(json).unwrap();
        assert_eq!(info["name"], "测试");
        assert_eq!(info["author"], "作者");
    }

    #[test]
    fn test_marshal_book_info_not_object() {
        let json = r#"[1,2,3]"#;
        let result = JsSourceMarshaller::marshal_book_info(json);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不是对象"));
    }

    #[test]
    fn test_marshal_chapters_valid() {
        let json = r#"[{"title":"第一章","url":"http://a.com/1"},{"title":"第二章","url":"http://a.com/2"}]"#;
        let chapters = JsSourceMarshaller::marshal_chapters(json).unwrap();
        assert_eq!(chapters.len(), 2);
    }

    #[test]
    fn test_marshal_chapters_filters_invalid() {
        let json = r#"[{"title":"","url":"http://a.com"},{"title":"有效","url":"http://b.com"}]"#;
        let chapters = JsSourceMarshaller::marshal_chapters(json).unwrap();
        assert_eq!(chapters.len(), 1);
    }

    #[test]
    fn test_marshal_content() {
        assert_eq!(JsSourceMarshaller::marshal_content("  hello  "), "hello");
        assert_eq!(JsSourceMarshaller::marshal_content(""), "");
    }

    #[test]
    fn test_extract_field() {
        let obj = json!({"name": "测试", "count": 42, "active": true, "null_field": null});
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "name"),
            Some("测试".to_string())
        );
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "count"),
            Some("42".to_string())
        );
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "active"),
            Some("true".to_string())
        );
        assert_eq!(JsSourceMarshaller::extract_field(&obj, "null_field"), None);
        assert_eq!(JsSourceMarshaller::extract_field(&obj, "missing"), None);
    }

    #[test]
    fn test_validate_book_type() {
        assert_eq!(JsSourceMarshaller::validate_book_type(0), None);
        assert_eq!(JsSourceMarshaller::validate_book_type(1), Some(1));
        assert_eq!(JsSourceMarshaller::validate_book_type(3), Some(3));
        assert_eq!(JsSourceMarshaller::validate_book_type(16), None);
        assert_eq!(JsSourceMarshaller::validate_book_type(17), None);
    }
}
