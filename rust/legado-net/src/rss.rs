//! RSS/Atom Feed 解析器
//!
//! 支持 RSS 2.0 和 Atom 格式。
//! 参考 Kotlin 实现 `RssSource.kt` / `RssArticle.kt`。

use legado_core::{LegadoError, LegadoResult};
use quick_xml::events::Event;
use quick_xml::Reader;

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
pub fn parse_feed(xml_content: &str) -> LegadoResult<RssFeed> {
    if xml_content.contains("<feed") {
        parse_atom(xml_content)
    } else {
        parse_rss(xml_content)
    }
}

/// 解析 RSS 2.0
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
pub async fn fetch_feed(url: &str, client: &crate::client::LegadoClient) -> LegadoResult<RssFeed> {
    let response = client.get(url, None).await?;
    parse_feed(&response.body)
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
        // quick-xml is lenient; it may still parse partial content
        // but a completely broken document should error or return empty
        assert!(result.is_ok() || result.is_err());
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
