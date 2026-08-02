//! HTML 正文净化器
//!
//! 对标 Kotlin `HtmlFormatter.formatKeepImg` + `StringEscapeUtils.unescapeHtml4`。
//! 独立于 JS 引擎，可在 legado-core 层直接使用。
//!
//! 主要功能：
//! - [`format_keep_img`] — 清理 HTML 标签但保留 `<img>`，处理懒加载属性，URL 绝对化
//! - [`unescape_html4`] — 完整 HTML4 实体反转义（命名实体 + 数字实体）

use regex::Regex;
use std::sync::LazyLock;

// ─── 预编译正则 ─────────────────────────────────────────────────────────────────

/// 匹配 <script>...</script> 块
static SCRIPT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<script[^>]*>.*?</script\s*>").unwrap());

/// 匹配 <style>...</style> 块
static STYLE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<style[^>]*>.*?</style\s*>").unwrap());

/// 匹配 HTML 注释
static COMMENT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<!--[^>]*?-->").unwrap());

/// 匹配 <img ...> 标签（含自闭合）
static IMG_TAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<img\b[^>]*?/?>").unwrap());

/// 从 img 标签中提取指定属性值
static ATTR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)\b(data-src|data-original|srcset|src)\s*=\s*["']([^"']*)["']"#).unwrap());

/// 块级标签 → 换行
static BLOCK_TAG_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)</?(?:div|p|br|hr|h[1-6]|article|dd|dl|dt|li|ul|ol|table|tr|td|th|section|header|footer|blockquote|figure|figcaption|pre|address|main|aside|nav)[^>]*>").unwrap()
});

/// 匹配所有 HTML 标签（用于最终清除）
static ALL_TAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"</?[a-zA-Z][^<>]*>").unwrap());

/// 合并多个连续换行为单个换行
static MULTI_NEWLINE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[ \t]*(?:\n[ \t]*)+").unwrap());

/// 命名实体匹配
static NAMED_ENTITY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&([a-zA-Z][a-zA-Z0-9]*);").unwrap());

/// 数字实体匹配（十进制 &#123; 和十六进制 &#x7B;）
static NUMERIC_ENTITY_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"&#([xX]?)([0-9a-fA-F]+);").unwrap());

// ─── 公共接口 ─────────────────────────────────────────────────────────────────

/// 清理 HTML 标签但保留 `<img>` 标签
///
/// 对标 Kotlin `HtmlFormatter.formatKeepImg(content, baseUrl)`：
/// 1. 移除 script/style/注释
/// 2. 保留 `<img>` 标签，处理懒加载属性（data-src, data-original, srcset）
/// 3. 将图片相对 URL 转为绝对 URL
/// 4. 块级标签转换为换行
/// 5. 移除其他所有 HTML 标签
/// 6. 合并多余空行
pub fn format_keep_img(html: &str, base_url: &str) -> String {
    if html.is_empty() {
        return String::new();
    }

    // 1. 移除 script/style 块
    let text = SCRIPT_RE.replace_all(html, "");
    let text = STYLE_RE.replace_all(&text, "");

    // 2. 移除 HTML 注释
    let text = COMMENT_RE.replace_all(&text, "");

    // 3. 处理 img 标签：提取真实 URL 并绝对化，用占位符保护
    let (text, img_tags) = process_img_tags(&text, base_url);

    // 4. 块级标签 → 换行
    let text = BLOCK_TAG_RE.replace_all(&text, "\n");

    // 5. 移除所有剩余 HTML 标签（img 已用纯文本占位符保护）
    let text = ALL_TAG_RE.replace_all(&text, "");

    // 6. 恢复 img 占位符为真实标签
    let text = restore_img_placeholders(&text, &img_tags);

    // 7. 合并多余空行，trim
    let text = MULTI_NEWLINE_RE.replace_all(&text, "\n");
    let text = text.trim().to_string();

    text
}

/// 完整的 HTML4 实体反转义
///
/// 对标 Kotlin `StringEscapeUtils.unescapeHtml4(content)`：
/// 1. 处理命名实体：&amp; &lt; &gt; &quot; &apos; &nbsp; 等
/// 2. 处理十进制数字实体：&#123;
/// 3. 处理十六进制数字实体：&#x7B; &#X7b;
pub fn unescape_html4(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }

    // 先处理数字实体（避免命名实体正则干扰）
    let text = NUMERIC_ENTITY_RE.replace_all(text, |caps: &regex::Captures| {
        let is_hex = !caps[1].is_empty();
        let num_str = &caps[2];
        let code_point = if is_hex {
            u32::from_str_radix(num_str, 16)
        } else {
            num_str.parse::<u32>()
        };
        match code_point {
            Ok(cp) => char::from_u32(cp)
                .map(|c| c.to_string())
                .unwrap_or_else(|| caps[0].to_string()),
            Err(_) => caps[0].to_string(),
        }
    });

    // 再处理命名实体
    let text = NAMED_ENTITY_RE.replace_all(&text, |caps: &regex::Captures| {
        let name = &caps[1];
        match lookup_named_entity(name) {
            Some(replacement) => replacement.to_string(),
            None => caps[0].to_string(), // 未知实体保持原样
        }
    });

    text.to_string()
}

// ─── 内部辅助 ─────────────────────────────────────────────────────────────────

/// 处理所有 img 标签：提取真实 URL，绝对化，用纯文本占位符替换
///
/// 返回处理后的文本和 img 标签列表（按顺序对应占位符索引）
fn process_img_tags(html: &str, base_url: &str) -> (String, Vec<String>) {
    let mut result = String::new();
    let mut img_tags: Vec<String> = Vec::new();
    let mut last_end = 0;

    for m in IMG_TAG_RE.find_iter(html) {
        result.push_str(&html[last_end..m.start()]);

        let tag = m.as_str();
        let real_url = extract_img_url(tag);

        if let Some(url) = real_url {
            let absolute_url = get_absolute_url(base_url, &url);
            let normalized = format!("<img src=\"{}\">", absolute_url);
            // 用纯文本占位符替代（不含 < > 字符，不会被 ALL_TAG_RE 匹配）
            result.push_str(&format!("\u{FFF0}IMG{}\u{FFF1}", img_tags.len()));
            img_tags.push(normalized);
        }
        // 如果无法提取 URL，则直接丢弃该 img 标签

        last_end = m.end();
    }
    result.push_str(&html[last_end..]);
    (result, img_tags)
}

/// 恢复 img 占位符为真实标签
fn restore_img_placeholders(text: &str, img_tags: &[String]) -> String {
    let mut result = text.to_string();
    for (i, tag) in img_tags.iter().enumerate() {
        let placeholder = format!("\u{FFF0}IMG{}\u{FFF1}", i);
        result = result.replace(&placeholder, tag);
    }
    result
}

/// 从 img 标签中提取真实图片 URL
///
/// 优先级：data-src > data-original > srcset（第一个 URL）> src
fn extract_img_url(tag: &str) -> Option<String> {
    let mut src_val: Option<String> = None;
    let mut data_src_val: Option<String> = None;
    let mut data_original_val: Option<String> = None;
    let mut srcset_val: Option<String> = None;

    for caps in ATTR_RE.captures_iter(tag) {
        let attr_name = caps[1].to_lowercase();
        let attr_value = caps[2].trim().to_string();
        if attr_value.is_empty() {
            continue;
        }
        match attr_name.as_str() {
            "data-src" => data_src_val = Some(attr_value),
            "data-original" => data_original_val = Some(attr_value),
            "srcset" => srcset_val = Some(attr_value),
            "src" => src_val = Some(attr_value),
            _ => {}
        }
    }

    // 优先级：data-src > data-original > srcset > src
    if let Some(url) = data_src_val {
        return Some(url);
    }
    if let Some(url) = data_original_val {
        return Some(url);
    }
    if let Some(srcset) = srcset_val {
        // srcset 格式："url1 1x, url2 2x" 或 "url1 300w, url2 600w"
        // 取第一个 URL
        let first = srcset.split(',').next().unwrap_or("").trim();
        let url = first.split_whitespace().next().unwrap_or("");
        if !url.is_empty() {
            return Some(url.to_string());
        }
    }
    src_val
}

/// 将相对 URL 转为绝对 URL
///
/// 逻辑复制自 `legado-parser::AnalyzeUrl::get_absolute_url`，
/// 因为 legado-core 不能反向依赖 legado-parser（会形成循环依赖）。
fn get_absolute_url(base: &str, relative: &str) -> String {
    let relative = relative.trim();

    // 已经是绝对 URL
    if relative.starts_with("http://") || relative.starts_with("https://") {
        return relative.to_string();
    }

    // data URI 保持原样
    if relative.starts_with("data:") {
        return relative.to_string();
    }

    let base = base.trim();
    if base.is_empty() {
        return relative.to_string();
    }

    // 协议相对路径 //cdn.example.com/...
    if relative.starts_with("//") {
        if let Some(pos) = base.find("://") {
            return format!("{}:{}", &base[..pos], relative);
        }
        return format!("https:{}", relative);
    }

    // 绝对路径 /path/to/file
    if relative.starts_with('/') {
        if let Some(pos) = base.find("://") {
            if let Some(slash_pos) = base[pos + 3..].find('/') {
                let domain = &base[..pos + 3 + slash_pos];
                return format!("{}{}", domain, relative);
            } else {
                return format!("{}{}", base, relative);
            }
        }
        return format!("{}/{}", base.trim_end_matches('/'), relative);
    }

    // 相对路径
    if base.ends_with('/') {
        format!("{}{}", base, relative)
    } else if let Some(pos) = base.rfind('/') {
        // 确保不截断协议部分
        if pos > base.find("://").map(|p| p + 2).unwrap_or(0) {
            format!("{}/{}", &base[..pos], relative)
        } else {
            format!("{}/{}", base, relative)
        }
    } else {
        format!("{}/{}", base, relative)
    }
}

/// 查找命名实体对应的字符
///
/// 覆盖 HTML4 常用命名实体 + XML 基本实体
fn lookup_named_entity(name: &str) -> Option<&'static str> {
    match name {
        // XML 基本实体
        "amp" => Some("&"),
        "lt" => Some("<"),
        "gt" => Some(">"),
        "quot" => Some("\""),
        "apos" => Some("'"),
        // 常用 HTML 实体
        "nbsp" => Some(" "),
        "ensp" => Some("\u{2002}"),
        "emsp" => Some("\u{2003}"),
        "thinsp" => Some("\u{2009}"),
        "zwnj" => Some("\u{200C}"),
        "zwj" => Some("\u{200D}"),
        "lrm" => Some("\u{200E}"),
        "rlm" => Some("\u{200F}"),
        "ndash" => Some("\u{2013}"),
        "mdash" => Some("\u{2014}"),
        "lsquo" => Some("\u{2018}"),
        "rsquo" => Some("\u{2019}"),
        "sbquo" => Some("\u{201A}"),
        "ldquo" => Some("\u{201C}"),
        "rdquo" => Some("\u{201D}"),
        "bdquo" => Some("\u{201E}"),
        "dagger" => Some("\u{2020}"),
        "Dagger" => Some("\u{2021}"),
        "bull" => Some("\u{2022}"),
        "hellip" => Some("\u{2026}"),
        "permil" => Some("\u{2030}"),
        "prime" => Some("\u{2032}"),
        "Prime" => Some("\u{2033}"),
        "lsaquo" => Some("\u{2039}"),
        "rsaquo" => Some("\u{203A}"),
        "oline" => Some("\u{203E}"),
        "frasl" => Some("\u{2044}"),
        "euro" => Some("\u{20AC}"),
        "trade" => Some("\u{2122}"),
        "copy" => Some("\u{00A9}"),
        "reg" => Some("\u{00AE}"),
        "deg" => Some("\u{00B0}"),
        "plusmn" => Some("\u{00B1}"),
        "times" => Some("\u{00D7}"),
        "divide" => Some("\u{00F7}"),
        "micro" => Some("\u{00B5}"),
        "para" => Some("\u{00B6}"),
        "middot" => Some("\u{00B7}"),
        "frac14" => Some("\u{00BC}"),
        "frac12" => Some("\u{00BD}"),
        "frac34" => Some("\u{00BE}"),
        "iquest" => Some("\u{00BF}"),
        "iexcl" => Some("\u{00A1}"),
        "cent" => Some("\u{00A2}"),
        "pound" => Some("\u{00A3}"),
        "curren" => Some("\u{00A4}"),
        "yen" => Some("\u{00A5}"),
        "brvbar" => Some("\u{00A6}"),
        "sect" => Some("\u{00A7}"),
        "uml" => Some("\u{00A8}"),
        "ordf" => Some("\u{00AA}"),
        "not" => Some("\u{00AC}"),
        "shy" => Some("\u{00AD}"),
        "macr" => Some("\u{00AF}"),
        "acute" => Some("\u{00B4}"),
        "cedil" => Some("\u{00B8}"),
        "ordm" => Some("\u{00BA}"),
        "laquo" => Some("\u{00AB}"),
        "raquo" => Some("\u{00BB}"),
        // 箭头
        "larr" => Some("\u{2190}"),
        "uarr" => Some("\u{2191}"),
        "rarr" => Some("\u{2192}"),
        "darr" => Some("\u{2193}"),
        "harr" => Some("\u{2194}"),
        // 数学符号
        "forall" => Some("\u{2200}"),
        "part" => Some("\u{2202}"),
        "exist" => Some("\u{2203}"),
        "empty" => Some("\u{2205}"),
        "nabla" => Some("\u{2207}"),
        "isin" => Some("\u{2208}"),
        "notin" => Some("\u{2209}"),
        "sum" => Some("\u{2211}"),
        "prod" => Some("\u{220F}"),
        "minus" => Some("\u{2212}"),
        "lowast" => Some("\u{2217}"),
        "radic" => Some("\u{221A}"),
        "infin" => Some("\u{221E}"),
        "ne" => Some("\u{2260}"),
        "le" => Some("\u{2264}"),
        "ge" => Some("\u{2265}"),
        "sub" => Some("\u{2282}"),
        "sup" => Some("\u{2283}"),
        "nsub" => Some("\u{2284}"),
        "sube" => Some("\u{2286}"),
        "supe" => Some("\u{2287}"),
        "oplus" => Some("\u{2295}"),
        "otimes" => Some("\u{2297}"),
        "perp" => Some("\u{22A5}"),
        // 其他
        "spades" => Some("\u{2660}"),
        "clubs" => Some("\u{2663}"),
        "hearts" => Some("\u{2665}"),
        "diams" => Some("\u{2666}"),
        _ => None,
    }
}

// ─── 单元测试 ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_keep_img_basic() {
        let html = "<p>第一段</p><p>第二段</p>";
        let result = format_keep_img(html, "https://example.com");
        assert_eq!(result, "第一段\n第二段");
    }

    #[test]
    fn test_format_keep_img_preserves_img() {
        let html = r#"<p>正文</p><img src="cover.jpg"><p>结尾</p>"#;
        let result = format_keep_img(html, "https://example.com/path/");
        assert!(result.contains(r#"<img src="https://example.com/path/cover.jpg">"#));
        assert!(result.contains("正文"));
        assert!(result.contains("结尾"));
        assert!(!result.contains("<p>"));
    }

    #[test]
    fn test_format_keep_img_lazy_load_data_src() {
        let html = r#"<img data-src="/images/pic.png" src="placeholder.gif">"#;
        let result = format_keep_img(html, "https://example.com");
        assert!(result.contains(r#"<img src="https://example.com/images/pic.png">"#));
        assert!(!result.contains("placeholder.gif"));
    }

    #[test]
    fn test_format_keep_img_lazy_load_data_original() {
        let html = r#"<img data-original="lazy.jpg" src="loading.gif">"#;
        let result = format_keep_img(html, "https://cdn.example.com/novel/");
        assert!(result.contains(r#"<img src="https://cdn.example.com/novel/lazy.jpg">"#));
    }

    #[test]
    fn test_format_keep_img_srcset() {
        let html = r#"<img srcset="small.jpg 300w, large.jpg 800w" src="fallback.jpg">"#;
        let result = format_keep_img(html, "https://example.com/");
        assert!(result.contains(r#"<img src="https://example.com/small.jpg">"#));
    }

    #[test]
    fn test_format_keep_img_absolute_url_unchanged() {
        let html = r#"<img src="https://cdn.other.com/pic.jpg">"#;
        let result = format_keep_img(html, "https://example.com");
        assert!(result.contains(r#"<img src="https://cdn.other.com/pic.jpg">"#));
    }

    #[test]
    fn test_format_keep_img_removes_script_style() {
        let html = "<div>正文</div><script>alert('x')</script><style>.a{}</style><div>结尾</div>";
        let result = format_keep_img(html, "https://example.com");
        assert_eq!(result, "正文\n结尾");
    }

    #[test]
    fn test_format_keep_img_block_tags_to_newline() {
        let html = "第一行<br>第二行<br/>第三行";
        let result = format_keep_img(html, "https://example.com");
        assert_eq!(result, "第一行\n第二行\n第三行");
    }

    #[test]
    fn test_format_keep_img_empty() {
        assert_eq!(format_keep_img("", "https://example.com"), "");
    }

    #[test]
    fn test_unescape_html4_basic_entities() {
        assert_eq!(unescape_html4("&amp;"), "&");
        assert_eq!(unescape_html4("&lt;hello&gt;"), "<hello>");
        assert_eq!(unescape_html4("&quot;world&quot;"), "\"world\"");
        assert_eq!(unescape_html4("&apos;"), "'");
        assert_eq!(unescape_html4("&nbsp;"), " ");
    }

    #[test]
    fn test_unescape_html4_numeric_decimal() {
        assert_eq!(unescape_html4("&#65;&#66;&#67;"), "ABC");
        assert_eq!(unescape_html4("&#20013;&#25991;"), "中文");
    }

    #[test]
    fn test_unescape_html4_numeric_hex() {
        assert_eq!(unescape_html4("&#x41;&#x42;&#x43;"), "ABC");
        assert_eq!(unescape_html4("&#X4E2D;&#x6587;"), "中文");
    }

    #[test]
    fn test_unescape_html4_mixed() {
        let input = "&lt;div&gt; &amp; &#x27;test&#39;";
        let result = unescape_html4(input);
        assert_eq!(result, "<div> & 'test'");
    }

    #[test]
    fn test_unescape_html4_no_entities() {
        let input = "普通文本没有实体";
        assert_eq!(unescape_html4(input), input);
    }

    #[test]
    fn test_unescape_html4_unknown_entity_preserved() {
        let input = "&unknownentity;";
        assert_eq!(unescape_html4(input), "&unknownentity;");
    }

    #[test]
    fn test_get_absolute_url_variants() {
        assert_eq!(
            get_absolute_url("https://example.com/path/", "page.html"),
            "https://example.com/path/page.html"
        );
        assert_eq!(
            get_absolute_url("https://example.com/path/page.html", "img/pic.jpg"),
            "https://example.com/path/img/pic.jpg"
        );
        assert_eq!(
            get_absolute_url("https://example.com/path/", "/absolute.html"),
            "https://example.com/absolute.html"
        );
        assert_eq!(
            get_absolute_url("https://example.com", "//cdn.example.com/file"),
            "https://cdn.example.com/file"
        );
        assert_eq!(
            get_absolute_url("", "https://other.com/page"),
            "https://other.com/page"
        );
        assert_eq!(
            get_absolute_url("https://example.com", "https://already.absolute.com/x"),
            "https://already.absolute.com/x"
        );
    }
}
