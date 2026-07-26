use serde::{Deserialize, Serialize};

/// Flexbox 子元素样式
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlexChildStyle {
    #[serde(default, rename = "layout_flexGrow")]
    pub layout_flex_grow: f32,
    #[serde(
        default = "FlexChildStyle::default_flex_shrink",
        rename = "layout_flexShrink"
    )]
    pub layout_flex_shrink: f32,
    #[serde(default = "FlexChildStyle::default_auto", rename = "layout_alignSelf")]
    pub layout_align_self: String,
    #[serde(
        default = "FlexChildStyle::default_negative_one",
        rename = "layout_flexBasisPercent"
    )]
    pub layout_flex_basis_percent: f32,
    #[serde(default, rename = "layout_wrapBefore")]
    pub layout_wrap_before: bool,
    /// 自定义的内部水平对齐属性
    #[serde(
        default = "FlexChildStyle::default_auto",
        rename = "layout_justifySelf"
    )]
    pub layout_justify_self: String,
}

impl Default for FlexChildStyle {
    fn default() -> Self {
        Self {
            layout_flex_grow: 0.0,
            layout_flex_shrink: 1.0,
            layout_align_self: "auto".to_string(),
            layout_flex_basis_percent: -1.0,
            layout_wrap_before: false,
            layout_justify_self: "auto".to_string(),
        }
    }
}

impl FlexChildStyle {
    fn default_flex_shrink() -> f32 {
        1.0
    }

    fn default_auto() -> String {
        "auto".to_string()
    }

    fn default_negative_one() -> f32 {
        -1.0
    }
}
