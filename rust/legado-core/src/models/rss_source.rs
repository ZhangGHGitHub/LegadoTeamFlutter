use serde::{Deserialize, Serialize};

/// RSS源实体
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RssSource {
    #[serde(default, rename = "sourceUrl")]
    pub source_url: String,
    /// 名称
    #[serde(default, rename = "sourceName")]
    pub source_name: String,
    /// 图标
    #[serde(default, rename = "sourceIcon")]
    pub source_icon: String,
    /// 分组
    #[serde(skip_serializing_if = "Option::is_none", rename = "sourceGroup")]
    pub source_group: Option<String>,
    /// 注释
    #[serde(skip_serializing_if = "Option::is_none", rename = "sourceComment")]
    pub source_comment: Option<String>,
    /// 是否启用
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 自定义变量说明
    #[serde(skip_serializing_if = "Option::is_none", rename = "variableComment")]
    pub variable_comment: Option<String>,
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
    /// 登录Ui
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUi")]
    pub login_ui: Option<String>,
    /// 登录检测js
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginCheckJs")]
    pub login_check_js: Option<String>,
    /// 封面解密js
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverDecodeJs")]
    pub cover_decode_js: Option<String>,
    /// 分类Url
    #[serde(skip_serializing_if = "Option::is_none", rename = "sortUrl")]
    pub sort_url: Option<String>,
    /// 是否单url源
    #[serde(default, rename = "singleUrl")]
    pub single_url: bool,
    /// 列表样式,0,1,2,3,4
    #[serde(default, rename = "articleStyle")]
    pub article_style: i32,
    /// 列表规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleArticles")]
    pub rule_articles: Option<String>,
    /// 下一页规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleNextPage")]
    pub rule_next_page: Option<String>,
    /// 标题规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleTitle")]
    pub rule_title: Option<String>,
    /// 发布日期规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "rulePubDate")]
    pub rule_pub_date: Option<String>,
    /// 描述规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleDescription")]
    pub rule_description: Option<String>,
    /// 图片规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleImage")]
    pub rule_image: Option<String>,
    /// 链接规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleLink")]
    pub rule_link: Option<String>,
    /// 正文规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "ruleContent")]
    pub rule_content: Option<String>,
    /// 正文url白名单
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentWhitelist")]
    pub content_whitelist: Option<String>,
    /// 正文url黑名单
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentBlacklist")]
    pub content_blacklist: Option<String>,
    /// 跳转url拦截
    #[serde(
        skip_serializing_if = "Option::is_none",
        rename = "shouldOverrideUrlLoading"
    )]
    pub should_override_url_loading: Option<String>,
    /// webView样式
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<String>,
    #[serde(default = "default_true", rename = "enableJs")]
    pub enable_js: bool,
    #[serde(default = "default_true", rename = "loadWithBaseUrl")]
    pub load_with_base_url: bool,
    /// 注入js
    #[serde(skip_serializing_if = "Option::is_none", rename = "injectJs")]
    pub inject_js: Option<String>,
    /// 提前预注入js
    #[serde(skip_serializing_if = "Option::is_none", rename = "preloadJs")]
    pub preload_js: Option<String>,
    /// web形式起始页
    #[serde(skip_serializing_if = "Option::is_none", rename = "startHtml")]
    pub start_html: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "startStyle")]
    pub start_style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "startJs")]
    pub start_js: Option<String>,
    /// 是否输出web网页日志
    #[serde(default, rename = "showWebLog")]
    pub show_web_log: bool,
    /// 最后更新时间，用于排序
    #[serde(default, rename = "lastUpdateTime")]
    pub last_update_time: i64,
    #[serde(default, rename = "customOrder")]
    pub custom_order: i32,
    /// 类型 0网页，1图片，2视频
    #[serde(default, rename = "type")]
    pub rss_type: i32,
    /// 是否启用预加载
    #[serde(default)]
    pub preload: bool,
    /// 是否优先加载缓存
    #[serde(default, rename = "cacheFirst")]
    pub cache_first: bool,
    /// 搜索url
    #[serde(skip_serializing_if = "Option::is_none", rename = "searchUrl")]
    pub search_url: Option<String>,
}

fn default_true() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rss_source_default() {
        let rss = RssSource::default();
        // Note: derive(Default) gives false for bool, serde defaults only apply during deserialization
        assert!(!rss.enabled);
        assert!(!rss.enable_js);
        assert!(!rss.load_with_base_url);
        assert!(!rss.single_url);
        assert!(!rss.show_web_log);
        assert_eq!(rss.article_style, 0);
        assert_eq!(rss.rss_type, 0);
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn test_rss_source_serde_roundtrip() {
        let mut rss = RssSource::default();
        rss.source_url = "https://rss.example.com".to_string();
        rss.source_name = "测试 RSS".to_string();
        rss.source_group = Some("新闻".to_string());
        rss.single_url = true;

        let json = serde_json::to_string(&rss).unwrap();
        let de: RssSource = serde_json::from_str(&json).unwrap();
        assert_eq!(de.source_url, rss.source_url);
        assert_eq!(de.source_name, rss.source_name);
        assert_eq!(de.source_group, Some("新闻".to_string()));
        assert!(de.single_url);
    }

    #[test]
    fn test_rss_source_optional_fields_skipped() {
        let rss = RssSource::default();
        let json = serde_json::to_string(&rss).unwrap();
        assert!(!json.contains("sourceGroup"));
        assert!(!json.contains("sourceComment"));
        assert!(!json.contains("jsLib"));
        assert!(!json.contains("loginUrl"));
    }

    #[test]
    fn test_rss_source_json_field_names() {
        let rss = RssSource::default();
        let val = serde_json::to_value(&rss).unwrap();
        let obj = val.as_object().unwrap();
        assert!(obj.contains_key("sourceUrl"));
        assert!(obj.contains_key("sourceName"));
        assert!(obj.contains_key("sourceIcon"));
        assert!(obj.contains_key("enableJs"));
        assert!(obj.contains_key("loadWithBaseUrl"));
    }

    #[test]
    fn test_rss_source_deserialize_minimal() {
        let json = r#"{"sourceUrl":"https://rss.example.com","sourceName":"Test"}"#;
        let rss: RssSource = serde_json::from_str(json).unwrap();
        assert_eq!(rss.source_url, "https://rss.example.com");
        assert_eq!(rss.source_name, "Test");
        assert!(rss.enabled);
        assert!(rss.enable_js);
    }
}
