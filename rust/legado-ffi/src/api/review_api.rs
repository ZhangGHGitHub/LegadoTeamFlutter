//! 段评/章评 FFI API
//!
//! 暴露 legado-db::ReviewRepository 到 Flutter 端。
//! 支持：获取章节评论、添加评论、删除评论、点赞。
//! 另提供书源段评回复按需加载（上游 #519）。

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_core::review::ChapterReview;
use legado_core::{LegadoError, LegadoResult};
use legado_db::ReviewRepository;
use legado_parser::{AnalyzeUrl, RequestMethod};

use crate::db_state::with_database;

/// 获取指定章节的所有评论（JSON 数组）
pub fn review_get_by_chapter(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let reviews = repo.get_by_chapter(book_url, chapter_index)?;
        serde_json::to_string(&reviews)
            .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 获取指定书籍的所有评论（JSON 数组）
pub fn review_get_by_book(book_url: &str) -> LegadoResult<String> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let reviews = repo.get_by_book(book_url)?;
        serde_json::to_string(&reviews)
            .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
    })
}

/// 添加评论，返回评论 ID
pub fn review_add(
    book_url: &str,
    chapter_index: i32,
    paragraph_index: i32,
    content: &str,
    author: &str,
) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let review = ChapterReview {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index,
            paragraph_index,
            content: content.to_string(),
            author: author.to_string(),
            created_at: now,
            like_count: 0,
        };
        repo.insert(&review)
    })
}

/// 删除评论
pub fn review_delete(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let count = repo.delete(id)?;
        Ok(count > 0)
    })
}

/// 点赞评论
pub fn review_like(id: i64) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        repo.add_like(id)
    })
}

/// 删除章节所有评论
pub fn review_delete_chapter(book_url: &str, chapter_index: i32) -> LegadoResult<i32> {
    with_database(|db| {
        let repo = ReviewRepository::new(db.connection());
        let count = repo.delete_by_chapter(book_url, chapter_index)?;
        Ok(count as i32)
    })
}

// ─── 书源段评回复按需加载（上游 #519）─────────────────────────

/// 按需加载段评回复
///
/// 对标 Android `ReviewDetailDialog.loadReplies` + `ReviewRuleParser.parseReplyPage`：
/// 1. 以 `reviewQuoteUrl` 规则（或入参直连 URL）构造回复请求，
///    变量含 paraIndex/paraData/reviewId/page（支持分页）；
/// 2. 发起 HTTP 请求获取回复页面；
/// 3. 以 reply* 规则族解析回复列表。
///
/// # 参数
/// - `source_json`: BookSource JSON 字符串（含 ruleReview）
/// - `request_json`: 请求上下文 JSON，支持字段：
///   - `reviewId`（父评论 ID，替换 reviewQuoteUrl 中的 reviewId 变量）
///   - `paraIndex` / `paraData`（段落索引/段落数据）
///   - `chapterUrl`（章节 URL，作为 URL 解析的 baseUrl）
///   - `replyUrl`（可选：直连回复 URL，非空时优先于 reviewQuoteUrl）
/// - `page`: 回复页码（从 1 开始）
///
/// # 返回
/// JSON 对象字符串 `{"items": [回复列表], "nextPageUrl": "下一页 URL 或 null"}`；
/// 回复条目字段对齐 Kotlin DetailItem：
/// id/avatar/name/badges/content/imageUrl/audioUrl/time/likeCount/replyCount/replies。
/// 注：返回为对象包装而非裸数组（含分页 URL），已在 API_CONTRACT.md 登记。
pub fn review_get_replies(source_json: &str, request_json: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // 对标 Kotlin：JS 书源的回复随 getReviewDetail 嵌套返回，无独立 reply 协议
    if source.is_js_source() {
        return Err(LegadoError::Internal(
            "JS 书源暂不支持段评回复按需加载".into(),
        ));
    }

    let rule = source
        .rule_review
        .as_ref()
        .ok_or_else(|| LegadoError::Internal("书源未配置段评规则".into()))?;
    let quote_url_rule = rule
        .review_quote_url
        .as_deref()
        .unwrap_or("")
        .trim()
        .to_string();
    let reply_list_rule = rule.reply_list_rule.as_deref().unwrap_or("").trim();
    let reply_content_rule = rule.reply_content_rule.as_deref().unwrap_or("").trim();
    // 对标 Kotlin hasReplyUrl 判定：enabled + reviewQuoteUrl + replyListRule + replyContentRule
    if !rule.enabled || quote_url_rule.is_empty() || reply_list_rule.is_empty()
        || reply_content_rule.is_empty()
    {
        return Err(LegadoError::Internal(
            "段评回复规则缺失（需 enabled/reviewQuoteUrl/replyListRule/replyContentRule）".into(),
        ));
    }

    let request: serde_json::Value = serde_json::from_str(request_json)
        .map_err(|e| LegadoError::Internal(format!("回复请求参数解析失败: {e}")))?;
    let field = |key: &str| -> String {
        request
            .get(key)
            .and_then(|v| match v {
                serde_json::Value::String(s) => Some(s.clone()),
                serde_json::Value::Null => None,
                other => Some(other.to_string()),
            })
            .unwrap_or_default()
    };
    let review_id = field("reviewId");
    let para_index = field("paraIndex");
    let para_data = field("paraData");
    let chapter_url = field("chapterUrl");
    let direct_url = field("replyUrl");

    // 直连 URL 优先（翻页场景可直接传上一页解析出的 URL）
    let url_rule = if direct_url.trim().is_empty() {
        quote_url_rule.clone()
    } else {
        direct_url
    };

    let page = page.max(1);
    let make_vars = |page_value: i32| {
        let mut vars = HashMap::new();
        vars.insert("paraIndex".to_string(), para_index.clone());
        vars.insert("paraData".to_string(), para_data.clone());
        vars.insert("reviewId".to_string(), review_id.clone());
        vars.insert("page".to_string(), page_value.to_string());
        vars
    };

    let analyze_url = AnalyzeUrl::parse(&url_rule, &make_vars(page), page)?;
    // 对标 Kotlin AnalyzeUrl(baseUrl = chapter.url)：相对 URL 以章节 URL 补全
    let final_url = {
        let raw = analyze_url.url().to_string();
        if raw.is_empty() {
            return Err(LegadoError::Internal("解析后回复 URL 为空".into()));
        }
        if chapter_url.trim().is_empty() {
            raw
        } else {
            AnalyzeUrl::get_absolute_url(&chapter_url, &raw)
        }
    };

    // 合并请求头：书源全局 header + AnalyzeUrl 解析出的 header
    let source_headers: Option<HashMap<String, String>> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok());
    let mut headers = source_headers.unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    // 发起 HTTP 请求（复用进程共享客户端单例）
    let method = analyze_url.method().clone();
    let post_body = analyze_url.body().unwrap_or("").to_string();
    let response = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client();
        match method {
            RequestMethod::Post => {
                client
                    .post(&final_url, &post_body, headers_opt)
                    .await
            }
            _ => client.get(&final_url, headers_opt).await,
        }
    })
    .map_err(|e| LegadoError::Network(format!("请求段评回复失败: {e}")))?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "HTTP {} for {}",
            response.status, final_url
        )));
    }

    // 解析回复列表（quickjs 特性下注入 JS 执行器以支持 @js: 规则）
    let probe = crate::js_executor::construct_analyzer(
        String::new(),
        String::new(),
        &source.book_source_url,
    );
    let executor = probe.js_executor();
    let base_url = if response.url.is_empty() {
        final_url.clone()
    } else {
        response.url.clone()
    };
    let replies =
        legado_parser::parse_reply_page_with(&response.body, rule, &base_url, executor)?;

    // 分页：回复非空时按 page+1 重新渲染 URL 规则得到下一页 URL；
    // 若 URL 不随页码变化（无分页占位符）则返回 null。
    let next_page_url = if replies.is_empty() {
        None
    } else {
        AnalyzeUrl::parse(&url_rule, &make_vars(page + 1), page + 1)
            .ok()
            .map(|a| {
                let raw = a.url().to_string();
                if chapter_url.trim().is_empty() {
                    raw
                } else {
                    AnalyzeUrl::get_absolute_url(&chapter_url, &raw)
                }
            })
            .filter(|u| !u.is_empty() && u != &final_url)
    };

    let payload = serde_json::json!({
        "items": replies,
        "nextPageUrl": next_page_url,
    });
    serde_json::to_string(&payload).map_err(LegadoError::Serialization)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_review_get_replies_invalid_source_json() {
        let err = review_get_replies("not valid json", "{}", 1).unwrap_err();
        assert!(matches!(err, LegadoError::Serialization(_)));
    }

    #[test]
    fn test_review_get_replies_missing_rule() {
        let source_json = serde_json::to_string(&BookSource::default()).unwrap();
        let err = review_get_replies(&source_json, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("段评规则"));
    }

    #[test]
    fn test_review_get_replies_incomplete_rules() {
        let mut source = BookSource::default();
        source.rule_review = Some(legado_core::models::ReviewRule {
            enabled: true,
            review_quote_url: Some("http://example.com/reply?page={{page}}".into()),
            // 缺 replyListRule/replyContentRule
            ..Default::default()
        });
        let source_json = serde_json::to_string(&source).unwrap();
        let err = review_get_replies(&source_json, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("段评回复规则缺失"));
    }

    #[test]
    fn test_review_get_replies_js_source_rejected() {
        let mut source = BookSource::default();
        source.main_js = Some("// js source".into());
        let source_json = serde_json::to_string(&source).unwrap();
        let err = review_get_replies(&source_json, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("JS 书源"));
    }
}
