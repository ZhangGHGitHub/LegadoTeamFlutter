//! RSS/Atom Feed 解析器
//!
//! 支持 RSS 2.0 和 Atom 格式。
//! 参考 Kotlin 实现 `RssSource.kt` / `RssArticle.kt`。
//!
//! 另提供 [`parse_default_items`]：逐行对齐原版 `RssParserDefault.kt` 的
//! **默认列表解析**（只认 `<item>`；Atom `<feed>` 为已登记超集回退）。
//!
//! ## 旧兼容 API（仅 REST 调试/兼容保留）
//!
//! [`parse_feed`] / [`fetch_feed`] 及内部的 `parse_rss` 面向
//! `legado-server` 的 RSS 调试接口，语义与 Android 原版 `RssParserDefault`
//! 不一致（按 local-name 匹配、字段映射口径不同、无 `sort`/`origin` 等默认
//! 列表字段）；RSS 主链路（FFI 列表取数）一律走 [`parse_default_items`]。
//! 未加 `#[deprecated]` 是因为 `legado-server` 仍在编译期使用，避免以
//! `-D warnings` 门禁误伤；接线迁移后再评估下线。

use std::sync::OnceLock;

use legado_core::{LegadoError, LegadoResult};
use quick_xml::events::{BytesRef, BytesStart, Event};
use quick_xml::Reader;
use regex::Regex;

/// RSS 文章
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RssArticle {
    pub title: String,
    pub link: String,
    pub description: Option<String>,
    pub pub_date: Option<String>,
    pub author: Option<String>,
    pub image_url: Option<String>,
    pub content: Option<String>,
    pub categories: Vec<String>,
}

/// RSS Feed
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RssFeed {
    pub title: String,
    pub link: String,
    pub description: Option<String>,
    pub articles: Vec<RssArticle>,
}

/// 解析 RSS/Atom feed
///
/// **仅 REST 调试/兼容保留**（`legado-server` RSS 接口使用）：按
/// local-name 匹配，语义不等价于 Android 原版 `RssParserDefault`；RSS 主链路
/// 请使用 [`parse_default_items`]。
pub fn parse_feed(xml_content: &str) -> LegadoResult<RssFeed> {
    if xml_content.contains("<feed") {
        parse_atom(xml_content)
    } else {
        parse_rss(xml_content)
    }
}

/// 解析 RSS 2.0（旧兼容路径，仅 [`parse_feed`] 内部使用）
fn parse_rss(xml: &str) -> LegadoResult<RssFeed> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut buf = Vec::new();
    let mut articles = Vec::new();
    let mut feed_title = String::new();
    let mut feed_link = String::new();
    let mut feed_desc: Option<String> = None;

    let mut in_item = false;
    let mut in_channel = false;
    let mut current_tag = String::new();
    let mut current_text = String::new();

    // 当前 item 字段
    let mut item_title = String::new();
    let mut item_link = String::new();
    let mut item_desc: Option<String> = None;
    let mut item_pub_date: Option<String> = None;
    let mut item_author: Option<String> = None;
    let mut item_image_url: Option<String> = None;
    let mut item_content: Option<String> = None;
    let mut item_categories: Vec<String> = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                let tag_name = e.local_name().as_ref().to_string();
                current_tag = tag_name.clone();
                current_text.clear();

                match tag_name.as_str() {
                    "channel" => in_channel = true,
                    "item" => {
                        in_item = true;
                        item_title = String::new();
                        item_link = String::new();
                        item_desc = None;
                        item_pub_date = None;
                        item_author = None;
                        item_image_url = None;
                        item_content = None;
                        item_categories = Vec::new();
                    }
                    _ => {}
                }
            }
            Ok(Event::End(ref e)) => {
                let tag_name = e.local_name().as_ref().to_string();

                if tag_name == "item" {
                    articles.push(RssArticle {
                        title: item_title.clone(),
                        link: item_link.clone(),
                        description: item_desc.clone(),
                        pub_date: item_pub_date.clone(),
                        author: item_author.clone(),
                        image_url: item_image_url.clone(),
                        content: item_content.clone(),
                        categories: item_categories.clone(),
                    });
                    in_item = false;
                } else if tag_name == "channel" {
                    in_channel = false;
                } else if in_item {
                    match tag_name.as_str() {
                        "title" => item_title = current_text.clone(),
                        "link" => item_link = current_text.clone(),
                        "description" => {
                            if !current_text.is_empty() {
                                item_desc = Some(current_text.clone())
                            }
                        }
                        "pubDate" => {
                            if !current_text.is_empty() {
                                item_pub_date = Some(current_text.clone())
                            }
                        }
                        "author" | "creator" => {
                            if !current_text.is_empty() {
                                item_author = Some(current_text.clone())
                            }
                        }
                        "encoded" => {
                            if !current_text.is_empty() {
                                item_content = Some(current_text.clone())
                            }
                        }
                        "category" if !current_text.is_empty() => {
                            item_categories.push(current_text.clone())
                        }
                        _ => {}
                    }
                } else if in_channel {
                    match tag_name.as_str() {
                        "title" => feed_title = current_text.clone(),
                        "link" => feed_link = current_text.clone(),
                        "description" if !current_text.is_empty() => {
                            feed_desc = Some(current_text.clone())
                        }
                        _ => {}
                    }
                }

                current_tag.clear();
                current_text.clear();
            }
            Ok(Event::Empty(ref e)) => {
                // 处理自闭合标签，如 <enclosure url="..." />
                let tag_name = e.local_name().as_ref().to_string();
                if tag_name == "enclosure" && in_item {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == "url" {
                            item_image_url = Some(attr.value.to_string());
                        }
                    }
                }
            }
            Ok(Event::Text(ref e)) => {
                current_text.push_str(e.as_ref());
            }
            Ok(Event::CData(ref e)) => {
                current_text.push_str(e.as_ref());
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(LegadoError::Parser(format!("RSS XML parse error: {}", e)));
            }
            _ => {}
        }
        buf.clear();
    }

    Ok(RssFeed {
        title: feed_title,
        link: feed_link,
        description: feed_desc,
        articles,
    })
}

/// 解析 Atom
fn parse_atom(xml: &str) -> LegadoResult<RssFeed> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut buf = Vec::new();
    let mut articles = Vec::new();
    let mut feed_title = String::new();
    let mut feed_link = String::new();
    let mut feed_desc: Option<String> = None;

    let mut in_entry = false;
    let mut in_author = false;
    let mut current_tag = String::new();
    let mut current_text = String::new();

    // 当前 entry 字段
    let mut entry_title = String::new();
    let mut entry_link = String::new();
    let mut entry_summary: Option<String> = None;
    let mut entry_content: Option<String> = None;
    let mut entry_published: Option<String> = None;
    let mut entry_author: Option<String> = None;
    let mut entry_image_url: Option<String> = None;
    let mut entry_categories: Vec<String> = Vec::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                let tag_name = e.local_name().as_ref().to_string();
                current_tag = tag_name.clone();
                current_text.clear();

                match tag_name.as_str() {
                    "entry" => {
                        in_entry = true;
                        entry_title = String::new();
                        entry_link = String::new();
                        entry_summary = None;
                        entry_content = None;
                        entry_published = None;
                        entry_author = None;
                        entry_image_url = None;
                        entry_categories = Vec::new();
                    }
                    "author" | "contributor" => {
                        in_author = true;
                    }
                    _ => {}
                }
            }
            Ok(Event::End(ref e)) => {
                let tag_name = e.local_name().as_ref().to_string();

                if tag_name == "entry" {
                    articles.push(RssArticle {
                        title: entry_title.clone(),
                        link: entry_link.clone(),
                        description: entry_summary.clone(),
                        pub_date: entry_published.clone(),
                        author: entry_author.clone(),
                        image_url: entry_image_url.clone(),
                        content: entry_content.clone(),
                        categories: entry_categories.clone(),
                    });
                    in_entry = false;
                } else if tag_name == "author" || tag_name == "contributor" {
                    in_author = false;
                } else if in_author && tag_name == "name" {
                    if !current_text.is_empty() {
                        entry_author = Some(current_text.clone());
                    }
                } else if in_entry {
                    match tag_name.as_str() {
                        "title" => entry_title = current_text.clone(),
                        "summary" => {
                            if !current_text.is_empty() {
                                entry_summary = Some(current_text.clone())
                            }
                        }
                        "content" => {
                            if !current_text.is_empty() {
                                entry_content = Some(current_text.clone())
                            }
                        }
                        "published" | "updated"
                            if !current_text.is_empty() && entry_published.is_none() =>
                        {
                            entry_published = Some(current_text.clone())
                        }
                        _ => {}
                    }
                } else {
                    // feed 级别
                    match tag_name.as_str() {
                        "title" => feed_title = current_text.clone(),
                        "subtitle" if !current_text.is_empty() => {
                            feed_desc = Some(current_text.clone())
                        }
                        _ => {}
                    }
                }

                current_tag.clear();
                current_text.clear();
            }
            Ok(Event::Empty(ref e)) => {
                let tag_name = e.local_name().as_ref().to_string();
                if tag_name == "link" {
                    let mut href = String::new();
                    let mut rel = String::new();
                    let mut link_type = String::new();
                    for attr in e.attributes().flatten() {
                        match attr.key.as_ref() {
                            "href" => href = attr.value.to_string(),
                            "rel" => rel = attr.value.to_string(),
                            "type" => link_type = attr.value.to_string(),
                            _ => {}
                        }
                    }
                    if in_entry {
                        if rel.is_empty() || rel == "alternate" {
                            if entry_link.is_empty() {
                                entry_link = href;
                            }
                        } else if (rel == "enclosure"
                            || link_type.starts_with("image/")
                            || link_type.starts_with("audio/"))
                            && entry_image_url.is_none()
                        {
                            entry_image_url = Some(href);
                        }
                    } else if feed_link.is_empty() && (rel.is_empty() || rel == "alternate") {
                        feed_link = href;
                    }
                } else if tag_name == "category" && in_entry {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == "term" {
                            let term = attr.value.to_string();
                            if !term.is_empty() {
                                entry_categories.push(term);
                            }
                        }
                    }
                }
            }
            Ok(Event::Text(ref e)) => {
                current_text.push_str(e.as_ref());
            }
            Ok(Event::CData(ref e)) => {
                current_text.push_str(e.as_ref());
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(LegadoError::Parser(format!("Atom XML parse error: {}", e)));
            }
            _ => {}
        }
        buf.clear();
    }

    Ok(RssFeed {
        title: feed_title,
        link: feed_link,
        description: feed_desc,
        articles,
    })
}

/// 从 RSS 源 URL 获取并解析 feed
///
/// **仅 REST 调试/兼容保留**（`legado-server` RSS 接口使用）。RSS 主链路的
/// 列表取数走 `legado-fetcher::rss`（默认解析 [`parse_default_items`]）。
pub async fn fetch_feed(url: &str, client: &crate::client::LegadoClient) -> LegadoResult<RssFeed> {
    let response = client.get(url, None).await?;
    parse_feed(&response.body)
}

// ===========================================================================
// 默认列表解析（对齐原版 RssParserDefault.kt:36-136）
// ===========================================================================

/// 默认解析产出的一篇文章（字段口径对齐原版 `RssParserDefault.parseXML`
/// 构造的 `RssArticle`）。
///
/// 取值规则（逐行对齐 `RssParserDefault.kt`）：
/// - `title` / `link`：元素文本 **trim**；
/// - `description` / `content`：元素文本（description trim 后存储）；
/// - `image`：`media:thumbnail@url` 与 `enclosure@url`（仅 `type` 含 `image/`）
///   按**文档顺序**无条件覆盖；`description` / `content:encoded` 仅在 image
///   仍为空时取**首个** `<img src="...">`（双引号 src、大小写敏感，同原版正则）；
/// - `pub_date`：`pubDate` **只取直接文本节点**（嵌套标签不取值），`time`
///   元素文本直接覆盖（原版不 trim）；
/// - `origin` = 源 URL（`sourceUrl`），`sort` = 分类名（`sortName`）；
/// - link / image 不做绝对化（原版同样原样保留）。
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultFeedItem {
    pub title: String,
    pub link: String,
    pub description: Option<String>,
    pub pub_date: Option<String>,
    pub image: Option<String>,
    pub content: Option<String>,
    pub origin: String,
    pub sort: String,
}

/// 默认解析 RSS 列表（对齐原版 `RssParserDefault.parseXML`）
///
/// 语义要点：
/// - 只认**字面**标签 `<item>`（等价 `factory.isNamespaceAware = false`：含前缀
///   标签如 `media:thumbnail` / `content:encoded` 按字面名匹配，标签名与
///   `item` 收尾判定均大小写不敏感），RSS 2.0 / RDF 均可用；
/// - 每个 `</item>` 收尾即收集一篇（`origin = source_url`、`sort = sort_name`），
///   **不做标题过滤**（对齐原版 `articleList.add(currentArticle)`）；
/// - 恒无下一页（原版返回 `Pair(list, null)`，默认解析无分页）。
///
/// ## 已登记的超集偏离：Atom 回退
///
/// 原版默认解析只认 `<item>`，Atom `<entry>` 文档得到 0 篇
/// （`RssParserDefault.kt:89-98` 只处理 `item` 收尾）。本实现为保留现有
/// Atom 订阅用户可用性：当 item 扫描结果为空**且**文档根元素为 `<feed>` 时，
/// 回退既有 [`parse_atom`] 并映射为 [`DefaultFeedItem`]。
///
/// ## 宽容度（quick-xml，偏离如实登记）
///
/// 原版 `XmlPullParser` 对畸形 XML 抛异常；本实现按 quick-xml 宽容度处理：
/// 解析出错即停止扫描并返回**已收集**条目（不 panic、不伪造文章）；裸 `&`
/// （真实 feed 常见的未转义）放行。
///
/// ## 已登记边界差异（与 `legado-fetcher::rss` 模块文档同步）
///
/// - `pubDate` 内嵌标签：原版 `next()` 后的 `continue@loop` 会让嵌套标签继续被
///   外层解析（如内嵌 `<time>` 仍生效）；本实现 `read_direct_text` 吞掉嵌套
///   起始事件后不赋值；
/// - `time` 元素文本**不 trim**（同原版）；其余文本字段的空白裁剪与 Kotlin
///   `trim()` 在极端空白字符（NBSP、控制字符）上不完全一致；
/// - 嵌套 `<item>`：本实现 START item 复位当前文章（原版不复位，内层 item
///   继承外层字段）；
/// - 未声明实体按字面保留 `&name;`（原版抛异常）；
/// - 带命名空间前缀的核心元素（如 `<rss:item>`）: **不识别**（对齐原版
///   `namespaceAware = false` 的字面名规则）；旧 [`parse_feed`] 用 local-name
///   匹配，行为不同（旧 API 仅 REST 调试/兼容保留）。
pub fn parse_default_items(sort_name: &str, xml: &str, source_url: &str) -> Vec<DefaultFeedItem> {
    let mut reader = Reader::from_str(xml);
    {
        let config = reader.config_mut();
        // 文本裁剪由本实现按原版逐字段处理（title/link/description/content 显式
        // trim；pubDate 的 TEXT 分支 trim；`time` 不 trim）
        config.trim_text(false);
        // 真实 feed 常见未转义 `&`：原版 kXML 会抛异常，此处放行（已登记超集）
        config.allow_dangling_amp = true;
    }

    let mut items: Vec<DefaultFeedItem> = Vec::new();
    let mut inside_item = false;
    let mut current = DefaultFeedItem::default();
    // 根元素名（小写）：仅用于 Atom `<feed>` 回退判定
    let mut root_name: Option<String> = None;

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = literal_name(e.name());
                let lower = name.to_ascii_lowercase();
                if root_name.is_none() {
                    root_name = Some(lower.clone());
                }
                if lower == "item" {
                    inside_item = true;
                    current = DefaultFeedItem::default();
                    continue;
                }
                if !inside_item {
                    continue;
                }
                match lower.as_str() {
                    "title" => current.title = read_element_text(&mut reader).trim().to_string(),
                    "link" => current.link = read_element_text(&mut reader).trim().to_string(),
                    // `media:thumbnail@url`：直接覆盖（原版无条件赋值）
                    "media:thumbnail" => current.image = attribute_value(&e, "url"),
                    "enclosure" => {
                        // 仅 type 含 `image/` 时取 url 作封面（原版 :50-58）
                        if attribute_value(&e, "type").is_some_and(|t| t.contains("image/")) {
                            current.image = attribute_value(&e, "url");
                        }
                    }
                    "description" => {
                        // 原版：description = nextText()，存储时 trim；取图用未 trim 原文
                        let raw = read_element_text(&mut reader);
                        if current.image.is_none() {
                            current.image = get_image_url(&raw);
                        }
                        current.description = Some(raw.trim().to_string());
                    }
                    "content:encoded" => {
                        // 原版：content = nextText().trim()，取图同样用 trim 后内容
                        let content = read_element_text(&mut reader).trim().to_string();
                        if current.image.is_none() {
                            current.image = get_image_url(&content);
                        }
                        current.content = Some(content);
                    }
                    "pubdate" => {
                        // 原版 :76-85：只取紧随其后的 TEXT，嵌套标签跳过
                        if let Some(text) = read_direct_text(&mut reader) {
                            current.pub_date = Some(text);
                        }
                    }
                    // 原版 :86-87：`time` 文本直接覆盖 pubDate（不 trim）
                    "time" => current.pub_date = Some(read_element_text(&mut reader)),
                    _ => {}
                }
            }
            Ok(Event::Empty(e)) => {
                // 自闭合元素：对应原版 START_TAG + 紧随 END_TAG
                let name = literal_name(e.name());
                let lower = name.to_ascii_lowercase();
                if root_name.is_none() {
                    root_name = Some(lower.clone());
                }
                if lower == "item" {
                    // `<item/>`：原版 START 后立即 END → 收集一条空文章
                    items.push(finish_item(current, sort_name, source_url));
                    current = DefaultFeedItem::default();
                    inside_item = false;
                    continue;
                }
                if !inside_item {
                    continue;
                }
                match lower.as_str() {
                    "media:thumbnail" => current.image = attribute_value(&e, "url"),
                    "enclosure" => {
                        if attribute_value(&e, "type").is_some_and(|t| t.contains("image/")) {
                            current.image = attribute_value(&e, "url");
                        }
                    }
                    // 原版 nextText() 对空元素返回 "" → 字段被置为 Some("")
                    "description" => current.description = Some(String::new()),
                    "content:encoded" => current.content = Some(String::new()),
                    "time" => current.pub_date = Some(String::new()),
                    _ => {}
                }
            }
            Ok(Event::End(e)) => {
                let name = literal_name(e.name());
                if name.eq_ignore_ascii_case("item") {
                    items.push(finish_item(current, sort_name, source_url));
                    current = DefaultFeedItem::default();
                    inside_item = false;
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }

    // Atom 回退（已登记超集）：item 扫描为空且根元素为 `<feed>`
    if items.is_empty() && root_name.as_deref() == Some("feed") {
        if let Ok(feed) = parse_atom(xml) {
            return feed
                .articles
                .into_iter()
                .map(|a| DefaultFeedItem {
                    title: a.title,
                    link: a.link,
                    description: a.description,
                    pub_date: a.pub_date,
                    image: a.image_url,
                    content: a.content,
                    origin: source_url.to_string(),
                    sort: sort_name.to_string(),
                })
                .collect();
        }
    }

    items
}

/// 收尾收集：补齐 `origin` / `sort`（对齐原版 `</item>` 分支 :93-97）
fn finish_item(item: DefaultFeedItem, sort_name: &str, source_url: &str) -> DefaultFeedItem {
    DefaultFeedItem {
        origin: source_url.to_string(),
        sort: sort_name.to_string(),
        ..item
    }
}

/// 事件标签名（**含前缀**的字面名，`namespaceAware=false` 口径）
fn literal_name(name: quick_xml::name::QName<'_>) -> String {
    name.into_inner().to_string()
}

/// 读取属性值（按字面名精确匹配，大小写敏感，对齐 `getAttributeValue(null, key)`）
fn attribute_value(e: &BytesStart<'_>, key: &str) -> Option<String> {
    e.attributes()
        .flatten()
        .find(|attr| attr.key.as_ref() == key)
        .and_then(|attr| {
            attr.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                .ok()
        })
        .map(|value| value.into_owned())
}

/// 读取当前元素到其闭合标签之间的全部文本（含 CDATA；实体引用已还原）
///
/// 对应原版 `nextText()`；差异：原版遇到嵌套标签抛异常，这里按 quick-xml
/// 宽容度把嵌套文本一并拼入（已登记）。
fn read_element_text(reader: &mut Reader<&[u8]>) -> String {
    let mut out = String::new();
    let mut depth = 0usize;
    loop {
        match reader.read_event() {
            Ok(Event::Text(text)) => out.push_str(text.as_ref()),
            Ok(Event::CData(data)) => out.push_str(data.as_ref()),
            Ok(Event::GeneralRef(reference)) => push_reference(&mut out, &reference),
            Ok(Event::Start(_)) => depth += 1,
            Ok(Event::End(_)) => {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

/// 读取元素的**直接文本**（遇到嵌套起始标签立即返回已收集文本）
///
/// 对齐原版 `pubDate` 分支：`next()` 后仅当事件为 TEXT 才取值；嵌套标签
/// （START_TAG）视为「跳过」。返回 `None` = 未取到任何文本（字段不赋值）。
fn read_direct_text(reader: &mut Reader<&[u8]>) -> Option<String> {
    let mut out = String::new();
    let mut saw_text = false;
    loop {
        match reader.read_event() {
            Ok(Event::Text(text)) => {
                saw_text = true;
                out.push_str(text.as_ref());
            }
            Ok(Event::CData(data)) => {
                saw_text = true;
                out.push_str(data.as_ref());
            }
            Ok(Event::GeneralRef(reference)) => {
                saw_text = true;
                push_reference(&mut out, &reference);
            }
            // 嵌套元素 / 闭合 / EOF：结束本次取值
            Ok(Event::Start(_)) | Ok(Event::End(_)) | Ok(Event::Eof) | Err(_) => {
                return saw_text.then(|| out.trim().to_string());
            }
            _ => {}
        }
    }
}

/// 还原实体引用（字符引用 → 字符；预定义实体 → 替换串；未声明实体按字面保留）
fn push_reference(out: &mut String, reference: &BytesRef<'_>) {
    if let Ok(Some(ch)) = reference.resolve_char_ref() {
        out.push(ch);
    } else if let Some(replacement) = quick_xml::escape::resolve_predefined_entity(reference) {
        out.push_str(replacement);
    } else {
        // 原版 XmlPullParser 对未声明实体会抛异常；这里按字面保留避免丢文本
        out.push('&');
        out.push_str(reference);
        out.push(';');
    }
}

/// 取正文中首个 `<img ...>` 的 `src`（对齐原版 `getImageUrl`，`RssParserDefault.kt:122-136`）
///
/// 原版正则：`(<img [^>]*>)` + `src\s*=\s*"([^"]+)"` —— 大小写敏感、只认双引号、
/// `<img` 后必须有空格、src 值 trim。这里逐字保留同一口径。
fn get_image_url(input: &str) -> Option<String> {
    static IMG_TAG: OnceLock<Regex> = OnceLock::new();
    static IMG_SRC: OnceLock<Regex> = OnceLock::new();
    let tag_pattern =
        IMG_TAG.get_or_init(|| Regex::new(r"(<img [^>]*>)").expect("img 标签正则应合法"));
    let src_pattern =
        IMG_SRC.get_or_init(|| Regex::new(r#"src\s*=\s*"([^"]+)""#).expect("img src 正则应合法"));
    let tag = tag_pattern.find(input)?.as_str();
    let url = src_pattern.captures(tag)?.get(1)?.as_str().trim();
    Some(url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_rss_20() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Test Feed</title>
    <link>https://example.com</link>
    <description>A test RSS feed</description>
    <item>
      <title>Article One</title>
      <link>https://example.com/1</link>
      <description>First article</description>
      <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
      <author>author@example.com</author>
      <category>Tech</category>
      <category>Rust</category>
    </item>
    <item>
      <title>Article Two</title>
      <link>https://example.com/2</link>
      <description>Second article</description>
    </item>
  </channel>
</rss>"#;

        let feed = parse_rss(xml).unwrap();
        assert_eq!(feed.title, "Test Feed");
        assert_eq!(feed.link, "https://example.com");
        assert_eq!(feed.description, Some("A test RSS feed".to_string()));
        assert_eq!(feed.articles.len(), 2);

        let a1 = &feed.articles[0];
        assert_eq!(a1.title, "Article One");
        assert_eq!(a1.link, "https://example.com/1");
        assert_eq!(a1.description, Some("First article".to_string()));
        assert_eq!(
            a1.pub_date,
            Some("Mon, 01 Jan 2024 00:00:00 GMT".to_string())
        );
        assert_eq!(a1.author, Some("author@example.com".to_string()));
        assert_eq!(a1.categories, vec!["Tech", "Rust"]);

        let a2 = &feed.articles[1];
        assert_eq!(a2.title, "Article Two");
        assert_eq!(a2.description, Some("Second article".to_string()));
    }

    #[test]
    fn test_parse_atom() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Feed</title>
  <link href="https://example.com"/>
  <subtitle>An Atom feed</subtitle>
  <entry>
    <title>Entry One</title>
    <link href="https://example.com/e1"/>
    <summary>First entry</summary>
    <content>Full content of entry one</content>
    <published>2024-01-01T00:00:00Z</published>
    <author><name>Alice</name></author>
    <category term="News"/>
  </entry>
  <entry>
    <title>Entry Two</title>
    <link href="https://example.com/e2"/>
    <summary>Second entry</summary>
  </entry>
</feed>"#;

        let feed = parse_atom(xml).unwrap();
        assert_eq!(feed.title, "Atom Feed");
        assert_eq!(feed.link, "https://example.com");
        assert_eq!(feed.description, Some("An Atom feed".to_string()));
        assert_eq!(feed.articles.len(), 2);

        let e1 = &feed.articles[0];
        assert_eq!(e1.title, "Entry One");
        assert_eq!(e1.link, "https://example.com/e1");
        assert_eq!(e1.description, Some("First entry".to_string()));
        assert_eq!(e1.content, Some("Full content of entry one".to_string()));
        assert_eq!(e1.pub_date, Some("2024-01-01T00:00:00Z".to_string()));
        assert_eq!(e1.author, Some("Alice".to_string()));
        assert_eq!(e1.categories, vec!["News"]);
    }

    #[test]
    fn test_parse_feed_auto_detect_rss() {
        let xml = r#"<rss version="2.0"><channel><title>T</title><link>L</link></channel></rss>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.title, "T");
    }

    #[test]
    fn test_parse_feed_auto_detect_atom() {
        let xml =
            r#"<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title><link href="L"/></feed>"#;
        let feed = parse_feed(xml).unwrap();
        assert_eq!(feed.title, "A");
    }

    #[test]
    fn test_parse_rss_with_enclosure() {
        let xml = r#"<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Feed</title>
    <link>https://example.com</link>
    <item>
      <title>With Image</title>
      <link>https://example.com/img</link>
      <enclosure url="https://example.com/image.jpg" type="image/jpeg" length="12345"/>
    </item>
  </channel>
</rss>"#;
        let feed = parse_rss(xml).unwrap();
        assert_eq!(
            feed.articles[0].image_url,
            Some("https://example.com/image.jpg".to_string())
        );
    }

    #[test]
    fn test_parse_rss_cdata() {
        let xml = r#"<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>Feed</title>
    <link>https://example.com</link>
    <item>
      <title>CDATA Article</title>
      <link>https://example.com/cdata</link>
      <description><![CDATA[<p>HTML content</p>]]></description>
    </item>
  </channel>
</rss>"#;
        let feed = parse_rss(xml).unwrap();
        assert_eq!(
            feed.articles[0].description,
            Some("<p>HTML content</p>".to_string())
        );
    }

    #[test]
    fn test_parse_empty_feed() {
        let xml = r#"<rss version="2.0"><channel><title>Empty</title><link>http://x</link></channel></rss>"#;
        let feed = parse_rss(xml).unwrap();
        assert_eq!(feed.articles.len(), 0);
    }

    #[test]
    fn test_parse_invalid_xml() {
        let xml = r#"<not valid xml at all"#;
        let result = parse_rss(xml);
        assert!(
            result.is_err(),
            "完全非法的 XML 应报解析错误，不得返回 Ok: {result:?}"
        );
    }

    #[test]
    fn test_rss_article_serde() {
        let article = RssArticle {
            title: "Test".to_string(),
            link: "https://example.com".to_string(),
            description: Some("desc".to_string()),
            pub_date: None,
            author: None,
            image_url: None,
            content: None,
            categories: vec!["cat".to_string()],
        };
        let json = serde_json::to_string(&article).unwrap();
        let de: RssArticle = serde_json::from_str(&json).unwrap();
        assert_eq!(de.title, "Test");
        assert_eq!(de.categories, vec!["cat"]);
    }

    #[test]
    fn test_rss_feed_serde() {
        let feed = RssFeed {
            title: "F".to_string(),
            link: "L".to_string(),
            description: None,
            articles: vec![],
        };
        let json = serde_json::to_string(&feed).unwrap();
        let de: RssFeed = serde_json::from_str(&json).unwrap();
        assert_eq!(de.title, "F");
    }
}
