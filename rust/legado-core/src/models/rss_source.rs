use serde::{Deserialize, Serialize};

use super::serde_utils::lenient_bool_default_true;

/// RSS源实体
#[derive(Debug, Clone, Serialize, Deserialize)]
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
    /// 是否记录阅读历史（对齐 Kotlin `RssSource.enableReadRecord: Boolean = true`，
    /// 列 DDL `INTEGER NOT NULL DEFAULT 1`）
    ///
    /// 批28：上游运行期已回退为全局开关（`AppConfig.enableReadRecord`），按源
    /// 开关不生效；本批只做字段/DB 往返保真（导入、导出、备份、编辑保存不丢），
    /// 不实现按源开关行为。缺键 → true（对齐 Kotlin 构造默认值）。
    ///
    /// 批28b：原版备份/第三方 JSON 存在 `0`/`1` 整数与字符串布尔；
    /// `lenient_bool_default_true` 兼容 bool / 0/1 / `"true"`/`"false"`，
    /// 显式 null 按语义默认值 `true`（差异登记于 API 契约 §2.5）。
    /// `RssSource::default()` 同步为 `true`（批28b，见手写 Default）。
    #[serde(
        default = "default_true",
        rename = "enableReadRecord",
        deserialize_with = "lenient_bool_default_true"
    )]
    pub enable_read_record: bool,
    /// 自定义变量说明
    #[serde(skip_serializing_if = "Option::is_none", rename = "variableComment")]
    pub variable_comment: Option<String>,
    /// js库
    #[serde(skip_serializing_if = "Option::is_none", rename = "jsLib")]
    pub js_lib: Option<String>,
    /// 启用okhttp CookieJar 自动保存每次请求的cookie
    ///
    /// 缺键 → `Some(true)`（对齐 Kotlin `RssSource` 构造默认 true；复用
    /// [`super::book_source::default_true_opt`]）；显式 null → `None`
    /// （运行时按关，DB 旧行 NULL 同此路径）。
    #[serde(
        default = "super::book_source::default_true_opt",
        skip_serializing_if = "Option::is_none",
        rename = "enabledCookieJar"
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
    /// 正文下一页规则（对齐原版 `RssSource.nextContentUrl`，
    /// Room 104.json 同名列 TEXT 可空；RSS 正文分页抓取用）
    #[serde(skip_serializing_if = "Option::is_none", rename = "nextContentUrl")]
    pub next_content_url: Option<String>,
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

/// 手写 Default（批28b）：`enable_read_record` 与 serde/DB 默认值对齐为 `true`
///
/// 派生 `Default` 会让 bool 全部落 `false`，与反序列化缺键（`default_true`）
/// 及 DB 列 `INTEGER NOT NULL DEFAULT 1` 不一致；`RssSource::default()` 构造
/// 再落库/序列化时会把阅读记录开关写成 false。此处只把该字段改为 true，
/// 其余字段保持派生默认，避免扩大行为面（`enabled` 等字段的默认语义另案）。
impl Default for RssSource {
    fn default() -> Self {
        Self {
            source_url: String::new(),
            source_name: String::new(),
            source_icon: String::new(),
            source_group: None,
            source_comment: None,
            enabled: false,
            enable_read_record: true,
            variable_comment: None,
            js_lib: None,
            enabled_cookie_jar: None,
            concurrent_rate: None,
            header: None,
            login_url: None,
            login_ui: None,
            login_check_js: None,
            cover_decode_js: None,
            sort_url: None,
            single_url: false,
            article_style: 0,
            rule_articles: None,
            rule_next_page: None,
            rule_title: None,
            rule_pub_date: None,
            rule_description: None,
            rule_image: None,
            rule_link: None,
            rule_content: None,
            next_content_url: None,
            content_whitelist: None,
            content_blacklist: None,
            should_override_url_loading: None,
            style: None,
            enable_js: false,
            load_with_base_url: false,
            inject_js: None,
            preload_js: None,
            start_html: None,
            start_style: None,
            start_js: None,
            show_web_log: false,
            last_update_time: 0,
            custom_order: 0,
            rss_type: 0,
            preload: false,
            cache_first: false,
            search_url: None,
        }
    }
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
        // Note: 手写 Default 仅把 enableReadRecord 对齐 serde/DB 默认值 true，
        // 其余 bool 仍为 false（serde defaults 只在反序列化时生效）
        assert!(!rss.enabled);
        // 批28b（P3-2）：Default 与 serde/DB 默认一致（阅读历史开关默认开）
        assert!(rss.enable_read_record);
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
        // P1-2：nextContentUrl 为 None 时按既有口径省略
        assert!(!json.contains("nextContentUrl"));
    }

    /// P1-2：nextContentUrl（原版 RssSource.kt:73「正文下一页规则」）读写口径
    #[test]
    fn test_rss_source_next_content_url_serde() {
        let json = r#"{
            "sourceUrl": "https://rss.example.com",
            "sourceName": "Test",
            "nextContentUrl": ".next@href"
        }"#;
        let rss: RssSource = serde_json::from_str(json).unwrap();
        assert_eq!(rss.next_content_url.as_deref(), Some(".next@href"));
        let value = serde_json::to_value(&rss).unwrap();
        assert_eq!(value["nextContentUrl"], ".next@href");
    }

    /// 批28：`enableReadRecord`（原版 RssSource 阅读历史开关）
    /// - 缺键 → true（对齐 Kotlin 构造默认值）；
    /// - 显式 false → false；
    /// - JSON 键名恒为 `enableReadRecord`（camelCase，与 Room 列同名）。
    #[test]
    fn test_rss_source_enable_read_record_serde() {
        let missing: RssSource = serde_json::from_str(r#"{"sourceUrl": "u"}"#).unwrap();
        assert!(
            missing.enable_read_record,
            "缺键应默认 true（对齐 Kotlin `var enableReadRecord: Boolean = true`）"
        );

        let disabled: RssSource =
            serde_json::from_str(r#"{"sourceUrl": "u", "enableReadRecord": false}"#).unwrap();
        assert!(!disabled.enable_read_record);

        let value = serde_json::to_value(&disabled).unwrap();
        assert_eq!(value["enableReadRecord"], false);
        let decoded: RssSource = serde_json::from_value(value).unwrap();
        assert!(!decoded.enable_read_record);
    }

    /// 批28b（P2-1 红→绿）：`enableReadRecord` 宽松类型兼容
    ///
    /// 修复前 `bool` 严格字段遇到旧备份/第三方 JSON 的 `0`/`1` 整数或
    /// `"true"`/`"false"` 字符串会解析失败，并击穿 `import_rss_sources`
    /// 整数组导入（批28 之前该键被忽略，源可导入，属新增失败模式）。
    #[test]
    fn test_rss_source_enable_read_record_lenient_types() {
        let cases: [(&str, bool); 6] = [
            ("1", true),
            ("0", false),
            ("\"true\"", true),
            ("\"false\"", false),
            ("\"1\"", true),
            ("\"0\"", false),
        ];
        for (raw, expected) in cases {
            let json = format!(r#"{{"sourceUrl":"u","enableReadRecord":{raw}}}"#);
            let rss: RssSource = serde_json::from_str(&json)
                .unwrap_or_else(|e| panic!("{raw} 应可解析（Gson 宽松口径）: {e}"));
            assert_eq!(rss.enable_read_record, expected, "raw={raw}");
        }

        // 显式 null → 语义默认值 true（与缺键一致；与 Gson 原始类型跳赋值的
        // 差异已登记于 docs/API_CONTRACT.md §2.5）
        let null: RssSource =
            serde_json::from_str(r#"{"sourceUrl":"u","enableReadRecord":null}"#).unwrap();
        assert!(null.enable_read_record);
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

    /// 批 2 收尾：`enabledCookieJar` 三态（与 BookSource 同口径）
    /// - 缺键 → `Some(true)`（对齐 Kotlin RssSource 构造默认 true）；
    /// - 显式 false → `Some(false)`；
    /// - 显式 null → `None`（运行时按关，DB 旧行 NULL 同此路径）。
    #[test]
    fn test_rss_enabled_cookie_jar_missing_key_defaults_true() {
        let json = r#"{"sourceUrl":"https://rss.example.com","sourceName":"Test"}"#;
        let rss: RssSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            rss.enabled_cookie_jar,
            Some(true),
            "RSS 源缺键应默认 Some(true)（对齐 Kotlin 构造默认）"
        );
    }

    #[test]
    fn test_rss_enabled_cookie_jar_explicit_false_and_null() {
        let json = r#"{
            "sourceUrl": "https://rss.example.com",
            "sourceName": "Test",
            "enabledCookieJar": false
        }"#;
        let rss: RssSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            rss.enabled_cookie_jar,
            Some(false),
            "显式 false 应为 Some(false)"
        );

        let json = r#"{
            "sourceUrl": "https://rss.example.com",
            "sourceName": "Test",
            "enabledCookieJar": null
        }"#;
        let rss: RssSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            rss.enabled_cookie_jar, None,
            "显式 null 应为 None（运行时按关，与 DB 旧行 NULL 同语义）"
        );
    }
}
