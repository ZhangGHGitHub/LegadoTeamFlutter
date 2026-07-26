use serde::{Deserialize, Serialize};

/// 章节实体
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookChapter {
    /// 章节地址
    #[serde(default)]
    pub url: String,
    /// 章节标题
    #[serde(default)]
    pub title: String,
    /// 是否是卷名
    #[serde(default, rename = "isVolume")]
    pub is_volume: bool,
    /// 用来拼接相对url
    #[serde(default, rename = "baseUrl")]
    pub base_url: String,
    /// 书籍地址
    #[serde(default, rename = "bookUrl")]
    pub book_url: String,
    /// 章节序号
    #[serde(default)]
    pub index: i32,
    /// 是否VIP
    #[serde(default, rename = "isVip")]
    pub is_vip: bool,
    /// 是否已购买
    #[serde(default, rename = "isPay")]
    pub is_pay: bool,
    /// 音频真实URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "resourceUrl")]
    pub resource_url: Option<String>,
    /// 更新时间或其他章节附加信息
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    /// 本章节字数
    #[serde(skip_serializing_if = "Option::is_none", rename = "wordCount")]
    pub word_count: Option<String>,
    /// 章节起始位置
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<i64>,
    /// 章节终止位置
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<i64>,
    /// EPUB书籍当前章节的fragmentId
    #[serde(skip_serializing_if = "Option::is_none", rename = "startFragmentId")]
    pub start_fragment_id: Option<String>,
    /// EPUB书籍下一章节的fragmentId
    #[serde(skip_serializing_if = "Option::is_none", rename = "endFragmentId")]
    pub end_fragment_id: Option<String>,
    /// 变量
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variable: Option<String>,
    /// 标题段评图或者视频封面
    #[serde(skip_serializing_if = "Option::is_none", rename = "imgUrl")]
    pub img_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_chapter_default() {
        let ch = BookChapter::default();
        assert!(ch.url.is_empty());
        assert!(ch.title.is_empty());
        assert!(!ch.is_volume);
        assert!(!ch.is_vip);
        assert!(!ch.is_pay);
        assert_eq!(ch.index, 0);
        assert!(ch.start.is_none());
        assert!(ch.end.is_none());
    }

    #[test]
    fn test_book_chapter_json_field_names() {
        let ch = BookChapter {
            url: "https://example.com/ch1".to_string(),
            title: "第一章".to_string(),
            is_volume: false,
            base_url: "https://example.com".to_string(),
            book_url: "https://example.com/book".to_string(),
            index: 0,
            is_vip: false,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: Some("3000".to_string()),
            start: Some(0),
            end: Some(3000),
            start_fragment_id: None,
            end_fragment_id: None,
            variable: None,
            img_url: None,
        };
        let json = serde_json::to_value(&ch).unwrap();
        let obj = json.as_object().unwrap();
        assert!(obj.contains_key("isVolume"));
        assert!(obj.contains_key("baseUrl"));
        assert!(obj.contains_key("bookUrl"));
        assert!(obj.contains_key("isVip"));
        assert!(obj.contains_key("isPay"));
        assert!(obj.contains_key("wordCount"));
    }

    #[test]
    fn test_book_chapter_serde_roundtrip() {
        let ch = BookChapter {
            url: "ch1".to_string(),
            title: "第一章".to_string(),
            is_volume: true,
            index: 5,
            start: Some(100),
            end: Some(5000),
            ..BookChapter::default()
        };
        let json = serde_json::to_string(&ch).unwrap();
        let de: BookChapter = serde_json::from_str(&json).unwrap();
        assert_eq!(de.url, "ch1");
        assert_eq!(de.title, "第一章");
        assert!(de.is_volume);
        assert_eq!(de.index, 5);
        assert_eq!(de.start, Some(100));
        assert_eq!(de.end, Some(5000));
    }

    #[test]
    fn test_book_chapter_optional_fields_skipped() {
        let ch = BookChapter::default();
        let json = serde_json::to_string(&ch).unwrap();
        // Optional None fields should be skipped
        assert!(!json.contains("resourceUrl"));
        assert!(!json.contains("startFragmentId"));
        assert!(!json.contains("endFragmentId"));
        assert!(!json.contains("imgUrl"));
    }
}
