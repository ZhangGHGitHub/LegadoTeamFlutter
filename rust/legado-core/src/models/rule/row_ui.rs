use serde::{Deserialize, Serialize};

use super::flex_child_style::FlexChildStyle;

/// 登录表单行UI
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RowUi {
    #[serde(default)]
    pub name: String,
    #[serde(default = "RowUi::default_type")]
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

impl RowUi {
    fn default_type() -> String {
        "text".to_string()
    }
}
