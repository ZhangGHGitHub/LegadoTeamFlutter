//! JS 源保存验证
//! 移植自 Kotlin JsSourceUpsert.kt (163行)

use serde_json::Value;

/// 最大源文件大小（1MB）
pub const MAX_SOURCE_BYTES: usize = 1024 * 1024;

/// 保存验证结果
#[derive(Debug, Clone)]
pub struct UpsertValidation {
    pub is_valid: bool,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
}

/// 冲突检测结果
#[derive(Debug, Clone)]
pub struct ConflictResult {
    pub has_conflict: bool,
    pub conflicting_fields: Vec<String>,
    pub existing_source_url: Option<String>,
}

/// Payload 问题类型（参考 Kotlin PayloadIssue 枚举）
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadIssue {
    Empty,
    TooLarge,
}

pub struct JsSourceUpsert;

impl JsSourceUpsert {
    /// 验证载荷大小（参考 Kotlin validatePayload）
    pub fn validate_payload(text: &str) -> Option<PayloadIssue> {
        if text.trim().is_empty() {
            return Some(PayloadIssue::Empty);
        }
        if text.len() > MAX_SOURCE_BYTES || text.chars().count() > MAX_SOURCE_BYTES {
            return Some(PayloadIssue::TooLarge);
        }
        None
    }

    /// 验证 JS 源配置
    ///
    /// 检查必要字段：bookSourceUrl、bookSourceName、mainJs
    pub fn validate(source_json: &str) -> UpsertValidation {
        let mut errors = Vec::new();
        let mut warnings = Vec::new();

        // 先检查 payload
        if let Some(issue) = Self::validate_payload(source_json) {
            errors.push(match issue {
                PayloadIssue::Empty => "源配置为空".to_string(),
                PayloadIssue::TooLarge => "源配置超过 1MB 限制".to_string(),
            });
            return UpsertValidation {
                is_valid: false,
                errors,
                warnings,
            };
        }

        // 解析 JSON
        let parsed: Value = match serde_json::from_str(source_json) {
            Ok(v) => v,
            Err(e) => {
                errors.push(format!("JSON 解析失败: {e}"));
                return UpsertValidation {
                    is_valid: false,
                    errors,
                    warnings,
                };
            }
        };

        if !parsed.is_object() {
            errors.push("源配置不是 JSON 对象".to_string());
            return UpsertValidation {
                is_valid: false,
                errors,
                warnings,
            };
        }

        // 检查必要字段
        let url = parsed
            .get("bookSourceUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if url.is_empty() {
            errors.push("缺少 bookSourceUrl".to_string());
        } else if !url.starts_with("http://") && !url.starts_with("https://") {
            warnings.push("bookSourceUrl 不是有效的 HTTP(S) 链接".to_string());
        }

        let name = parsed
            .get("bookSourceName")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if name.is_empty() {
            errors.push("缺少 bookSourceName".to_string());
        }

        let main_js = parsed.get("mainJs").and_then(|v| v.as_str()).unwrap_or("");
        if main_js.is_empty() {
            errors.push("缺少 mainJs（非 JS 源）".to_string());
        }

        // 可选字段警告
        if parsed
            .get("searchUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .is_empty()
        {
            warnings.push("未配置 searchUrl".to_string());
        }

        UpsertValidation {
            is_valid: errors.is_empty(),
            errors,
            warnings,
        }
    }

    /// 检测保存冲突（参考 Kotlin hasTargetConflict）
    ///
    /// 当新源的 URL 与已有源列表中某个源重复时视为冲突
    pub fn detect_conflict(new_source: &str, existing_sources: &[String]) -> ConflictResult {
        let parsed: Value = match serde_json::from_str(new_source) {
            Ok(v) => v,
            Err(_) => {
                return ConflictResult {
                    has_conflict: false,
                    conflicting_fields: vec!["JSON 解析失败".to_string()],
                    existing_source_url: None,
                }
            }
        };

        let new_url = parsed
            .get("bookSourceUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if new_url.is_empty() {
            return ConflictResult {
                has_conflict: false,
                conflicting_fields: Vec::new(),
                existing_source_url: None,
            };
        }

        for existing in existing_sources {
            if let Ok(existing_parsed) = serde_json::from_str::<Value>(existing) {
                let existing_url = existing_parsed
                    .get("bookSourceUrl")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if existing_url == new_url {
                    let mut fields = vec!["bookSourceUrl".to_string()];
                    // 检查名称是否也冲突
                    let new_name = parsed
                        .get("bookSourceName")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let existing_name = existing_parsed
                        .get("bookSourceName")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if new_name == existing_name && !new_name.is_empty() {
                        fields.push("bookSourceName".to_string());
                    }
                    return ConflictResult {
                        has_conflict: true,
                        conflicting_fields: fields,
                        existing_source_url: Some(existing_url.to_string()),
                    };
                }
            }
        }

        ConflictResult {
            has_conflict: false,
            conflicting_fields: Vec::new(),
            existing_source_url: None,
        }
    }

    /// 合并用户自定义设置（参考 Kotlin preserveUserState）
    ///
    /// 保留旧源的 enabled/enabledExplore/customOrder/weight/respondTime/bookSourceGroup
    pub fn merge_user_state(new_source: &str, old_source: &str) -> String {
        let mut new_parsed: Value = match serde_json::from_str(new_source) {
            Ok(v) => v,
            Err(_) => return new_source.to_string(),
        };
        let old_parsed: Value = match serde_json::from_str(old_source) {
            Ok(v) => v,
            Err(_) => return new_source.to_string(),
        };

        if !new_parsed.is_object() || !old_parsed.is_object() {
            return new_source.to_string();
        }

        let obj = new_parsed.as_object_mut().unwrap();
        let old_obj = old_parsed.as_object().unwrap();

        // 保留用户状态字段
        let preserve_fields = [
            "enabled",
            "enabledExplore",
            "customOrder",
            "weight",
            "respondTime",
        ];
        for field in &preserve_fields {
            if let Some(val) = old_obj.get(*field) {
                obj.insert(field.to_string(), val.clone());
            }
        }

        // bookSourceGroup：仅当新源为空时保留旧值
        let new_group_empty = obj
            .get("bookSourceGroup")
            .and_then(|v| v.as_str())
            .is_none_or(|s| s.trim().is_empty());
        if new_group_empty {
            if let Some(val) = old_obj.get("bookSourceGroup") {
                obj.insert("bookSourceGroup".to_string(), val.clone());
            }
        }

        serde_json::to_string(&new_parsed).unwrap_or_else(|_| new_source.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_payload_empty() {
        assert_eq!(
            JsSourceUpsert::validate_payload(""),
            Some(PayloadIssue::Empty)
        );
        assert_eq!(
            JsSourceUpsert::validate_payload("   "),
            Some(PayloadIssue::Empty)
        );
    }

    #[test]
    fn test_validate_payload_too_large() {
        let large = "x".repeat(MAX_SOURCE_BYTES + 1);
        assert_eq!(
            JsSourceUpsert::validate_payload(&large),
            Some(PayloadIssue::TooLarge)
        );
    }

    #[test]
    fn test_validate_payload_valid() {
        assert_eq!(
            JsSourceUpsert::validate_payload(r#"{"bookSourceUrl":"http://a.com"}"#),
            None
        );
    }

    #[test]
    fn test_validate_valid_source() {
        let json = r#"{"bookSourceUrl":"http://example.com","bookSourceName":"测试源","mainJs":"function search(){}","searchUrl":"http://example.com/s"}"#;
        let result = JsSourceUpsert::validate(json);
        assert!(result.is_valid);
        assert!(result.errors.is_empty());
    }

    #[test]
    fn test_validate_missing_fields() {
        let json = r#"{"bookSourceUrl":"","bookSourceName":"","mainJs":""}"#;
        let result = JsSourceUpsert::validate(json);
        assert!(!result.is_valid);
        assert!(result.errors.len() >= 3);
    }

    #[test]
    fn test_validate_invalid_json() {
        let result = JsSourceUpsert::validate("not json");
        assert!(!result.is_valid);
        assert!(result.errors[0].contains("JSON 解析失败"));
    }

    #[test]
    fn test_validate_url_warning() {
        let json = r#"{"bookSourceUrl":"ftp://bad.com","bookSourceName":"源","mainJs":"code","searchUrl":"x"}"#;
        let result = JsSourceUpsert::validate(json);
        assert!(result.is_valid);
        assert!(!result.warnings.is_empty());
    }

    #[test]
    fn test_detect_conflict_found() {
        let new_src = r#"{"bookSourceUrl":"http://a.com","bookSourceName":"源A"}"#;
        let existing =
            vec![r#"{"bookSourceUrl":"http://a.com","bookSourceName":"源A"}"#.to_string()];
        let result = JsSourceUpsert::detect_conflict(new_src, &existing);
        assert!(result.has_conflict);
        assert!(result
            .conflicting_fields
            .contains(&"bookSourceUrl".to_string()));
        assert!(result
            .conflicting_fields
            .contains(&"bookSourceName".to_string()));
        assert_eq!(result.existing_source_url, Some("http://a.com".to_string()));
    }

    #[test]
    fn test_detect_conflict_not_found() {
        let new_src = r#"{"bookSourceUrl":"http://new.com","bookSourceName":"新源"}"#;
        let existing =
            vec![r#"{"bookSourceUrl":"http://old.com","bookSourceName":"旧源"}"#.to_string()];
        let result = JsSourceUpsert::detect_conflict(new_src, &existing);
        assert!(!result.has_conflict);
    }

    #[test]
    fn test_merge_user_state() {
        let new_src = r#"{"bookSourceUrl":"http://a.com","bookSourceName":"新名","enabled":true,"customOrder":0}"#;
        let old_src = r#"{"bookSourceUrl":"http://a.com","bookSourceName":"旧名","enabled":false,"customOrder":5,"weight":10,"bookSourceGroup":"分组A"}"#;
        let merged = JsSourceUpsert::merge_user_state(new_src, old_src);
        let parsed: Value = serde_json::from_str(&merged).unwrap();
        // 用户状态应保留旧值
        assert_eq!(parsed["enabled"], false);
        assert_eq!(parsed["customOrder"], 5);
        assert_eq!(parsed["weight"], 10);
        assert_eq!(parsed["bookSourceGroup"], "分组A");
        // 新源名称应保留
        assert_eq!(parsed["bookSourceName"], "新名");
    }

    #[test]
    fn test_merge_user_state_invalid_json() {
        let result = JsSourceUpsert::merge_user_state("invalid", "{}");
        assert_eq!(result, "invalid");
    }
}
