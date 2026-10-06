//! 原版 Web API 的 JSON 形状（唯一真源：Kotlin 实体 + 项目 GSON 配置）
//!
//! 为什么需要投影结构：Rust [`Book`] / [`BookChapter`] 的 serde 形状与原版
//! GSON 形状并不相同 ——
//! - **null 语义（与原版一致）：null 字段省略**。项目 GSON
//!   （`utils/GsonExtensions.kt:28-51` 的 `GsonBuilder()`）**未调用
//!   `serializeNulls()`** → GSON 默认跳过 null 字段：Kotlin 可空类型字段为
//!   null 时该键**不出现**；非空类型字段（String/Int/Long/Boolean/Float）
//!   恒出现。本模块所有 `Option` 字段均以
//!   `skip_serializing_if = "Option::is_none"` 对齐该语义（2026-10-07 修正：
//!   修正前恒输出 null 键，与真实 GSON 行为相反）；
//! - Rust 侧有原版不存在的库列（`originBookUrl`、`coverOrigin`），不得外泄到
//!   原版端点；
//! - 原版实体有 Room 非持久化字段（`@Ignore`：infoHtml/tocHtml/downloadUrls/
//!   folderName/titleMD5）与新增列（`persistedCoverUrl`）；从库载入时
//!   `@Ignore` 字段为 null → GSON 省略（仅 `persistedCoverUrl` 有值时出现，
//!   Rust 库无该列 → 恒省略，登记差异 1）。
//!
//! 因此本模块按 Kotlin 源码声明顺序逐字段构造投影，`data` 元素键集与
//! 原版 Gson 输出一致（tests/legacy_web_test.rs 对键集硬编码断言：
//! 全字段非空 = 全字段集；可空字段为 null = 非空字段集）。
//!
//! 依据：
//! - `app/src/main/java/io/legado/app/data/entities/Book.kt`（34 个构造属性与
//!   类体 @Ignore 字段 infoHtml/tocHtml/downloadUrls/folderName；非空/可空
//!   类型见 :39-130）
//! - `app/src/main/java/io/legado/app/data/entities/BookChapter.kt`（17 个构造
//!   属性与类体 @Ignore 字段 titleMD5；见 :42-59、:92-94）
//! - `app/src/main/java/io/legado/app/utils/GsonExtensions.kt:28-51`（默认
//!   `GsonBuilder()`：**未调 `serializeNulls()`**、不重命名、无 Expose 模式）
//!
//! 登记差异：
//! 1. `persistedCoverUrl`：Rust `books` 表无该列（存量兼容）→ 恒省略
//!    （等价原版「未保存本地封面」；有持久封面的原版书此键会带值）；
//! 2. `Book.ReadConfig.tocExpanded` / `manualReplaceRuleIds`：Rust `ReadConfig`
//!    模型未承载（旧 JSON 无键），按 Kotlin 默认值 true / [] 输出；
//! 3. Rust 侧 `ReadConfig` 独有字段（mangaScrollMode/webtoonSidePaddingDp）
//!    不出现在原版形状中（Vue 前端不使用）。
//!
//! 另登记（净化链，见 book_api.rs）：`readConfig.useReplaceRule` 为 null 时
//! 的净化默认值由 `Book.getUseReplaceRule()`（Book.kt:226-236）决定，与服务端
//! 投影无关（本投影原样输出该键或省略）。

use legado_core::models::{Book, BookChapter, ReadConfig};
use serde::Serialize;

/// 原版 `Book` 的 Gson JSON 形状（null 字段省略，对齐 GSON 默认）
#[derive(Debug, Serialize)]
pub struct LegacyBook {
    #[serde(rename = "bookUrl")]
    pub book_url: String,
    #[serde(rename = "tocUrl")]
    pub toc_url: String,
    pub origin: String,
    #[serde(rename = "originName")]
    pub origin_name: String,
    pub name: String,
    pub author: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(rename = "customTag", skip_serializing_if = "Option::is_none")]
    pub custom_tag: Option<String>,
    #[serde(rename = "coverUrl", skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
    #[serde(rename = "customCoverUrl", skip_serializing_if = "Option::is_none")]
    pub custom_cover_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    #[serde(rename = "customIntro", skip_serializing_if = "Option::is_none")]
    pub custom_intro: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub charset: Option<String>,
    #[serde(rename = "type")]
    pub book_type: i32,
    pub group: i64,
    #[serde(rename = "latestChapterTitle", skip_serializing_if = "Option::is_none")]
    pub latest_chapter_title: Option<String>,
    #[serde(rename = "latestChapterTime")]
    pub latest_chapter_time: i64,
    #[serde(rename = "lastCheckTime")]
    pub last_check_time: i64,
    #[serde(rename = "lastCheckCount")]
    pub last_check_count: i32,
    #[serde(rename = "totalChapterNum")]
    pub total_chapter_num: i32,
    #[serde(rename = "durChapterTitle", skip_serializing_if = "Option::is_none")]
    pub dur_chapter_title: Option<String>,
    #[serde(rename = "durChapterIndex")]
    pub dur_chapter_index: i32,
    #[serde(rename = "durVolumeIndex")]
    pub dur_volume_index: i32,
    #[serde(rename = "chapterInVolumeIndex")]
    pub chapter_in_volume_index: i32,
    #[serde(rename = "durChapterPos")]
    pub dur_chapter_pos: i32,
    #[serde(rename = "durChapterTime")]
    pub dur_chapter_time: i64,
    #[serde(rename = "wordCount", skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    #[serde(rename = "canUpdate")]
    pub can_update: bool,
    pub order: i32,
    #[serde(rename = "originOrder")]
    pub origin_order: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    #[serde(rename = "readConfig", skip_serializing_if = "Option::is_none")]
    pub read_config: Option<LegacyReadConfig>,
    #[serde(rename = "syncTime")]
    pub sync_time: i64,
    /// Rust 库无此列（原版 Room 列 persistedCoverUrl）→ 恒 null（登记差异 1）
    #[serde(rename = "persistedCoverUrl", skip_serializing_if = "Option::is_none")]
    pub persisted_cover_url: Option<String>,
    /// 原版 Room `@Ignore` 字段，从库载入恒 null（GSON 省略）
    #[serde(rename = "infoHtml", skip_serializing_if = "Option::is_none")]
    pub info_html: Option<String>,
    #[serde(rename = "tocHtml", skip_serializing_if = "Option::is_none")]
    pub toc_html: Option<String>,
    #[serde(rename = "downloadUrls", skip_serializing_if = "Option::is_none")]
    pub download_urls: Option<Vec<String>>,
    /// 原版私有字段（从库载入恒 null → GSON 省略）
    #[serde(rename = "folderName", skip_serializing_if = "Option::is_none")]
    pub folder_name: Option<String>,
}

impl From<&Book> for LegacyBook {
    fn from(book: &Book) -> Self {
        Self {
            book_url: book.book_url.clone(),
            toc_url: book.toc_url.clone(),
            origin: book.origin.clone(),
            origin_name: book.origin_name.clone(),
            name: book.name.clone(),
            author: book.author.clone(),
            kind: book.kind.clone(),
            custom_tag: book.custom_tag.clone(),
            cover_url: book.cover_url.clone(),
            custom_cover_url: book.custom_cover_url.clone(),
            intro: book.intro.clone(),
            custom_intro: book.custom_intro.clone(),
            charset: book.charset.clone(),
            book_type: book.book_type,
            group: book.group,
            latest_chapter_title: book.latest_chapter_title.clone(),
            latest_chapter_time: book.latest_chapter_time,
            last_check_time: book.last_check_time,
            last_check_count: book.last_check_count,
            total_chapter_num: book.total_chapter_num,
            dur_chapter_title: book.dur_chapter_title.clone(),
            dur_chapter_index: book.dur_chapter_index,
            dur_volume_index: book.dur_volume_index,
            chapter_in_volume_index: book.chapter_in_volume_index,
            dur_chapter_pos: book.dur_chapter_pos,
            dur_chapter_time: book.dur_chapter_time,
            word_count: book.word_count.clone(),
            can_update: book.can_update,
            order: book.order,
            origin_order: book.origin_order,
            variable: book.variable.clone(),
            read_config: book.read_config.as_ref().map(LegacyReadConfig::from),
            sync_time: book.sync_time,
            persisted_cover_url: None,
            info_html: None,
            toc_html: None,
            download_urls: None,
            folder_name: None,
        }
    }
}

/// 原版 `Book.ReadConfig` 的 Gson JSON 形状（Kotlin 声明顺序；null 字段省略）
#[derive(Debug, Serialize)]
pub struct LegacyReadConfig {
    #[serde(rename = "reverseToc")]
    pub reverse_toc: bool,
    /// Rust 模型未承载 → Kotlin 默认 true
    #[serde(rename = "tocExpanded")]
    pub toc_expanded: bool,
    #[serde(rename = "pageAnim", skip_serializing_if = "Option::is_none")]
    pub page_anim: Option<i32>,
    #[serde(rename = "reSegment")]
    pub re_segment: bool,
    #[serde(rename = "imageStyle", skip_serializing_if = "Option::is_none")]
    pub image_style: Option<String>,
    #[serde(rename = "useReplaceRule", skip_serializing_if = "Option::is_none")]
    pub use_replace_rule: Option<bool>,
    #[serde(rename = "delTag")]
    pub del_tag: i64,
    #[serde(rename = "ttsEngine", skip_serializing_if = "Option::is_none")]
    pub tts_engine: Option<String>,
    #[serde(rename = "splitLongChapter")]
    pub split_long_chapter: bool,
    #[serde(rename = "readSimulating")]
    pub read_simulating: bool,
    #[serde(rename = "startDate", skip_serializing_if = "Option::is_none")]
    pub start_date: Option<String>,
    #[serde(rename = "startChapter", skip_serializing_if = "Option::is_none")]
    pub start_chapter: Option<i32>,
    #[serde(rename = "dailyChapters")]
    pub daily_chapters: i32,
    #[serde(rename = "openCredits")]
    pub open_credits: i32,
    #[serde(rename = "closeCredits")]
    pub close_credits: i32,
    #[serde(rename = "playMode")]
    pub play_mode: i32,
    #[serde(rename = "playSpeed")]
    pub play_speed: f32,
    #[serde(rename = "useGlobalAudioSkip")]
    pub use_global_audio_skip: bool,
    /// Rust 模型未承载 → Kotlin 默认空列表（非空类型 → 恒输出 []）
    #[serde(rename = "manualReplaceRuleIds")]
    pub manual_replace_rule_ids: Vec<i64>,
}

impl From<&ReadConfig> for LegacyReadConfig {
    fn from(config: &ReadConfig) -> Self {
        Self {
            reverse_toc: config.reverse_toc,
            toc_expanded: true,
            page_anim: config.page_anim,
            re_segment: config.re_segment,
            image_style: config.image_style.clone(),
            use_replace_rule: config.use_replace_rule,
            del_tag: config.del_tag,
            tts_engine: config.tts_engine.clone(),
            split_long_chapter: config.split_long_chapter,
            read_simulating: config.read_simulating,
            start_date: config.start_date.clone(),
            start_chapter: config.start_chapter,
            daily_chapters: config.daily_chapters,
            open_credits: config.open_credits,
            close_credits: config.close_credits,
            play_mode: config.play_mode,
            play_speed: config.play_speed,
            use_global_audio_skip: config.use_global_audio_skip,
            manual_replace_rule_ids: Vec::new(),
        }
    }
}

/// 原版 `BookChapter` 的 Gson JSON 形状（Kotlin 声明顺序；null 字段省略）
#[derive(Debug, Serialize)]
pub struct LegacyBookChapter {
    pub url: String,
    pub title: String,
    #[serde(rename = "isVolume")]
    pub is_volume: bool,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
    #[serde(rename = "bookUrl")]
    pub book_url: String,
    pub index: i32,
    #[serde(rename = "isVip")]
    pub is_vip: bool,
    #[serde(rename = "isPay")]
    pub is_pay: bool,
    #[serde(rename = "resourceUrl", skip_serializing_if = "Option::is_none")]
    pub resource_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(rename = "wordCount", skip_serializing_if = "Option::is_none")]
    pub word_count: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<i64>,
    #[serde(rename = "startFragmentId", skip_serializing_if = "Option::is_none")]
    pub start_fragment_id: Option<String>,
    #[serde(rename = "endFragmentId", skip_serializing_if = "Option::is_none")]
    pub end_fragment_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    #[serde(rename = "imgUrl", skip_serializing_if = "Option::is_none")]
    pub img_url: Option<String>,
    /// 原版 Room `@Ignore` 字段，从库载入恒 null（GSON 省略）
    #[serde(rename = "titleMD5", skip_serializing_if = "Option::is_none")]
    pub title_md5: Option<String>,
}

impl From<&BookChapter> for LegacyBookChapter {
    fn from(chapter: &BookChapter) -> Self {
        Self {
            url: chapter.url.clone(),
            title: chapter.title.clone(),
            is_volume: chapter.is_volume,
            base_url: chapter.base_url.clone(),
            book_url: chapter.book_url.clone(),
            index: chapter.index,
            is_vip: chapter.is_vip,
            is_pay: chapter.is_pay,
            resource_url: chapter.resource_url.clone(),
            tag: chapter.tag.clone(),
            word_count: chapter.word_count.clone(),
            start: chapter.start,
            end: chapter.end,
            start_fragment_id: chapter.start_fragment_id.clone(),
            end_fragment_id: chapter.end_fragment_id.clone(),
            variable: chapter.variable.clone(),
            img_url: chapter.img_url.clone(),
            title_md5: None,
        }
    }
}

/// `Book.kt` 非空字段（Kotlin 非可空类型 → GSON 恒输出）
#[cfg(test)]
const BOOK_REQUIRED_KEYS: &[&str] = &[
    "bookUrl",
    "tocUrl",
    "origin",
    "originName",
    "name",
    "author",
    "type",
    "group",
    "latestChapterTime",
    "lastCheckTime",
    "lastCheckCount",
    "totalChapterNum",
    "durChapterIndex",
    "durVolumeIndex",
    "chapterInVolumeIndex",
    "durChapterPos",
    "durChapterTime",
    "canUpdate",
    "order",
    "originOrder",
    "syncTime",
];

/// `Book.kt` 可空字段（Kotlin `String?`/`Int?`/… → GSON 默认省略 null 键）
#[cfg(test)]
const BOOK_NULLABLE_KEYS: &[&str] = &[
    "kind",
    "customTag",
    "coverUrl",
    "customCoverUrl",
    "intro",
    "customIntro",
    "charset",
    "latestChapterTitle",
    "durChapterTitle",
    "wordCount",
    "variable",
    "readConfig",
    "persistedCoverUrl",
    "infoHtml",
    "tocHtml",
    "downloadUrls",
    "folderName",
];

/// `Book.kt:492-514` ReadConfig 非空字段
#[cfg(test)]
const READ_CONFIG_REQUIRED_KEYS: &[&str] = &[
    "reverseToc",
    "tocExpanded",
    "reSegment",
    "delTag",
    "splitLongChapter",
    "readSimulating",
    "dailyChapters",
    "openCredits",
    "closeCredits",
    "playMode",
    "playSpeed",
    "useGlobalAudioSkip",
    "manualReplaceRuleIds",
];

/// `Book.kt:492-514` ReadConfig 可空字段
#[cfg(test)]
const READ_CONFIG_NULLABLE_KEYS: &[&str] = &[
    "pageAnim",
    "imageStyle",
    "useReplaceRule",
    "ttsEngine",
    "startDate",
    "startChapter",
];

/// `BookChapter.kt:42-59` 非空字段
#[cfg(test)]
const CHAPTER_REQUIRED_KEYS: &[&str] = &[
    "url", "title", "isVolume", "baseUrl", "bookUrl", "index", "isVip", "isPay",
];

/// `BookChapter.kt:42-59` 可空字段（含类体 @Ignore `titleMD5`）
#[cfg(test)]
const CHAPTER_NULLABLE_KEYS: &[&str] = &[
    "resourceUrl",
    "tag",
    "wordCount",
    "start",
    "end",
    "startFragmentId",
    "endFragmentId",
    "variable",
    "imgUrl",
    "titleMD5",
];

#[cfg(test)]
fn object_keys(value: &serde_json::Value) -> Vec<String> {
    value
        .as_object()
        .unwrap()
        .keys()
        .map(|k| k.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// 先红后绿（P1-1）：GSON 默认省略 null（`GsonExtensions.kt:28-51` 未调
    /// `serializeNulls()`）——默认 `Book` 的可空字段全为 null → **键不出现**。
    /// 修复前本实现恒输出 null 键（38 键），故本测试先红。
    #[test]
    fn test_legacy_book_omits_null_fields_like_gson_default() {
        let value = serde_json::to_value(LegacyBook::from(&Book::default())).unwrap();
        let keys = object_keys(&value);
        for key in BOOK_REQUIRED_KEYS {
            assert!(keys.iter().any(|k| k == key), "非空字段 {key} 必须恒在");
        }
        for key in BOOK_NULLABLE_KEYS {
            assert!(
                !keys.iter().any(|k| k == key),
                "null 字段 {key} 应按 GSON 默认省略（实际输出：{keys:?}）"
            );
        }
        assert_eq!(keys.len(), BOOK_REQUIRED_KEYS.len(), "键集={keys:?}");
    }

    /// 可空字段有值时键必须出现（GSON 仅在 null 时省略）
    #[test]
    fn test_legacy_book_optional_fields_present_when_set() {
        let book = Book {
            kind: Some("分类".to_string()),
            custom_tag: Some("标签".to_string()),
            cover_url: Some("https://x/c.jpg".to_string()),
            custom_cover_url: Some("D:/covers/c.png".to_string()),
            intro: Some("简介".to_string()),
            custom_intro: Some("自定义简介".to_string()),
            charset: Some("UTF-8".to_string()),
            latest_chapter_title: Some("最新章".to_string()),
            dur_chapter_title: Some("当前章".to_string()),
            word_count: Some("1万字".to_string()),
            variable: Some("{}".to_string()),
            read_config: Some(ReadConfig::default()),
            ..Book::default()
        };
        let value = serde_json::to_value(LegacyBook::from(&book)).unwrap();
        let keys = object_keys(&value);
        for key in BOOK_REQUIRED_KEYS {
            assert!(keys.iter().any(|k| k == key), "非空字段 {key} 必须恒在");
        }
        for key in [
            "kind",
            "customTag",
            "coverUrl",
            "customCoverUrl",
            "intro",
            "customIntro",
            "charset",
            "latestChapterTitle",
            "durChapterTitle",
            "wordCount",
            "variable",
            "readConfig",
        ] {
            assert!(keys.iter().any(|k| k == key), "非 null 字段 {key} 必须出现");
        }
        // Rust 无该列 / 原版 @Ignore 恒 null 字段 → 仍省略
        for key in [
            "persistedCoverUrl",
            "infoHtml",
            "tocHtml",
            "downloadUrls",
            "folderName",
        ] {
            assert!(
                !keys.iter().any(|k| k == key),
                "恒 null 字段 {key} 不应出现"
            );
        }
    }

    /// 先红后绿（P1-1）：ReadConfig 可空字段 null 时省略，非空字段恒在
    #[test]
    fn test_read_config_omits_null_fields_like_gson_default() {
        let value = serde_json::to_value(LegacyReadConfig::from(&ReadConfig::default())).unwrap();
        let keys = object_keys(&value);
        for key in READ_CONFIG_REQUIRED_KEYS {
            assert!(keys.iter().any(|k| k == key), "非空字段 {key} 必须恒在");
        }
        for key in READ_CONFIG_NULLABLE_KEYS {
            assert!(
                !keys.iter().any(|k| k == key),
                "null 字段 {key} 应按 GSON 默认省略（实际输出：{keys:?}）"
            );
        }
        assert_eq!(keys.len(), READ_CONFIG_REQUIRED_KEYS.len(), "键集={keys:?}");
        assert_eq!(value["tocExpanded"], Value::Bool(true));
        assert_eq!(value["manualReplaceRuleIds"], Value::Array(vec![]));
    }

    /// ReadConfig 可空字段有值时键出现
    #[test]
    fn test_read_config_optional_fields_present_when_set() {
        let config = ReadConfig {
            page_anim: Some(1),
            image_style: Some("FULL".to_string()),
            use_replace_rule: Some(true),
            tts_engine: Some("engine".to_string()),
            start_date: Some("2026-01-01".to_string()),
            start_chapter: Some(3),
            ..ReadConfig::default()
        };
        let value = serde_json::to_value(LegacyReadConfig::from(&config)).unwrap();
        let keys = object_keys(&value);
        for key in READ_CONFIG_NULLABLE_KEYS {
            assert!(keys.iter().any(|k| k == key), "非 null 字段 {key} 必须出现");
        }
        assert_eq!(
            keys.len(),
            READ_CONFIG_REQUIRED_KEYS.len() + READ_CONFIG_NULLABLE_KEYS.len()
        );
    }

    /// 先红后绿（P1-1）：BookChapter 可空字段 null 时省略
    #[test]
    fn test_legacy_chapter_omits_null_fields_like_gson_default() {
        let chapter = BookChapter::default();
        let value = serde_json::to_value(LegacyBookChapter::from(&chapter)).unwrap();
        let keys = object_keys(&value);
        for key in CHAPTER_REQUIRED_KEYS {
            assert!(keys.iter().any(|k| k == key), "非空字段 {key} 必须恒在");
        }
        for key in CHAPTER_NULLABLE_KEYS {
            assert!(
                !keys.iter().any(|k| k == key),
                "null 字段 {key} 应按 GSON 默认省略（实际输出：{keys:?}）"
            );
        }
        assert_eq!(keys.len(), CHAPTER_REQUIRED_KEYS.len(), "键集={keys:?}");
    }

    /// BookChapter 可空字段有值时键出现
    #[test]
    fn test_legacy_chapter_optional_fields_present_when_set() {
        let chapter = BookChapter {
            resource_url: Some("https://x/a.mp3".to_string()),
            tag: Some("2026-10-07".to_string()),
            word_count: Some("3000".to_string()),
            start: Some(1),
            end: Some(9),
            start_fragment_id: Some("f1".to_string()),
            end_fragment_id: Some("f2".to_string()),
            variable: Some("{}".to_string()),
            img_url: Some("https://x/a.jpg".to_string()),
            ..BookChapter::default()
        };
        let value = serde_json::to_value(LegacyBookChapter::from(&chapter)).unwrap();
        let keys = object_keys(&value);
        for key in CHAPTER_NULLABLE_KEYS {
            if *key == "titleMD5" {
                // Rust 无 @Ignore 字段来源（章节文件命名缓存未承载）→ 恒省略
                assert!(!keys.iter().any(|k| k == key));
                continue;
            }
            assert!(keys.iter().any(|k| k == key), "非 null 字段 {key} 必须出现");
        }
    }
}
