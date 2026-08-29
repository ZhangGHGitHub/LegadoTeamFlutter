//! 旧版（阅读 2.x）备份数据导入映射
//!
//! 对齐 Android `io.legado.app.help.storage.ImportOldData`：
//! - `toNewRule` / `toNewUrl` / `toNewUrls` / `uaToHeader`
//! - `fromOldBooks` / `fromOldBookSource` / 旧替换规则字段兼容

use std::collections::HashMap;

use regex::Regex;
use serde_json::Value;

use crate::models::book_type;
use crate::models::rule::{BookInfoRule, ContentRule, ExploreRule, SearchRule, TocRule};
use crate::models::{book_source_type, Book, BookSource, ReadConfig, ReplaceRule};

/// 将旧版 default 规则语法迁到 3.x（#→##、|→||、&→&&，保留前缀 -/+/特殊前缀）
pub fn to_new_rule(old_rule: Option<&str>) -> Option<String> {
    let old_rule = old_rule?.trim();
    if old_rule.is_empty() {
        return None;
    }
    let mut new_rule = old_rule.to_string();
    let mut reverse = false;
    let mut allinone = false;
    if new_rule.starts_with('-') {
        reverse = true;
        new_rule = new_rule[1..].to_string();
    }
    if new_rule.starts_with('+') {
        allinone = true;
        new_rule = new_rule[1..].to_string();
    }
    let lower = new_rule.to_ascii_lowercase();
    let skip = lower.starts_with("@css:")
        || lower.starts_with("@xpath:")
        || new_rule.starts_with("//")
        || new_rule.starts_with("##")
        || new_rule.starts_with(':')
        || lower.contains("@js:")
        || lower.contains("<js>");
    if !skip {
        // 对齐原版：# 替换时用 oldRule（含可能的 -/+ 前缀）
        if new_rule.contains('#') && !new_rule.contains("##") {
            new_rule = old_rule.replace('#', "##");
        }
        if new_rule.contains('|') && !new_rule.contains("||") {
            if new_rule.contains("##") {
                let list: Vec<&str> = new_rule.split("##").collect();
                if list[0].contains('|') {
                    let mut rebuilt = list[0].replace('|', "||");
                    for item in list.iter().skip(1) {
                        rebuilt.push_str("##");
                        rebuilt.push_str(item);
                    }
                    new_rule = rebuilt;
                }
            } else {
                new_rule = new_rule.replace('|', "||");
            }
        }
        if new_rule.contains('&')
            && !new_rule.contains("&&")
            && !new_rule.contains("http")
            && !new_rule.starts_with('/')
        {
            new_rule = new_rule.replace('&', "&&");
        }
    }
    if allinone {
        new_rule = format!("+{new_rule}");
    }
    if reverse {
        new_rule = format!("-{new_rule}");
    }
    Some(new_rule)
}

/// 多行/&& 分隔的发现 URL 列表迁移；空白项丢弃（对齐 ImportOldDataTest）
pub fn to_new_urls(old_urls: Option<&str>) -> Option<String> {
    let old_urls = old_urls?.trim();
    if old_urls.is_empty() {
        return None;
    }
    let lower = old_urls.to_ascii_lowercase();
    if lower.starts_with("@js:") || lower.starts_with("<js>") {
        return Some(old_urls.to_string());
    }
    if !old_urls.contains('\n') && !old_urls.contains("&&") {
        return to_new_url(Some(old_urls));
    }
    let re = Regex::new(r"(&&|\r?\n)+").unwrap();
    let joined: String = re
        .split(old_urls)
        .filter_map(|part| {
            to_new_url(Some(part.trim())).map(|u| {
                let trim_ws = Regex::new(r"\n\s*").unwrap();
                trim_ws.replace_all(&u, "").into_owned()
            })
        })
        .collect::<Vec<_>>()
        .join("\n");
    if joined.trim().is_empty() {
        None
    } else {
        Some(joined)
    }
}

/// 单条旧版 URL（含 @Header、searchKey、|charset、@body POST）迁到 AnalyzeUrl 形态
pub fn to_new_url(old_url: Option<&str>) -> Option<String> {
    let old_url = old_url?.trim();
    if old_url.is_empty() {
        return None;
    }
    let mut url = old_url.to_string();
    if url.to_ascii_lowercase().starts_with("<js>") {
        url = url
            .replace("=searchKey", "={{key}}")
            .replace("=searchPage", "={{page}}");
        return Some(url);
    }

    let mut map: HashMap<String, Value> = HashMap::new();
    let header_re = Regex::new(r"(?i)@Header:\{.+?}").unwrap();
    if let Some(m) = header_re.find(&url) {
        let header = m.as_str().to_string();
        url = url.replacen(&header, "", 1);
        map.insert(
            "headers".to_string(),
            Value::String(header[8..].to_string()),
        );
    }

    let mut url_list: Vec<String> = url.split('|').map(|s| s.to_string()).collect();
    url = url_list.remove(0);
    if !url_list.is_empty() {
        let charset_part = &url_list[0];
        if let Some((_, v)) = charset_part.split_once('=') {
            map.insert("charset".to_string(), Value::String(v.to_string()));
        }
    }

    let js_re = Regex::new(r"\{\{.+?}}").unwrap();
    let mut js_list = Vec::new();
    while let Some(m) = js_re.find(&url) {
        let item = m.as_str().to_string();
        let idx = js_list.len();
        url = url.replacen(&item, &format!("${idx}"), 1);
        js_list.push(item);
    }

    url = url.replace('{', "<").replace('}', ">");
    url = url.replace("searchKey", "{{key}}");
    let page_angle = Regex::new(r"<searchPage([-+]1)>").unwrap();
    url = page_angle.replace_all(&url, "{{page$1}}").into_owned();
    let page_plain = Regex::new(r"searchPage([-+]1)").unwrap();
    url = page_plain.replace_all(&url, "{{page$1}}").into_owned();
    url = url.replace("searchPage", "{{page}}");

    for (index, item) in js_list.iter().enumerate() {
        let restored = item
            .replace("searchKey", "key")
            .replace("searchPage", "page");
        url = url.replace(&format!("${index}"), &restored);
    }

    let at_parts: Vec<String> = url.splitn(2, '@').map(|s| s.to_string()).collect();
    url = at_parts[0].clone();
    if at_parts.len() > 1 {
        map.insert("method".to_string(), Value::String("POST".to_string()));
        map.insert("body".to_string(), Value::String(at_parts[1].clone()));
    }

    if !map.is_empty() {
        let json = serde_json::to_string(&map).unwrap_or_else(|_| "{}".to_string());
        url = format!("{url},{json}");
    }
    Some(url)
}

/// User-Agent 字符串 → header JSON `{"User-Agent":"..."}`
pub fn ua_to_header(ua: Option<&str>) -> Option<String> {
    let ua = ua?.trim();
    if ua.is_empty() {
        return None;
    }
    let map = serde_json::json!({ "User-Agent": ua });
    Some(map.to_string())
}

fn json_str(v: &Value, path: &str) -> Option<String> {
    let mut cur = v;
    for part in path.split('.') {
        cur = cur.get(part)?;
    }
    match cur {
        Value::Null => None,
        Value::String(s) => {
            if s.is_empty() {
                None
            } else {
                Some(s.clone())
            }
        }
        other => Some(other.to_string()),
    }
}

fn json_str_or_empty(v: &Value, path: &str) -> String {
    json_str(v, path).unwrap_or_default()
}

fn json_bool(v: &Value, path: &str) -> Option<bool> {
    let mut cur = v;
    for part in path.split('.') {
        cur = cur.get(part)?;
    }
    match cur {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => Some(n.as_i64() != Some(0)),
        Value::String(s) => match s.trim() {
            "true" | "1" => Some(true),
            "false" | "0" | "" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn json_i64(v: &Value, path: &str) -> Option<i64> {
    let mut cur = v;
    for part in path.split('.') {
        cur = cur.get(part)?;
    }
    match cur {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn json_i32(v: &Value, path: &str) -> Option<i32> {
    json_i64(v, path).and_then(|n| i32::try_from(n).ok())
}

/// 旧版书架 JSON 数组 → Book 列表（跳过 blank bookUrl；`existing` 中已有则跳过）
pub fn from_old_books(json: &str, existing: &std::collections::HashSet<String>) -> Vec<Book> {
    let Ok(items) = serde_json::from_str::<Vec<Value>>(json) else {
        return Vec::new();
    };
    let mut books = Vec::new();
    for item in items {
        let book_url = json_str_or_empty(&item, "noteUrl");
        if book_url.is_empty() {
            continue;
        }
        let name = json_str_or_empty(&item, "bookInfoBean.name");
        if existing.contains(&book_url) {
            continue;
        }
        let origin = json_str_or_empty(&item, "tag");
        let local = if origin == book_type::LOCAL_TAG {
            book_type::LOCAL
        } else {
            0
        };
        let is_audio = json_str(&item, "bookInfoBean.bookSourceType").as_deref() == Some("AUDIO");
        let book_type_val = local
            | if is_audio {
                book_type::AUDIO
            } else {
                book_type::TEXT
            };
        let toc = json_str(&item, "bookInfoBean.chapterUrl").unwrap_or_else(|| book_url.clone());
        let use_replace = json_bool(&item, "useReplaceRule") == Some(true);
        let mut book = Book {
            book_url,
            name,
            origin,
            origin_name: json_str_or_empty(&item, "bookInfoBean.origin"),
            author: json_str_or_empty(&item, "bookInfoBean.author"),
            book_type: book_type_val,
            toc_url: toc,
            cover_url: json_str(&item, "bookInfoBean.coverUrl"),
            custom_cover_url: json_str(&item, "customCoverPath"),
            last_check_time: json_i64(&item, "bookInfoBean.finalRefreshData").unwrap_or(0),
            can_update: json_bool(&item, "allowUpdate") == Some(true),
            total_chapter_num: json_i32(&item, "chapterListSize").unwrap_or(0),
            dur_chapter_index: json_i32(&item, "durChapter").unwrap_or(0),
            dur_chapter_title: json_str(&item, "durChapterName"),
            dur_chapter_pos: json_i32(&item, "durChapterPage").unwrap_or(0),
            dur_chapter_time: json_i64(&item, "finalDate").unwrap_or(0),
            intro: json_str(&item, "bookInfoBean.introduce"),
            latest_chapter_title: json_str(&item, "lastChapterName"),
            last_check_count: json_i32(&item, "newChapters").unwrap_or(0),
            order: json_i32(&item, "serialNumber").unwrap_or(0),
            variable: json_str(&item, "variable"),
            ..Book::default()
        };
        if use_replace {
            book.read_config = Some(ReadConfig {
                use_replace_rule: Some(true),
                ..ReadConfig::default()
            });
        }
        books.push(book);
    }
    books
}

/// 单条旧版书源 → BookSource
pub fn from_old_book_source(item: &Value) -> Result<BookSource, String> {
    let book_source_url = json_str(item, "bookSourceUrl")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "格式错误：缺少 bookSourceUrl".to_string())?;
    let explore_url = to_new_urls(json_str(item, "ruleFindUrl").as_deref());
    let enabled_explore = !explore_url.as_ref().map(|s| s.is_empty()).unwrap_or(true);
    let book_source_type = if json_str(item, "bookSourceType").as_deref() == Some("AUDIO") {
        book_source_type::AUDIO
    } else {
        book_source_type::TEXT
    };

    let mut content = to_new_rule(json_str(item, "ruleBookContent").as_deref()).unwrap_or_default();
    if content.starts_with('$') && !content.starts_with("$.") {
        content = content[1..].to_string();
    }

    Ok(BookSource {
        book_source_url,
        book_source_name: json_str_or_empty(item, "bookSourceName"),
        book_source_group: json_str(item, "bookSourceGroup"),
        login_url: json_str(item, "loginUrl"),
        login_ui: json_str(item, "loginUi"),
        login_check_js: json_str(item, "loginCheckJs"),
        cover_decode_js: json_str(item, "coverDecodeJs"),
        book_source_comment: json_str(item, "bookSourceComment"),
        book_url_pattern: json_str(item, "ruleBookUrlPattern"),
        custom_order: json_i32(item, "serialNumber").unwrap_or(0),
        header: ua_to_header(json_str(item, "httpUserAgent").as_deref()),
        search_url: to_new_url(json_str(item, "ruleSearchUrl").as_deref()),
        explore_url,
        book_source_type,
        enabled: json_bool(item, "enable").unwrap_or(true),
        enabled_explore,
        rule_search: Some(SearchRule {
            book_list: to_new_rule(json_str(item, "ruleSearchList").as_deref()),
            name: to_new_rule(json_str(item, "ruleSearchName").as_deref()),
            author: to_new_rule(json_str(item, "ruleSearchAuthor").as_deref()),
            intro: to_new_rule(json_str(item, "ruleSearchIntroduce").as_deref()),
            kind: to_new_rule(json_str(item, "ruleSearchKind").as_deref()),
            book_url: to_new_rule(json_str(item, "ruleSearchNoteUrl").as_deref()),
            cover_url: to_new_rule(json_str(item, "ruleSearchCoverUrl").as_deref()),
            last_chapter: to_new_rule(json_str(item, "ruleSearchLastChapter").as_deref()),
            ..SearchRule::default()
        }),
        rule_explore: Some(ExploreRule {
            book_list: to_new_rule(json_str(item, "ruleFindList").as_deref()),
            name: to_new_rule(json_str(item, "ruleFindName").as_deref()),
            author: to_new_rule(json_str(item, "ruleFindAuthor").as_deref()),
            intro: to_new_rule(json_str(item, "ruleFindIntroduce").as_deref()),
            kind: to_new_rule(json_str(item, "ruleFindKind").as_deref()),
            book_url: to_new_rule(json_str(item, "ruleFindNoteUrl").as_deref()),
            cover_url: to_new_rule(json_str(item, "ruleFindCoverUrl").as_deref()),
            last_chapter: to_new_rule(json_str(item, "ruleFindLastChapter").as_deref()),
            ..ExploreRule::default()
        }),
        rule_book_info: Some(BookInfoRule {
            init: to_new_rule(json_str(item, "ruleBookInfoInit").as_deref()),
            name: to_new_rule(json_str(item, "ruleBookName").as_deref()),
            author: to_new_rule(json_str(item, "ruleBookAuthor").as_deref()),
            intro: to_new_rule(json_str(item, "ruleIntroduce").as_deref()),
            kind: to_new_rule(json_str(item, "ruleBookKind").as_deref()),
            cover_url: to_new_rule(json_str(item, "ruleCoverUrl").as_deref()),
            last_chapter: to_new_rule(json_str(item, "ruleBookLastChapter").as_deref()),
            toc_url: to_new_rule(json_str(item, "ruleChapterUrl").as_deref()),
            ..BookInfoRule::default()
        }),
        rule_toc: Some(TocRule {
            chapter_list: to_new_rule(json_str(item, "ruleChapterList").as_deref()),
            chapter_name: to_new_rule(json_str(item, "ruleChapterName").as_deref()),
            chapter_url: to_new_rule(json_str(item, "ruleContentUrl").as_deref()),
            next_toc_url: to_new_rule(json_str(item, "ruleChapterUrlNext").as_deref()),
            ..TocRule::default()
        }),
        rule_content: Some(ContentRule {
            content: if content.is_empty() {
                None
            } else {
                Some(content)
            },
            replace_regex: to_new_rule(json_str(item, "ruleBookContentReplace").as_deref()),
            next_content_url: to_new_rule(json_str(item, "ruleContentUrlNext").as_deref()),
            ..ContentRule::default()
        }),
        ..BookSource::default()
    })
}

/// 旧版书源 JSON 数组 → BookSource 列表
pub fn from_old_book_sources(json: &str) -> Vec<BookSource> {
    let Ok(items) = serde_json::from_str::<Vec<Value>>(json) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| from_old_book_source(item).ok())
        .collect()
}

fn replace_rule_valid(rule: &ReplaceRule) -> bool {
    !rule.pattern.is_empty()
}

/// 单条替换规则：优先新格式；否则旧字段 regex/replaceSummary/useTo/enable/serialNumber
pub fn from_old_replace_rule(item: &Value) -> Option<ReplaceRule> {
    // 尝试新格式
    if let Ok(mut rule) = serde_json::from_value::<ReplaceRule>(item.clone()) {
        if replace_rule_valid(&rule) {
            if rule.id == 0 {
                rule.id = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
            }
            return Some(rule);
        }
    }
    let pattern = json_str(item, "regex").unwrap_or_default();
    if pattern.is_empty() {
        return None;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    Some(ReplaceRule {
        id: json_i64(item, "id").unwrap_or(now),
        pattern,
        name: json_str_or_empty(item, "replaceSummary"),
        replacement: json_str_or_empty(item, "replacement"),
        is_regex: json_bool(item, "isRegex") == Some(true),
        scope: json_str(item, "useTo"),
        is_enabled: json_bool(item, "enable") == Some(true),
        order: json_i32(item, "serialNumber").unwrap_or(0),
        ..ReplaceRule::default()
    })
}

/// 替换规则 JSON 数组 → ReplaceRule 列表
pub fn from_old_replace_rules(json: &str) -> Vec<ReplaceRule> {
    let Ok(items) = serde_json::from_str::<Vec<Value>>(json) else {
        return Vec::new();
    };
    items.iter().filter_map(from_old_replace_rule).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blank_newline_rule_omitted_from_multiple_explore_urls() {
        let migrated = to_new_urls(Some("https://example.com/a\n   \nhttps://example.com/b"));
        assert_eq!(
            migrated.as_deref(),
            Some("https://example.com/a\nhttps://example.com/b")
        );
        assert!(!migrated.unwrap().lines().any(|l| l == "null"));
    }

    #[test]
    fn blank_ampersand_rule_omitted_from_multiple_explore_urls() {
        assert_eq!(
            to_new_urls(Some(
                "https://example.com/searchKey&&   &&https://example.net/searchPage"
            ))
            .as_deref(),
            Some("https://example.com/{{key}}\nhttps://example.net/{{page}}")
        );
    }

    #[test]
    fn only_blank_multiple_explore_urls_migrate_to_none() {
        assert_eq!(to_new_urls(Some("  && \n &&  ")), None);
    }

    #[test]
    fn single_explore_url_unchanged() {
        let url = "https://example.com/books";
        assert_eq!(to_new_urls(Some(url)).as_deref(), Some(url));
    }

    #[test]
    fn script_explore_url_unchanged() {
        let script = "<js>return 'https://example.com'";
        assert_eq!(to_new_urls(Some(script)).as_deref(), Some(script));
    }

    #[test]
    fn at_js_explore_url_unchanged() {
        let script = "@js:return 'https://example.com'";
        assert_eq!(to_new_urls(Some(script)).as_deref(), Some(script));
    }

    #[test]
    fn to_new_rule_hash_pipe_amp() {
        // 原版：先 #→## 后，若 | 不在 ## 前半段则不改 |
        assert_eq!(to_new_rule(Some("a#b|c")).as_deref(), Some("a##b|c"));
        assert_eq!(to_new_rule(Some("a|b")).as_deref(), Some("a||b"));
        assert_eq!(to_new_rule(Some("a|b#c")).as_deref(), Some("a||b##c"));
        assert_eq!(to_new_rule(Some("a&b")).as_deref(), Some("a&&b"));
    }

    #[test]
    fn from_old_book_maps_fields() {
        let json = r#"[{
            "noteUrl": "https://ex.com/book/1",
            "tag": "https://ex.com",
            "allowUpdate": true,
            "chapterListSize": 10,
            "durChapter": 2,
            "durChapterName": "第二章",
            "durChapterPage": 5,
            "finalDate": 1000,
            "lastChapterName": "第十章",
            "newChapters": 1,
            "serialNumber": 3,
            "useReplaceRule": true,
            "bookInfoBean": {
                "name": "测试书",
                "author": "作者",
                "origin": "源名",
                "chapterUrl": "https://ex.com/toc",
                "introduce": "简介",
                "bookSourceType": "AUDIO"
            }
        }]"#;
        let books = from_old_books(json, &Default::default());
        assert_eq!(books.len(), 1);
        let b = &books[0];
        assert_eq!(b.book_url, "https://ex.com/book/1");
        assert_eq!(b.name, "测试书");
        assert_eq!(b.author, "作者");
        assert_eq!(b.book_type, book_type::AUDIO);
        assert_eq!(b.toc_url, "https://ex.com/toc");
        assert_eq!(b.dur_chapter_index, 2);
        assert_eq!(
            b.read_config.as_ref().and_then(|c| c.use_replace_rule),
            Some(true)
        );
    }

    #[test]
    fn from_old_book_skips_existing() {
        let json = r#"[{"noteUrl":"u1","bookInfoBean":{"name":"a"}}]"#;
        let mut existing = std::collections::HashSet::new();
        existing.insert("u1".to_string());
        assert!(from_old_books(json, &existing).is_empty());
    }

    #[test]
    fn from_old_replace_rule_legacy_fields() {
        let item = serde_json::json!({
            "regex": "foo",
            "replaceSummary": "名",
            "replacement": "bar",
            "isRegex": true,
            "useTo": "scope",
            "enable": true,
            "serialNumber": 9
        });
        let rule = from_old_replace_rule(&item).unwrap();
        assert_eq!(rule.pattern, "foo");
        assert_eq!(rule.name, "名");
        assert_eq!(rule.order, 9);
        assert!(rule.is_enabled);
    }
}
