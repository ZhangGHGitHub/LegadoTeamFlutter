use serde::{Deserialize, Deserializer, Serialize};

use super::rule::{BookInfoRule, ContentRule, ExploreRule, ReviewRule, SearchRule, TocRule};
use super::serde_utils::{lenient_bool, lenient_i32, lenient_i64, lenient_opt_bool};

/// 宽松反序列化：字符串字段容忍显式 null 与其他标量类型
///
/// Dart 侧 String? 字段的 toJson 会恒输出键（值可为 null），第三方书源
/// JSON 也可能带显式 `"variable": null`；serde 严格模式对 null 直接报错，
/// 会击穿 add_source/update_source/source_import 全链路（台账评审 C1）。
/// 规则：Null→空串、String 原样、其他类型 to_string（Gson 式宽松）。
///
/// 数字/布尔宽松解析已抽到 [`super::serde_utils`]（批28b），供
/// `ContentRule.maxBatchSize` / `RssSource.enableReadRecord` 复用。
fn lenient_string<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Null => Ok(String::new()),
        serde_json::Value::String(s) => Ok(s.clone()),
        other => Ok(other.to_string()),
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
    ///
    /// - 缺键 → `Some(true)`：对齐 Kotlin `BookSource` 构造默认值 true
    ///   （上游 `AnalyzeUrl.kt:126` `source?.enabledCookieJar == true` 才放
    ///   CookieJar 标记头；本仓写侧门控同口径，见 `legado_net::COOKIE_JAR_HEADER`）；
    /// - 显式 null → `None`：运行时按**关**（保留 null→false 语义；DB 旧行
    ///   NULL 读回同此路径，不受 default_true 影响）；
    /// - 显式 false → `Some(false)`。
    #[serde(
        default = "default_true_opt",
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
    /// 自定义变量内容（对齐 Kotlin `BookSource.variable`，由 `setSourceVariable` 写入，
    /// 空串表示未设置/已清除；台账 §5.11-3，SCHEMA_VERSION 102→103 迁移补列）
    ///
    /// lenient_string 容忍 Dart toJson 输出的显式 null（评审 C1 双轨失配修复）；
    /// skip_serializing_if 对齐 variableComment 惯例，空值不输出避免导出物形态漂移
    #[serde(
        default,
        rename = "variable",
        deserialize_with = "lenient_string",
        skip_serializing_if = "str::is_empty"
    )]
    pub variable: String,
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
        self.main_js.as_ref().is_some_and(|s| !s.trim().is_empty())
    }

    /// 检验内容指纹：忽略排序/时间/列表开关等「不影响规则」的字段
    ///
    /// 对齐原版 `BookSource.kt:260-263`：
    /// ```kotlin
    /// fun checkContent(): String = GSON.toJson(copy(
    ///     customOrder = 0, enabled = true, enabledExplore = true,
    ///     lastUpdateTime = 0, respondTime = 0, weight = 0,
    /// ))
    /// ```
    ///
    /// 用途（两处，语义一致）：
    /// 1. 书源保存时与库内旧值比较，决定是否重置检验状态（`sourceRevision`）；
    /// 2. `startBookSourceCheck` 校验网页端提交的源与库内版本一致（防用旧编辑
    ///    结果跑检验）。
    ///
    /// 本实现用 serde 序列化归一后的副本：`Option` 为 `None` / 空 `variable`
    /// 时键省略，结构体字段序固定，因此同一内容的输出逐字节稳定。与 Kotlin
    /// GSON 的差异仅在「省略 null 键」的取舍（GSON 同样省略 null），不影响
    /// 「同内容同指纹、异内容异指纹」的判定语义。
    ///
    /// `enabledCookieJar` 额外归一：`None`（旧库 NULL / `BookSource::default()`
    /// / 显式 null）与 `Some(true)` 视为同一内容。理由：网页端
    /// `utils/sourceCheckState.js` 的规范化对「缺键 / null / 默认值 true」
    /// 一律丢弃，若服务端区分二者，旧库书源在网页端会无端报「书源尚未保存」；
    /// 该归一与前端判定口径一致（登记于批30 模块文档）。
    pub fn check_content(&self) -> String {
        let mut normalized = self.clone();
        normalized.custom_order = 0;
        normalized.enabled = true;
        normalized.enabled_explore = true;
        if normalized.enabled_cookie_jar.is_none() {
            normalized.enabled_cookie_jar = Some(true);
        }
        normalized.last_update_time = 0;
        normalized.respond_time = 0;
        normalized.weight = 0;
        serde_json::to_string(&normalized).unwrap_or_default()
    }
}

fn default_true() -> bool {
    true
}

/// `Option<bool>` 版 default_true：JSON 缺键 → `Some(true)`
///
/// 对齐 Kotlin `BookSource.enabledCookieJar` 构造默认 true；显式 null 仍由
/// `lenient_opt_bool` 解析为 `None`（运行时按关），故不能直接用 `default_true`
/// （返回类型为 `bool`，与 `Option<bool>` 字段不匹配）。
///
/// `pub(crate)`：`RssSource.enabled_cookie_jar`（`models::rss_source`）经
/// serde `default = "super::book_source::default_true_opt"` 复用同一口径
/// （上游 RssSource 同为构造默认 true）。
pub(crate) fn default_true_opt() -> Option<bool> {
    Some(true)
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
        // 缺键 → Some(true)（对齐 Kotlin 构造默认 true；写侧 CookieJar 门控基准）
        assert_eq!(bs.enabled_cookie_jar, Some(true));
    }

    /// enabledCookieJar 反序列化口径（写侧门控批 1）：
    /// - 缺键 → Some(true)，对齐 Kotlin `BookSource` 构造默认值 true；
    /// - 显式 false → Some(false)；
    /// - 显式 null → None（运行时按关，对齐上游 `source?.enabledCookieJar == true`
    ///   的 null→false 语义；DB 旧行 NULL 读回同此路径）。
    #[test]
    fn test_enabled_cookie_jar_missing_key_defaults_true() {
        let json = r#"{"bookSourceUrl":"https://example.com","bookSourceName":"Test"}"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            bs.enabled_cookie_jar,
            Some(true),
            "缺键应默认 Some(true)（对齐 Kotlin 构造默认）"
        );
    }

    #[test]
    fn test_enabled_cookie_jar_explicit_false_and_null() {
        let json = r#"{
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "Test",
            "enabledCookieJar": false
        }"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            bs.enabled_cookie_jar,
            Some(false),
            "显式 false 应为 Some(false)"
        );

        let json = r#"{
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "Test",
            "enabledCookieJar": null
        }"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(
            bs.enabled_cookie_jar, None,
            "显式 null 应为 None（运行时按关，与 DB 旧行 NULL 同语义）"
        );
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

    /// 评审 C1：variable 双轨 null 序列化失配防护——显式 null/缺键/正常串
    /// 均须反序列化成功（Dart toJson 恒输出该键且可为 null）
    #[test]
    fn test_book_source_variable_lenient_deserialize() {
        // 显式 null → 空串（Dart String? toJson 输出 null 的主场景）
        let json =
            r#"{"bookSourceUrl":"https://example.com","bookSourceName":"Test","variable":null}"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(bs.variable, "");

        // 缺键 → 空串（旧版 Dart 导出物/第三方源无该字段）
        let json = r#"{"bookSourceUrl":"https://example.com","bookSourceName":"Test"}"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(bs.variable, "");

        // 正常串原样保留
        let json =
            r#"{"bookSourceUrl":"https://example.com","bookSourceName":"Test","variable":"abc=1"}"#;
        let bs: BookSource = serde_json::from_str(json).unwrap();
        assert_eq!(bs.variable, "abc=1");

        // 空串序列化时不输出该键（对齐 variableComment 惯例）
        let bs = BookSource::default();
        let obj = serde_json::to_value(&bs).unwrap();
        assert!(!obj.as_object().unwrap().contains_key("variable"));
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

    // ─── 批30：check_content 指纹（对齐原版 BookSource.checkContent） ───

    #[test]
    fn test_check_content_ignores_ranking_and_time_fields() {
        let base = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            book_source_name: "源".to_string(),
            respond_time: 100,
            ..BookSource::default()
        };
        let mut changed = base.clone();
        changed.custom_order = 99;
        changed.enabled = !base.enabled;
        changed.enabled_explore = !base.enabled_explore;
        changed.last_update_time = 123456;
        changed.respond_time = 300000;
        changed.weight = 42;
        assert_eq!(
            base.check_content(),
            changed.check_content(),
            "排序/时间/列表开关不应影响检验指纹"
        );
    }

    #[test]
    fn test_check_content_detects_rule_changes() {
        let base = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            book_source_name: "源".to_string(),
            ..BookSource::default()
        };
        let mut changed = base.clone();
        changed.search_url = Some("https://a.example.com/s?q={key}".to_string());
        assert_ne!(base.check_content(), changed.check_content());

        let mut group_changed = base.clone();
        group_changed.book_source_group = Some("分组A".to_string());
        assert_ne!(base.check_content(), group_changed.check_content());

        let mut comment_changed = base.clone();
        comment_changed.book_source_comment = Some("注释".to_string());
        assert_ne!(base.check_content(), comment_changed.check_content());
    }

    #[test]
    fn test_check_content_normalizes_cookie_jar_none_and_true() {
        let none = BookSource {
            enabled_cookie_jar: None,
            ..BookSource::default()
        };
        let some_true = BookSource {
            enabled_cookie_jar: Some(true),
            ..BookSource::default()
        };
        assert_eq!(
            none.check_content(),
            some_true.check_content(),
            "缺键/None 与默认 true 同指纹（对齐网页端 sourceCheckState.js）"
        );
        let some_false = BookSource {
            enabled_cookie_jar: Some(false),
            ..BookSource::default()
        };
        assert_ne!(none.check_content(), some_false.check_content());
    }

    #[test]
    fn test_check_content_json_roundtrip_stable() {
        let source = BookSource {
            book_source_url: "https://a.example.com".to_string(),
            book_source_name: "源".to_string(),
            ..BookSource::default()
        };
        let json = serde_json::to_string(&source).unwrap();
        let restored: BookSource = serde_json::from_str(&json).unwrap();
        assert_eq!(
            source.check_content(),
            restored.check_content(),
            "JSON 往返后指纹必须一致（startBookSourceCheck 的版本校验依赖）"
        );
    }
}
