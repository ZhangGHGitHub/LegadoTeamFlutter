//! HTML 格式化工具
//!
//! 对应 Kotlin 端 `HtmlFormatter` 中的格式化方法：
//! - htmlFormat(html) — 清理 HTML 标签，保留文本内容
//! - htmlFormat(html, keepTags) — 保留指定标签
//!
//! 使用简单正则方案（基于 `regex` crate），不引入重量级 HTML 解析器。

#[cfg(feature = "quickjs")]
mod impl_html_format {
    use regex::Regex;
    use std::sync::LazyLock;

    // 预编译正则
    // 注意: regex crate 不支持反向引用，所以分别匹配 script 和 style
    static SCRIPT_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?is)<script[^>]*>.*?</script\s*>").unwrap());
    static STYLE_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?is)<style[^>]*>.*?</style\s*>").unwrap());
    static COMMENT_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?s)<!--[^>]*?-->").unwrap());
    static WRAP_TAG_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?i)</?(?:div|p|br|hr|h\d|article|dd|dl|li|ul|ol|table|tr|td|th|section|header|footer|blockquote|figure|figcaption)[^>]*>").unwrap()
    });
    // 注意: regex crate 不支持 lookahead，简化正则
    static ALL_TAG_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"</?[a-zA-Z][^<>]*>").unwrap());
    static NBSP_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(&nbsp;)+").unwrap());
    static ESP_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(&ensp;|&emsp;)").unwrap());
    static NO_PRINT_RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})").unwrap()
    });
    // 合并多个连续换行符为单个换行符
    static MULTI_NEWLINE_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"[ \t]*(?:\n[ \t]*)+").unwrap());
    static LEADING_TRAILING_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^[\n\s]+|[\n\s]+$").unwrap());

    /// 解码常见 HTML 实体
    fn decode_entities(s: &str) -> String {
        s.replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&apos;", "'")
            .replace("&#39;", "'")
    }

    /// htmlFormat(html) — 清理 HTML 标签，保留文本内容
    ///
    /// 对应 Kotlin: `HtmlFormatter.format(html)` / `JsExtensions.htmlFormat(str)`
    /// 用于书源规则中从 HTML 提取纯文本
    pub fn html_format(html: &str) -> String {
        if html.is_empty() {
            return String::new();
        }

        // 1. 移除 <script>...</script> 和 <style>...</style> 块
        let text = SCRIPT_RE.replace_all(html, "");
        let text = STYLE_RE.replace_all(&text, "");
        // 2. 移除 HTML 注释
        let text = COMMENT_RE.replace_all(&text, "");
        // 3. 处理 HTML 实体
        let text = NBSP_RE.replace_all(&text, " ");
        let text = ESP_RE.replace_all(&text, " ");
        let text = NO_PRINT_RE.replace_all(&text, "");
        // 4. 将块级标签替换为换行符
        let text = WRAP_TAG_RE.replace_all(&text, "\n");
        // 5. 移除所有其他 HTML 标签
        let text = ALL_TAG_RE.replace_all(&text, "");
        // 6. 解码 HTML 实体
        let text = decode_entities(&text);
        // 7. 合并多余空白行，trim 每行
        let text = MULTI_NEWLINE_RE.replace_all(&text, "\n");
        let text = LEADING_TRAILING_RE.replace_all(&text, "");

        // trim 每行首尾空白
        text.lines()
            .map(|line| line.trim())
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_string()
    }

    /// htmlFormat(html, keepTags) — 保留指定标签
    ///
    /// 对应 Kotlin: `HtmlFormatter.formatKeepImg(html)` 的简化版
    /// keep_tags: 逗号分隔的标签名，如 "img,a"
    pub fn html_format_with_tags(html: &str, keep_tags: Option<&str>) -> String {
        if html.is_empty() {
            return String::new();
        }

        let keep_set: Vec<String> = keep_tags
            .unwrap_or("")
            .split(',')
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();

        // 1. 移除 script/style
        let text = SCRIPT_RE.replace_all(html, "");
        let text = STYLE_RE.replace_all(&text, "");
        // 2. 移除注释
        let text = COMMENT_RE.replace_all(&text, "");
        // 3. 处理实体
        let text = NBSP_RE.replace_all(&text, " ");
        let text = ESP_RE.replace_all(&text, " ");
        let text = NO_PRINT_RE.replace_all(&text, "");

        // 4. 选择性移除标签：保留 keep_set 中的标签
        let text = if keep_set.is_empty() {
            // 不保留任何标签 → 块级替换 + 全部移除
            let t = WRAP_TAG_RE.replace_all(&text, "\n");
            ALL_TAG_RE.replace_all(&t, "").to_string()
        } else {
            // 构建正则：匹配不在 keep_set 中的标签
            let tag_re = Regex::new(r"</?([a-zA-Z][a-zA-Z0-9]*)\b[^<>]*>").unwrap();
            let mut result = String::new();
            let mut last_end = 0;
            for m in tag_re.find_iter(&text) {
                let tag_full = m.as_str();
                // 提取标签名
                let tag_name = tag_full
                    .trim_start_matches("</")
                    .trim_start_matches('<')
                    .chars()
                    .take_while(|c| c.is_alphanumeric())
                    .collect::<String>()
                    .to_lowercase();

                if keep_set.contains(&tag_name) {
                    // 保留此标签
                    result.push_str(&text[last_end..m.end()]);
                } else {
                    // 块级标签替换为换行
                    let is_block = matches!(
                        tag_name.as_str(),
                        "div" | "p" | "br" | "hr" | "article" | "dd" | "dl" | "li" | "ul" | "ol"
                    );
                    result.push_str(&text[last_end..m.start()]);
                    if is_block {
                        result.push('\n');
                    }
                }
                last_end = m.end();
            }
            result.push_str(&text[last_end..]);
            result
        };

        // 5. 解码实体
        let text = decode_entities(&text);
        // 6. 合并空白
        let text = MULTI_NEWLINE_RE.replace_all(&text, "\n");
        let text = LEADING_TRAILING_RE.replace_all(&text, "");

        text.lines()
            .map(|line| line.trim())
            .collect::<Vec<_>>()
            .join("\n")
            .trim()
            .to_string()
    }
}

#[cfg(feature = "quickjs")]
pub use impl_html_format::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_html_format {
    pub fn html_format(html: &str) -> String {
        html.to_string()
    }

    pub fn html_format_with_tags(html: &str, _keep_tags: Option<&str>) -> String {
        html.to_string()
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_html_format::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    #[test]
    fn test_html_format_basic_paragraphs() {
        let input = "<p>第一段</p><p>第二段</p>";
        let result = html_format(input);
        assert_eq!(result, "第一段\n第二段");
    }

    #[test]
    fn test_html_format_removes_script_style() {
        let input = "<div>正文</div><script>alert('x')</script><style>.a{}</style><div>结尾</div>";
        let result = html_format(input);
        assert_eq!(result, "正文\n结尾");
    }

    #[test]
    fn test_html_format_decodes_entities() {
        let input = "<p>&lt;hello&gt; &amp; &quot;world&quot;</p>";
        let result = html_format(input);
        assert_eq!(result, "<hello> & \"world\"");
    }

    #[test]
    fn test_html_format_nbsp() {
        let input = "<div>A&nbsp;&nbsp;B</div>";
        let result = html_format(input);
        assert_eq!(result, "A B");
    }

    #[test]
    fn test_html_format_br_tags() {
        let input = "第一行<br>第二行<br/>第三行";
        let result = html_format(input);
        assert_eq!(result, "第一行\n第二行\n第三行");
    }

    #[test]
    fn test_html_format_removes_comments() {
        let input = "<div>A</div><!-- hidden --><div>B</div>";
        let result = html_format(input);
        assert_eq!(result, "A\nB");
    }

    #[test]
    fn test_html_format_empty() {
        assert_eq!(html_format(""), "");
    }

    #[test]
    fn test_html_format_with_tags_keep_img() {
        let input = "<p>正文</p><img src=\"cover.jpg\"><p>结尾</p>";
        let result = html_format_with_tags(input, Some("img"));
        assert!(result.contains("<img src=\"cover.jpg\">"));
        assert!(result.contains("正文"));
        assert!(result.contains("结尾"));
        assert!(!result.contains("<p>"));
    }

    #[test]
    fn test_html_format_with_tags_keep_multiple() {
        let input = "<div><a href=\"url\">链接</a><span>文本</span></div>";
        let result = html_format_with_tags(input, Some("a"));
        assert!(result.contains("<a href=\"url\">"));
        assert!(result.contains("</a>"));
        assert!(!result.contains("<span>"));
        assert!(!result.contains("<div>"));
    }

    #[test]
    fn test_html_format_with_tags_none() {
        let input = "<p>纯文本</p>";
        let result = html_format_with_tags(input, None);
        assert_eq!(result, "纯文本");
    }
}
