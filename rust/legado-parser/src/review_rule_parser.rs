//! 段评规则解析器
//!
//! 移植自 Kotlin `ReviewRuleParser.kt`：
//! - `parseSummary`（段评摘要）
//! - `parseDetailPage`（段评详情分页）
//! - `parseReplyPage` / `parseDetailItem`（上游 #519 回复按需加载）
//!
//! 复用 [`AnalyzeRule`] 基础设施：
//! 支持 CSS / XPath / JsonPath / 正则 / `@js:` 规则，
//! 自动按内容类型（HTML / JSON）选择解析引擎。

use std::collections::HashMap;
use std::sync::Arc;

use legado_core::models::ReviewRule;
use legado_core::{LegadoError, LegadoResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::analyze_rule::{AnalyzeRule, JsExecutor};

/// 段评摘要（参考 Kotlin `ReviewRuleParser.SummaryResult`）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewSummaryResult {
    /// 段落索引 → 评论数（仅 count > 0）
    pub counts: HashMap<i32, i32>,
    /// 段落索引 → 段落数据键（paraData）
    pub keys: HashMap<i32, String>,
}

/// 段评详情分页（参考 Kotlin `ReviewRuleParser.DetailPage`）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewDetailPage {
    pub items: Vec<ReviewDetailItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_page_url: Option<String>,
}

/// 段评/回复条目（参考 Kotlin `ReviewRuleParser.DetailItem`）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewDetailItem {
    /// 评论 ID（回复分页加载时用于构造 reviewId 参数）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// 发布者头像（绝对 URL）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    /// 发布者昵称
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// 徽章/标签列表
    #[serde(default)]
    pub badges: Vec<String>,
    /// 评论文本内容
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// 图片内容（绝对 URL）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_url: Option<String>,
    /// 音频内容（绝对 URL）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_url: Option<String>,
    /// 发布时间文本
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time: Option<String>,
    /// 点赞数（回复条目固定为 None）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub like_count: Option<i32>,
    /// 回复数（回复条目固定为 None）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_count: Option<i32>,
    /// 嵌套回复（按需加载场景下回复条目不再嵌套）
    #[serde(default)]
    pub replies: Vec<ReviewDetailItem>,
}

/// 内容协议解析结果（参考 Kotlin `ReviewRuleParser.ContentProtocol`）
///
/// 评论规则返回值形如 `{"text": "...", "img": "...", ...}` 时按协议解析。
struct ContentProtocol {
    text: Option<String>,
    image_url: Option<String>,
    audio_url: Option<String>,
    time: Option<String>,
    like_count: Option<i32>,
    reply_count: Option<i32>,
}

/// 解析段评摘要（参考 Kotlin `ReviewRuleParser.parseSummary`）
///
/// 按 `summaryListRule` 提取列表，再按 index/count/data 规则填充 maps。
/// body 为空或必备规则缺失时返回 `None`（对齐 Kotlin 可空返回）。
pub fn parse_summary(
    body: &str,
    rule: &ReviewRule,
    base_url: &str,
) -> Option<ReviewSummaryResult> {
    parse_summary_with(body, rule, base_url, None)
}

/// 解析段评摘要（可注入 JS 执行器）
pub fn parse_summary_with(
    body: &str,
    rule: &ReviewRule,
    base_url: &str,
    executor: Option<Arc<dyn JsExecutor>>,
) -> Option<ReviewSummaryResult> {
    if body.trim().is_empty() {
        return None;
    }
    let list_rule = rule.summary_list_rule.as_deref().unwrap_or("").trim();
    let index_rule = rule
        .summary_paragraph_index_rule
        .as_deref()
        .unwrap_or("")
        .trim();
    if list_rule.is_empty() || index_rule.is_empty() {
        return None;
    }

    let analyzer = match executor {
        Some(exec) => AnalyzeRule::with_js_executor(body.to_string(), base_url.to_string(), exec),
        None => AnalyzeRule::new(body.to_string(), base_url.to_string()),
    };
    let items = get_element_list(&analyzer, list_rule).unwrap_or_default();
    if items.is_empty() {
        return Some(ReviewSummaryResult::default());
    }

    let count_rule = rule.summary_count_rule.as_deref().unwrap_or("").trim();
    let data_rule = rule
        .summary_paragraph_data_rule
        .as_deref()
        .unwrap_or("")
        .trim();
    let mut counts = HashMap::new();
    let mut keys = HashMap::new();

    for (i, item) in items.iter().enumerate() {
        let mut item_analyzer = AnalyzeRule::new(item.to_string(), base_url.to_string());
        if let Some(exec) = analyzer.js_executor() {
            item_analyzer.set_js_executor(exec);
        }
        let index_value = safe_rule_string(&item_analyzer, Some(index_rule));
        let paragraph_index = index_value
            .as_deref()
            .and_then(parse_int_str)
            .unwrap_or((i + 1) as i32);
        let count = if count_rule.is_empty() {
            0
        } else {
            safe_rule_string(&item_analyzer, Some(count_rule))
                .as_deref()
                .and_then(parse_int_str)
                .unwrap_or(0)
        };
        if paragraph_index != 0 && count > 0 {
            counts.insert(paragraph_index, count);
            let key = if data_rule.is_empty() {
                None
            } else {
                safe_rule_string(&item_analyzer, Some(data_rule))
            }
            .or(index_value)
            .unwrap_or_else(|| paragraph_index.to_string());
            keys.insert(paragraph_index, key);
        }
    }
    Some(ReviewSummaryResult { counts, keys })
}

/// 解析段评详情页（参考 Kotlin `ReviewRuleParser.parseDetailPage`）
pub fn parse_detail_page(
    body: &str,
    rule: &ReviewRule,
    next_page_rule: Option<&str>,
    base_url: &str,
) -> ReviewDetailPage {
    parse_detail_page_with(body, rule, next_page_rule, base_url, None)
}

/// 解析段评详情页（可注入 JS 执行器）
pub fn parse_detail_page_with(
    body: &str,
    rule: &ReviewRule,
    next_page_rule: Option<&str>,
    base_url: &str,
    executor: Option<Arc<dyn JsExecutor>>,
) -> ReviewDetailPage {
    let list_rule = rule.detail_list_rule.as_deref().unwrap_or("").trim();
    if list_rule.is_empty() {
        return ReviewDetailPage::default();
    }

    let analyzer = match executor {
        Some(exec) => AnalyzeRule::with_js_executor(body.to_string(), base_url.to_string(), exec),
        None => AnalyzeRule::new(body.to_string(), base_url.to_string()),
    };
    let items = get_element_list(&analyzer, list_rule).unwrap_or_default();
    let next_page_url = next_page_rule
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .and_then(|r| safe_rule_string(&analyzer, Some(r)))
        .map(|v| {
            let trimmed = v.trim().to_string();
            // 含 AnalyzeUrl 参数模式时保持原样，否则相对路径补全
            if trimmed.contains(',') && (trimmed.contains("{{") || trimmed.contains("method")) {
                trimmed
            } else {
                crate::analyze_url::AnalyzeUrl::get_absolute_url(base_url, &trimmed)
            }
        })
        .filter(|s| !s.is_empty());

    let parsed_items = items
        .iter()
        .filter_map(|item| parse_detail_item(&analyzer, item, rule, base_url, false))
        .collect();

    ReviewDetailPage {
        items: parsed_items,
        next_page_url,
    }
}

/// 解析回复页面（参考 Kotlin `ReviewRuleParser.parseReplyPage`）
///
/// 从回复页面 HTML/JSON 中按 `replyListRule` 提取回复列表，
/// 每条回复再按 `replyIdRule` / `replyAvatarRule` / `replyNameRule` /
/// `replyBadgeRule` / `replyContentRule` 提取字段。
///
/// # 参数
/// - `body`: 回复页面响应内容（HTML 或 JSON）
/// - `rule`: 书源段评规则（`ruleReview`）
/// - `base_url`: 回复页面 URL（用于相对 URL 补全）
pub fn parse_reply_page(
    body: &str,
    rule: &ReviewRule,
    base_url: &str,
) -> LegadoResult<Vec<ReviewDetailItem>> {
    parse_reply_page_with(body, rule, base_url, None)
}

/// 解析回复页面（可注入 JS 执行器，支持 `@js:` 规则）
pub fn parse_reply_page_with(
    body: &str,
    rule: &ReviewRule,
    base_url: &str,
    executor: Option<Arc<dyn JsExecutor>>,
) -> LegadoResult<Vec<ReviewDetailItem>> {
    if body.trim().is_empty() {
        return Err(LegadoError::ContentEmpty("段评回复内容为空".into()));
    }
    let list_rule = rule.reply_list_rule.as_deref().unwrap_or("").trim();
    if list_rule.is_empty() {
        return Ok(Vec::new());
    }

    let analyzer = match executor {
        Some(exec) => AnalyzeRule::with_js_executor(body.to_string(), base_url.to_string(), exec),
        None => AnalyzeRule::new(body.to_string(), base_url.to_string()),
    };

    let items = get_element_list(&analyzer, list_rule)?;
    let mut replies = Vec::new();
    for item in &items {
        if let Some(parsed) = parse_detail_item(&analyzer, item, rule, base_url, true) {
            replies.push(parsed);
        }
    }

    // 参考 Kotlin: check(items.isEmpty() || replies.isNotEmpty()) { "段评回复解析为空" }
    if !items.is_empty() && replies.is_empty() {
        return Err(LegadoError::Parser("段评回复解析为空".into()));
    }
    Ok(replies)
}

/// 提取列表元素（参考 Kotlin `normalizeList(analyzeRule.getElementsRaw(...))`）
fn get_element_list(analyzer: &AnalyzeRule, list_rule: &str) -> LegadoResult<Vec<String>> {
    // JSON 内容走 JsonPath（get_elements 的 Auto 分支仅处理 CSS 选择器）；
    // HTML 内容走 CSS 元素提取。
    let mut items = if analyzer.is_json() {
        analyzer.get_strings(list_rule).unwrap_or_default()
    } else {
        analyzer.get_elements(list_rule).unwrap_or_default()
    };

    // Kotlin normalizeList 的 String 分支：单个 JSON 数组字符串 → 展开为各项
    if items.len() == 1 {
        let trimmed = items[0].trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(trimmed) {
                let expanded: Vec<String> = arr
                    .iter()
                    .map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect();
                if !expanded.is_empty() {
                    items = expanded;
                }
            }
        }
    }
    Ok(items)
}

/// 解析单条详情/回复条目（参考 Kotlin `parseDetailItem`）
fn parse_detail_item(
    analyzer: &AnalyzeRule,
    item: &str,
    rule: &ReviewRule,
    base_url: &str,
    is_reply: bool,
) -> Option<ReviewDetailItem> {
    let mut item_analyzer = AnalyzeRule::new(item.to_string(), base_url.to_string());
    if let Some(exec) = analyzer.js_executor() {
        item_analyzer.set_js_executor(exec);
    }

    let id_rule = if is_reply {
        rule.reply_id_rule.as_deref()
    } else {
        rule.detail_id_rule.as_deref()
    };
    let avatar_rule = if is_reply {
        rule.reply_avatar_rule.as_deref()
    } else {
        rule.detail_avatar_rule.as_deref()
    };
    let name_rule = if is_reply {
        rule.reply_name_rule.as_deref()
    } else {
        rule.detail_name_rule.as_deref()
    };
    let badge_rule = if is_reply {
        rule.reply_badge_rule.as_deref()
    } else {
        rule.detail_badge_rule.as_deref()
    };
    let content_rule = if is_reply {
        rule.reply_content_rule.as_deref()
    } else {
        rule.detail_content_rule.as_deref()
    };

    let id = safe_rule_string(&item_analyzer, id_rule);
    let avatar = safe_rule_string(&item_analyzer, avatar_rule)
        .map(|v| crate::analyze_url::AnalyzeUrl::get_absolute_url(base_url, &v));
    let name = safe_rule_string(&item_analyzer, name_rule);
    let badges = safe_rule_list(&item_analyzer, badge_rule);

    let raw_content = safe_rule_string(&item_analyzer, content_rule);
    let protocol = parse_content_protocol(raw_content.as_deref(), base_url);
    let content = match &protocol {
        Some(p) => p.text.clone(),
        None => raw_content,
    };

    // 无独立 quote URL 且配置了 replyListRule 时，嵌套解析回复
    let has_quote = !rule
        .review_quote_url
        .as_deref()
        .unwrap_or("")
        .trim()
        .is_empty();
    let reply_list = rule.reply_list_rule.as_deref().unwrap_or("").trim();
    let replies = if !is_reply && !has_quote && !reply_list.is_empty() {
        get_element_list(&item_analyzer, reply_list)
            .unwrap_or_default()
            .iter()
            .filter_map(|r| parse_detail_item(&item_analyzer, r, rule, base_url, true))
            .collect()
    } else {
        Vec::new()
    };

    let empty = name.as_deref().map_or(true, |s| s.trim().is_empty())
        && content.as_deref().map_or(true, |s| s.trim().is_empty())
        && protocol.as_ref().map_or(true, |p| {
            p.image_url.as_deref().map_or(true, |s| s.trim().is_empty())
                && p.audio_url.as_deref().map_or(true, |s| s.trim().is_empty())
        });
    if empty {
        return None;
    }

    Some(ReviewDetailItem {
        id,
        avatar,
        name,
        badges,
        content,
        image_url: protocol.as_ref().and_then(|p| p.image_url.clone()),
        audio_url: protocol.as_ref().and_then(|p| p.audio_url.clone()),
        time: protocol.as_ref().and_then(|p| p.time.clone()),
        like_count: if is_reply {
            None
        } else {
            protocol.as_ref().and_then(|p| p.like_count)
        },
        reply_count: if is_reply {
            None
        } else {
            protocol.as_ref().and_then(|p| p.reply_count)
        },
        replies,
    })
}

/// 安全执行字符串规则：规则为空返回 None，执行出错返回 None（参考 Kotlin safeRuleString）
fn safe_rule_string(analyzer: &AnalyzeRule, rule: Option<&str>) -> Option<String> {
    let value = rule.map_or("", |s| s.trim());
    if value.is_empty() {
        return None;
    }
    analyzer
        .get_string(value)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// 安全执行列表规则，结果按徽章语义拆分去重（参考 Kotlin safeRuleList）
fn safe_rule_list(analyzer: &AnalyzeRule, rule: Option<&str>) -> Vec<String> {
    let value = rule.map_or("", |s| s.trim());
    if value.is_empty() {
        return Vec::new();
    }
    let mut list = analyzer.get_strings(value).unwrap_or_default();
    if list.is_empty() {
        return Vec::new();
    }
    if list.len() == 1 {
        list = split_badge_value(Some(list[0].as_str()));
    }
    let mut result: Vec<String> = Vec::new();
    for v in list {
        let t = v.trim().to_string();
        if !t.is_empty() && !result.contains(&t) {
            result.push(t);
        }
    }
    result
}

/// 拆分徽章值（参考 Kotlin splitBadgeValue）
///
/// 支持：JSON 数组字符串、换行/竖线/逗号分隔、data: URI 保持原样。
fn split_badge_value(raw: Option<&str>) -> Vec<String> {
    let raw = raw.map_or("", |s| s.trim()).to_string();
    if raw.is_empty() {
        return Vec::new();
    }
    // data: URI 不拆分
    if raw.starts_with("data:") {
        return vec![raw];
    }
    // JSON 数组字符串
    if raw.starts_with('[') && raw.ends_with(']') {
        if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(&raw) {
            let items: Vec<String> = arr
                .iter()
                .filter_map(|v| v.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            if !items.is_empty() {
                return items;
            }
        }
    }
    // 分隔符优先级：换行 > 竖线 > 逗号（含 URL 保护，参考 Kotlin shouldSplitByComma）
    let separator = if raw.contains('\n') {
        Some('\n')
    } else if raw.contains('|') {
        Some('|')
    } else if raw.contains(',') && should_split_by_comma(&raw) {
        Some(',')
    } else {
        None
    };
    match separator {
        Some(sep) => raw
            .split(sep)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        None => vec![raw],
    }
}

/// 逗号拆分保护（参考 Kotlin shouldSplitByComma）
fn should_split_by_comma(value: &str) -> bool {
    if value.starts_with("data:") {
        return false;
    }
    if !value.contains("://") {
        return true;
    }
    value.contains(",http://") || value.contains(",https://")
}

/// 解析内容协议（参考 Kotlin parseContentProtocol）
///
/// 规则返回值形如 `{"text","img","audio","time","likeCount","replyCount"}` 时
/// 按协议提取结构化字段，否则返回 None（视为纯文本内容）。
fn parse_content_protocol(raw: Option<&str>, base_url: &str) -> Option<ContentProtocol> {
    let value = raw.map_or("", |s| s.trim());
    if !value.starts_with('{') || !value.ends_with('}') {
        return None;
    }
    let obj: serde_json::Map<String, Value> = serde_json::from_str(value).ok()?;

    let text = string_value(&obj, "text");
    let image = string_value(&obj, "img");
    let audio = string_value(&obj, "audio");
    let time = string_value(&obj, "time");
    let like_count = obj.get("likeCount").and_then(parse_int_value);
    let reply_count = obj.get("replyCount").and_then(parse_int_value);

    if text.is_none()
        && image.is_none()
        && audio.is_none()
        && time.is_none()
        && like_count.is_none()
        && reply_count.is_none()
    {
        return None;
    }
    Some(ContentProtocol {
        text,
        image_url: image.map(|u| crate::analyze_url::AnalyzeUrl::get_absolute_url(base_url, &u)),
        audio_url: audio.map(|u| crate::analyze_url::AnalyzeUrl::get_absolute_url(base_url, &u)),
        time,
        like_count,
        reply_count,
    })
}

/// 提取对象中的非空字符串字段（参考 Kotlin Map.stringValue）
fn string_value(obj: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key)
        .and_then(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Null => None,
            other => Some(other.to_string()),
        })
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// 宽松整数解析（参考 Kotlin parseInt：Number 或字符串，支持小数截断）
fn parse_int_value(value: &Value) -> Option<i32> {
    match value {
        Value::Number(n) => n.as_i64().map(|v| v as i32),
        Value::String(s) => parse_int_str(s),
        _ => None,
    }
}

fn parse_int_str(s: &str) -> Option<i32> {
    let t = s.trim();
    t.parse::<i32>().ok().or_else(|| t.parse::<f64>().ok().map(|f| f as i32))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造带 reply 规则族的 ReviewRule
    fn reply_rule(list: &str, id: &str, avatar: &str, name: &str, badge: &str, content: &str) -> ReviewRule {
        ReviewRule {
            reply_list_rule: Some(list.into()),
            reply_id_rule: Some(id.into()),
            reply_avatar_rule: Some(avatar.into()),
            reply_name_rule: Some(name.into()),
            reply_badge_rule: Some(badge.into()),
            reply_content_rule: Some(content.into()),
            ..Default::default()
        }
    }

    #[test]
    fn test_parse_summary_json() {
        let body = r#"{
            "data": [
                {"idx": 1, "cnt": 5, "token": "p1"},
                {"idx": 2, "cnt": 0, "token": "p2"},
                {"idx": 3, "cnt": 12, "token": "p3"}
            ]
        }"#;
        let rule = ReviewRule {
            summary_list_rule: Some("$.data".into()),
            summary_paragraph_index_rule: Some("$.idx".into()),
            summary_count_rule: Some("$.cnt".into()),
            summary_paragraph_data_rule: Some("$.token".into()),
            ..Default::default()
        };
        let result = parse_summary(body, &rule, "http://example.com").unwrap();
        assert_eq!(result.counts.get(&1), Some(&5));
        assert_eq!(result.counts.get(&3), Some(&12));
        assert!(!result.counts.contains_key(&2));
        assert_eq!(result.keys.get(&1).map(String::as_str), Some("p1"));
        assert_eq!(result.keys.get(&3).map(String::as_str), Some("p3"));
    }

    #[test]
    fn test_parse_summary_blank_body_returns_none() {
        let rule = ReviewRule {
            summary_list_rule: Some("$.data".into()),
            summary_paragraph_index_rule: Some("$.idx".into()),
            ..Default::default()
        };
        assert!(parse_summary("  ", &rule, "http://example.com").is_none());
    }

    #[test]
    fn test_parse_detail_page_json() {
        let body = r#"{
            "comments": [
                {"id": "c1", "user": "甲", "text": "好看", "tag": "作者"},
                {"id": "c2", "user": "乙", "text": "一般"}
            ],
            "next": "/page/2"
        }"#;
        let rule = ReviewRule {
            detail_list_rule: Some("$.comments".into()),
            detail_id_rule: Some("$.id".into()),
            detail_name_rule: Some("$.user".into()),
            detail_badge_rule: Some("$.tag".into()),
            detail_content_rule: Some("$.text".into()),
            ..Default::default()
        };
        let page = parse_detail_page(body, &rule, Some("$.next"), "http://example.com");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].id.as_deref(), Some("c1"));
        assert_eq!(page.items[0].name.as_deref(), Some("甲"));
        assert_eq!(page.items[0].badges, vec!["作者".to_string()]);
        assert_eq!(
            page.next_page_url.as_deref(),
            Some("http://example.com/page/2")
        );
    }

    #[test]
    fn test_parse_reply_page_json() {
        let body = r#"{
            "data": {
                "reply_list": [
                    {"uid": "r1", "avatar": "/a/1.jpg", "nick": "读者甲", "tag": "沙发", "text": "写得真好"},
                    {"uid": "r2", "avatar": "http://img.com/2.jpg", "nick": "读者乙", "tag": "", "text": "同意楼上"}
                ]
            }
        }"#;
        let rule = reply_rule(
            "$.data.reply_list",
            "$.uid",
            "$.avatar",
            "$.nick",
            "$.tag",
            "$.text",
        );
        let replies = parse_reply_page(body, &rule, "http://example.com").unwrap();
        assert_eq!(replies.len(), 2);
        assert_eq!(replies[0].id.as_deref(), Some("r1"));
        assert_eq!(replies[0].name.as_deref(), Some("读者甲"));
        assert_eq!(replies[0].content.as_deref(), Some("写得真好"));
        assert_eq!(replies[0].badges, vec!["沙发".to_string()]);
        // 相对头像补全为绝对 URL
        assert_eq!(
            replies[0].avatar.as_deref(),
            Some("http://example.com/a/1.jpg")
        );
        // 绝对头像保持原样
        assert_eq!(
            replies[1].avatar.as_deref(),
            Some("http://img.com/2.jpg")
        );
        // 空徽章不产生条目
        assert!(replies[1].badges.is_empty());
        // 回复条目不携带点赞数/回复数
        assert!(replies[0].like_count.is_none());
        assert!(replies[0].reply_count.is_none());
    }

    #[test]
    fn test_parse_reply_page_html() {
        let body = r#"<div class="replies">
            <div class="reply"><span class="user">用户A</span><span class="content">第一段回复</span></div>
            <div class="reply"><span class="user">用户B</span><span class="content">第二段回复</span></div>
        </div>"#;
        let rule = ReviewRule {
            reply_list_rule: Some("div.reply".into()),
            reply_name_rule: Some("span.user@text".into()),
            reply_content_rule: Some("span.content@text".into()),
            ..Default::default()
        };
        let replies = parse_reply_page(body, &rule, "http://example.com").unwrap();
        assert_eq!(replies.len(), 2);
        assert_eq!(replies[0].name.as_deref(), Some("用户A"));
        assert_eq!(replies[0].content.as_deref(), Some("第一段回复"));
        assert_eq!(replies[1].content.as_deref(), Some("第二段回复"));
    }

    #[test]
    fn test_parse_reply_page_content_protocol() {
        let body = r#"{"list": [
            {"user": "图图", "raw": "{\"text\":\"带图回复\",\"img\":\"/img/p.jpg\",\"time\":\"3分钟前\"}"}
        ]}"#;
        let rule = reply_rule("$.list", "", "", "$.user", "", "$.raw");
        let replies = parse_reply_page(body, &rule, "http://example.com").unwrap();
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0].content.as_deref(), Some("带图回复"));
        assert_eq!(
            replies[0].image_url.as_deref(),
            Some("http://example.com/img/p.jpg")
        );
        assert_eq!(replies[0].time.as_deref(), Some("3分钟前"));
    }

    #[test]
    fn test_parse_reply_page_empty_body() {
        let rule = reply_rule("$.list", "", "", "", "", "$.text");
        let err = parse_reply_page("   ", &rule, "http://example.com").unwrap_err();
        assert!(err.to_string().contains("段评回复内容为空"));
    }

    #[test]
    fn test_parse_reply_page_missing_list_rule() {
        let rule = ReviewRule::default();
        let replies = parse_reply_page(r#"{"list": []}"#, &rule, "http://example.com").unwrap();
        assert!(replies.is_empty());
    }

    #[test]
    fn test_parse_reply_page_all_filtered_errors() {
        // 列表非空但所有条目字段全空 → 参考 Kotlin check 抛错
        let body = r#"{"list": [{"other": "无字段"}]}"#;
        let rule = reply_rule("$.list", "$.uid", "$.avatar", "$.nick", "", "$.text");
        let err = parse_reply_page(body, &rule, "http://example.com").unwrap_err();
        assert!(err.to_string().contains("段评回复解析为空"));
    }

    #[test]
    fn test_parse_reply_page_json_array_string_list() {
        // 列表规则返回单个 JSON 数组字符串时应展开
        let body = r#"{"all": "[{\"nick\": \"甲\", \"text\": \"一\"}, {\"nick\": \"乙\", \"text\": \"二\"}]"}"#;
        let rule = reply_rule("$.all", "", "", "$.nick", "", "$.text");
        let replies = parse_reply_page(body, &rule, "http://example.com").unwrap();
        assert_eq!(replies.len(), 2);
        assert_eq!(replies[0].name.as_deref(), Some("甲"));
        assert_eq!(replies[1].content.as_deref(), Some("二"));
    }

    #[test]
    fn test_split_badge_value() {
        // JSON 数组字符串
        assert_eq!(
            split_badge_value(Some(r#"["作者", "置顶"]"#)),
            vec!["作者".to_string(), "置顶".to_string()]
        );
        // 换行分隔
        assert_eq!(
            split_badge_value(Some("楼主\n层主")),
            vec!["楼主".to_string(), "层主".to_string()]
        );
        // 竖线分隔
        assert_eq!(
            split_badge_value(Some("VIP|达人")),
            vec!["VIP".to_string(), "达人".to_string()]
        );
        // 含 URL 时逗号不拆分（除非 ,http 形式）
        assert_eq!(
            split_badge_value(Some("http://a.com/x,y")),
            vec!["http://a.com/x,y".to_string()]
        );
        assert_eq!(
            split_badge_value(Some("http://a.com,https://b.com")),
            vec!["http://a.com".to_string(), "https://b.com".to_string()]
        );
        // data: URI 保持原样
        assert_eq!(
            split_badge_value(Some("data:image/png;base64,AAAA")),
            vec!["data:image/png;base64,AAAA".to_string()]
        );
        // 空值
        assert!(split_badge_value(None).is_empty());
        assert!(split_badge_value(Some("  ")).is_empty());
    }

    #[test]
    fn test_parse_content_protocol_plain_text_returns_none() {
        assert!(parse_content_protocol(Some("普通文本"), "http://example.com").is_none());
        // 无已知键的 JSON → None（按纯文本处理）
        assert!(parse_content_protocol(Some(r#"{"foo": 1}"#), "http://example.com").is_none());
    }

    #[test]
    fn test_parse_content_protocol_audio() {
        let protocol = parse_content_protocol(
            Some(r#"{"audio": "/voice/1.mp3", "likeCount": "12"}"#),
            "http://example.com",
        )
        .unwrap();
        assert_eq!(
            protocol.audio_url.as_deref(),
            Some("http://example.com/voice/1.mp3")
        );
        assert_eq!(protocol.like_count, Some(12));
        assert!(protocol.text.is_none());
    }
}
