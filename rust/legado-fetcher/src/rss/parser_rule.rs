//! RSS 规则列表解析（批15b）
//!
//! 逐行对齐原版 `RssParserByRule.parseXML`（`RssParserByRule.kt:22-140`）：
//!
//! ```text
//! ruleArticles 空/空白 → RssParserDefault 默认解析（15a）
//! 否则：
//!   AnalyzeRule(ruleData, rssSource).setContent(body)
//!     .setBaseUrl(sortUrl).setRedirectUrl(redirectUrl)
//!   首字符 '-' → reverse
//!   collections = getElements(ruleArticles)
//!   ruleNextPage 非空：
//!     uppercase == "PAGE" → nextUrl = sortUrl
//!     否则 getString → 非空时按 sortUrl 绝对化
//!   variable = ruleData.getVariable()（列表级 @put 导出）
//!   逐元素 getItem → title / pubDate / description / image / link 全部求值
//!                    → title 空白丢弃（求值顺序与丢弃时点对齐原版）
//!                    / description 空规则→null、非空规则无匹配→空串
//!                    / image 按 sourceUrl 绝对化 / link isUrl 空回退 sortUrl
//!                    / type 复制源 type / sort+origin 回填
//!   reverse → 列表反转
//! ```
//!
//! ## 与原版的等价说明
//!
//! - `splitSourceRule` 按 `SourceRule` 预编译；本实现把同一规则字符串逐次
//!   交给 [`crate::web_book::eval_rule_string`]（支持 `##` 替换与 JS 链），
//!   语义对齐 `AnalyzeRule.getString(rule: String?)`；
//! - `AnalyzeRule(ruleData, rssSource)` 的 `source` / `java` / jsLib 绑定由
//!   [`crate::source_setup::rss_source_js_setup_script`] + jsLib 注入；
//! - `getString(ruleLink, isUrl = true)` 空值回退 `baseUrl`（= `sortUrl`）、
//!   非空按 `redirectUrl`（重定向后最终 URL）绝对化——本实现直接复用
//!   [`legado_parser::AnalyzeRule::get_string_ex`]（同口径）。

use legado_core::models::RssSource;
use legado_core::LegadoResult;
use legado_parser::AnalyzeUrl;

use crate::js_adapter::{construct_analyzer_with_source_context, sanitize_js_lib_for_quickjs};
use crate::web_book::eval_rule_string;

use super::default_parser::parse_default_list;
use super::models::{RssArticleItem, RssListPage};

/// 规则列表解析（`ruleArticles` 空/空白自动回退默认解析）
pub fn parse_rule_list(
    source: &RssSource,
    sort_name: &str,
    sort_url: &str,
    redirect_url: &str,
    body: &str,
    setup_script: Option<String>,
) -> LegadoResult<RssListPage> {
    let rule_articles = source.rule_articles.as_deref().unwrap_or("");
    // [RssParserByRule.kt:32-41] ruleArticles 空/空白 → 默认解析
    if rule_articles.trim().is_empty() {
        return Ok(parse_default_list(sort_name, body, &source.source_url));
    }

    let js_lib = source.js_lib.as_deref().map(sanitize_js_lib_for_quickjs);
    let body_src_json = serde_json::to_string(body).unwrap_or_default();
    let mut analyzer = construct_analyzer_with_source_context(
        body.to_string(),
        sort_url.to_string(),
        &source.source_url,
        js_lib.as_deref(),
        setup_script.clone(),
    )
    .with_js_binding("src", &body_src_json);
    // [RssParserByRule.kt:52-54] setBaseUrl(sortUrl) + setRedirectUrl(redirectUrl)
    analyzer.set_redirect_url(redirect_url);

    let mut rule_articles_owned = rule_articles.to_string();
    let reverse = rule_articles_owned.starts_with('-');
    if reverse {
        rule_articles_owned = rule_articles_owned[1..].to_string();
    }

    let collections = analyzer.get_elements(&rule_articles_owned)?;

    // [RssParserByRule.kt:62-74] ruleNextPage 求值
    let mut next_url: Option<String> = None;
    if let Some(rule_next_page) = source
        .rule_next_page
        .as_deref()
        .filter(|rule| !rule.is_empty())
    {
        if rule_next_page.to_uppercase() == "PAGE" {
            // 对齐原版 `uppercase() == "PAGE"`：不 trim，整串比较
            next_url = Some(sort_url.to_string());
        } else {
            let raw = eval_rule_string(&analyzer, rule_next_page).unwrap_or_default();
            if !raw.is_empty() {
                next_url = Some(AnalyzeUrl::get_absolute_url(sort_url, &raw));
            }
        }
    }
    // [RssParserByRule.kt:75-82] 列表级规则变量（@put 导出）
    let variable = analyzer.export_variables_json();

    let rule_title = source.rule_title.as_deref().unwrap_or("");
    let rule_pub_date = source.rule_pub_date.as_deref().unwrap_or("");
    let rule_description = source.rule_description.as_deref().unwrap_or("");
    let rule_image = source.rule_image.as_deref().unwrap_or("");
    let rule_link = source.rule_link.as_deref().unwrap_or("");

    let mut items = Vec::with_capacity(collections.len());
    for element in &collections {
        if let Some(item) = parse_item(
            source,
            sort_name,
            sort_url,
            redirect_url,
            element,
            js_lib.as_deref(),
            setup_script.clone(),
            variable.clone(),
            rule_title,
            rule_pub_date,
            rule_description,
            rule_image,
            rule_link,
        )? {
            items.push(item);
        }
    }

    if reverse {
        items.reverse();
    }

    Ok(RssListPage { items, next_url })
}

/// 单元素字段提取（对齐 `RssParserByRule.getItem`，`RssParserByRule.kt:95-140`）
#[allow(clippy::too_many_arguments)]
fn parse_item(
    source: &RssSource,
    sort_name: &str,
    sort_url: &str,
    redirect_url: &str,
    element: &str,
    js_lib: Option<&str>,
    setup_script: Option<String>,
    variable: Option<String>,
    rule_title: &str,
    rule_pub_date: &str,
    rule_description: &str,
    rule_image: &str,
    rule_link: &str,
) -> LegadoResult<Option<RssArticleItem>> {
    let mut item_analyzer = construct_analyzer_with_source_context(
        element.to_string(),
        sort_url.to_string(),
        &source.source_url,
        js_lib,
        setup_script,
    );
    item_analyzer.set_redirect_url(redirect_url);
    // JSON 列表元素按对象注入 result（对齐原版 getElements 返回 Map）
    item_analyzer.set_element_content(element.to_string());
    // 对齐原版 `RssArticle(variable = 列表级变量)` + `setRuleData(rssArticle)`：
    // 子规则 `@get:{k}` 可读取列表级 `@put` 导出的变量
    if let Some(variable_json) = variable.as_deref() {
        item_analyzer.seed_variables_json(variable_json);
    }
    // 原版 `bindings["rssArticle"] = rssArticle`（AnalyzeRule.kt:906）：列表
    // 元素求值时注入文章基线对象（origin/sort/variable）；「已求值字段逐步
    // 可见」不逐字段复刻（content.rs 模块文档已登记差异）。
    let article_seed = serde_json::json!({
        "origin": source.source_url,
        "sort": sort_name,
        "variable": variable,
    });
    item_analyzer.add_js_binding("rssArticle", &article_seed.to_string());

    // 字段求值顺序逐行对齐原版 `RssParserByRule.getItem`（`RssParserByRule.kt:95-140`）：
    // title → pubDate → description → image → link，**全部求值后**才做
    // `title.isBlank()` 丢弃（P2-1）。保持该顺序的原因：每条子规则都可能带
    // `@put:` 副作用（写入文章级变量），提前丢弃会跳过空标题条目的
    // `@put` 与后续规则；子规则异常按原版语义上抛（getString 不吞错），
    // 由调用方把整次列表刷新判为失败。
    let title = eval_rule_string(&item_analyzer, rule_title)?;
    let pub_date = eval_rule_string(&item_analyzer, rule_pub_date)?;
    // [RssParserByRule.kt:110-116] 描述：规则为空 → null；规则非空则直接取
    // `getString` 结果（无匹配 → 空串而非 null，P2-2）
    let description = if rule_description.is_empty() {
        None
    } else {
        Some(eval_rule_string(&item_analyzer, rule_description)?)
    };
    // [RssParserByRule.kt:117-125] 图片按 sourceUrl 绝对化；原版此处
    // try/catch 静默忽略异常，本实现保持同口径（唯一吞错的字段）
    let image = match eval_rule_string(&item_analyzer, rule_image) {
        Ok(value) if !value.is_empty() => {
            Some(AnalyzeUrl::get_absolute_url(&source.source_url, &value))
        }
        _ => None,
    };
    // [RssParserByRule.kt:126-128] isUrl=true：空值回退 sortUrl，非空按
    // redirectUrl 绝对化；unescape=true 对齐 `AnalyzeRule.getString` 默认重载（P2-3）
    let link = item_analyzer.get_string_ex(rule_link, true, true)?;
    // [RssParserByRule.kt:131-133] 全部字段求值完成后，标题空白 → 丢弃整条
    if title.trim().is_empty() {
        return Ok(None);
    }

    Ok(Some(RssArticleItem {
        title,
        link,
        description,
        pub_date: Some(pub_date),
        image,
        content: None,
        origin: source.source_url.clone(),
        sort: sort_name.to_string(),
        article_type: source.rss_type,
        variable,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 含三条元素（第三条标题空白）的 HTML 列表页
    const HTML_BODY: &str = r#"<html><body>
<div class="item"><h2 class="title">标题A</h2><span class="time">2024-01-01</span>
  <a class="link" href="/a">A</a><img class="img" src="/coverA.jpg"><p class="desc">描述A</p></div>
<div class="item"><h2 class="title">标题B</h2><span class="time">2024-01-02</span>
  <a class="link" href="https://other.example.com/b">B</a><p class="desc">描述B</p></div>
<div class="item"><h2 class="title">   </h2><a class="link" href="/c">C</a><p class="desc">描述C</p></div>
</body></html>"#;

    fn html_source() -> RssSource {
        RssSource {
            source_url: "https://origin.example.com/feed".to_string(),
            rule_articles: Some(".item".to_string()),
            rule_title: Some(".title".to_string()),
            rule_pub_date: Some(".time".to_string()),
            rule_description: Some(".desc".to_string()),
            rule_image: Some(".img@src".to_string()),
            rule_link: Some(".link@href".to_string()),
            rss_type: 2,
            ..RssSource::default()
        }
    }

    /// CSS 列表：字段映射、空标题丢弃、image 按 sourceUrl 绝对化、
    /// link 按 redirectUrl 绝对化、type/sort/origin 回填
    #[test]
    fn css_list_maps_fields_and_drops_blank_title() {
        let source = html_source();
        let page = parse_rule_list(
            &source,
            "科技",
            "https://feed.example.com/list",
            "https://feed.example.com/post/1",
            HTML_BODY,
            None,
        )
        .expect("CSS 列表解析");

        assert_eq!(page.items.len(), 2, "空标题条目应被丢弃: {:#?}", page.items);
        let first = &page.items[0];
        assert_eq!(first.title, "标题A");
        assert_eq!(first.pub_date.as_deref(), Some("2024-01-01"));
        assert_eq!(first.description.as_deref(), Some("描述A"));
        assert_eq!(
            first.image.as_deref(),
            Some("https://origin.example.com/coverA.jpg"),
            "image 以 sourceUrl 为基准绝对化"
        );
        assert_eq!(
            first.link, "https://feed.example.com/a",
            "相对 link 以 redirectUrl 为基准绝对化"
        );
        assert_eq!(first.origin, "https://origin.example.com/feed");
        assert_eq!(first.sort, "科技");
        assert_eq!(first.article_type, 2, "type 复制源 type");
        assert_eq!(first.variable, None, "无 @put 时 variable 为 None");
        assert_eq!(page.next_url, None, "未配置 ruleNextPage");
        // 绝对链接原样保留
        assert_eq!(page.items[1].link, "https://other.example.com/b");
    }

    /// `-` 前缀反转列表
    #[test]
    fn leading_dash_reverses_order() {
        let mut source = html_source();
        source.rule_articles = Some("-.item".to_string());
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            HTML_BODY,
            None,
        )
        .expect("反转列表解析");
        assert_eq!(
            page.items
                .iter()
                .map(|i| i.title.as_str())
                .collect::<Vec<_>>(),
            vec!["标题B", "标题A"]
        );
    }

    /// XPath 列表 + 子规则
    #[test]
    fn xpath_list_parses_items() {
        let mut source = html_source();
        source.rule_articles = Some("//div[@class='item']".to_string());
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            HTML_BODY,
            None,
        )
        .expect("XPath 列表解析");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "标题A");
        assert_eq!(page.items[0].link, "https://feed.example.com/a");
    }

    /// JsonPath 列表 + 子规则
    #[test]
    fn jsonpath_list_parses_items() {
        let body = r#"{"items":[{"title":"J1","url":"/j1"},{"title":"J2","url":"https://h/j2"}]}"#;
        let source = RssSource {
            source_url: "https://origin.example.com/feed".to_string(),
            rule_articles: Some("$.items[*]".to_string()),
            rule_title: Some("$.title".to_string()),
            rule_link: Some("$.url".to_string()),
            rule_pub_date: Some("$.date".to_string()),
            ..RssSource::default()
        };
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect("JsonPath 列表解析");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].title, "J1");
        assert_eq!(page.items[0].link, "https://feed.example.com/j1");
        assert_eq!(
            page.items[0].pub_date.as_deref(),
            Some(""),
            "pubDate 原样（缺字段 → 空串）"
        );
        assert_eq!(page.items[1].link, "https://h/j2");
    }

    /// JS 列表（`@js:` 与 `<js>` 两种写法）
    #[cfg(feature = "quickjs")]
    #[test]
    fn js_list_parses_items() {
        let js_array =
            r#"JSON.stringify([{"title":"JS1","url":"/js1"},{"title":"JS2","url":"/js2"}])"#;
        for rule in [format!("@js:{js_array}"), format!("<js>{js_array}</js>")] {
            let source = RssSource {
                source_url: "https://origin.example.com/feed".to_string(),
                rule_articles: Some(rule.clone()),
                rule_title: Some("$.title".to_string()),
                rule_link: Some("$.url".to_string()),
                ..RssSource::default()
            };
            let page = parse_rule_list(
                &source,
                "",
                "https://feed.example.com/list",
                "https://feed.example.com/list",
                "<html></html>",
                None,
            )
            .unwrap_or_else(|e| panic!("JS 列表解析失败（{rule}）: {e}"));
            assert_eq!(
                page.items
                    .iter()
                    .map(|i| i.title.as_str())
                    .collect::<Vec<_>>(),
                vec!["JS1", "JS2"],
                "规则：{rule}"
            );
            assert_eq!(page.items[0].link, "https://feed.example.com/js1");
        }
    }

    /// ruleNextPage：空 / PAGE（大小写不敏感）/ 相对 / 绝对
    #[test]
    fn next_page_variants() {
        let mut source = html_source();
        // 空规则 → None
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            HTML_BODY,
            None,
        )
        .unwrap();
        assert_eq!(page.next_url, None);

        // PAGE（大小写不敏感）→ nextUrl = sortUrl
        for rule in ["PAGE", "page", "PaGe"] {
            source.rule_next_page = Some(rule.to_string());
            let page = parse_rule_list(
                &source,
                "",
                "https://feed.example.com/list",
                "https://feed.example.com/list",
                HTML_BODY,
                None,
            )
            .unwrap();
            assert_eq!(
                page.next_url.as_deref(),
                Some("https://feed.example.com/list"),
                "规则：{rule}"
            );
        }

        // 相对路径 → 按 sortUrl 绝对化
        source.rule_next_page = Some(".next@href".to_string());
        let body = r#"<html><body>
<div class="item"><h2 class="title">A</h2><a class="link" href="/a">A</a></div>
<a class="next" href="/list?page=2">下一页</a>
</body></html>"#;
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .unwrap();
        assert_eq!(
            page.next_url.as_deref(),
            Some("https://feed.example.com/list?page=2")
        );

        // 绝对路径原样
        source.rule_next_page = Some(".next@href".to_string());
        let body = r#"<html><body>
<div class="item"><h2 class="title">A</h2><a class="link" href="/a">A</a></div>
<a class="next" href="https://feed.example.com/abs?p=3">下一页</a>
</body></html>"#;
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .unwrap();
        assert_eq!(
            page.next_url.as_deref(),
            Some("https://feed.example.com/abs?p=3")
        );
    }

    /// 列表级 `@put` 变量导出到每篇文章的 variable
    #[test]
    fn list_level_put_variable_is_exported() {
        let mut source = html_source();
        source.rule_articles = Some(".item@put:{token:.title@text}".to_string());
        // 子规则 @get 读取列表级 @put（对齐原版 setRuleData(rssArticle)）
        source.rule_pub_date = Some("@get:{token}".to_string());
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            HTML_BODY,
            None,
        )
        .expect("带 @put 的列表解析");
        assert_eq!(page.items.len(), 2);
        let variable = page.items[0].variable.as_deref().unwrap_or_default();
        assert!(
            variable.contains("token") && variable.contains("标题A"),
            "variable 应导出列表级 @put: {variable}"
        );
        assert_eq!(page.items[0].variable, page.items[1].variable);
        assert_eq!(
            page.items[0].pub_date.as_deref(),
            Some("标题A\n标题B"),
            "子规则 @get 应读到列表级变量（@put 值按整页规则聚合）"
        );
    }

    /// P2-1：空标题条目的后续字段规则仍执行（`title.isBlank()` 判定移到
    /// 全部字段求值之后）。`ruleLink` 的 JS 抛错会让整次解析失败——若仍按
    /// 旧顺序提前丢弃，本用例会错误地返回 `Ok`。
    #[cfg(feature = "quickjs")]
    #[test]
    fn blank_title_still_evaluates_later_rules() {
        let mut source = html_source();
        source.rule_link = Some("@js:throw new Error('link 规则失败')".to_string());
        let body = r#"<html><body>
<div class="item"><h2 class="title">   </h2><a class="link" href="/c">C</a></div>
</body></html>"#;
        let err = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect_err("空标题条目的 link 规则仍应求值（异常按原版上抛）");
        assert!(
            format!("{err}").contains("link 规则失败"),
            "错误应来自 link 规则: {err}"
        );
    }

    /// P2-1：条目级 `@put` 在后续字段规则可读（title → pubDate 顺序），
    /// 且各条目的变量互相隔离、不写入列表级 variable
    #[test]
    fn item_put_side_effects_are_scoped_to_item() {
        let mut source = html_source();
        source.rule_title = Some(".title@put:{probe:.title}".to_string());
        source.rule_pub_date = Some("@get:{probe}".to_string());
        source.rule_description = None;
        let body = r#"<html><body>
<div class="item"><h2 class="title">标题A</h2><a class="link" href="/a">A</a></div>
<div class="item"><h2 class="title">   </h2><a class="link" href="/blank">B</a></div>
<div class="item"><h2 class="title">标题C</h2><a class="link" href="/c">C</a></div>
</body></html>"#;
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect("条目级 @put 解析");
        assert_eq!(
            page.items
                .iter()
                .map(|i| i.title.as_str())
                .collect::<Vec<_>>(),
            vec!["标题A", "标题C"],
            "空标题条目仍被丢弃"
        );
        assert_eq!(
            page.items[0].pub_date.as_deref(),
            Some("标题A"),
            "后续字段规则应读到本条目的 @put"
        );
        assert_eq!(
            page.items[1].pub_date.as_deref(),
            Some("标题C"),
            "条目变量按元素隔离（空标题条目的 @put 不泄漏）"
        );
        assert_eq!(
            page.items[0].variable, None,
            "条目级 @put 不写入列表级 variable"
        );
    }

    /// P2-2：`description` 规则非空但无匹配 → `Some("")`（对齐原版
    /// `getString` 返回空串）；规则为空 → `None`
    #[test]
    fn description_empty_rule_versus_empty_match() {
        let body = r#"<html><body>
<div class="item"><h2 class="title">A</h2><a class="link" href="/a">A</a></div>
</body></html>"#;
        let mut source = html_source();
        source.rule_description = Some(".missing".to_string());
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect("规则非空解析");
        assert_eq!(
            page.items[0].description.as_deref(),
            Some(""),
            "规则非空但无匹配 → 空串（不是 None）"
        );

        let mut source = html_source();
        source.rule_description = None;
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect("规则为空解析");
        assert_eq!(page.items[0].description, None, "规则为空 → null");
    }

    /// P2-3：`link` 走 `get_string_ex(..., is_url=true, unescape=true)`，
    /// HTML 实体反转义与 `AnalyzeRule.getString` 默认重载一致
    #[test]
    fn link_is_unescaped() {
        let body = r#"{"items":[{"title":"A","url":"/a?x=1&amp;y=2"}]}"#;
        let source = RssSource {
            source_url: "https://origin.example.com/feed".to_string(),
            rule_articles: Some("$.items[*]".to_string()),
            rule_title: Some("$.title".to_string()),
            rule_link: Some("$.url".to_string()),
            ..RssSource::default()
        };
        let page = parse_rule_list(
            &source,
            "",
            "https://feed.example.com/list",
            "https://feed.example.com/list",
            body,
            None,
        )
        .expect("JSON 列表解析");
        assert_eq!(
            page.items[0].link, "https://feed.example.com/a?x=1&y=2",
            "link 应做 HTML4 反转义"
        );
    }

    /// ruleArticles 空/空白 → 默认解析（走 15a 路径，不构造规则解析器）
    #[test]
    fn blank_rule_articles_falls_back_to_default() {
        let body = r#"<rss version="2.0"><channel>
<item><title>默认A</title><link>https://feed.example.com/1</link></item>
</channel></rss>"#;
        for rule in [None, Some(""), Some("   ")] {
            let source = RssSource {
                source_url: "https://feed.example.com".to_string(),
                rule_articles: rule.map(str::to_string),
                ..RssSource::default()
            };
            let page = parse_rule_list(
                &source,
                "默认",
                "https://feed.example.com",
                "https://feed.example.com",
                body,
                None,
            )
            .unwrap();
            assert_eq!(page.items.len(), 1, "rule={rule:?}");
            assert_eq!(page.items[0].title, "默认A");
            assert_eq!(page.items[0].sort, "默认");
        }
    }
}
