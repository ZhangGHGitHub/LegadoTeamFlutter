//! 直链上传
//! 移植自 Kotlin DirectLinkUpload.kt (121行)
//! 通过规则引擎解析上传/下载地址

use serde::{Deserialize, Serialize};

/// 上传规则配置（对应 Kotlin DirectLinkUpload.Rule）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadRule {
    /// 上传接口 URL（创建分享链接）
    pub upload_url: String,
    /// 下载链接提取规则（JSONPath 或正则）
    pub download_url_rule: String,
    /// 注释/摘要
    #[serde(default)]
    pub summary: String,
    /// 是否压缩后上传
    #[serde(default)]
    pub compress: bool,
    /// 有效期/天，0 为永久
    #[serde(default)]
    pub expiry_date: i32,
}

impl std::fmt::Display for UploadRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.summary)
    }
}

/// 上传结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadResult {
    pub success: bool,
    pub download_url: Option<String>,
    pub error: Option<String>,
    pub response_body: Option<String>,
}

/// 直链上传器
pub struct DirectLinkUploader;

impl DirectLinkUploader {
    /// 上传文本内容并获取下载链接
    ///
    /// 对应 Kotlin `DirectLinkUpload.upLoad`
    pub async fn upload(rule: &UploadRule, content: &str) -> Result<UploadResult, String> {
        if rule.upload_url.is_empty() {
            return Err("上传url未配置".to_string());
        }
        if rule.download_url_rule.is_empty() {
            return Err("下载地址规则未配置".to_string());
        }

        let client = reqwest::Client::new();
        let resp = client
            .post(&rule.upload_url)
            .body(content.to_string())
            .send()
            .await
            .map_err(|e| e.to_string())?;

        let body = resp.text().await.map_err(|e| e.to_string())?;

        // 使用规则提取下载链接
        let download_url = Self::extract_download_url(&body, &rule.download_url_rule);

        if download_url.is_none() {
            return Ok(UploadResult {
                success: false,
                download_url: None,
                error: Some(format!("上传失败,{body}")),
                response_body: Some(body),
            });
        }

        Ok(UploadResult {
            success: true,
            download_url,
            error: None,
            response_body: Some(body),
        })
    }

    /// 从响应中提取下载链接
    ///
    /// 支持两种规则格式：
    /// - JSONPath（以 `$.` 或 `$[` 开头）
    /// - 正则表达式（其他情况）
    pub fn extract_download_url(response: &str, rule: &str) -> Option<String> {
        if rule.starts_with("$.") || rule.starts_with("$[") {
            Self::extract_jsonpath(response, rule)
        } else {
            Self::extract_regex(response, rule)
        }
    }

    /// 简单 JSONPath 提取（支持 `$.a.b.c` 形式）
    fn extract_jsonpath(response: &str, rule: &str) -> Option<String> {
        let json: serde_json::Value = serde_json::from_str(response).ok()?;
        let path = rule.trim_start_matches("$.");
        let parts: Vec<&str> = path.split('.').collect();
        let mut current = &json;
        for part in parts {
            current = current.get(part)?;
        }
        current.as_str().map(|s| s.to_string())
    }

    /// 正则提取（取第一个捕获组；规则为用户可配置 pattern，走统一安全入口）
    fn extract_regex(response: &str, rule: &str) -> Option<String> {
        let re = legado_core::regex_safe::compile_regex_safe(rule)?;
        re.captures(response)
            .and_then(|caps| caps.get(1))
            .map(|m| m.as_str().to_string())
    }

    /// 验证规则配置是否有效
    pub fn validate_rule(rule: &UploadRule) -> Result<(), String> {
        if rule.upload_url.is_empty() {
            return Err("上传url未配置".to_string());
        }
        if rule.download_url_rule.is_empty() {
            return Err("下载地址规则未配置".to_string());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_rule() -> UploadRule {
        UploadRule {
            upload_url: "https://example.com/upload".to_string(),
            download_url_rule: "$.data.url".to_string(),
            summary: "测试规则".to_string(),
            compress: false,
            expiry_date: 7,
        }
    }

    #[test]
    fn test_extract_jsonpath() {
        let response = r#"{"code":0,"data":{"url":"https://dl.example.com/f/abc123"}}"#;
        let result = DirectLinkUploader::extract_download_url(response, "$.data.url");
        assert_eq!(result, Some("https://dl.example.com/f/abc123".to_string()));
    }

    #[test]
    fn test_extract_jsonpath_missing_field() {
        let response = r#"{"code":0,"data":{}}"#;
        let result = DirectLinkUploader::extract_download_url(response, "$.data.url");
        assert_eq!(result, None);
    }

    #[test]
    fn test_extract_regex() {
        let response = r#"下载链接: https://dl.example.com/file/xyz"#;
        let result =
            DirectLinkUploader::extract_download_url(response, r"(https://dl\.example\.com/\S+)");
        assert_eq!(result, Some("https://dl.example.com/file/xyz".to_string()));
    }

    #[test]
    fn test_extract_regex_no_match() {
        let response = "no link here";
        let result = DirectLinkUploader::extract_download_url(response, r"(https://\S+)");
        assert_eq!(result, None);
    }

    #[test]
    fn test_validate_rule_ok() {
        let rule = sample_rule();
        assert!(DirectLinkUploader::validate_rule(&rule).is_ok());
    }

    #[test]
    fn test_validate_rule_empty_url() {
        let mut rule = sample_rule();
        rule.upload_url = String::new();
        let err = DirectLinkUploader::validate_rule(&rule).unwrap_err();
        assert!(err.contains("上传url未配置"));
    }

    #[test]
    fn test_validate_rule_empty_download_rule() {
        let mut rule = sample_rule();
        rule.download_url_rule = String::new();
        let err = DirectLinkUploader::validate_rule(&rule).unwrap_err();
        assert!(err.contains("下载地址规则未配置"));
    }

    #[test]
    fn test_rule_serialization() {
        let rule = sample_rule();
        let json = serde_json::to_string(&rule).unwrap();
        let deserialized: UploadRule = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.upload_url, rule.upload_url);
        assert_eq!(deserialized.download_url_rule, rule.download_url_rule);
        assert_eq!(deserialized.expiry_date, 7);
    }

    #[test]
    fn test_rule_display() {
        let rule = sample_rule();
        assert_eq!(format!("{rule}"), "测试规则");
    }
}
