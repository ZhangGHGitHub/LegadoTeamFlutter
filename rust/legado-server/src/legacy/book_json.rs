//! 原版 Web API 的 JSON 形状（唯一真源：Kotlin 实体 + 项目 GSON 配置）
//!
//! 为什么需要投影结构：Rust [`Book`] / [`BookChapter`] 的 serde 形状与原版
//! GSON 形状并不相同 ——
//! - Rust 侧 `skip_serializing_if = "Option::is_none"` 会省略 null 键，
//!   而项目 GSON（`utils/GsonExtensions.kt` 的 `GsonBuilder()`）默认**不省略
//!   null**，字段恒在；
//! - Rust 侧有原版不存在的库列（`originBookUrl`、`coverOrigin`），不得外泄到
//!   原版端点；
//! - 原版实体有 Room 非持久化字段（`@Ignore`：infoHtml/tocHtml/downloadUrls/
//!   folderName/titleMD5）与新增列（`persistedCoverUrl`），GSON 仍会序列化
//!   （从 Room 载入时为 null）。
//!
//! 因此本模块按 Kotlin 源码声明顺序逐字段构造投影，`data` 元素键集与
//! 原版 Gson 输出一致（tests/legacy_web_test.rs 对键集硬编码断言）。
//!
//! 依据：
//! - `app/src/main/java/io/legado/app/data/entities/Book.kt`（34 个构造属性
//!   + 类体 @Ignore 字段 infoHtml/tocHtml/downloadUrls/folderName）
//! - `app/src/main/java/io/legado/app/data/entities/BookChapter.kt`（17 个构造
//!   属性 + 类体 @Ignore 字段 titleMD5）
//! - `app/src/main/java/io/legado/app/utils/GsonExtensions.kt`（默认
//!   `GsonBuilder()`：不省略 null、不重命名、无 Expose 模式）
//!
//! 登记差异：
//! 1. `persistedCoverUrl`：Rust `books` 表无该列（存量兼容），恒输出 null；
//! 2. `Book.ReadConfig.tocExpanded` / `manualReplaceRuleIds`：Rust `ReadConfig`
//!    模型未承载（旧 JSON 无键），按 Kotlin 默认值 true / [] 输出；
//! 3. Rust 侧 `ReadConfig` 独有字段（mangaScrollMode/webtoonSidePaddingDp）
//!    不出现在原版形状中（Vue 前端不使用）。

use legado_core::models::{Book, BookChapter, ReadConfig};
use serde::Serialize;

/// 原版 `Book` 的 Gson JSON 形状
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
    pub kind: Option<String>,
    #[serde(rename = "customTag")]
    pub custom_tag: Option<String>,
    #[serde(rename = "coverUrl")]
    pub cover_url: Option<String>,
    #[serde(rename = "customCoverUrl")]
    pub custom_cover_url: Option<String>,
    pub intro: Option<String>,
    #[serde(rename = "customIntro")]
    pub custom_intro: Option<String>,
    pub charset: Option<String>,
    #[serde(rename = "type")]
    pub book_type: i32,
    pub group: i64,
    #[serde(rename = "latestChapterTitle")]
    pub latest_chapter_title: Option<String>,
    #[serde(rename = "latestChapterTime")]
    pub latest_chapter_time: i64,
    #[serde(rename = "lastCheckTime")]
    pub last_check_time: i64,
    #[serde(rename = "lastCheckCount")]
    pub last_check_count: i32,
    #[serde(rename = "totalChapterNum")]
    pub total_chapter_num: i32,
    #[serde(rename = "durChapterTitle")]
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
    #[serde(rename = "wordCount")]
    pub word_count: Option<String>,
    #[serde(rename = "canUpdate")]
    pub can_update: bool,
    pub order: i32,
    #[serde(rename = "originOrder")]
    pub origin_order: i32,
    pub variable: Option<String>,
    #[serde(rename = "readConfig")]
    pub read_config: Option<LegacyReadConfig>,
    #[serde(rename = "syncTime")]
    pub sync_time: i64,
    /// Rust 库无此列（原版 Room 列 persistedCoverUrl）→ 恒 null
    #[serde(rename = "persistedCoverUrl")]
    pub persisted_cover_url: Option<String>,
    /// 原版 Room `@Ignore` 字段，从库载入恒 null
    #[serde(rename = "infoHtml")]
    pub info_html: Option<String>,
    #[serde(rename = "tocHtml")]
    pub toc_html: Option<String>,
    #[serde(rename = "downloadUrls")]
    pub download_urls: Option<Vec<String>>,
    /// 原版私有字段（Gson 反射序列化为 null）
    #[serde(rename = "folderName")]
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

/// 原版 `Book.ReadConfig` 的 Gson JSON 形状（Kotlin 声明顺序）
#[derive(Debug, Serialize)]
pub struct LegacyReadConfig {
    #[serde(rename = "reverseToc")]
    pub reverse_toc: bool,
    /// Rust 模型未承载 → Kotlin 默认 true
    #[serde(rename = "tocExpanded")]
    pub toc_expanded: bool,
    #[serde(rename = "pageAnim")]
    pub page_anim: Option<i32>,
    #[serde(rename = "reSegment")]
    pub re_segment: bool,
    #[serde(rename = "imageStyle")]
    pub image_style: Option<String>,
    #[serde(rename = "useReplaceRule")]
    pub use_replace_rule: Option<bool>,
    #[serde(rename = "delTag")]
    pub del_tag: i64,
    #[serde(rename = "ttsEngine")]
    pub tts_engine: Option<String>,
    #[serde(rename = "splitLongChapter")]
    pub split_long_chapter: bool,
    #[serde(rename = "readSimulating")]
    pub read_simulating: bool,
    #[serde(rename = "startDate")]
    pub start_date: Option<String>,
    #[serde(rename = "startChapter")]
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
    /// Rust 模型未承载 → Kotlin 默认空列表
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

/// 原版 `BookChapter` 的 Gson JSON 形状（Kotlin 声明顺序）
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
    #[serde(rename = "resourceUrl")]
    pub resource_url: Option<String>,
    pub tag: Option<String>,
    #[serde(rename = "wordCount")]
    pub word_count: Option<String>,
    pub start: Option<i64>,
    pub end: Option<i64>,
    #[serde(rename = "startFragmentId")]
    pub start_fragment_id: Option<String>,
    #[serde(rename = "endFragmentId")]
    pub end_fragment_id: Option<String>,
    pub variable: Option<String>,
    #[serde(rename = "imgUrl")]
    pub img_url: Option<String>,
    /// 原版 Room `@Ignore` 字段，从库载入恒 null
    #[serde(rename = "titleMD5")]
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn test_legacy_book_key_set_matches_kotlin_gson() {
        let book = Book::default();
        let value = serde_json::to_value(LegacyBook::from(&book)).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        let mut expected = vec![
            "bookUrl",
            "tocUrl",
            "origin",
            "originName",
            "name",
            "author",
            "kind",
            "customTag",
            "coverUrl",
            "customCoverUrl",
            "intro",
            "customIntro",
            "charset",
            "type",
            "group",
            "latestChapterTitle",
            "latestChapterTime",
            "lastCheckTime",
            "lastCheckCount",
            "totalChapterNum",
            "durChapterTitle",
            "durChapterIndex",
            "durVolumeIndex",
            "chapterInVolumeIndex",
            "durChapterPos",
            "durChapterTime",
            "wordCount",
            "canUpdate",
            "order",
            "originOrder",
            "variable",
            "readConfig",
            "syncTime",
            "persistedCoverUrl",
            "infoHtml",
            "tocHtml",
            "downloadUrls",
            "folderName",
        ];
        expected.sort_unstable();
        assert_eq!(keys, expected);
    }

    #[test]
    fn test_read_config_key_set() {
        let value = serde_json::to_value(LegacyReadConfig::from(&ReadConfig::default())).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        let mut expected = vec![
            "reverseToc",
            "tocExpanded",
            "pageAnim",
            "reSegment",
            "imageStyle",
            "useReplaceRule",
            "delTag",
            "ttsEngine",
            "splitLongChapter",
            "readSimulating",
            "startDate",
            "startChapter",
            "dailyChapters",
            "openCredits",
            "closeCredits",
            "playMode",
            "playSpeed",
            "useGlobalAudioSkip",
            "manualReplaceRuleIds",
        ];
        expected.sort_unstable();
        assert_eq!(keys, expected);
        assert_eq!(value["tocExpanded"], Value::Bool(true));
        assert_eq!(value["manualReplaceRuleIds"], Value::Array(vec![]));
    }

    #[test]
    fn test_legacy_chapter_key_set_matches_kotlin_gson() {
        let chapter = BookChapter::default();
        let value = serde_json::to_value(LegacyBookChapter::from(&chapter)).unwrap();
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        keys.sort_unstable();
        let mut expected = vec![
            "url",
            "title",
            "isVolume",
            "baseUrl",
            "bookUrl",
            "index",
            "isVip",
            "isPay",
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
        expected.sort_unstable();
        assert_eq!(keys, expected);
    }
}
