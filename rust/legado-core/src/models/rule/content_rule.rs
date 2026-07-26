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
}
