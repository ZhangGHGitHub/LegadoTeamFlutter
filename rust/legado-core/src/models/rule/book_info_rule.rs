use serde::{Deserialize, Serialize};

/// 书籍详情页规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookInfoRule {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub init: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastChapter")]
    pub last_chapter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "updateTime")]
    pub update_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "tocUrl")]
    pub toc_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "canReName")]
    pub can_re_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "downloadUrls")]
    pub download_urls: Option<String>,
    /// 相关书模块配置（JSON 数组，每项 `{key, title, url}`）
    ///
    /// [R42 阶段 1 | 2026-11-21] 参考版独有字段（`BookInfoRule.kt:25`），
    /// 授权依据见 `docs/API_CONTRACT.md` 2026-11-21c 行。加法式新增：
    /// 既有书源无此字段 → `None`，解析与序列化行为不变。
    /// 消费方 `legado_ffi::api::related_books_api::get_related_books`。
    #[serde(skip_serializing_if = "Option::is_none", rename = "relatedBooks")]
    pub related_books: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::BookInfoRule;

    /// [R42 阶段 1 | 2026-11-21] 加法式字段：既有书源（无 `relatedBooks`）
    /// 解析后为 `None`，序列化也不输出该键——不破坏既有书源往返。
    #[test]
    fn related_books_absent_keeps_none_and_is_not_serialized() {
        let rule: BookInfoRule =
            serde_json::from_str(r#"{"name":"h1@text","author":"span@text"}"#).unwrap();
        assert_eq!(rule.related_books, None);
        let json = serde_json::to_string(&rule).unwrap();
        assert!(
            !json.contains("relatedBooks"),
            "未配置时不得输出 relatedBooks: {json}"
        );
    }

    /// `relatedBooks` 键按原样读写（JSON 数组字符串，原样保留不解析）
    #[test]
    fn related_books_round_trips_raw_json_string() {
        let raw = r#"[{"key":"m1","title":"模块一","url":"/list/1.html"}]"#;
        let payload = serde_json::json!({ "relatedBooks": raw }).to_string();
        let rule: BookInfoRule = serde_json::from_str(&payload).unwrap();
        assert_eq!(rule.related_books.as_deref(), Some(raw));

        let json: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&rule).unwrap()).unwrap();
        assert_eq!(json["relatedBooks"], raw);
    }
}
