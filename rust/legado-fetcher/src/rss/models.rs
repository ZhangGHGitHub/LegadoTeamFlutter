//! RSS 中立数据结构（跨引擎/宿主层传递）
//!
//! 字段语义对齐 Kotlin `RssArticle`（`app/src/main/java/io/legado/app/data/
//! entities/RssArticle.kt`）：`origin` = 源 URL、`sort` = 分类名、
//! `article_type` = 0 网页 / 1 图片 / 2 视频、`variable` = 规则源变量 JSON。
//!
//! 本层**不含任何宿主（FFI/DB）类型**：宿主按需自行映射（书源抓取同款分层）。

/// 列表中的一篇文章（中立结构）
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssArticleItem {
    /// 标题
    pub title: String,
    /// 文章链接（默认解析原样保留，不做绝对化）
    pub link: String,
    /// 描述
    pub description: Option<String>,
    /// 发布时间（原版为原样字符串，不解析为时间）
    pub pub_date: Option<String>,
    /// 封面图 URL
    pub image: Option<String>,
    /// 正文（`content:encoded` 等）
    pub content: Option<String>,
    /// 所属源 URL（`sourceUrl`）
    pub origin: String,
    /// 分类名（`sortName`）
    pub sort: String,
    /// 类型 0 网页 / 1 图片 / 2 视频（对齐 Kotlin `RssArticle.type`）
    pub article_type: i32,
    /// 规则源变量（默认解析恒 `None`）
    pub variable: Option<String>,
}

/// 列表页结果（对齐原版 `Pair<MutableList<RssArticle>, String?>` 的 Rust 形态）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RssListPage {
    /// 本页文章
    pub items: Vec<RssArticleItem>,
    /// 下一页 URL（`ruleNextPage` 解析结果；默认解析恒 `None`）
    pub next_url: Option<String>,
}
