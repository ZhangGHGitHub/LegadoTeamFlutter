//! RSS 默认解析等价性测试（批15a）
//!
//! 对照基准（Android 原版）：
//! - `RssParserDefault.kt:36-136` —— 默认列表解析（只认 `<item>`）；
//! - `RssParserByRule.kt:32-41` —— `ruleArticles` 空/空白 → 走默认解析；
//! - `Rss.kt:39-84` —— 列表请求编排（`AnalyzeUrl` + 默认解析 → list + null）。
//!
//! 主体为**表驱动 fixture**（[`field_cases`]）：RSS2 全字段 / RDF /
//! `media:thumbnail` / `enclosure`（image 与非 image）/ `description`、
//! `content:encoded` 首图 / `pubDate` 嵌套 / `time` / 空 link / CDATA /
//! 空 feed / 畸形 XML / Atom 回退（已登记超集）。
//! 另有专项用例覆盖图片优先级、大小写、实体与映射透传。

use legado_fetcher::rss::default_parser::parse_default_list;
use legado_net::rss::{parse_default_items, DefaultFeedItem};

/// 固定分类名与源 URL（断言 origin / sort 透传）
const SORT: &str = "科技";
const SOURCE: &str = "https://src.example.com/feed";

fn parse(xml: &str) -> Vec<DefaultFeedItem> {
    parse_default_items(SORT, xml, SOURCE)
}

/// 表驱动用例：`expected_items == 0` 时只校验条数，其余字段忽略
struct FieldCase {
    name: &'static str,
    xml: &'static str,
    expected_items: usize,
    title: &'static str,
    link: &'static str,
    image: Option<&'static str>,
    description: Option<&'static str>,
    content: Option<&'static str>,
    pub_date: Option<&'static str>,
}

/// 表驱动 fixture 集（字段口径逐条对应原版 `RssParserDefault.kt`）
fn field_cases() -> Vec<FieldCase> {
    vec![
        FieldCase {
            name: "RSS2 全字段",
            xml: r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"
     xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>频道标题（不应进入任何文章字段）</title>
    <link>https://src.example.com/</link>
    <item>
      <title>  第一篇标题  </title>
      <link>  https://src.example.com/a1  </link>
      <description>  描述一  </description>
      <content:encoded>  正文一  </content:encoded>
      <pubDate>  Mon, 01 Jan 2024 00:00:00 GMT  </pubDate>
      <media:thumbnail url="https://img.example.com/cover.jpg" />
    </item>
  </channel>
</rss>"#,
            expected_items: 1,
            title: "第一篇标题",
            link: "https://src.example.com/a1",
            image: Some("https://img.example.com/cover.jpg"),
            description: Some("描述一"),
            content: Some("正文一"),
            pub_date: Some("Mon, 01 Jan 2024 00:00:00 GMT"),
        },
        FieldCase {
            name: "RDF（RSS 1.0）",
            xml: r#"<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
         xmlns="http://purl.org/rss/1.0/">
  <channel rdf:about="https://src.example.com/">
    <title>RDF 频道</title>
  </channel>
  <item rdf:about="https://src.example.com/r1">
    <title>RDF 文章</title>
    <link>https://src.example.com/r1</link>
    <description>RDF 描述</description>
    <pubDate>Tue, 02 Jan 2024 01:02:03 GMT</pubDate>
  </item>
</rdf:RDF>"#,
            expected_items: 1,
            title: "RDF 文章",
            link: "https://src.example.com/r1",
            image: None,
            description: Some("RDF 描述"),
            content: None,
            pub_date: Some("Tue, 02 Jan 2024 01:02:03 GMT"),
        },
        FieldCase {
            name: "media:thumbnail 封面",
            xml: r#"<rss><channel><item xmlns:media="http://search.yahoo.com/mrss/">
  <title>缩略图</title>
  <media:thumbnail url="https://img.example.com/t.jpg"/>
</item></channel></rss>"#,
            expected_items: 1,
            title: "缩略图",
            link: "",
            image: Some("https://img.example.com/t.jpg"),
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "enclosure image/* 作为封面",
            xml: r#"<rss><channel><item>
  <title>图片附件</title>
  <enclosure url="https://img.example.com/e.jpg" type="image/jpeg" length="100"/>
</item></channel></rss>"#,
            expected_items: 1,
            title: "图片附件",
            link: "",
            image: Some("https://img.example.com/e.jpg"),
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "enclosure 非 image 类型不取封面",
            xml: r#"<rss><channel><item>
  <title>音频附件</title>
  <enclosure url="https://cdn.example.com/e.mp3" type="audio/mpeg"/>
</item></channel></rss>"#,
            expected_items: 1,
            title: "音频附件",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "description 首个 img 作为封面",
            xml: r#"<rss><channel><item>
  <title>描述首图</title>
  <description><![CDATA[<p>前文</p><img src="https://img.example.com/d1.jpg" /><img src="https://img.example.com/d2.jpg" />]]></description>
</item></channel></rss>"#,
            expected_items: 1,
            title: "描述首图",
            link: "",
            image: Some("https://img.example.com/d1.jpg"),
            description: Some(
                "<p>前文</p><img src=\"https://img.example.com/d1.jpg\" /><img src=\"https://img.example.com/d2.jpg\" />",
            ),
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "content:encoded 首个 img 作为封面",
            xml: r#"<rss><channel><item>
  <title>正文首图</title>
  <content:encoded><![CDATA[<div><img src="https://img.example.com/c1.jpg"></div>]]></content:encoded>
</item></channel></rss>"#,
            expected_items: 1,
            title: "正文首图",
            link: "",
            image: Some("https://img.example.com/c1.jpg"),
            description: None,
            content: Some("<div><img src=\"https://img.example.com/c1.jpg\"></div>"),
            pub_date: None,
        },
        FieldCase {
            name: "pubDate 嵌套标签不取值",
            xml: r#"<rss><channel><item>
  <title>嵌套日期</title>
  <pubDate><span>Mon, 01 Jan 2024 00:00:00 GMT</span></pubDate>
</item></channel></rss>"#,
            expected_items: 1,
            title: "嵌套日期",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "time 覆盖 pubDate",
            xml: r#"<rss><channel><item>
  <title>时间覆盖</title>
  <pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
  <time>2024-01-02</time>
</item></channel></rss>"#,
            expected_items: 1,
            title: "时间覆盖",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: Some("2024-01-02"),
        },
        FieldCase {
            name: "空 link 原样保留",
            xml: r#"<rss><channel><item><title>无链接</title></item></channel></rss>"#,
            expected_items: 1,
            title: "无链接",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "CDATA 文本",
            xml: r#"<rss><channel><item>
  <title><![CDATA[CDATA 标题]]></title>
  <description><![CDATA[<p>CDATA 描述</p>]]></description>
  <content:encoded><![CDATA[<p>CDATA 正文</p>]]></content:encoded>
</item></channel></rss>"#,
            expected_items: 1,
            title: "CDATA 标题",
            link: "",
            image: None,
            description: Some("<p>CDATA 描述</p>"),
            content: Some("<p>CDATA 正文</p>"),
            pub_date: None,
        },
        FieldCase {
            name: "空 feed",
            xml: r#"<rss version="2.0"><channel><title>空频道</title>
<link>https://src.example.com/</link></channel></rss>"#,
            expected_items: 0,
            title: "",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "畸形 XML：未闭合 item",
            // quick-xml 在 Eof 处不补闭合 → 不收集（原版会抛异常）
            xml: r#"<rss><channel><item><title>截断</title>"#,
            expected_items: 0,
            title: "",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "畸形 XML：缺根闭合但 item 完整",
            // quick-xml 宽容度：item 已收尾 → 照常收集
            xml: r#"<rss><channel><item><title>缺根闭合</title></item></channel>"#,
            expected_items: 1,
            title: "缺根闭合",
            link: "",
            image: None,
            description: None,
            content: None,
            pub_date: None,
        },
        FieldCase {
            name: "Atom 回退（已登记超集）",
            xml: r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom 源</title>
  <link href="https://src.example.com/"/>
  <entry>
    <title>Atom 文章</title>
    <link href="https://src.example.com/atom/1"/>
    <summary>Atom 摘要</summary>
    <content>Atom 正文</content>
    <published>2024-01-01T00:00:00Z</published>
  </entry>
</feed>"#,
            expected_items: 1,
            title: "Atom 文章",
            link: "https://src.example.com/atom/1",
            image: None,
            description: Some("Atom 摘要"),
            content: Some("Atom 正文"),
            pub_date: Some("2024-01-01T00:00:00Z"),
        },
    ]
}

/// 表驱动主用例：逐条校验条数与首篇字段 + origin/sort
#[test]
fn default_parse_field_matrix() {
    for case in field_cases() {
        let items = parse(case.xml);
        assert_eq!(
            items.len(),
            case.expected_items,
            "用例「{}」条数不符: {items:#?}",
            case.name
        );
        if case.expected_items == 0 {
            continue;
        }
        let item = &items[0];
        assert_eq!(item.title, case.title, "用例「{}」title", case.name);
        assert_eq!(item.link, case.link, "用例「{}」link", case.name);
        assert_eq!(
            item.image.as_deref(),
            case.image,
            "用例「{}」image",
            case.name
        );
        assert_eq!(
            item.description.as_deref(),
            case.description,
            "用例「{}」description",
            case.name
        );
        assert_eq!(
            item.content.as_deref(),
            case.content,
            "用例「{}」content",
            case.name
        );
        assert_eq!(
            item.pub_date.as_deref(),
            case.pub_date,
            "用例「{}」pub_date",
            case.name
        );
        // 收尾字段对齐原版 `</item>` 分支
        assert_eq!(item.origin, SOURCE, "用例「{}」origin", case.name);
        assert_eq!(item.sort, SORT, "用例「{}」sort", case.name);
    }
}

/// 原版取图正则大小写敏感且只认双引号：单引号 / 大写标签不取
#[test]
fn img_extraction_matches_original_regex_scope() {
    let single_quote = parse(
        r#"<rss><channel><item><title>单引号</title>
        <description><![CDATA[<img src='https://img.example.com/sq.jpg'>]]></description>
        </item></channel></rss>"#,
    );
    assert_eq!(single_quote[0].image, None, "原版正则只认双引号");

    let uppercase = parse(
        r#"<rss><channel><item><title>大写</title>
        <description><![CDATA[<IMG SRC="https://img.example.com/up.jpg">]]></description>
        </item></channel></rss>"#,
    );
    assert_eq!(uppercase[0].image, None, "原版正则大小写敏感");
}

/// 图片优先级按文档顺序（原版按元素出现顺序赋值，后到者覆盖）
#[test]
fn image_precedence_follows_document_order() {
    // media:thumbnail 在 description 之后 → 覆盖 description 的图
    let thumbnail_last = parse(
        r#"<rss><channel><item xmlns:media="http://search.yahoo.com/mrss/">
  <title>后置封面</title>
  <description><![CDATA[<img src="https://img.example.com/desc.jpg">]]></description>
  <media:thumbnail url="https://img.example.com/thumb.jpg"/>
</item></channel></rss>"#,
    );
    assert_eq!(
        thumbnail_last[0].image.as_deref(),
        Some("https://img.example.com/thumb.jpg")
    );

    // media:thumbnail 在 description 之前 → description 不再覆盖（image 已非空）
    let thumbnail_first = parse(
        r#"<rss><channel><item xmlns:media="http://search.yahoo.com/mrss/">
  <title>前置封面</title>
  <media:thumbnail url="https://img.example.com/thumb.jpg"/>
  <description><![CDATA[<img src="https://img.example.com/desc.jpg">]]></description>
</item></channel></rss>"#,
    );
    assert_eq!(
        thumbnail_first[0].image.as_deref(),
        Some("https://img.example.com/thumb.jpg")
    );

    // description 先取到图后，content:encoded 不覆盖
    let description_first = parse(
        r#"<rss><channel><item>
  <title>描述优先</title>
  <description><![CDATA[<img src="https://img.example.com/desc.jpg">]]></description>
  <content:encoded><![CDATA[<img src="https://img.example.com/content.jpg">]]></content:encoded>
</item></channel></rss>"#,
    );
    assert_eq!(
        description_first[0].image.as_deref(),
        Some("https://img.example.com/desc.jpg")
    );
}

/// 无标题不过滤：原版 `</item>` 无条件收集（含 `<item/>` 空元素）
#[test]
fn items_without_title_are_kept() {
    let items = parse(
        r#"<rss><channel>
  <item><link>https://src.example.com/no-title</link></item>
  <item><title>有标题</title></item>
  <item/>
</channel></rss>"#,
    );
    assert_eq!(items.len(), 3, "空 item 也按原版收集");
    assert_eq!(items[0].title, "");
    assert_eq!(items[0].link, "https://src.example.com/no-title");
    assert_eq!(items[1].title, "有标题");
    assert_eq!(items[2].title, "");
}

/// 大小写不敏感（原版 `equals(..., true)`）：标签名识别；属性名仍敏感
#[test]
fn tag_names_case_insensitive() {
    let items = parse(
        r#"<rss><channel><ITEM xmlns:media="http://search.yahoo.com/mrss/">
  <TITLE>大写标签</TITLE>
  <LINK>https://src.example.com/case</LINK>
  <MEDIA:THUMBNAIL URL="https://img.example.com/case.jpg"/>
</ITEM></channel></rss>"#,
    );
    assert_eq!(items.len(), 1, "标签名大小写不敏感: {items:#?}");
    assert_eq!(items[0].title, "大写标签");
    assert_eq!(items[0].link, "https://src.example.com/case");
    // 属性名大小写敏感（对齐 getAttributeValue）：URL 不等于 url → 不取
    assert_eq!(items[0].image, None);
}

/// 实体引用：预定义实体还原；裸 `&`（未转义）不影响后续解析（已登记宽容度）
#[test]
fn entity_references_and_dangling_amp() {
    let items = parse(
        r#"<rss><channel><item>
  <title>Tom &amp; Jerry &lt;篇&gt;</title>
  <description>R&amp;D & 裸与号</description>
</item></channel></rss>"#,
    );
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Tom & Jerry <篇>");
    assert_eq!(items[0].description.as_deref(), Some("R&D & 裸与号"));
}

/// 畸形 XML 的其余形态（表外补充）：完全非法 / 标签错配
#[test]
fn malformed_xml_other_shapes() {
    assert!(parse("<not valid xml at all").is_empty(), "非 XML → 0 篇");
    let mismatched = parse(
        r#"<rss><channel><item><title>t</title><link>L</link></title></item></channel></rss>"#,
    );
    assert_eq!(
        mismatched.len(),
        0,
        "标签错配应在 item 收尾前中止: {mismatched:#?}"
    );
}

/// 有 item 的 `<feed>` 文档不得触发 Atom 回退（回退仅限 item 为空 + 根 feed）：
/// 同一文档同时含 `<item>` 与 `<entry>`，只收集字面 item，entry 不得进入结果
#[test]
fn atom_fallback_not_triggered_when_feed_has_item() {
    let items = parse(
        r#"<feed xmlns="http://www.w3.org/2005/Atom">
  <title>混合 feed</title>
  <item><title>字面 item</title><link>https://src.example.com/item</link></item>
  <entry><title>Atom 条目</title><link href="https://src.example.com/entry"/></entry>
</feed>"#,
    );
    assert_eq!(
        items.len(),
        1,
        "只应收集 item，不得因根为 feed 而回退 parse_atom: {items:#?}"
    );
    assert_eq!(items[0].title, "字面 item");
    assert_eq!(items[0].link, "https://src.example.com/item");
}

/// `time` 与原版一致不做 trim（原版 `nextText()` 直接赋值）
#[test]
fn time_value_is_not_trimmed() {
    let items = parse(
        r#"<rss><channel><item>
  <title>不裁剪时间</title>
  <time>  2024-01-02  </time>
</item></channel></rss>"#,
    );
    assert_eq!(
        items[0].pub_date.as_deref(),
        Some("  2024-01-02  "),
        "time 元素文本应原样保留（不 trim）"
    );
}

/// link / image 不做绝对化（原版原样保留相对路径）
#[test]
fn relative_link_and_image_are_not_absolutized() {
    let items = parse(
        r#"<rss><channel><item>
  <title>相对路径</title>
  <link>/post/1</link>
  <description><![CDATA[<img src="/img/1.jpg">]]></description>
</item></channel></rss>"#,
    );
    assert_eq!(items[0].link, "/post/1");
    assert_eq!(items[0].image.as_deref(), Some("/img/1.jpg"));
}

/// 带命名空间前缀的核心元素不识别（对齐原版 `namespaceAware = false` 的
/// 字面名规则：`xmlPullParser.name` 含前缀，不等于 `item`）
#[test]
fn namespaced_rss_core_elements_are_not_parsed() {
    let items = parse(
        r#"<rss:rss xmlns:rss="http://purl.org/rss/1.0/"><rss:channel>
  <rss:item><rss:title>前缀文章</rss:title></rss:item>
</rss:channel></rss:rss>"#,
    );
    assert!(
        items.is_empty(),
        "`<rss:item>` 不应按字面名识别: {items:#?}"
    );
}

/// 引擎映射：`DefaultFeedItem` → `RssArticleItem` 全字段透传（防复发 #3）
#[test]
fn fetcher_mapping_passes_all_fields() {
    let xml = r#"<rss><channel><item xmlns:media="http://search.yahoo.com/mrss/">
  <title>全字段</title>
  <link>https://src.example.com/full</link>
  <description><![CDATA[<img src="https://img.example.com/full.jpg">全部描述]]></description>
  <content:encoded>全部正文</content:encoded>
  <pubDate>Wed, 03 Jan 2024 00:00:00 GMT</pubDate>
  <media:thumbnail url="https://img.example.com/thumb.jpg"/>
</item></channel></rss>"#;
    let page = parse_default_list(SORT, xml, SOURCE);
    assert_eq!(page.next_url, None, "默认解析恒无下一页");
    assert_eq!(page.items.len(), 1);
    let article = &page.items[0];
    assert_eq!(article.title, "全字段");
    assert_eq!(article.link, "https://src.example.com/full");
    assert_eq!(
        article.description.as_deref(),
        Some("<img src=\"https://img.example.com/full.jpg\">全部描述")
    );
    assert_eq!(article.content.as_deref(), Some("全部正文"));
    assert_eq!(
        article.pub_date.as_deref(),
        Some("Wed, 03 Jan 2024 00:00:00 GMT")
    );
    assert_eq!(
        article.image.as_deref(),
        Some("https://img.example.com/thumb.jpg")
    );
    assert_eq!(article.origin, SOURCE);
    assert_eq!(article.sort, SORT);
    assert_eq!(article.article_type, 0, "默认解析 type 恒 0（网页）");
    assert_eq!(article.variable, None);
}

/// 多篇：origin/sort 逐篇写入，顺序与文档一致
#[test]
fn multiple_items_preserve_order() {
    let items = parse(
        r#"<rss><channel>
  <item><title>一</title></item>
  <item><title>二</title></item>
  <item><title>三</title></item>
</channel></rss>"#,
    );
    let titles: Vec<&str> = items.iter().map(|i| i.title.as_str()).collect();
    assert_eq!(titles, vec!["一", "二", "三"]);
    assert!(items.iter().all(|i| i.origin == SOURCE && i.sort == SORT));
}
