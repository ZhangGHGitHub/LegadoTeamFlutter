//! RSS 默认解析（对齐原版 `RssParserDefault` + `RssParserByRule` 默认分支）
//!
//! 解析本体在 [`legado_net::rss::parse_default_items`]（单一实现，逐行对齐
//! `RssParserDefault.kt:36-136`）；本模块只负责把网络层产物
//! [`DefaultFeedItem`] 映射为跨层中立结构 [`RssArticleItem`]。
//!
//! 原版 `RssParserByRule.parseXML`（`RssParserByRule.kt:32-41`）在
//! `ruleArticles` 为空/空白时直接走默认解析；本批（15a）规则列表未落地，
//! 引擎统一使用本模块。

use legado_net::rss::{parse_default_items, DefaultFeedItem};

use super::models::{RssArticleItem, RssListPage};

/// 默认解析的正文类型恒为 0（网页）
///
/// 原版 `RssParserDefault` 不设置 `RssArticle.type`，取实体默认值 0
/// （`RssArticle.kt` `var type: Int = 0`）。
const DEFAULT_ARTICLE_TYPE: i32 = 0;

/// 默认解析列表页
///
/// 恒无下一页（原版默认解析返回 `Pair(articleList, null)`）。
pub fn parse_default_list(sort_name: &str, xml: &str, source_url: &str) -> RssListPage {
    RssListPage {
        items: parse_default_items(sort_name, xml, source_url)
            .into_iter()
            .map(map_item)
            .collect(),
        next_url: None,
    }
}

/// [`DefaultFeedItem`] → [`RssArticleItem`]（全字段透传，不丢字段）
fn map_item(item: DefaultFeedItem) -> RssArticleItem {
    RssArticleItem {
        title: item.title,
        link: item.link,
        description: item.description,
        pub_date: item.pub_date,
        image: item.image,
        content: item.content,
        origin: item.origin,
        sort: item.sort,
        article_type: DEFAULT_ARTICLE_TYPE,
        variable: None,
    }
}
