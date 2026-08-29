//! JS 源数据序列化/反序列化
//! 移植自 Kotlin JsSourceMarshaller.kt (160行)

use legado_core::models::Book;
use legado_parser::AnalyzeUrl;
use serde::{Deserialize, Serialize};
use serde_json::Value;

// ─── 类型化结构体（camelCase 对齐 JS 书源返回 JSON）───────────────────────

/// JS 搜索结果项
///
/// 对应 Kotlin `SearchBook` GSON 映射，JS 书源返回 camelCase JSON
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsSearchResult {
    /// 书名
    pub name: String,
    /// 作者
    #[serde(default)]
    pub author: Option<String>,
    /// 详情页 URL
    #[serde(default)]
    pub book_url: String,
    /// 封面 URL
    #[serde(default)]
    pub cover_url: Option<String>,
    /// 简介
    #[serde(default)]
    pub intro: Option<String>,
    /// 最新章节标题
    #[serde(default)]
    pub latest_chapter_title: Option<String>,
    /// 最新章节 URL
    #[serde(default)]
    pub latest_chapter_url: Option<String>,
    /// 分类
    #[serde(default)]
    pub kind: Option<String>,
    /// 字数
    #[serde(default)]
    pub word_count: Option<String>,
}

/// JS 书籍详情
///
/// 对应 Kotlin `BookInfo` GSON 映射
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsBookInfo {
    /// 书名
    pub name: String,
    /// 作者
    #[serde(default)]
    pub author: Option<String>,
    /// 简介
    #[serde(default)]
    pub intro: Option<String>,
    /// 封面 URL
    #[serde(default)]
    pub cover_url: Option<String>,
    /// 分类
    #[serde(default)]
    pub kind: Option<String>,
    /// 字数
    #[serde(default)]
    pub word_count: Option<String>,
    /// 最新章节标题
    #[serde(default)]
    pub latest_chapter_title: Option<String>,
    /// 目录页 URL
    #[serde(default)]
    pub toc_url: Option<String>,
    /// 是否可重命名
    #[serde(default)]
    pub can_re_name: Option<bool>,
    /// 下载 URL 列表
    #[serde(default)]
    pub download_urls: Option<Vec<String>>,
}

impl JsBookInfo {
    /// 当 getBookInfo 函数不存在时，从已有 Book 构造 JsBookInfo
    ///
    /// 参考 Kotlin `JsSourceBook.getBookInfoAwait`：函数缺失时沿用搜索阶段字段
    pub fn from_book(book: &Book) -> Self {
        Self {
            name: book.name.clone(),
            author: if book.author.is_empty() {
                None
            } else {
                Some(book.author.clone())
            },
            intro: book.intro.clone(),
            cover_url: book.cover_url.clone(),
            kind: book.kind.clone(),
            word_count: book.word_count.clone(),
            latest_chapter_title: book.latest_chapter_title.clone(),
            toc_url: if book.toc_url.is_empty() {
                None
            } else {
                Some(book.toc_url.clone())
            },
            can_re_name: None,
            download_urls: None,
        }
    }
}

/// JS 章节信息
///
/// 对应 Kotlin `BookChapter` GSON 映射
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JsChapter {
    /// 章节标题
    pub title: String,
    /// 章节 URL
    pub url: String,
    /// 是否卷（分隔页）
    #[serde(default)]
    pub is_volume: Option<bool>,
    /// 是否 VIP 章节
    #[serde(default)]
    pub is_vip: Option<bool>,
    /// 是否已购买
    #[serde(default)]
    pub is_pay: Option<bool>,
    /// 标签（如更新时间等）
    #[serde(default)]
    pub tag: Option<String>,
}

/// 将 JS 引擎返回的原始 JSON 字符串转换为标准实体
pub struct JsSourceMarshaller;

impl JsSourceMarshaller {
    /// 解析搜索结果为标准格式
    ///
    /// 参考 Kotlin `parseSearchBooks`：
    /// - 输入必须是 JSON 数组
    /// - 丢弃缺少 name/bookUrl 的条目
    pub fn marshal_search(raw_json: &str) -> Result<Vec<Value>, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        let array = parsed
            .as_array()
            .ok_or_else(|| "search/explore 返回值不是数组".to_string())?;
        let results: Vec<Value> = array
            .iter()
            .filter(|item| {
                item.is_object()
                    && item
                        .get("name")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
                    && item
                        .get("bookUrl")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
            })
            .cloned()
            .collect();
        Ok(results)
    }

    /// 解析书籍详情
    ///
    /// 参考 Kotlin `mergeBookInfo`：输入必须是 JSON 对象
    /// - `book_url`: 书籍详情页 URL，用于绝对化 downloadUrls
    pub fn marshal_book_info(raw_json: &str, book_url: &str) -> Result<Value, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Err("getBookInfo 返回值为空".to_string());
        }
        let mut parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        if !parsed.is_object() {
            return Err("getBookInfo 返回值不是对象".to_string());
        }
        // downloadUrls 绝对化 + javascript: 过滤
        if let Some(obj) = parsed.as_object_mut() {
            if let Some(urls_val) = obj.get_mut("downloadUrls") {
                if let Some(arr) = urls_val.as_array_mut() {
                    let new_urls: Vec<Value> = arr
                        .iter()
                        .filter_map(|u| u.as_str().map(|s| s.to_string()))
                        .filter(|u| !u.trim().starts_with("javascript:"))
                        .map(|u| Value::String(AnalyzeUrl::get_absolute_url(book_url, &u)))
                        .collect();
                    *urls_val = Value::Array(new_urls);
                }
            }
        }
        Ok(parsed)
    }

    /// 解析章节列表
    ///
    /// 参考 Kotlin `parseChapters`：
    /// - 输入必须是 JSON 数组
    /// - 丢弃缺少 title/url 的章节
    /// - 对非卷章的 url 进行绝对化（参考 Kotlin `NetworkUtils.getAbsoluteURL`）
    ///
    /// `toc_url`: 目录页 URL，用作相对 URL 的基准
    pub fn marshal_chapters(raw_json: &str, toc_url: &str) -> Result<Vec<Value>, String> {
        let trimmed = raw_json.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        let array = parsed
            .as_array()
            .ok_or_else(|| "getChapters 返回值不是数组".to_string())?;
        let results: Vec<Value> = array
            .iter()
            .filter(|item| {
                item.is_object()
                    && item
                        .get("title")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
                    && item
                        .get("url")
                        .and_then(|v| v.as_str())
                        .is_some_and(|s| !s.is_empty())
            })
            .map(|item| {
                let mut ch = item.clone();
                // 对非卷章的 url 进行绝对化
                let is_volume = ch
                    .get("isVolume")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if !is_volume {
                    if let Some(url_str) = ch
                        .get("url")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                    {
                        let absolute = AnalyzeUrl::get_absolute_url(toc_url, &url_str);
                        if let Some(obj) = ch.as_object_mut() {
                            obj.insert("url".to_string(), Value::String(absolute));
                        }
                    }
                }
                ch
            })
            .collect();
        Ok(results)
    }

    /// 解析正文内容（去除首尾空白，保留原始 HTML/文本）
    pub fn marshal_content(raw_html: &str) -> String {
        raw_html.trim().to_string()
    }

    /// 通用 JSON 字段提取
    pub fn extract_field(json: &Value, field: &str) -> Option<String> {
        json.get(field).and_then(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            Value::Bool(b) => Some(b.to_string()),
            Value::Null => None,
            _ => Some(v.to_string()),
        })
    }

    /// 验证书籍类型是否合法（参考 Kotlin validateBookType）
    ///
    /// type == 0 或含非法位时返回 None
    pub fn validate_book_type(raw: i32) -> Option<i32> {
        // BookType.allBookType 掩码（text=1, audio=2, image=4, file=8）
        const ALL_BOOK_TYPE: i32 = 0x0F;
        if raw == 0 || (raw & !ALL_BOOK_TYPE) != 0 {
            return None;
        }
        Some(raw)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_marshal_search_valid() {
        let json =
            r#"[{"name":"书A","bookUrl":"http://a.com"},{"name":"书B","bookUrl":"http://b.com"}]"#;
        let results = JsSourceMarshaller::marshal_search(json).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_marshal_search_filters_invalid_entries() {
        let json = r#"[{"name":"","bookUrl":"http://a.com"},{"name":"有效","bookUrl":"http://b.com"},{"name":"无URL","bookUrl":""}]"#;
        let results = JsSourceMarshaller::marshal_search(json).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["name"], "有效");
    }

    #[test]
    fn test_marshal_search_not_array() {
        let json = r#"{"name":"不是数组"}"#;
        let result = JsSourceMarshaller::marshal_search(json);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不是数组"));
    }

    #[test]
    fn test_marshal_search_empty() {
        let results = JsSourceMarshaller::marshal_search("").unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_marshal_book_info_valid() {
        let json = r#"{"name":"测试","author":"作者","intro":"简介"}"#;
        let info =
            JsSourceMarshaller::marshal_book_info(json, "https://example.com/book/1").unwrap();
        assert_eq!(info["name"], "测试");
        assert_eq!(info["author"], "作者");
    }

    #[test]
    fn test_marshal_book_info_not_object() {
        let json = r#"[1,2,3]"#;
        let result = JsSourceMarshaller::marshal_book_info(json, "https://example.com");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不是对象"));
    }

    #[test]
    fn test_marshal_book_info_download_urls_absolute_and_filter() {
        let json = r#"{"name":"测试","downloadUrls":["/down/1.zip","javascript:alert(1)","https://cdn.com/2.zip"]}"#;
        let info =
            JsSourceMarshaller::marshal_book_info(json, "https://example.com/book/1").unwrap();
        let urls = info["downloadUrls"].as_array().unwrap();
        // javascript: 被过滤，剩余 2 个
        assert_eq!(urls.len(), 2);
        // 相对路径被绝对化
        assert_eq!(urls[0], "https://example.com/down/1.zip");
        // 已是绝对 URL 保持不变
        assert_eq!(urls[1], "https://cdn.com/2.zip");
    }

    #[test]
    fn test_marshal_chapters_valid() {
        let json = r#"[{"title":"第一章","url":"http://a.com/1"},{"title":"第二章","url":"http://a.com/2"}]"#;
        let chapters = JsSourceMarshaller::marshal_chapters(json, "http://a.com/toc").unwrap();
        assert_eq!(chapters.len(), 2);
    }

    #[test]
    fn test_marshal_chapters_filters_invalid() {
        let json = r#"[{"title":"","url":"http://a.com"},{"title":"有效","url":"http://b.com"}]"#;
        let chapters = JsSourceMarshaller::marshal_chapters(json, "http://a.com/toc").unwrap();
        assert_eq!(chapters.len(), 1);
    }

    #[test]
    fn test_marshal_chapters_url_normalization() {
        let json = r#"[{"title":"第一章","url":"/chapter/1.html"},{"title":"卷","url":"/vol/2","isVolume":true}]"#;
        let chapters =
            JsSourceMarshaller::marshal_chapters(json, "https://example.com/book/toc.html")
                .unwrap();
        assert_eq!(chapters.len(), 2);
        // 非卷章 url 被绝对化
        assert_eq!(chapters[0]["url"], "https://example.com/chapter/1.html");
        // 卷章 url 不做绝对化
        assert_eq!(chapters[1]["url"], "/vol/2");
    }

    #[test]
    fn test_marshal_content() {
        assert_eq!(JsSourceMarshaller::marshal_content("  hello  "), "hello");
        assert_eq!(JsSourceMarshaller::marshal_content(""), "");
    }

    #[test]
    fn test_extract_field() {
        let obj = json!({"name": "测试", "count": 42, "active": true, "null_field": null});
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "name"),
            Some("测试".to_string())
        );
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "count"),
            Some("42".to_string())
        );
        assert_eq!(
            JsSourceMarshaller::extract_field(&obj, "active"),
            Some("true".to_string())
        );
        assert_eq!(JsSourceMarshaller::extract_field(&obj, "null_field"), None);
        assert_eq!(JsSourceMarshaller::extract_field(&obj, "missing"), None);
    }

    #[test]
    fn test_validate_book_type() {
        assert_eq!(JsSourceMarshaller::validate_book_type(0), None);
        assert_eq!(JsSourceMarshaller::validate_book_type(1), Some(1));
        assert_eq!(JsSourceMarshaller::validate_book_type(3), Some(3));
        assert_eq!(JsSourceMarshaller::validate_book_type(16), None);
        assert_eq!(JsSourceMarshaller::validate_book_type(17), None);
    }

    // ─── 类型化结构体 camelCase 测试 ───────────────────────────────────────

    #[test]
    fn test_js_search_result_camel_case_deserialize() {
        use super::JsSearchResult;
        let json = r#"{"name":"三体","author":"刘慈欣","bookUrl":"http://a.com/1","coverUrl":"http://img.com/1.jpg","latestChapterTitle":"第100章","wordCount":"120万"}"#;
        let result: JsSearchResult = serde_json::from_str(json).unwrap();
        assert_eq!(result.name, "三体");
        assert_eq!(result.author.as_deref(), Some("刘慈欣"));
        assert_eq!(result.book_url, "http://a.com/1");
        assert_eq!(result.cover_url.as_deref(), Some("http://img.com/1.jpg"));
        assert_eq!(result.latest_chapter_title.as_deref(), Some("第100章"));
        assert_eq!(result.word_count.as_deref(), Some("120万"));
    }

    #[test]
    fn test_js_book_info_camel_case_deserialize() {
        use super::JsBookInfo;
        let json = r#"{"name":"测试","tocUrl":"http://a.com/toc","canReName":true,"downloadUrls":["http://a.com/1.zip"]}"#;
        let info: JsBookInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.name, "测试");
        assert_eq!(info.toc_url.as_deref(), Some("http://a.com/toc"));
        assert_eq!(info.can_re_name, Some(true));
        assert_eq!(info.download_urls.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn test_js_chapter_camel_case_deserialize() {
        use super::JsChapter;
        let json = r#"{"title":"第一章","url":"http://a.com/1","isVolume":false,"isVip":true,"tag":"2024-01-01"}"#;
        let ch: JsChapter = serde_json::from_str(json).unwrap();
        assert_eq!(ch.title, "第一章");
        assert_eq!(ch.url, "http://a.com/1");
        assert_eq!(ch.is_volume, Some(false));
        assert_eq!(ch.is_vip, Some(true));
        assert_eq!(ch.tag.as_deref(), Some("2024-01-01"));
    }

    #[test]
    fn test_js_search_result_serialize_camel_case() {
        use super::JsSearchResult;
        let result = JsSearchResult {
            name: "测试".to_string(),
            author: Some("作者".to_string()),
            book_url: "http://a.com".to_string(),
            cover_url: None,
            intro: None,
            latest_chapter_title: None,
            latest_chapter_url: None,
            kind: None,
            word_count: None,
        };
        let json = serde_json::to_value(&result).unwrap();
        // 确保序列化后是 camelCase
        assert!(json.get("bookUrl").is_some());
        assert!(json.get("book_url").is_none());
    }
}
