use serde::{Deserialize, Serialize};

use super::rule::{BookInfoRule, ContentRule, ExploreRule, ReviewRule, SearchRule, TocRule};

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
    #[serde(default, rename = "bookSourceType")]
    pub book_source_type: i32,
    /// 详情页url正则
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookUrlPattern")]
    pub book_url_pattern: Option<String>,
    /// 手动排序编号
    #[serde(default, rename = "customOrder")]
    pub custom_order: i32,
    /// 是否启用
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 启用发现
    #[serde(default = "default_true", rename = "enabledExplore")]
    pub enabled_explore: bool,
    /// js库
    #[serde(skip_serializing_if = "Option::is_none", rename = "jsLib")]
    pub js_lib: Option<String>,
    /// 启用okhttp CookieJar 自动保存每次请求的cookie
    #[serde(skip_serializing_if = "Option::is_none", rename = "enabledCookieJar")]
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
    #[serde(default, rename = "lastUpdateTime")]
    pub last_update_time: i64,
    /// 响应时间，用于排序
    #[serde(default = "default_respond_time", rename = "respondTime")]
    pub respond_time: i64,
    /// 智能排序的权重
    #[serde(default)]
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
    #[serde(default, rename = "eventListener")]
    pub event_listener: bool,
    /// 由书源控制的自定义按钮
    #[serde(default, rename = "customButton")]
    pub custom_button: bool,
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

    #[test]
    fn test_book_source_with_nested_rules() {
        use super::super::rule::SearchRule;
        let mut bs = BookSource::default();
        bs.rule_search = Some(SearchRule::default());
        let json = serde_json::to_string(&bs).unwrap();
        let de: BookSource = serde_json::from_str(&json).unwrap();
        assert!(de.rule_search.is_some());
    }
}
