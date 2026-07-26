use serde::{Deserialize, Serialize};

use super::flex_child_style::FlexChildStyle;

/// 发现分类
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ExploreKind {
    #[serde(default)]
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default = "ExploreKind::default_type")]
    pub r#type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chars: Option<Vec<Option<String>>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "default")]
    pub default_value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "viewName")]
    pub view_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<FlexChildStyle>,
}

impl ExploreKind {
    fn default_type() -> String {
        "url".to_string()
    }
}
