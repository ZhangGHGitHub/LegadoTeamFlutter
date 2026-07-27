//! JS 源书评
//! 移植自 Kotlin JsSourceReview.kt (170行)

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 书评条目
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookReview {
    pub title: String,
    pub content: String,
    pub author: String,
    pub rating: Option<f32>,
    pub created_at: Option<i64>,
}

/// 书评摘要结果（参考 Kotlin ReviewRuleParser.SummaryResult）
#[derive(Debug, Clone, Default)]
pub struct ReviewSummary {
    /// 段落索引 → 评论数
    pub counts: Vec<(i32, i32)>,
    /// 段落索引 → 段落数据
    pub keys: Vec<(i32, String)>,
}

/// 书评详情条目（参考 Kotlin ReviewRuleParser.DetailItem）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewDetailItem {
    pub id: Option<String>,
    pub name: Option<String>,
    pub content: String,
    pub avatar: Option<String>,
    pub badges: Vec<String>,
    pub replies: Vec<ReviewDetailItem>,
}

/// 书评详情分页（参考 Kotlin ReviewRuleParser.DetailPage）
#[derive(Debug, Clone)]
pub struct ReviewDetailPage {
    pub items: Vec<ReviewDetailItem>,
    pub next_page_url: Option<String>,
}

pub struct JsSourceReview;

impl JsSourceReview {
    /// 解析书评列表 JSON
    pub fn parse_reviews(json: &str) -> Result<Vec<BookReview>, String> {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        serde_json::from_str(trimmed).map_err(|e| e.to_string())
    }

    /// 解析单条书评详情 JSON
    pub fn parse_review_detail(json: &str) -> Result<BookReview, String> {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return Err("书评详情为空".to_string());
        }
        serde_json::from_str(trimmed).map_err(|e| e.to_string())
    }

    /// 解析书评摘要（参考 Kotlin getReviewSummaryAwait）
    ///
    /// 输入为 JSON 数组，每项含 paraIndex/count/paraData
    pub fn parse_review_summary(json: &str) -> Result<ReviewSummary, String> {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return Ok(ReviewSummary::default());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        let array = parsed
            .as_array()
            .ok_or_else(|| "书评摘要返回值不是数组".to_string())?;

        let mut summary = ReviewSummary::default();
        for item in array {
            if !item.is_object() {
                continue;
            }
            let para_index = match item.get("paraIndex").and_then(|v| v.as_i64()) {
                Some(idx) => idx as i32,
                None => continue,
            };
            let count = item.get("count").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            // 参考 Kotlin: (paragraphIndex == -1 || paragraphIndex > 0) && count > 0
            if (para_index == -1 || para_index > 0) && count > 0 {
                summary.counts.push((para_index, count));
                let para_data = item
                    .get("paraData")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let key = if para_data.is_empty() {
                    para_index.to_string()
                } else {
                    para_data
                };
                summary.keys.push((para_index, key));
            }
        }
        Ok(summary)
    }

    /// 解析书评详情分页（参考 Kotlin parseDetailObject）
    pub fn parse_detail_page(json: &str, base_url: &str) -> Result<ReviewDetailPage, String> {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return Err("书评详情为空".to_string());
        }
        let parsed: Value = serde_json::from_str(trimmed).map_err(|e| e.to_string())?;
        if !parsed.is_object() {
            return Err("书评详情不是对象".to_string());
        }

        let items_array = parsed
            .get("items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| "缺少 items 数组".to_string())?;

        let items: Vec<ReviewDetailItem> = items_array
            .iter()
            .filter_map(|item| Self::parse_detail_item(item, base_url))
            .collect();

        let next_page_url = parsed
            .get("nextPageUrl")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());

        Ok(ReviewDetailPage {
            items,
            next_page_url,
        })
    }

    /// 解析单条评论条目（含嵌套回复扁平化）
    fn parse_detail_item(value: &Value, base_url: &str) -> Option<ReviewDetailItem> {
        if !value.is_object() {
            return None;
        }
        let content = value
            .get("content")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())?;

        let id = value
            .get("id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let name = value
            .get("name")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let avatar = value
            .get("avatar")
            .and_then(|v| v.as_str())
            .map(|s| Self::resolve_url(base_url, s));
        let badges = value
            .get("badge")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| vec![s.to_string()])
            .unwrap_or_default();

        // 扁平化嵌套回复（参考 Kotlin flattenReplies）
        let replies = value
            .get("replies")
            .and_then(|v| v.as_array())
            .map(|arr| Self::flatten_replies(arr, base_url))
            .unwrap_or_default();

        Some(ReviewDetailItem {
            id,
            name,
            content: content.to_string(),
            avatar,
            badges,
            replies,
        })
    }

    /// 扁平化嵌套回复（迭代方式，参考 Kotlin flattenReplies 使用栈）
    fn flatten_replies(array: &[Value], base_url: &str) -> Vec<ReviewDetailItem> {
        let mut result = Vec::new();
        let mut stack: Vec<&Value> = array.iter().rev().collect();
        while let Some(item) = stack.pop() {
            if let Some(parsed) = Self::parse_detail_item(item, base_url) {
                // 先收集子回复再 push 当前项（保持顺序）
                if let Some(sub_replies) = item.get("replies").and_then(|v| v.as_array()) {
                    for sub in sub_replies.iter().rev() {
                        stack.push(sub);
                    }
                }
                result.push(parsed);
            }
        }
        result
    }

    /// 简单 URL 解析（相对路径 → 绝对路径）
    fn resolve_url(base_url: &str, url: &str) -> String {
        if url.starts_with("http://") || url.starts_with("https://") {
            url.to_string()
        } else if url.starts_with('/') {
            // 提取 base 的 scheme + host
            if let Some(pos) = base_url.find("://") {
                let after_scheme = &base_url[pos + 3..];
                if let Some(slash_pos) = after_scheme.find('/') {
                    format!("{}{}", &base_url[..pos + 3 + slash_pos], url)
                } else {
                    format!("{base_url}{url}")
                }
            } else {
                url.to_string()
            }
        } else {
            url.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_reviews_valid() {
        let json = r#"[
            {"title":"好书","content":"非常精彩","author":"读者A","rating":4.5,"created_at":1700000000},
            {"title":"一般","content":"还行吧","author":"读者B","rating":3.0,"created_at":null}
        ]"#;
        let reviews = JsSourceReview::parse_reviews(json).unwrap();
        assert_eq!(reviews.len(), 2);
        assert_eq!(reviews[0].title, "好书");
        assert_eq!(reviews[0].rating, Some(4.5));
        assert_eq!(reviews[1].created_at, None);
    }

    #[test]
    fn test_parse_reviews_empty() {
        let reviews = JsSourceReview::parse_reviews("").unwrap();
        assert!(reviews.is_empty());
    }

    #[test]
    fn test_parse_review_detail_valid() {
        let json = r#"{"title":"精彩书评","content":"内容很好","author":"评论者","rating":5.0,"created_at":1700000000}"#;
        let review = JsSourceReview::parse_review_detail(json).unwrap();
        assert_eq!(review.title, "精彩书评");
        assert_eq!(review.rating, Some(5.0));
    }

    #[test]
    fn test_parse_review_detail_empty() {
        let result = JsSourceReview::parse_review_detail("");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_review_summary() {
        let json = r#"[
            {"paraIndex":1,"count":5,"paraData":"段落1"},
            {"paraIndex":-1,"count":3,"paraData":"全部"},
            {"paraIndex":0,"count":2,"paraData":"无效"},
            {"paraIndex":2,"count":0,"paraData":"零评论"}
        ]"#;
        let summary = JsSourceReview::parse_review_summary(json).unwrap();
        // paraIndex=0 和 count=0 的应被过滤
        assert_eq!(summary.counts.len(), 2);
        assert_eq!(summary.counts[0], (1, 5));
        assert_eq!(summary.counts[1], (-1, 3));
        assert_eq!(summary.keys[0], (1, "段落1".to_string()));
    }

    #[test]
    fn test_parse_detail_page() {
        let json = r#"{
            "items": [
                {"id":"1","name":"用户A","content":"好看","avatar":"/avatar/1.jpg","badge":"大佬","replies":[
                    {"id":"2","name":"用户B","content":"同意","avatar":"http://img.com/2.jpg"}
                ]},
                {"id":"3","name":"用户C","content":""}
            ],
            "nextPageUrl": "http://example.com/page2"
        }"#;
        let page = JsSourceReview::parse_detail_page(json, "http://example.com").unwrap();
        // 第三项 content 为空应被过滤
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].name, Some("用户A".to_string()));
        assert_eq!(page.items[0].badges, vec!["大佬".to_string()]);
        // 嵌套回复应被扁平化
        assert_eq!(page.items[0].replies.len(), 1);
        assert_eq!(page.items[0].replies[0].content, "同意");
        // 相对路径 avatar 应被解析
        assert_eq!(
            page.items[0].avatar,
            Some("http://example.com/avatar/1.jpg".to_string())
        );
        assert_eq!(
            page.next_page_url,
            Some("http://example.com/page2".to_string())
        );
    }

    #[test]
    fn test_parse_detail_page_missing_items() {
        let json = r#"{"nextPageUrl":null}"#;
        let result = JsSourceReview::parse_detail_page(json, "http://example.com");
        assert!(result.is_err());
    }
}
