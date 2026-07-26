use serde::{Deserialize, Serialize};

/// 段评规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReviewRule {
    /// 段评URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "reviewUrl")]
    pub review_url: Option<String>,
    /// 段评发布者头像
    #[serde(skip_serializing_if = "Option::is_none", rename = "avatarRule")]
    pub avatar_rule: Option<String>,
    /// 段评内容
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentRule")]
    pub content_rule: Option<String>,
    /// 段评发布时间
    #[serde(skip_serializing_if = "Option::is_none", rename = "postTimeRule")]
    pub post_time_rule: Option<String>,
    /// 获取段评回复URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "reviewQuoteUrl")]
    pub review_quote_url: Option<String>,
    /// 点赞URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "voteUpUrl")]
    pub vote_up_url: Option<String>,
    /// 点踩URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "voteDownUrl")]
    pub vote_down_url: Option<String>,
    /// 发送回复URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "postReviewUrl")]
    pub post_review_url: Option<String>,
    /// 发送回复段评URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "postQuoteUrl")]
    pub post_quote_url: Option<String>,
    /// 删除段评URL
    #[serde(skip_serializing_if = "Option::is_none", rename = "deleteUrl")]
    pub delete_url: Option<String>,
    #[serde(default)]
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none", rename = "reviewSummaryUrl")]
    pub review_summary_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "summaryListRule")]
    pub summary_list_rule: Option<String>,
    #[serde(
        skip_serializing_if = "Option::is_none",
        rename = "summaryParagraphIndexRule"
    )]
    pub summary_paragraph_index_rule: Option<String>,
    #[serde(
        skip_serializing_if = "Option::is_none",
        rename = "summaryParagraphDataRule"
    )]
    pub summary_paragraph_data_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "summaryCountRule")]
    pub summary_count_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "reviewDetailUrl")]
    pub review_detail_url: Option<String>,
    #[serde(
        skip_serializing_if = "Option::is_none",
        rename = "reviewDetailNextPageUrl"
    )]
    pub review_detail_next_page_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailListRule")]
    pub detail_list_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailIdRule")]
    pub detail_id_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailAvatarRule")]
    pub detail_avatar_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailNameRule")]
    pub detail_name_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailBadgeRule")]
    pub detail_badge_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "detailContentRule")]
    pub detail_content_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyListRule")]
    pub reply_list_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyIdRule")]
    pub reply_id_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyAvatarRule")]
    pub reply_avatar_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyNameRule")]
    pub reply_name_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyBadgeRule")]
    pub reply_badge_rule: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyContentRule")]
    pub reply_content_rule: Option<String>,
}
