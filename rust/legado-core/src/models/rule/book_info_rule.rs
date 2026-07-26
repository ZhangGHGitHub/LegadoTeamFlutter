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
}
