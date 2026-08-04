use serde::{Deserialize, Serialize};

// ─── SearchBook ───────────────────────────────────────────

/// 搜索结果书籍
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchBook {
    #[serde(default, rename = "bookUrl")]
    pub book_url: String,
    #[serde(default)]
    pub origin: String,
    #[serde(default, rename = "originName")]
    pub origin_name: String,
    #[serde(default, rename = "type")]
    pub book_type: i32,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "latestChapterTitle")]
    pub latest_chapter_title: Option<String>,
    #[serde(default, rename = "tocUrl")]
    pub toc_url: String,
    #[serde(default)]
    pub time: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    #[serde(default, rename = "originOrder")]
    pub origin_order: i32,
    #[serde(
        skip_serializing_if = "Option::is_none",
        rename = "chapterWordCountText"
    )]
    pub chapter_word_count_text: Option<String>,
    #[serde(default = "default_neg_one", rename = "chapterWordCount")]
    pub chapter_word_count: i32,
    #[serde(default = "default_neg_one", rename = "respondTime")]
    pub respond_time: i32,
    /// 是否有阅读记录（#424：搜索结果阅读记录标识，加法式字段，
    /// 原版 Kotlin 在 UI 层计算，Flutter 轨由 Rust 侧随 JSON 附加）
    #[serde(default, rename = "hasReadRecord")]
    pub has_read_record: bool,
    /// 阅读记录中的作者信息（仅在有阅读记录时附加，无记录时缺省）
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "readRecordAuthor"
    )]
    pub read_record_author: Option<String>,
}

fn default_neg_one() -> i32 {
    -1
}

// ─── ReplaceRule ──────────────────────────────────────────

/// 替换规则
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplaceRule {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(default)]
    pub pattern: String,
    #[serde(default)]
    pub replacement: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, rename = "scopeTitle")]
    pub scope_title: bool,
    #[serde(default = "default_true", rename = "scopeContent")]
    pub scope_content: bool,
    #[serde(skip_serializing_if = "Option::is_none", rename = "excludeScope")]
    pub exclude_scope: Option<String>,
    #[serde(default = "default_true", rename = "isEnabled")]
    pub is_enabled: bool,
    #[serde(default = "default_true", rename = "isRegex")]
    pub is_regex: bool,
    #[serde(default = "default_timeout", rename = "timeoutMillisecond")]
    pub timeout_millisecond: i64,
    #[serde(default, rename = "sortOrder")]
    pub order: i32,
}

impl Default for ReplaceRule {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            group: None,
            pattern: String::new(),
            replacement: String::new(),
            scope: None,
            scope_title: false,
            scope_content: true,
            exclude_scope: None,
            is_enabled: true,
            is_regex: true,
            timeout_millisecond: 3000,
            order: 0,
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_timeout() -> i64 {
    3000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_replace_rule_default() {
        let rule = ReplaceRule::default();
        assert!(rule.is_enabled);
        assert!(rule.is_regex);
        assert!(rule.scope_content);
        assert!(!rule.scope_title);
        assert_eq!(rule.timeout_millisecond, 3000);
        assert_eq!(rule.id, 0);
    }

    #[test]
    fn test_replace_rule_regex_match() {
        let rule = ReplaceRule {
            pattern: r"\d+".to_string(),
            replacement: "NUM".to_string(),
            is_regex: true,
            ..ReplaceRule::default()
        };
        let re = regex::Regex::new(&rule.pattern).unwrap();
        let result = re.replace_all("test 123 and 456", rule.replacement.as_str());
        assert_eq!(result, "test NUM and NUM");
    }

    #[test]
    fn test_replace_rule_serde_roundtrip() {
        let rule = ReplaceRule {
            id: 1,
            name: "测试规则".to_string(),
            pattern: "hello".to_string(),
            replacement: "world".to_string(),
            is_regex: false,
            ..ReplaceRule::default()
        };
        let json = serde_json::to_string(&rule).unwrap();
        let de: ReplaceRule = serde_json::from_str(&json).unwrap();
        assert_eq!(de.id, 1);
        assert_eq!(de.name, "测试规则");
        assert_eq!(de.pattern, "hello");
        assert_eq!(de.replacement, "world");
        assert!(!de.is_regex);
    }

    #[test]
    fn test_search_book_default() {
        let json = "{}";
        let sb: SearchBook = serde_json::from_str(json).unwrap();
        assert!(sb.book_url.is_empty());
        assert_eq!(sb.chapter_word_count, -1);
        assert_eq!(sb.respond_time, -1);
    }

    #[test]
    fn test_book_group_default() {
        let bg = BookGroup::default();
        assert_eq!(bg.group_id, 1);
        assert!(bg.enable_refresh);
        assert!(bg.show);
        assert_eq!(bg.book_sort, -1);
    }

    #[test]
    fn test_book_group_serde() {
        let bg = BookGroup {
            group_id: 42,
            group_name: "测试分组".to_string(),
            ..BookGroup::default()
        };
        let json = serde_json::to_string(&bg).unwrap();
        let de: BookGroup = serde_json::from_str(&json).unwrap();
        assert_eq!(de.group_id, 42);
        assert_eq!(de.group_name, "测试分组");
    }

    #[test]
    fn test_bookmark_serde() {
        let bm = Bookmark {
            id: 1,
            time: 1234567890,
            book_name: "TestBook".to_string(),
            book_author: "Author".to_string(),
            chapter_index: 5,
            chapter_pos: 100,
            chapter_name: "第5章".to_string(),
            book_text: "some text".to_string(),
            content: "note".to_string(),
        };
        let json = serde_json::to_string(&bm).unwrap();
        let de: Bookmark = serde_json::from_str(&json).unwrap();
        assert_eq!(de.time, 1234567890);
        assert_eq!(de.book_name, "TestBook");
        assert_eq!(de.chapter_index, 5);
        assert_eq!(de.id, 1);
    }

    #[test]
    fn test_server_type_serde() {
        let st = ServerType::WebDav;
        let json = serde_json::to_string(&st).unwrap();
        assert_eq!(json, r#""WEBDAV""#);
        let de: ServerType = serde_json::from_str(&json).unwrap();
        assert_eq!(de, ServerType::WebDav);
    }

    #[test]
    fn test_rss_article_default_group() {
        let json = "{}";
        let ra: RssArticle = serde_json::from_str(json).unwrap();
        assert_eq!(ra.group, "默认分组");
    }

    #[test]
    fn test_search_keyword_default_usage() {
        let json = r#"{"word":"test"}"#;
        let sk: SearchKeyword = serde_json::from_str(json).unwrap();
        assert_eq!(sk.word, "test");
        assert_eq!(sk.usage, 1);
    }

    #[test]
    fn test_http_tts_default() {
        let tts = HttpTts::default();
        assert_eq!(tts.concurrent_rate, Some("0".to_string()));
        assert_eq!(tts.enabled_cookie_jar, Some(false));
    }
}

// ─── HttpTTS ──────────────────────────────────────────────

/// 在线朗读引擎
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpTts {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentType")]
    pub content_type: Option<String>,
    #[serde(default, rename = "pauseDuration")]
    pub pause_duration: i32,
    #[serde(skip_serializing_if = "Option::is_none", rename = "concurrentRate")]
    pub concurrent_rate: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUrl")]
    pub login_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUi")]
    pub login_ui: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "jsLib")]
    pub js_lib: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "enabledCookieJar")]
    pub enabled_cookie_jar: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginCheckJs")]
    pub login_check_js: Option<String>,
    #[serde(default, rename = "lastUpdateTime")]
    pub last_update_time: i64,
}

impl Default for HttpTts {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            url: String::new(),
            content_type: None,
            pause_duration: 0,
            concurrent_rate: Some("0".to_string()),
            login_url: None,
            login_ui: None,
            header: None,
            js_lib: None,
            enabled_cookie_jar: Some(false),
            login_check_js: None,
            last_update_time: 0,
        }
    }
}

// ─── Bookmark ─────────────────────────────────────────────

/// 书签
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Bookmark {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub time: i64,
    #[serde(default, rename = "bookName")]
    pub book_name: String,
    #[serde(default, rename = "bookAuthor")]
    pub book_author: String,
    #[serde(default, rename = "chapterIndex")]
    pub chapter_index: i32,
    #[serde(default, rename = "chapterPos")]
    pub chapter_pos: i32,
    #[serde(default, rename = "chapterName")]
    pub chapter_name: String,
    #[serde(default, rename = "bookText")]
    pub book_text: String,
    #[serde(default)]
    pub content: String,
}

// ─── BookGroup ────────────────────────────────────────────

/// 书籍分组
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookGroup {
    #[serde(rename = "groupId")]
    pub group_id: i64,
    #[serde(default, rename = "groupName")]
    pub group_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    #[serde(default)]
    pub order: i32,
    #[serde(default = "default_true", rename = "enableRefresh")]
    pub enable_refresh: bool,
    #[serde(default = "default_true")]
    pub show: bool,
    #[serde(default = "default_neg_one_i32", rename = "bookSort")]
    pub book_sort: i32,
    /// 只更新已读
    #[serde(default, rename = "onlyUpdateRead")]
    pub only_update_read: bool,
}

impl Default for BookGroup {
    fn default() -> Self {
        Self {
            group_id: 1,
            group_name: String::new(),
            cover: None,
            order: 0,
            enable_refresh: true,
            show: true,
            book_sort: -1,
            only_update_read: false,
        }
    }
}

fn default_neg_one_i32() -> i32 {
    -1
}

// ─── AutoTaskRule ─────────────────────────────────────────

/// 自动任务规则
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutoTaskRule {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_true")]
    pub enable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cron: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUrl")]
    pub login_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginUi")]
    pub login_ui: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "loginCheckJs")]
    pub login_check_js: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
    #[serde(default)]
    pub script: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "jsLib")]
    pub js_lib: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "concurrentRate")]
    pub concurrent_rate: Option<String>,
    #[serde(default = "default_true", rename = "enabledCookieJar")]
    pub enabled_cookie_jar: bool,
    #[serde(default, rename = "customOrder")]
    pub custom_order: i32,
    #[serde(default, rename = "lastRunAt")]
    pub last_run_at: i64,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastResult")]
    pub last_result: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastError")]
    pub last_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "lastLog")]
    pub last_log: Option<String>,
}

impl Default for AutoTaskRule {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            enable: true,
            cron: Some("*/30 * * * *".to_string()),
            login_url: None,
            login_ui: None,
            login_check_js: None,
            comment: None,
            script: String::new(),
            header: None,
            js_lib: None,
            concurrent_rate: None,
            enabled_cookie_jar: true,
            custom_order: 0,
            last_run_at: 0,
            last_result: None,
            last_error: None,
            last_log: None,
        }
    }
}

impl AutoTaskRule {
    /// 导出为 JSON（剥离运行时字段）
    ///
    /// 移除 `customOrder`、`lastRunAt`、`lastResult`、`lastError`、`lastLog`
    /// 等运行时状态字段，便于跨实例迁移。
    pub fn export_json(&self) -> serde_json::Value {
        let mut json = serde_json::to_value(self).unwrap();
        if let Some(obj) = json.as_object_mut() {
            obj.remove("customOrder");
            obj.remove("lastRunAt");
            obj.remove("lastResult");
            obj.remove("lastError");
            obj.remove("lastLog");
        }
        json
    }
}

// ─── RssArticle ───────────────────────────────────────────

/// RSS文章
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RssArticle {
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub sort: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub order: i64,
    #[serde(default)]
    pub link: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "pubDate")]
    pub pub_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default = "RssArticle::default_group")]
    pub group: String,
    #[serde(default)]
    pub read: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 类型 0网页，1图片，2视频
    #[serde(default, rename = "type")]
    pub article_type: i32,
    /// 阅读进度
    #[serde(default, rename = "durPos")]
    pub dur_pos: i32,
}

impl RssArticle {
    fn default_group() -> String {
        "默认分组".to_string()
    }
}

// ─── RssStar ──────────────────────────────────────────────

/// RSS收藏
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RssStar {
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub sort: String,
    #[serde(default)]
    pub title: String,
    #[serde(default, rename = "starTime")]
    pub star_time: i64,
    #[serde(default)]
    pub link: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "pubDate")]
    pub pub_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default = "RssStar::default_group")]
    pub group: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 类型 0网页，1图片，2视频
    #[serde(default, rename = "type")]
    pub star_type: i32,
    /// 阅读进度
    #[serde(default, rename = "durPos")]
    pub dur_pos: i32,
}

impl RssStar {
    fn default_group() -> String {
        "默认分组".to_string()
    }
}

// ─── Cookie ───────────────────────────────────────────────

/// Cookie存储
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Cookie {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub cookie: String,
}

// ─── Cache ────────────────────────────────────────────────

/// 缓存
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Cache {
    #[serde(default)]
    pub key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default)]
    pub deadline: i64,
}

// ─── DictRule ─────────────────────────────────────────────

/// 字典规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DictRule {
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "urlRule")]
    pub url_rule: String,
    #[serde(default, rename = "showRule")]
    pub show_rule: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default, rename = "sortNumber")]
    pub sort_number: i32,
}

// ─── Server ───────────────────────────────────────────────

/// 服务器类型
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub enum ServerType {
    #[default]
    #[serde(rename = "WEBDAV")]
    WebDav,
}

/// 服务器
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Server {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "type")]
    pub server_type: ServerType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<String>,
    #[serde(default, rename = "sortNumber")]
    pub sort_number: i32,
}

/// WebDav配置
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct WebDavConfig {
    pub url: String,
    pub username: String,
    pub password: String,
}

// ─── BookSourcePart ───────────────────────────────────────

/// 书源部分信息（数据库视图）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookSourcePart {
    #[serde(default, rename = "bookSourceUrl")]
    pub book_source_url: String,
    #[serde(default, rename = "bookSourceName")]
    pub book_source_name: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "bookSourceGroup")]
    pub book_source_group: Option<String>,
    #[serde(default, rename = "customOrder")]
    pub custom_order: i32,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true", rename = "enabledExplore")]
    pub enabled_explore: bool,
    #[serde(default, rename = "hasLoginUrl")]
    pub has_login_url: bool,
    #[serde(default, rename = "lastUpdateTime")]
    pub last_update_time: i64,
    #[serde(default = "default_respond_time", rename = "respondTime")]
    pub respond_time: i64,
    #[serde(default)]
    pub weight: i32,
    #[serde(default, rename = "hasExploreUrl")]
    pub has_explore_url: bool,
    #[serde(default, rename = "eventListener")]
    pub event_listener: bool,
    #[serde(default, rename = "bookSourceType")]
    pub book_source_type: i32,
    #[serde(default, rename = "hasJs")]
    pub has_js: bool,
}

fn default_respond_time() -> i64 {
    180000
}

// ─── SearchKeyword ────────────────────────────────────────

/// 搜索关键词
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchKeyword {
    #[serde(default)]
    pub word: String,
    #[serde(default = "default_one")]
    pub usage: i32,
    #[serde(default, rename = "lastUseTime")]
    pub last_use_time: i64,
}

fn default_one() -> i32 {
    1
}

// ─── RuleSub ──────────────────────────────────────────────

/// 规则订阅
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RuleSub {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub url: String,
    /// 0 书源, 1 订阅源, 3 替换规则
    #[serde(default, rename = "type")]
    pub sub_type: i32,
    #[serde(default, rename = "customOrder")]
    pub custom_order: i32,
    #[serde(default, rename = "autoUpdate")]
    pub auto_update: bool,
    #[serde(default)]
    pub update: i64,
    #[serde(default, rename = "updateInterval")]
    pub update_interval: i32,
    #[serde(default, rename = "silentUpdate")]
    pub silent_update: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub js: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "showRule")]
    pub show_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "sourceUrl")]
    pub source_url: Option<String>,
}

// ─── TxtTocRule ───────────────────────────────────────────

/// TXT目录规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TxtTocRule {
    #[serde(default)]
    pub id: i64,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub rule: String,
    #[serde(default)]
    pub replacement: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub example: Option<String>,
    #[serde(default = "default_neg_one_i32", rename = "serialNumber")]
    pub serial_number: i32,
    #[serde(default = "default_true")]
    pub enable: bool,
}

// ─── BookChapterReview ────────────────────────────────────

/// 章节段评关联
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookChapterReview {
    #[serde(default, rename = "bookId")]
    pub book_id: i64,
    #[serde(default, rename = "chapterId")]
    pub chapter_id: i64,
    #[serde(default, rename = "summaryUrl")]
    pub summary_url: String,
}

// ─── KeyboardAssist ───────────────────────────────────────

/// 键盘辅助
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KeyboardAssist {
    #[serde(default, rename = "type")]
    pub assist_type: i32,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub value: String,
    #[serde(default, rename = "serialNo")]
    pub serial_no: i32,
}

// ─── ReadRecord ───────────────────────────────────────────

/// 阅读记录
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReadRecord {
    #[serde(default, rename = "deviceId")]
    pub device_id: String,
    #[serde(default, rename = "bookName")]
    pub book_name: String,
    #[serde(default, rename = "readTime")]
    pub read_time: i64,
    #[serde(default, rename = "lastRead")]
    pub last_read: i64,
}

// ─── RssReadRecord ────────────────────────────────────────

/// RSS阅读记录
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RssReadRecord {
    #[serde(default)]
    pub record: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "readTime")]
    pub read_time: Option<i64>,
    #[serde(default = "default_true")]
    pub read: bool,
    #[serde(default)]
    pub origin: String,
    #[serde(default)]
    pub sort: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    /// 类型 0网页，1图片，2视频
    #[serde(default, rename = "type")]
    pub record_type: i32,
    /// 阅读进度
    #[serde(default, rename = "durPos")]
    pub dur_pos: i32,
    #[serde(skip_serializing_if = "Option::is_none", rename = "pubDate")]
    pub pub_date: Option<String>,
}

// ─── BookProgress ─────────────────────────────────────────

/// 书籍阅读进度
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookProgress {
    pub name: String,
    pub author: String,
    #[serde(rename = "durChapterIndex")]
    pub dur_chapter_index: i32,
    #[serde(rename = "durChapterPos")]
    pub dur_chapter_pos: i32,
    #[serde(rename = "durChapterTime")]
    pub dur_chapter_time: i64,
    #[serde(skip_serializing_if = "Option::is_none", rename = "durChapterTitle")]
    pub dur_chapter_title: Option<String>,
}

// ─── ReplaceBook ──────────────────────────────────────────

/// 替换规则作用范围书籍
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReplaceBook {
    #[serde(default, rename = "bookUrl")]
    pub book_url: String,
    #[serde(default)]
    pub origin: String,
    #[serde(default, rename = "originName")]
    pub origin_name: String,
    #[serde(default, rename = "type")]
    pub book_type: i32,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "latestChapterTitle")]
    pub latest_chapter_title: Option<String>,
    #[serde(default, rename = "tocUrl")]
    pub toc_url: String,
    #[serde(default, rename = "originOrder")]
    pub origin_order: i32,
}

// ─── BookCacheInfo ────────────────────────────────────────

/// 书籍缓存信息
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookCacheInfo {
    #[serde(default, rename = "bookUrl")]
    pub book_url: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub origin: String,
    #[serde(default, rename = "originName")]
    pub origin_name: String,
    #[serde(default, rename = "type")]
    pub book_type: i32,
}

// ─── ReadRecordShow ───────────────────────────────────────

/// 阅读记录展示
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReadRecordShow {
    #[serde(default, rename = "bookName")]
    pub book_name: String,
    #[serde(default, rename = "readTime")]
    pub read_time: i64,
    #[serde(default, rename = "lastRead")]
    pub last_read: i64,
}
