use serde::{Deserialize, Serialize};

/// 书籍类型常量
pub mod book_type {
    pub const TEXT: i32 = 0;
    pub const AUDIO: i32 = 1;
    pub const IMAGE: i32 = 2;
    pub const FILE: i32 = 3;
    pub const VIDEO: i32 = 4;
    pub const LOCAL: i32 = 0x1000;
    pub const ALL_BOOK_TYPE_LOCAL: i32 = 0x1000;
    pub const LOCAL_TAG: &str = "loc_book";
    pub const WEB_DAV_TAG: &str = "dav:";
}

/// 阅读配置
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReadConfig {
    #[serde(default, rename = "reverseToc")]
    pub reverse_toc: bool,
    #[serde(skip_serializing_if = "Option::is_none", rename = "pageAnim")]
    pub page_anim: Option<i32>,
    #[serde(default, rename = "reSegment")]
    pub re_segment: bool,
    #[serde(skip_serializing_if = "Option::is_none", rename = "imageStyle")]
    pub image_style: Option<String>,
    /// 正文使用净化替换规则
    #[serde(skip_serializing_if = "Option::is_none", rename = "useReplaceRule")]
    pub use_replace_rule: Option<bool>,
    /// 去除标签
    #[serde(default, rename = "delTag")]
    pub del_tag: i64,
    #[serde(skip_serializing_if = "Option::is_none", rename = "ttsEngine")]
    pub tts_engine: Option<String>,
    #[serde(default = "default_true", rename = "splitLongChapter")]
    pub split_long_chapter: bool,
    #[serde(default, rename = "readSimulating")]
    pub read_simulating: bool,
    #[serde(skip_serializing_if = "Option::is_none", rename = "startDate")]
    pub start_date: Option<String>,
    /// 用户设置的起始章节
    #[serde(skip_serializing_if = "Option::is_none", rename = "startChapter")]
    pub start_chapter: Option<i32>,
    /// 用户设置的每日更新章节数
    #[serde(default = "default_daily_chapters", rename = "dailyChapters")]
    pub daily_chapters: i32,
    /// 音频片头
    #[serde(default, rename = "openCredits")]
    pub open_credits: i32,
    /// 音频片尾
    #[serde(default, rename = "closeCredits")]
    pub close_credits: i32,
    /// 音频播放模式
    #[serde(default, rename = "playMode")]
    pub play_mode: i32,
    /// 音频播放速度
    #[serde(default = "default_play_speed", rename = "playSpeed")]
    pub play_speed: f32,
}

fn default_true() -> bool {
    true
}

fn default_daily_chapters() -> i32 {
    3
}

fn default_play_speed() -> f32 {
    1.0
}

/// 书籍实体
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Book {
    /// 详情页Url(本地书源存储完整文件路径)
    #[serde(default, rename = "bookUrl")]
    pub book_url: String,
    /// 目录页Url
    #[serde(default, rename = "tocUrl")]
    pub toc_url: String,
    /// 书源URL(默认BookType.local)
    #[serde(default = "Book::default_origin")]
    pub origin: String,
    /// 书源名称 or 本地书籍文件名
    #[serde(default, rename = "originName")]
    pub origin_name: String,
    /// 书籍名称(书源获取)
    #[serde(default)]
    pub name: String,
    /// 作者名称(书源获取)
    #[serde(default)]
    pub author: String,
    /// 分类信息(书源获取)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 分类信息(用户修改)
    #[serde(skip_serializing_if = "Option::is_none", rename = "customTag")]
    pub custom_tag: Option<String>,
    /// 封面Url(书源获取)
    #[serde(skip_serializing_if = "Option::is_none", rename = "coverUrl")]
    pub cover_url: Option<String>,
    /// 封面Url(用户修改)
    #[serde(skip_serializing_if = "Option::is_none", rename = "customCoverUrl")]
    pub custom_cover_url: Option<String>,
    /// 简介内容(书源获取)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intro: Option<String>,
    /// 简介内容(用户修改)
    #[serde(skip_serializing_if = "Option::is_none", rename = "customIntro")]
    pub custom_intro: Option<String>,
    /// 自定义字符集名称(仅适用于本地书籍)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub charset: Option<String>,
    /// 类型，详见BookType
    #[serde(default, rename = "type")]
    pub book_type: i32,
    /// 自定义分组索引号
    #[serde(default)]
    pub group: i64,
    /// 最新章节标题
    #[serde(skip_serializing_if = "Option::is_none", rename = "latestChapterTitle")]
    pub latest_chapter_title: Option<String>,
    /// 最新章节标题更新时间
    #[serde(default, rename = "latestChapterTime")]
    pub latest_chapter_time: i64,
    /// 最近一次更新书籍信息的时间
    #[serde(default, rename = "lastCheckTime")]
    pub last_check_time: i64,
    /// 最近一次发现新章节的数量
    #[serde(default, rename = "lastCheckCount")]
    pub last_check_count: i32,
    /// 书籍目录总数
    #[serde(default, rename = "totalChapterNum")]
    pub total_chapter_num: i32,
    /// 当前章节名称
    #[serde(skip_serializing_if = "Option::is_none", rename = "durChapterTitle")]
    pub dur_chapter_title: Option<String>,
    /// 当前章节索引
    #[serde(default, rename = "durChapterIndex")]
    pub dur_chapter_index: i32,
    /// 当前卷索引
    #[serde(default, rename = "durVolumeIndex")]
    pub dur_volume_index: i32,
    /// 相对于卷的索引
    #[serde(default, rename = "chapterInVolumeIndex")]
    pub chapter_in_volume_index: i32,
    /// 当前阅读的进度(首行字符的索引位置)
    #[serde(default, rename = "durChapterPos")]
    pub dur_chapter_pos: i32,
    /// 最近一次阅读书籍的时间(打开正文的时间)
    #[serde(default, rename = "durChapterTime")]
    pub dur_chapter_time: i64,
    /// 字数
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
    /// 刷新书架时更新书籍信息
    #[serde(default = "default_true", rename = "canUpdate")]
    pub can_update: bool,
    /// 手动排序
    #[serde(default)]
    pub order: i32,
    /// 书源排序
    #[serde(default, rename = "originOrder")]
    pub origin_order: i32,
    /// 自定义书籍变量信息
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 阅读设置
    #[serde(skip_serializing_if = "Option::is_none", rename = "readConfig")]
    pub read_config: Option<ReadConfig>,
    /// 同步时间
    #[serde(default, rename = "syncTime")]
    pub sync_time: i64,
}

impl Default for Book {
    fn default() -> Self {
        Self {
            book_url: String::new(),
            toc_url: String::new(),
            origin: book_type::LOCAL_TAG.to_string(),
            origin_name: String::new(),
            name: String::new(),
            author: String::new(),
            kind: None,
            custom_tag: None,
            cover_url: None,
            custom_cover_url: None,
            intro: None,
            custom_intro: None,
            charset: None,
            book_type: book_type::TEXT,
            group: 0,
            latest_chapter_title: None,
            latest_chapter_time: 0,
            last_check_time: 0,
            last_check_count: 0,
            total_chapter_num: 0,
            dur_chapter_title: None,
            dur_chapter_index: 0,
            dur_volume_index: 0,
            chapter_in_volume_index: 0,
            dur_chapter_pos: 0,
            dur_chapter_time: 0,
            word_count: None,
            can_update: true,
            order: 0,
            origin_order: 0,
            variable: None,
            read_config: None,
            sync_time: 0,
        }
    }
}

impl Book {
    fn default_origin() -> String {
        book_type::LOCAL_TAG.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_default() {
        let book = Book::default();
        assert_eq!(book.origin, book_type::LOCAL_TAG);
        assert_eq!(book.book_type, book_type::TEXT);
        assert!(book.can_update);
        assert!(book.name.is_empty());
        assert!(book.author.is_empty());
        assert_eq!(book.total_chapter_num, 0);
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn test_book_serde_roundtrip() {
        let mut book = Book::default();
        book.book_url = "https://example.com/book/1".to_string();
        book.name = "测试书籍".to_string();
        book.author = "测试作者".to_string();
        book.book_type = book_type::AUDIO;
        book.total_chapter_num = 100;

        let json = serde_json::to_string(&book).unwrap();
        let deserialized: Book = serde_json::from_str(&json).unwrap();

        assert_eq!(deserialized.book_url, book.book_url);
        assert_eq!(deserialized.name, book.name);
        assert_eq!(deserialized.author, book.author);
        assert_eq!(deserialized.book_type, book_type::AUDIO);
        assert_eq!(deserialized.total_chapter_num, 100);
    }

    #[test]
    fn test_book_json_field_names() {
        let book = Book::default();
        let json = serde_json::to_value(&book).unwrap();
        let obj = json.as_object().unwrap();
        assert!(obj.contains_key("bookUrl"));
        assert!(obj.contains_key("tocUrl"));
        assert!(obj.contains_key("originName"));
        assert!(obj.contains_key("type"));
        assert!(obj.contains_key("canUpdate"));
        assert!(obj.contains_key("durChapterIndex"));
    }

    #[test]
    fn test_book_deserialize_from_minimal_json() {
        let json = r#"{"bookUrl":"https://example.com","name":"Minimal"}"#;
        let book: Book = serde_json::from_str(json).unwrap();
        assert_eq!(book.book_url, "https://example.com");
        assert_eq!(book.name, "Minimal");
        assert_eq!(book.origin, book_type::LOCAL_TAG);
        assert!(book.can_update);
    }

    #[test]
    fn test_read_config_defaults() {
        let json = "{}";
        let rc: ReadConfig = serde_json::from_str(json).unwrap();
        assert!(!rc.reverse_toc);
        assert!(rc.split_long_chapter);
        assert_eq!(rc.daily_chapters, 3);
        assert!((rc.play_speed - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    #[allow(clippy::field_reassign_with_default)]
    fn test_book_with_read_config() {
        let mut book = Book::default();
        book.read_config = Some(ReadConfig {
            reverse_toc: true,
            play_speed: 1.5,
            ..ReadConfig::default()
        });
        let json = serde_json::to_string(&book).unwrap();
        let de: Book = serde_json::from_str(&json).unwrap();
        let rc = de.read_config.unwrap();
        assert!(rc.reverse_toc);
        assert!((rc.play_speed - 1.5).abs() < f32::EPSILON);
    }

    #[test]
    fn test_book_type_constants() {
        assert_eq!(book_type::TEXT, 0);
        assert_eq!(book_type::AUDIO, 1);
        assert_eq!(book_type::IMAGE, 2);
        assert_eq!(book_type::FILE, 3);
        assert_eq!(book_type::VIDEO, 4);
        assert_eq!(book_type::LOCAL, 0x1000);
    }
}
