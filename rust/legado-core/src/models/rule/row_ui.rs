use serde::{Deserialize, Serialize};

use super::flex_child_style::FlexChildStyle;

/// 登录表单行UI
///
/// 对齐 Kotlin `data/entities/rule/RowUi.kt`，含上游 #402 新增的
/// V2 动态状态协议扩展字段：key/hint/value/options/countdown。
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
    /// 表单字段键（#402）：text/password/select 行的表单提交键，必须唯一
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// 输入占位提示（#402）：对应 TextInputLayout.placeholderText
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hint: Option<String>,
    /// 渲染时预填值（#402）：优先级高于会话输入与存储值
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// select 行的候选项列表（#402）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<String>>,
    /// button 行点击成功后的倒计时秒数（#402），负数非法
    #[serde(skip_serializing_if = "Option::is_none")]
    pub countdown: Option<i32>,
}

/// 行类型常量，对齐 Kotlin `RowUi.Type`
pub mod row_ui_type {
    pub const TEXT: &str = "text";
    pub const PASSWORD: &str = "password";
    pub const BUTTON: &str = "button";
    pub const LABEL: &str = "label";
    pub const TOGGLE: &str = "toggle";
    pub const SELECT: &str = "select";
}

impl RowUi {
    fn default_type() -> String {
        "text".to_string()
    }
}

/// 对齐 Kotlin `RowUi.equals`：仅比较 name/type/action/default 四个字段
impl PartialEq for RowUi {
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name
            && self.r#type == other.r#type
            && self.action == other.action
            && self.default_value == other.default_value
    }
}

impl Eq for RowUi {}
