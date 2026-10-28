use serde::{Deserialize, Serialize};

/// 正文处理规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ContentRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// 副文规则，拼接在正文后面或者获取歌词等
    #[serde(skip_serializing_if = "Option::is_none", rename = "subContent")]
    pub sub_content: Option<String>,
    /// 有些网站只能在正文中获取标题
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "nextContentUrl")]
    pub next_content_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "webJs")]
    pub web_js: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "sourceRegex")]
    pub source_regex: Option<String>,
    /// 替换规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "replaceRegex")]
    pub replace_regex: Option<String>,
    /// 默认大小居中，FULL最大宽度
    #[serde(skip_serializing_if = "Option::is_none", rename = "imageStyle")]
    pub image_style: Option<String>,
    /// 图片bytes二次解密js，返回解密后的bytes
    #[serde(skip_serializing_if = "Option::is_none", rename = "imageDecode")]
    pub image_decode: Option<String>,
    /// 购买操作，js或者包含{{js}}的url
    #[serde(skip_serializing_if = "Option::is_none", rename = "payAction")]
    pub pay_action: Option<String>,
    /// 监听到事件后执行的回调js代码
    #[serde(skip_serializing_if = "Option::is_none", rename = "callBackJs")]
    pub call_back_js: Option<String>,
    /// 批量正文规则，支持 JS（对齐原版 `ContentRule.contentBatch: String?`）
    ///
    /// 批28：原版用于正文批量下载（`BookContent.analyzeContentBatch`），
    /// 本批只做字段往返保真（导入/导出/备份/编辑保存不丢），下载功能不实现。
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentBatch")]
    pub content_batch: Option<String>,
    /// 最大批量数量（对齐原版 `ContentRule.maxBatchSize: Int?`）
    ///
    /// 默认 `None` 表示不支持批量；原版 `BookSource.contentBatchSize()` 把
    /// 有效值收敛到 1..=50（`MAX_CONTENT_BATCH_SIZE`），本批仅保真存储、不做行为。
    #[serde(skip_serializing_if = "Option::is_none", rename = "maxBatchSize")]
    pub max_batch_size: Option<i32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 批28：批量正文两字段按原版键名序列化/反序列化（camelCase）
    #[test]
    fn test_content_rule_batch_fields_serde_roundtrip() {
        let json = r#"{
            "content": "id.content@textNodes",
            "contentBatch": "batch@js:result",
            "maxBatchSize": 20
        }"#;
        let rule: ContentRule = serde_json::from_str(json).unwrap();
        assert_eq!(rule.content_batch.as_deref(), Some("batch@js:result"));
        assert_eq!(rule.max_batch_size, Some(20));

        let value = serde_json::to_value(&rule).unwrap();
        assert_eq!(value["contentBatch"], "batch@js:result");
        assert_eq!(value["maxBatchSize"], 20);
        // 读回等价
        let decoded: ContentRule = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.content_batch, rule.content_batch);
        assert_eq!(decoded.max_batch_size, rule.max_batch_size);
    }

    /// 批28：缺键 → None；None 时按既有口径省略输出键（不产生 null 噪音）
    #[test]
    fn test_content_rule_batch_fields_optional() {
        let rule: ContentRule = serde_json::from_str(r#"{"content": ".content"}"#).unwrap();
        assert!(rule.content_batch.is_none());
        assert!(rule.max_batch_size.is_none());

        let json = serde_json::to_string(&rule).unwrap();
        assert!(!json.contains("contentBatch"));
        assert!(!json.contains("maxBatchSize"));
    }

    /// 批28：`maxBatchSize` 原版为可空 Int，显式 null 按缺省处理
    #[test]
    fn test_content_rule_max_batch_size_explicit_null() {
        let rule: ContentRule =
            serde_json::from_str(r#"{"contentBatch": "x", "maxBatchSize": null}"#).unwrap();
        assert_eq!(rule.content_batch.as_deref(), Some("x"));
        assert_eq!(rule.max_batch_size, None);
    }
}
