//! JS 源书籍操作 — 搜索/发现/书籍信息/目录/正文
//! 移植自 Kotlin JsSourceBook.kt (143行)

use serde::{Deserialize, Serialize};

/// JS 源搜索请求
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsSearchRequest {
    pub key: String,
    pub page: i32,
    pub source_url: String,
}

/// JS 源搜索结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsSearchResult {
    pub book_name: String,
    pub author: String,
    pub book_url: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub latest_chapter: Option<String>,
}

/// JS 源书籍信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsBookInfo {
    pub name: String,
    pub author: String,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
    pub categories: Vec<String>,
    pub word_count: Option<String>,
    pub last_chapter: Option<String>,
    pub book_url: String,
}

/// JS 源章节
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsChapter {
    pub index: i32,
    pub title: String,
    pub url: String,
    pub is_vip: bool,
}

/// JS 源书籍管理器
pub struct JsSourceBookManager;

impl JsSourceBookManager {
    /// 解析搜索结果 JSON
    pub fn parse_search_results(json: &str) -> Result<Vec<JsSearchResult>, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 解析书籍信息 JSON
    pub fn parse_book_info(json: &str) -> Result<JsBookInfo, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 解析章节列表 JSON
    pub fn parse_chapters(json: &str) -> Result<Vec<JsChapter>, String> {
        serde_json::from_str(json).map_err(|e| e.to_string())
    }

    /// 构建搜索 URL（使用 AnalyUrl 模板）
    pub fn build_search_url(search_url_template: &str, key: &str, page: i32) -> String {
        search_url_template
            .replace("{key}", key)
            .replace("{page}", &page.to_string())
    }

    /// 验证搜索结果是否有效（name 和 book_url 不为空）
    pub fn validate_search_result(result: &JsSearchResult) -> bool {
        !result.book_name.is_empty() && !result.book_url.is_empty()
    }

    /// 过滤无效搜索结果（参考 Kotlin: 丢弃缺少 name/bookUrl 的搜索条目）
    pub fn filter_valid_results(results: Vec<JsSearchResult>) -> Vec<JsSearchResult> {
        results
            .into_iter()
            .filter(Self::validate_search_result)
            .collect()
    }

    /// 验证章节是否有效（title 和 url 不为空）
    pub fn validate_chapter(chapter: &JsChapter) -> bool {
        !chapter.title.is_empty() && !chapter.url.is_empty()
    }

    /// 过滤无效章节（参考 Kotlin: 丢弃缺少 title/url 的章节）
    pub fn filter_valid_chapters(chapters: Vec<JsChapter>) -> Vec<JsChapter> {
        chapters
            .into_iter()
            .filter(Self::validate_chapter)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_search_results_valid() {
        let json = r#"[
            {"book_name":"斗破苍穹","author":"天蚕土豆","book_url":"http://example.com/1","cover_url":null,"intro":"简介","latest_chapter":"第100章"},
            {"book_name":"完美世界","author":"辰东","book_url":"http://example.com/2","cover_url":"http://img.com/2.jpg","intro":null,"latest_chapter":null}
        ]"#;
        let results = JsSourceBookManager::parse_search_results(json).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert_eq!(results[1].author, "辰东");
        assert_eq!(
            results[1].cover_url,
            Some("http://img.com/2.jpg".to_string())
        );
    }

    #[test]
    fn test_parse_search_results_invalid_json() {
        let result = JsSourceBookManager::parse_search_results("not json");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_book_info_valid() {
        let json = r#"{"name":"测试书籍","author":"作者","cover_url":"http://img.com/cover.jpg","intro":"这是简介","categories":["玄幻","热血"],"word_count":"100万字","last_chapter":"第500章","book_url":"http://example.com/book/1"}"#;
        let info = JsSourceBookManager::parse_book_info(json).unwrap();
        assert_eq!(info.name, "测试书籍");
        assert_eq!(info.categories.len(), 2);
        assert_eq!(info.word_count, Some("100万字".to_string()));
    }

    #[test]
    fn test_parse_book_info_missing_required_field() {
        let json = r#"{"name":"测试","author":"作者"}"#;
        let result = JsSourceBookManager::parse_book_info(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_chapters_valid() {
        let json = r#"[
            {"index":0,"title":"第一章","url":"http://example.com/1","is_vip":false},
            {"index":1,"title":"第二章","url":"http://example.com/2","is_vip":true}
        ]"#;
        let chapters = JsSourceBookManager::parse_chapters(json).unwrap();
        assert_eq!(chapters.len(), 2);
        assert!(!chapters[0].is_vip);
        assert!(chapters[1].is_vip);
    }

    #[test]
    fn test_parse_chapters_empty_array() {
        let json = "[]";
        let chapters = JsSourceBookManager::parse_chapters(json).unwrap();
        assert!(chapters.is_empty());
    }

    #[test]
    fn test_build_search_url() {
        let template = "http://example.com/search?q={key}&p={page}";
        let url = JsSourceBookManager::build_search_url(template, "斗破", 3);
        assert_eq!(url, "http://example.com/search?q=斗破&p=3");
    }

    #[test]
    fn test_build_search_url_no_placeholders() {
        let template = "http://example.com/static";
        let url = JsSourceBookManager::build_search_url(template, "key", 1);
        assert_eq!(url, "http://example.com/static");
    }

    #[test]
    fn test_validate_search_result() {
        let valid = JsSearchResult {
            book_name: "书名".to_string(),
            author: "作者".to_string(),
            book_url: "http://example.com".to_string(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
        };
        assert!(JsSourceBookManager::validate_search_result(&valid));

        let invalid = JsSearchResult {
            book_name: "".to_string(),
            author: "作者".to_string(),
            book_url: "http://example.com".to_string(),
            cover_url: None,
            intro: None,
            latest_chapter: None,
        };
        assert!(!JsSourceBookManager::validate_search_result(&invalid));
    }

    #[test]
    fn test_filter_valid_results() {
        let results = vec![
            JsSearchResult {
                book_name: "有效".to_string(),
                author: "A".to_string(),
                book_url: "http://a.com".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
            JsSearchResult {
                book_name: "".to_string(),
                author: "B".to_string(),
                book_url: "http://b.com".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
            JsSearchResult {
                book_name: "无URL".to_string(),
                author: "C".to_string(),
                book_url: "".to_string(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
            },
        ];
        let filtered = JsSourceBookManager::filter_valid_results(results);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].book_name, "有效");
    }

    #[test]
    fn test_filter_valid_chapters() {
        let chapters = vec![
            JsChapter {
                index: 0,
                title: "第一章".to_string(),
                url: "http://a.com".to_string(),
                is_vip: false,
            },
            JsChapter {
                index: 1,
                title: "".to_string(),
                url: "http://b.com".to_string(),
                is_vip: false,
            },
            JsChapter {
                index: 2,
                title: "第三章".to_string(),
                url: "".to_string(),
                is_vip: false,
            },
        ];
        let filtered = JsSourceBookManager::filter_valid_chapters(chapters);
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].title, "第一章");
    }
}
