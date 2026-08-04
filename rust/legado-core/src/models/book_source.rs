use serde::de::Error;
use serde::{Deserialize, Deserializer, Serialize};

use super::rule::{BookInfoRule, ContentRule, ExploreRule, ReviewRule, SearchRule, TocRule};

/// 宽松反序列化：兼容 JSON 数字与数字字符串
///
/// 原版 Legado 使用 Gson，会自动把字符串数字（如 "1785432524399"）
/// 转换为数字；第三方书源 JSON 中 lastUpdateTime 等字段经常以字符串
/// 形式出现，serde 默认严格模式会直接报错，这里做兼容。
fn lenient_i64<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Number(n) => n.as_i64().ok_or_else(|| D::Error::custom("数字超出 i64 范围")),
        serde_json::Value::String(s) => s
            .trim()
            .parse::<i64>()
            .map_err(|_| D::Error::custom(format!("无法解析数字: {s}"))),
        _ => Err(D::Error::custom("期望数字或数字字符串")),
    }
}

/// 宽松反序列化：兼容 JSON 数字与数字字符串（i32）
fn lenient_i32<'de, D: Deserializer<'de>>(d: D) -> Result<i32, D::Error> {
    let v = lenient_i64(d)?;
    i32::try_from(v).map_err(|_| D::Error::custom("数字超出 i32 范围"))
}

/// 宽松反序列化：兼容 bool、0/1 数字与 "true"/"false" 字符串
fn lenient_bool<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Bool(b) => Ok(*b),
        serde_json::Value::Number(n) => Ok(n.as_i64() != Some(0)),
        serde_json::Value::String(s) => match s.trim() {
            "true" | "1" => Ok(true),
            "false" | "0" | "" => Ok(false),
            other => Err(D::Error::custom(format!("无法解析布尔值: {other}"))),
        },
        _ => Err(D::Error::custom("期望布尔值")),
    }
}

/// 宽松反序列化：Option<bool> 版本（字段缺省时为 None）
fn lenient_opt_bool<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::Bool(b) => Ok(Some(*b)),
        serde_json::Value::Number(n) => Ok(Some(n.as_i64() != Some(0))),
        serde_json::Value::String(s) => match s.trim() {
            "true" | "1" => Ok(Some(true)),
            "false" | "0" | "" => Ok(Some(false)),
            other => Err(D::Error::custom(format!("无法解析布尔值: {other}"))),
        },
        _ => Err(D::Error::custom("期望布尔值")),
    }
}

/// 书源类型常量
pub mod book_source_type {
    pub const TEXT: i32 = 0;
    pub const AUDIO: i32 = 1;
    pub const IMAGE: i32 = 2;
    pub const FILE: i32 = 3;
    pub const VIDEO: i32 = 4;
}

/// 书源实体
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookSource {
    /// 地址，包括 http/https
    #[serde(default, rename = "bookSourceUrl")]
    pub book_source_url: String,
    /// 名称
    #[serde(default, rename = "bookSourceName")]
    pub book_source_name: String,
    /// 分组
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookSourceGroup")]
    pub book_source_group: Option<String>,
    /// 类型，0 文本，1 音频, 2 图片, 3 文件, 4 视频
    #[serde(default, rename = "bookSourceType", deserialize_with = "lenient_i32")]
    pub book_source_type: i32,
    /// 详情页url正则
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookUrlPattern")]
    pub book_url_pattern: Option<String>,
    /// 手动排序编号
    #[serde(default, rename = "customOrder", deserialize_with = "lenient_i32")]
    pub custom_order: i32,
    /// 是否启用
    #[serde(default = "default_true", deserialize_with = "lenient_bool")]
    pub enabled: bool,
    /// 启用发现
    #[serde(
        default = "default_true",
        rename = "enabledExplore",
        deserialize_with = "lenient_bool"
    )]
    pub enabled_explore: bool,
    /// js库
    #[serde(skip_serializing_if = "Option::is_none", rename = "jsLib")]
    pub js_lib: Option<String>,
    /// 启用okhttp CookieJar 自动保存每次请求的cookie
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "enabledCookieJar",
        deserialize_with = "lenient_opt_bool"
    )]
    pub enabled_cookie_jar: Option<bool>,
    /// 并发率
    #[serde(skip_serializing_if = "Option::is_none", rename = "concurrentRate")]
    pub concurrent_rate: Option<String>,
    /// 请求头
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    /// 登录地址
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUrl")]
    pub login_url: Option<String>,
    /// 登录UI
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUi")]
    pub login_ui: Option<String>,
    /// 登录检测js
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginCheckJs")]
    pub login_check_js: Option<String>,
    /// 封面解密js
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverDecodeJs")]
    pub cover_decode_js: Option<String>,
    /// 注释
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookSourceComment")]
    pub book_source_comment: Option<String>,
    /// 自定义变量说明
    #[serde(skip_serializing_if = "Option::is_none", rename = "variableComment")]
    pub variable_comment: Option<String>,
    /// 最后更新时间，用于排序
    #[serde(default, rename = "lastUpdateTime", deserialize_with = "lenient_i64")]
    pub last_update_time: i64,
    /// 响应时间，用于排序
    #[serde(
        default = "default_respond_time",
        rename = "respondTime",
        deserialize_with = "lenient_i64"
    )]
    pub respond_time: i64,
    /// 智能排序的权重
    #[serde(default, deserialize_with = "lenient_i32")]
    pub weight: i32,
    /// 发现url
    #[serde(skip_serializing_if = "Option::is_none", rename = "exploreUrl")]
    pub explore_url: Option<String>,
    /// 发现筛选规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "exploreScreen")]
    pub explore_screen: Option<String>,
    /// 发现规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleExplore")]
    pub rule_explore: Option<ExploreRule>,
    /// 搜索url
    #[serde(skip_serializing_if = "Option::is_none", rename = "searchUrl")]
    pub search_url: Option<String>,
    /// 搜索规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleSearch")]
    pub rule_search: Option<SearchRule>,
    /// 书籍信息页规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleBookInfo")]
    pub rule_book_info: Option<BookInfoRule>,
    /// 目录页规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleToc")]
    pub rule_toc: Option<TocRule>,
    /// 正文页规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleContent")]
    pub rule_content: Option<ContentRule>,
    /// 段评规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleReview")]
    pub rule_review: Option<ReviewRule>,
    /// 纯 JavaScript 单文件书源主脚本
    #[serde(skip_serializing_if = "Option::is_none", rename = "mainJs")]
    pub main_js: Option<String>,
    /// 是否监听事件来执行回调规则
    #[serde(default, rename = "eventListener", deserialize_with = "lenient_bool")]
    pub event_listener: bool,
    /// 由书源控制的自定义按钮
    #[serde(default, rename = "customButton", deserialize_with = "lenient_bool")]
    pub custom_button: bool,
}

impl BookSource {
    /// 判断是否为 JS 书源（mainJs 非空）
    ///
    /// 参考 Kotlin `BookSource.kt:238`: `fun isJsSource(): Boolean = !mainJs.isNullOrBlank()`
    pub fn is_js_source(&self) -> bool {
        self.main_js.as_ref().map_or(false, |s| !s.trim().is_empty())
    }
}

fn default_true() -> bool {
    true
}

fn default_respond_time() -> i64 {
    180000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_source_default() {
        let bs = BookSource::default();
        // Note: derive(Default) gives false for bool, serde defaults only apply during deserialization
        assert!(!bs.enabled);
        assert!(!bs.enabled_explore);
        assert_eq!(bs.respond_time, 0);
        assert_eq!(bs.book_source_type, book_source_type::TEXT);
        assert!(bs.book_source_url.is_empty());
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn test_book_source_serde_roundtrip() {
        let mut bs = BookSource::default();
        bs.book_source_url = "https://example.com".to_string();
        bs.book_source_name = "测试书源".to_string();
        bs.book_source_type = book_source_type::AUDIO;
        bs.search_url = Some("https://example.com/search?q={key}".to_string());

        let json = serde_json::to_string(&bs).unwrap();
        let de: BookSource = serde_json::from_str(&json).unwrap();
        assert_eq!(de.book_source_url, bs.book_source_url);
        assert_eq!(de.book_source_name, bs.book_source_name);
        assert_eq!(de.book_source_type, book_source_type::AUDIO);
        assert_eq!(de.search_url, bs.search_url);
    }

    #[test]
    fn test_book_source_type_constants() {
        assert_eq!(book_source_type::TEXT, 0);
        assert_eq!(book_source_type::AUDIO, 1);
        assert_eq!(book_source_type::IMAGE, 2);
        assert_eq!(book_source_type::FILE, 3);
        assert_eq!(book_source_type::VIDEO, 4);
    }

    #[test]
    fn test_book_source_json_field_names() {
        let bs = BookSource::default();
        let json = serde_json::to_value(&bs).unwrap();
        let obj = json.as_object().unwrap();
        assert!(obj.contains_key("bookSourceUrl"));
        assert!(obj.contains_key("bookSourceName"));
        assert!(obj.contains_key("bookSourceType"));
        assert!(obj.contains_key("customOrder"));
        assert!(obj.contains_key("enabledExplore"));
    }

    #[test]
    fn test_book_source_deserialize_minimal() {
        let json = r#"{"bookSourceUrl":"https://example.com","bookSourceName":"Test"}"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(bs.book_source_url, "https://example.com");
        assert_eq!(bs.book_source_name, "Test");
        assert!(bs.enabled);
        assert!(bs.enabled_explore);
        assert_eq!(bs.respond_time, 180000);
    }

    /// 第三方书源（如 yckceo 订阅）常把数字/布尔字段写成字符串或
    /// 用 true/false 代替 0/1，需要 Gson 式的宽松解析
    #[test]
    fn test_book_source_deserialize_lenient() {
        let json = r#"{
            "bookSourceUrl": "https://www.qianyezw.com",
            "bookSourceName": "新御书屋(千夜)",
            "bookSourceType": 0,
            "customButton": false,
            "customOrder": 0,
            "enabled": true,
            "enabledCookieJar": false,
            "enabledExplore": true,
            "eventListener": false,
            "lastUpdateTime": "1785432524399",
            "respondTime": 180000,
            "weight": 0
        }"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(bs.book_source_url, "https://www.qianyezw.com");
        assert_eq!(bs.last_update_time, 1785432524399);
        assert!(bs.enabled);
        assert!(!bs.enabled_cookie_jar.unwrap_or(true));
        assert!(!bs.custom_button);
        assert!(!bs.event_listener);

        // 0/1 数字形式的布尔字段也应兼容
        let json2 = r#"{
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "Test",
            "enabled": 1,
            "enabledExplore": 0,
            "eventListener": 1
        }"#;
        let bs2: BookSource = serde_json::from_str(json2).unwrap();
        assert!(bs2.enabled);
        assert!(!bs2.enabled_explore);
        assert!(bs2.event_listener);
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn test_book_source_with_nested_rules() {
        use super::super::rule::SearchRule;
        let mut bs = BookSource::default();
        bs.rule_search = Some(SearchRule::default());
        let json = serde_json::to_string(&bs).unwrap();
        let de: BookSource = serde_json::from_str(&json).unwrap();
        assert!(de.rule_search.is_some());
    }
}
