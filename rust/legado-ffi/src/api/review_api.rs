//! 段评 FFI API（书源 ruleReview 路径）
//!
//! 对齐原版 ReadBook / ReviewDetailDialog：摘要、详情分页、回复按需加载。
//! 本地库 CRUD（reviewGetByChapter 等）已移除——原版无此能力（F3-15）。

use std::collections::HashMap;

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use legado_parser::{AnalyzeUrl, RequestMethod};

// ─── 书源段评摘要 / 详情 / 回复（对齐原版 ruleReview）─────────────────────────

/// 段评摘要（对标 `ReadBookActivity.loadReviewSummary*`）
///
/// - 规则书源：请求 `reviewSummaryUrl` → `parseSummary`
/// - JS 书源：调用 `getReviewSummary`
///
/// 规则缺失/未启用返回空 `{counts:{}, keys:{}}`（非异常）。
///
/// # 参数
/// - `source_json`: BookSource JSON（含 ruleReview / mainJs）
/// - `request_json`: `chapterUrl`；可选 `book` / `chapter` JSON 对象
pub fn review_get_summary(source_json: &str, request_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let request: serde_json::Value = serde_json::from_str(request_json)
        .map_err(|e| LegadoError::Internal(format!("摘要请求参数解析失败: {e}")))?;

    if source.is_js_source() {
        return js_review_get_summary(&source, &request);
    }

    let empty = || {
        serde_json::to_string(&serde_json::json!({"counts": {}, "keys": {}}))
            .map_err(LegadoError::Serialization)
    };

    let rule = match source.rule_review.as_ref() {
        Some(r) => r,
        None => return empty(),
    };
    let summary_url = rule
        .review_summary_url
        .as_deref()
        .unwrap_or("")
        .trim()
        .to_string();
    if !rule.enabled
        || summary_url.is_empty()
        || rule
            .summary_list_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty()
        || rule
            .summary_paragraph_index_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty()
        || rule
            .summary_count_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty()
    {
        return empty();
    }

    let chapter_url = request
        .get("chapterUrl")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let analyze_url = AnalyzeUrl::parse(&summary_url, &HashMap::new(), 1)?;
    let final_url = {
        let raw = analyze_url.url().to_string();
        if raw.is_empty() {
            return Err(LegadoError::Internal("解析后段评摘要 URL 为空".into()));
        }
        if chapter_url.trim().is_empty() {
            raw
        } else {
            AnalyzeUrl::get_absolute_url(&chapter_url, &raw)
        }
    };

    let source_headers: Option<HashMap<String, String>> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok());
    let mut headers = source_headers.unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    // 写侧 CookieJar 门控（批 2）：开启源补内部标记头（只补不覆盖；
    // 发送前由 legado-net 剥离、绝不出网）；读侧 cookie 注入不受影响。
    legado_fetcher::web_book::apply_cookie_jar_marker(&mut headers, &source);
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    let method = analyze_url.method().clone();
    let post_body = analyze_url.request_body().to_string();
    let response = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        match method {
            RequestMethod::Post => client.post(&final_url, &post_body, headers_opt).await,
            _ => client.get(&final_url, headers_opt).await,
        }
    })
    .map_err(|e| LegadoError::Network(format!("请求段评摘要失败: {e}")))?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "HTTP {} for {}",
            response.status, final_url
        )));
    }

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
    let summary = legado_parser::parse_summary_with(&response.body, rule, &base_url, executor)
        .unwrap_or_default();

    // JSON 对象键须为字符串
    let counts: serde_json::Map<String, serde_json::Value> = summary
        .counts
        .into_iter()
        .map(|(k, v)| (k.to_string(), serde_json::json!(v)))
        .collect();
    let keys: serde_json::Map<String, serde_json::Value> = summary
        .keys
        .into_iter()
        .map(|(k, v)| (k.to_string(), serde_json::json!(v)))
        .collect();
    serde_json::to_string(&serde_json::json!({"counts": counts, "keys": keys}))
        .map_err(LegadoError::Serialization)
}

fn js_review_get_summary(source: &BookSource, request: &serde_json::Value) -> LegadoResult<String> {
    let book: legado_core::models::Book = request
        .get("book")
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()
        .map_err(|e| LegadoError::Internal(format!("book 参数解析失败: {e}")))?
        .unwrap_or_default();
    let mut chapter: legado_core::models::BookChapter = request
        .get("chapter")
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()
        .map_err(|e| LegadoError::Internal(format!("chapter 参数解析失败: {e}")))?
        .unwrap_or_default();
    if chapter.url.is_empty() {
        chapter.url = request
            .get("chapterUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
    }

    let mut orchestrator = crate::api::web_book::build_js_orchestrator(source)?
        .ok_or_else(|| LegadoError::Internal("JS 书源 mainJs 为空，无法加载段评摘要".into()))?;

    let summary = crate::runtime::block_on(async {
        tokio::task::spawn_blocking(move || orchestrator.get_review_summary(&book, &chapter))
            .await
            .map_err(|e| LegadoError::Internal(format!("JS 段评摘要任务异常: {e}")))?
    })?;

    let counts: serde_json::Map<String, serde_json::Value> = summary
        .counts
        .into_iter()
        .map(|(k, v)| (k.to_string(), serde_json::json!(v)))
        .collect();
    let keys: serde_json::Map<String, serde_json::Value> = summary
        .keys
        .into_iter()
        .map(|(k, v)| (k.to_string(), serde_json::json!(v)))
        .collect();
    serde_json::to_string(&serde_json::json!({"counts": counts, "keys": keys}))
        .map_err(LegadoError::Serialization)
}

/// 段评详情分页（对标 `ReviewDetailDialog.loadDetailPage`）
///
/// # 参数
/// - `source_json`: BookSource JSON
/// - `request_json`: `paraIndex`/`paraData`/`chapterUrl`；可选 `detailUrl`（翻页直连）、`book`/`chapter`
/// - `page`: 页码（从 1 开始）
///
/// # 返回
/// `{"items":[...],"nextPageUrl":String?,"hasReplyUrl":bool}`
pub fn review_get_detail(source_json: &str, request_json: &str, page: i32) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    if source.is_js_source() {
        return js_review_get_detail(&source, request_json, page);
    }

    let rule = source
        .rule_review
        .as_ref()
        .ok_or_else(|| LegadoError::Internal("书源未配置段评规则".into()))?;
    let detail_url_rule = rule
        .review_detail_url
        .as_deref()
        .unwrap_or("")
        .trim()
        .to_string();
    let detail_list = rule.detail_list_rule.as_deref().unwrap_or("").trim();
    let detail_content = rule.detail_content_rule.as_deref().unwrap_or("").trim();
    if !rule.enabled
        || detail_url_rule.is_empty()
        || detail_list.is_empty()
        || detail_content.is_empty()
    {
        return Err(LegadoError::Internal(
            "段评详情规则缺失（需 enabled/reviewDetailUrl/detailListRule/detailContentRule）"
                .into(),
        ));
    }

    let request: serde_json::Value = serde_json::from_str(request_json)
        .map_err(|e| LegadoError::Internal(format!("详情请求参数解析失败: {e}")))?;
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
    let para_index = field("paraIndex");
    let para_data = field("paraData");
    let chapter_url = field("chapterUrl");
    let direct_url = field("detailUrl");
    let next_page_rule = rule
        .review_detail_next_page_url
        .as_deref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());

    let page = page.max(1);
    let url_rule = if !direct_url.trim().is_empty() {
        direct_url
    } else if page > 1 {
        next_page_rule
            .map(|s| s.to_string())
            .unwrap_or_else(|| detail_url_rule.clone())
    } else {
        detail_url_rule.clone()
    };

    let make_vars = |page_value: i32| {
        let mut vars = HashMap::new();
        vars.insert("paraIndex".to_string(), para_index.clone());
        vars.insert("paraData".to_string(), para_data.clone());
        vars.insert("page".to_string(), page_value.to_string());
        vars
    };

    let analyze_url = AnalyzeUrl::parse(&url_rule, &make_vars(page), page)?;
    let final_url = {
        let raw = analyze_url.url().to_string();
        if raw.is_empty() {
            return Err(LegadoError::Internal("解析后段评详情 URL 为空".into()));
        }
        if chapter_url.trim().is_empty() {
            raw
        } else {
            AnalyzeUrl::get_absolute_url(&chapter_url, &raw)
        }
    };

    let source_headers: Option<HashMap<String, String>> = source
        .header
        .as_ref()
        .and_then(|h| serde_json::from_str(h).ok());
    let mut headers = source_headers.unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    // 写侧 CookieJar 门控（批 2）：开启源补内部标记头（只补不覆盖；
    // 发送前由 legado-net 剥离、绝不出网）；读侧 cookie 注入不受影响。
    legado_fetcher::web_book::apply_cookie_jar_marker(&mut headers, &source);
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    let method = analyze_url.method().clone();
    let post_body = analyze_url.request_body().to_string();
    let response = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        match method {
            RequestMethod::Post => client.post(&final_url, &post_body, headers_opt).await,
            _ => client.get(&final_url, headers_opt).await,
        }
    })
    .map_err(|e| LegadoError::Network(format!("请求段评详情失败: {e}")))?;

    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "HTTP {} for {}",
            response.status, final_url
        )));
    }

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
    let detail_page = legado_parser::parse_detail_page_with(
        &response.body,
        rule,
        next_page_rule,
        &base_url,
        executor,
    );

    let has_reply_url = !rule
        .review_quote_url
        .as_deref()
        .unwrap_or("")
        .trim()
        .is_empty()
        && !rule
            .reply_list_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty()
        && !rule
            .reply_content_rule
            .as_deref()
            .unwrap_or("")
            .trim()
            .is_empty();

    let payload = serde_json::json!({
        "items": detail_page.items,
        "nextPageUrl": detail_page.next_page_url,
        "hasReplyUrl": has_reply_url,
    });
    serde_json::to_string(&payload).map_err(LegadoError::Serialization)
}

fn js_review_get_detail(
    source: &BookSource,
    request_json: &str,
    page: i32,
) -> LegadoResult<String> {
    // JS 详情走原版 JsSourceReview.getReviewDetailAwait（与回复入口分离：
    // 详情返回整页条目 + nextPageUrl，回复只返回扁平化回复列表）
    let context = parse_js_review_context(request_json)?;
    let mut orchestrator = crate::api::web_book::build_js_orchestrator(source)?
        .ok_or_else(|| LegadoError::Internal("JS 书源 mainJs 为空，无法加载段评详情".into()))?;

    // 对齐原版 ReviewDetailDialog.kt:458-464：JS 书源 hasReplyUrl 取
    // `JsSourceReview.hasReviewRepliesCapability`（是否声明 getReviewReplies），
    // 不能恒 false——否则 Dart 侧 `_hasReplyUrl` 门控永不进入按需加载。
    // 探测与详情共用同一编排器（mainJs 只求值一次）。
    let has_reply_url = orchestrator.has_function("getReviewReplies");

    let detail_page = crate::runtime::block_on(async {
        tokio::task::spawn_blocking(move || {
            orchestrator.get_review_detail(
                &context.book,
                &context.chapter,
                context.para_index,
                &context.para_data,
                page,
            )
        })
        .await
        .map_err(|e| LegadoError::Internal(format!("JS 段评详情任务异常: {e}")))?
    })?;

    // 转换为与规则路径兼容的响应格式（camelCase 契约，API_CONTRACT.md 已登记）
    let items = convert_js_review_items(detail_page.items);
    let payload = serde_json::json!({
        "items": items,
        "nextPageUrl": detail_page.next_page_url,
        "hasReplyUrl": has_reply_url,
    });
    serde_json::to_string(&payload).map_err(LegadoError::Serialization)
}

/// 按需加载段评回复
///
/// 对标 Android `ReviewDetailDialog.loadReplies` + `ReviewRuleParser.parseReplyPage`：
/// 1. 以 `reviewQuoteUrl` 规则（或入参直连 URL）构造回复请求，
///    变量含 paraIndex/paraData/reviewId/page（支持分页）；
/// 2. 发起 HTTP 请求获取回复页面；
/// 3. 以 reply* 规则族解析回复列表。
///
/// JS 书源分支：对标 Kotlin `ReviewDetailDialog.loadReplies` 的 JS 分支，
/// 调用 JS 编排器 `getReviewReplies`（原版 `JsSourceReview.getReviewRepliesAwait`），
/// 返回按需加载的扁平化回复列表；函数缺失/返回 null → 空列表
/// （原版 `callOptionalFunction` 缺失语义）。
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
pub fn review_get_replies(
    source_json: &str,
    request_json: &str,
    page: i32,
) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;

    // JS 书源分支（Task #134）：复用 JS 编排器调用 getReviewDetail 实现按需加载，
    // 移除旧版"暂不支持"降级（对标 Kotlin ReviewDetailDialog 的 isJsSource 分支）
    if source.is_js_source() {
        return js_review_get_replies(&source, request_json, page);
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
    if !rule.enabled
        || quote_url_rule.is_empty()
        || reply_list_rule.is_empty()
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
    // 写侧 CookieJar 门控（批 2）：开启源补内部标记头（只补不覆盖；
    // 发送前由 legado-net 剥离、绝不出网）；读侧 cookie 注入不受影响。
    legado_fetcher::web_book::apply_cookie_jar_marker(&mut headers, &source);
    let headers_opt = if headers.is_empty() {
        None
    } else {
        Some(headers)
    };

    // 发起 HTTP 请求（复用进程共享客户端单例）
    let method = analyze_url.method().clone();
    let post_body = analyze_url.request_body().to_string();
    let response = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        match method {
            RequestMethod::Post => client.post(&final_url, &post_body, headers_opt).await,
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
    let replies = legado_parser::parse_reply_page_with(&response.body, rule, &base_url, executor)?;

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

/// JS 段评请求上下文（详情 / 回复共用解析）
struct JsReviewContext {
    book: legado_core::models::Book,
    chapter: legado_core::models::BookChapter,
    para_index: i32,
    para_data: String,
    review_id: String,
}

/// 解析 JS 段评请求 JSON。
///
/// `request_json` 可选字段：
/// - `book` / `chapter`：Book/BookChapter JSON 对象（缺失时用默认值，
///   chapter.url 以 `chapterUrl` 回填，对标 Kotlin 传入 ReadBook.book/chapter）；
/// - `paraIndex` / `paraData` / `reviewId` / `chapterUrl`：与规则路径同义。
fn parse_js_review_context(request_json: &str) -> LegadoResult<JsReviewContext> {
    let request: serde_json::Value = serde_json::from_str(request_json)
        .map_err(|e| LegadoError::Internal(format!("回复请求参数解析失败: {e}")))?;

    let para_index = request
        .get("paraIndex")
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
        })
        .unwrap_or(0) as i32;
    let para_data = request
        .get("paraData")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    // reviewId 兼容字符串/数字形态（原版为 String，规则路径同款宽松处理）
    let review_id = request
        .get("reviewId")
        .and_then(|v| match v {
            serde_json::Value::String(s) => Some(s.clone()),
            serde_json::Value::Null => None,
            other => Some(other.to_string()),
        })
        .unwrap_or_default();
    let chapter_url = request
        .get("chapterUrl")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    // Book/Chapter 上下文：优先调用方提供的字段，缺失时用默认值
    let book: legado_core::models::Book = request
        .get("book")
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()
        .map_err(|e| LegadoError::Internal(format!("book 参数解析失败: {e}")))?
        .unwrap_or_default();
    let mut chapter: legado_core::models::BookChapter = request
        .get("chapter")
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()
        .map_err(|e| LegadoError::Internal(format!("chapter 参数解析失败: {e}")))?
        .unwrap_or_default();
    if chapter.url.is_empty() {
        chapter.url = chapter_url;
    }

    Ok(JsReviewContext {
        book,
        chapter,
        para_index,
        para_data,
        review_id,
    })
}

/// JS 书源段评回复按需加载，对标 Kotlin `ReviewDetailDialog.loadReplies`
/// 的 JS 分支（`JsSourceReview.getReviewRepliesAwait`）与
/// `ReviewController.getReplies`（:331-345）：
/// 调用 JS `getReviewReplies(chapter, book, paraIndex, paraData, reviewId, page)`，
/// 返回 `{items:[扁平化回复列表]}`；函数缺失/返回 null → 空列表。
/// JS 协议无分页 URL（hasMore 由 items 非空表达），故 nextPageUrl 恒为 null。
fn js_review_get_replies(
    source: &BookSource,
    request_json: &str,
    page: i32,
) -> LegadoResult<String> {
    let context = parse_js_review_context(request_json)?;
    let mut orchestrator = crate::api::web_book::build_js_orchestrator(source)?
        .ok_or_else(|| LegadoError::Internal("JS 书源 mainJs 为空，无法加载段评回复".into()))?;

    // JS 分派：spawn_blocking 避免嵌套 runtime 死锁（同 webbook_search 模式）
    let items = crate::runtime::block_on(async {
        tokio::task::spawn_blocking(move || {
            orchestrator.get_review_replies(
                &context.book,
                &context.chapter,
                context.para_index,
                &context.para_data,
                &context.review_id,
                page,
            )
        })
        .await
        .map_err(|e| LegadoError::Internal(format!("JS 段评回复任务异常: {e}")))?
    })?;

    // 转换为与规则路径兼容的响应格式（camelCase 契约，API_CONTRACT.md 已登记）
    let payload = serde_json::json!({
        "items": convert_js_review_items(items),
        "nextPageUrl": serde_json::Value::Null,
    });
    serde_json::to_string(&payload).map_err(LegadoError::Serialization)
}

/// js_source_review 条目 → review_rule_parser camelCase 响应条目转换（Task #134）
///
/// JS 书源 `content` 为内容协议 JSON 时，`legado-js` 已按原版
/// `JsSourceReview.parseDetailItem` 解析出 replyToName/imageUrl/audioUrl/time/
/// likeCount/replyCount；此处逐字段透传（不允许 `None` 兜底丢字段）。
fn convert_js_review_items(
    items: Vec<legado_js::js_source::js_source_review::ReviewDetailItem>,
) -> Vec<legado_parser::review_rule_parser::ReviewDetailItem> {
    items
        .into_iter()
        .map(|it| legado_parser::review_rule_parser::ReviewDetailItem {
            id: it.id,
            avatar: it.avatar,
            name: it.name,
            reply_to_name: it.reply_to_name,
            badges: it.badges,
            content: Some(it.content),
            image_url: it.image_url,
            audio_url: it.audio_url,
            time: it.time,
            like_count: it.like_count,
            reply_count: it.reply_count,
            replies: convert_js_review_items(it.replies),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_review_get_summary_disabled_returns_empty() {
        let source = BookSource {
            rule_review: Some(legado_core::models::ReviewRule {
                enabled: false,
                review_summary_url: Some("http://example.com/summary".into()),
                summary_list_rule: Some("$.data".into()),
                summary_paragraph_index_rule: Some("$.idx".into()),
                summary_count_rule: Some("$.cnt".into()),
                ..Default::default()
            }),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let result = review_get_summary(&source_json, "{}").unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert!(payload["counts"].as_object().unwrap().is_empty());
        assert!(payload["keys"].as_object().unwrap().is_empty());
    }

    #[test]
    fn test_review_get_detail_incomplete_rules() {
        let source = BookSource {
            rule_review: Some(legado_core::models::ReviewRule {
                enabled: true,
                review_detail_url: Some("http://example.com/detail".into()),
                // 缺 detailListRule/detailContentRule
                ..Default::default()
            }),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let err = review_get_detail(&source_json, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("段评详情规则缺失"));
    }

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
        let source = BookSource {
            rule_review: Some(legado_core::models::ReviewRule {
                enabled: true,
                review_quote_url: Some("http://example.com/reply?page={{page}}".into()),
                // 缺 replyListRule/replyContentRule
                ..Default::default()
            }),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let err = review_get_replies(&source_json, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("段评回复规则缺失"));
    }

    #[test]
    fn test_review_get_replies_js_source_dispatched() {
        // JS 书源进入编排器 `getReviewReplies` 分派路径：
        // - quickjs：函数缺失 → 原版 callOptionalFunction 缺失语义 → 空列表；
        // - 非 quickjs：占位引擎报错（错误源自 JS 引擎而非"暂不支持"降级）。
        let source = BookSource {
            main_js: Some("// js source".into()),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        if cfg!(feature = "quickjs") {
            let result = review_get_replies(&source_json, "{}", 1).unwrap();
            let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
            assert!(payload["items"].as_array().unwrap().is_empty());
            assert!(payload["nextPageUrl"].is_null());
        } else {
            let err = review_get_replies(&source_json, "{}", 1).unwrap_err();
            assert!(
                !err.to_string().contains("暂不支持"),
                "降级分支应已移除: {err}"
            );
            assert!(
                err.to_string().contains("QuickJS"),
                "应为引擎占位错误: {err}"
            );
        }
    }

    #[test]
    fn test_js_review_get_replies_empty_main_js_rejected() {
        // mainJs 为空的 JS 书源 → 明确错误（无编排器可构建）
        let source = BookSource {
            main_js: Some("   ".into()),
            ..Default::default()
        };
        let err = js_review_get_replies(&source, "{}", 1).unwrap_err();
        assert!(err.to_string().contains("mainJs"));
    }

    #[test]
    fn test_convert_js_review_items_mapping() {
        use legado_js::js_source::js_source_review::ReviewDetailItem;
        let items = vec![ReviewDetailItem {
            id: Some("c1".into()),
            name: Some("用户A".into()),
            content: "好看".into(),
            avatar: Some("http://img.com/a.jpg".into()),
            badges: vec!["大佬".into()],
            reply_to_name: Some("楼主".into()),
            image_url: None,
            audio_url: None,
            time: None,
            like_count: None,
            reply_count: None,
            replies: vec![ReviewDetailItem {
                id: Some("r1".into()),
                name: None,
                content: "同意".into(),
                avatar: None,
                badges: vec![],
                reply_to_name: Some("用户A".into()),
                image_url: None,
                audio_url: None,
                time: None,
                like_count: None,
                reply_count: None,
                replies: vec![],
            }],
        }];
        let converted = convert_js_review_items(items);
        assert_eq!(converted.len(), 1);
        assert_eq!(converted[0].id.as_deref(), Some("c1"));
        assert_eq!(converted[0].content.as_deref(), Some("好看"));
        assert_eq!(converted[0].badges, vec!["大佬".to_string()]);
        // P1-1：replyToName 必须透传（含嵌套回复）
        assert_eq!(converted[0].reply_to_name.as_deref(), Some("楼主"));
        // 嵌套回复递归转换且不再嵌套（扁平化已在解析层完成）
        assert_eq!(converted[0].replies.len(), 1);
        assert_eq!(converted[0].replies[0].content.as_deref(), Some("同意"));
        assert_eq!(
            converted[0].replies[0].reply_to_name.as_deref(),
            Some("用户A")
        );
        assert!(converted[0].image_url.is_none());
        assert!(converted[0].like_count.is_none());
    }

    /// quickjs 真实引擎端到端：JS getReviewDetail 返回含嵌套回复的详情分页
    ///
    /// 注：Kotlin 原版 normalizeJsResult 对 Scriptable 对象自动 JSON.stringify；
    /// Rust QuickJsEngine 对象返回值降级为 Debug 格式（非 JSON），故测试 JS
    /// 显式 JSON.stringify（书源侧兼容写法）。该引擎层差异待专项对齐。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_review_get_detail_js_source_quickjs_e2e() {
        let source = BookSource {
            main_js: Some(
                r#"
            function getReviewDetail(chapter, book, paraIndex, paraData, page) {
                return JSON.stringify({
                    items: [{
                        id: "c1", name: "用户A", content: paraData + ":" + paraIndex,
                        avatar: "/a.png", badge: "作者",
                        replies: [{ id: "r1", content: "一级回复" }]
                    }],
                    nextPageUrl: page < 2 ? "more" : null
                });
            }
            "#
                .to_string(),
            ),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let request_json = serde_json::json!({
            "paraIndex": 3,
            "paraData": "token",
            "chapterUrl": "https://example.com/chap/1.html",
        })
        .to_string();

        let result = review_get_detail(&source_json, &request_json, 1).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(payload["nextPageUrl"], serde_json::json!("more"));
        assert_eq!(payload["hasReplyUrl"], serde_json::json!(false));
        let items = payload["items"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "c1");
        assert_eq!(items[0]["content"], "token:3");
        assert_eq!(items[0]["avatar"], "https://example.com/a.png");
        let replies = items[0]["replies"].as_array().unwrap();
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0]["content"], "一级回复");

        // 第二页：nextPageUrl 为 null
        let result2 = review_get_detail(&source_json, &request_json, 2).unwrap();
        let payload2: serde_json::Value = serde_json::from_str(&result2).unwrap();
        assert!(payload2["nextPageUrl"].is_null());
    }

    /// quickjs：JS 详情响应 hasReplyUrl 跟随 getReviewReplies 能力
    /// （对齐原版 ReviewDetailDialog.kt:462 的 hasReviewRepliesCapability）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_review_get_detail_has_reply_url_matches_capability() {
        let with_replies = BookSource {
            main_js: Some(
                r#"
            function getReviewDetail() {
                return JSON.stringify({items: [{id: "c1", content: "详情"}]});
            }
            function getReviewReplies() {
                return JSON.stringify({items: []});
            }
            "#
                .to_string(),
            ),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&with_replies).unwrap();
        let result = review_get_detail(&source_json, "{}", 1).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(payload["hasReplyUrl"], serde_json::json!(true));

        // 未声明 getReviewReplies → false（Dart 侧沿用详情内嵌回复）
        let without_replies = BookSource {
            main_js: Some(
                "function getReviewDetail() { return JSON.stringify({items: []}); }".to_string(),
            ),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&without_replies).unwrap();
        let result = review_get_detail(&source_json, "{}", 1).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(payload["hasReplyUrl"], serde_json::json!(false));
    }

    /// quickjs 真实引擎端到端：JS getReviewReplies 返回扁平化回复列表
    /// （批12 对齐原版 `JsSourceReview.getReviewRepliesAwait`）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_review_get_replies_js_source_quickjs_e2e() {
        let source = BookSource {
            main_js: Some(
                r#"
            function getReviewReplies(chapter, book, paraIndex, paraData, reviewId, page) {
                return JSON.stringify({
                    items: [
                        { id: reviewId, name: "读者甲", avatar: "/r/1.png",
                          content: "{\"text\":\"回复正文\",\"replyToName\":\"楼主\"}",
                          replies: [{ id: "r2", content: "楼中楼" }] },
                        { id: "r3", content: paraData + ":" + page }
                    ]
                });
            }
            "#
                .to_string(),
            ),
            ..Default::default()
        };
        let source_json = serde_json::to_string(&source).unwrap();
        let request_json = serde_json::json!({
            "paraIndex": 3,
            "paraData": "token",
            "reviewId": "c1",
            "chapterUrl": "https://example.com/chap/1.html",
        })
        .to_string();

        let result = review_get_replies(&source_json, &request_json, 1).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert!(payload["nextPageUrl"].is_null(), "JS 协议无分页 URL");
        let items = payload["items"].as_array().unwrap();
        // 顶层两条 + 嵌套一条（扁平化）
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["id"], "c1");
        assert_eq!(items[0]["content"], "回复正文");
        assert_eq!(items[0]["replyToName"], "楼主");
        assert_eq!(items[0]["avatar"], "https://example.com/r/1.png");
        assert_eq!(items[1]["id"], "r2");
        assert_eq!(items[2]["content"], "token:1");

        // 脚本未定义 getReviewReplies → 原版 callOptionalFunction 缺失语义 → 空列表
        let missing_source = BookSource {
            main_js: Some("function search() { return ''; }".to_string()),
            ..Default::default()
        };
        let missing_json = serde_json::to_string(&missing_source).unwrap();
        let result = review_get_replies(&missing_json, &request_json, 1).unwrap();
        let payload: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert!(payload["items"].as_array().unwrap().is_empty());
        assert!(payload["nextPageUrl"].is_null());
    }
}
