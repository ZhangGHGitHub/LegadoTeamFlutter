use serde::{Deserialize, Serialize};

/// 目录页规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TocRule {
    #[serde(skip_serializing_if = "Option::is_none", rename = "preUpdateJs")]
    pub pre_update_js: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "chapterList")]
    pub chapter_list: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "chapterName")]
    pub chapter_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "chapterUrl")]
    pub chapter_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "formatJs")]
    pub format_js: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "isVolume")]
    pub is_volume: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "isVip")]
    pub is_vip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "isPay")]
    pub is_pay: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "updateTime")]
    pub update_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "nextTocUrl")]
    pub next_toc_url: Option<String>,
}
