use serde::{Deserialize, Serialize};

/// 书籍列表规则（SearchRule 和 ExploreRule 共享的字段）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookListRule {
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookList")]
    pub book_list: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookUrl")]
    pub book_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
}
