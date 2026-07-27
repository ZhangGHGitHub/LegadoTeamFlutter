//! JS 源调试日志格式化
//! 移植自 Kotlin JsSourceDebugFormatter.kt (85行)

/// 字段最大显示长度
const MAX_FIELD_LENGTH: usize = 512;
/// 截断后缀
const TRUNCATED_SUFFIX: &str = "...(已截断)";

pub struct JsSourceDebugFormatter;

impl JsSourceDebugFormatter {
    /// 格式化搜索日志
    pub fn format_search_log(
        source_name: &str,
        key: &str,
        results: usize,
        duration_ms: u64,
    ) -> String {
        format!("[{source_name}] 搜索 \"{key}\" → {results} 条结果 ({duration_ms}ms)")
    }

    /// 格式化目录日志
    pub fn format_toc_log(source_name: &str, chapters: usize, duration_ms: u64) -> String {
        format!("[{source_name}] 获取目录 → {chapters} 章 ({duration_ms}ms)")
    }

    /// 格式化正文日志
    pub fn format_content_log(
        source_name: &str,
        chapter: &str,
        content_len: usize,
        duration_ms: u64,
    ) -> String {
        format!("[{source_name}] 获取正文 \"{chapter}\" → {content_len} 字符 ({duration_ms}ms)")
    }

    /// 格式化错误日志
    pub fn format_error(source_name: &str, step: &str, error: &str) -> String {
        format!("[{source_name}] ❌ {step} 失败: {error}")
    }

    /// 格式化书籍列表（参考 Kotlin bookList）
    pub fn format_book_list(
        source_name: &str,
        book_count: usize,
        first_book_name: Option<&str>,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        lines.push("┌获取书籍列表".to_string());
        lines.push(format!("└列表大小:{book_count}"));
        if let Some(name) = first_book_name {
            lines.push("┌获取书名".to_string());
            lines.push(format!("└{}", Self::format_value(name)));
        }
        lines.push(format!("[{source_name}] ◇书籍总数:{book_count}"));
        lines
    }

    /// 格式化章节列表（参考 Kotlin chapterList）
    pub fn format_chapter_list(
        source_name: &str,
        chapter_count: usize,
        first_title: Option<&str>,
        last_title: Option<&str>,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        lines.push("┌获取目录列表".to_string());
        lines.push(format!("└列表大小:{chapter_count}"));
        lines.push(format!("[{source_name}] ◇目录总数:{chapter_count}"));
        if let Some(title) = first_title {
            lines.push("≡首章信息".to_string());
            lines.push(format!("◇章节名称:{}", Self::format_value(title)));
        }
        if chapter_count > 1 {
            if let Some(title) = last_title {
                lines.push("≡末章信息".to_string());
                lines.push(format!("◇章节名称:{}", Self::format_value(title)));
            }
        }
        lines
    }

    /// 格式化正文获取日志（参考 Kotlin content）
    pub fn format_content_detail(chapter_title: &str, content_length: usize) -> Vec<String> {
        vec![
            "┌获取章节名称".to_string(),
            format!("└{}", Self::format_value(chapter_title)),
            "┌获取正文内容".to_string(),
            format!("└正文长度:{content_length}"),
        ]
    }

    /// 格式化字段值（超长截断，参考 Kotlin formatValue）
    pub fn format_value(value: &str) -> String {
        if value.len() <= MAX_FIELD_LENGTH {
            value.to_string()
        } else {
            // 按字符截断（避免截断 UTF-8 多字节字符）
            let truncated: String = value.chars().take(MAX_FIELD_LENGTH).collect();
            format!("{truncated}{TRUNCATED_SUFFIX}")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_search_log() {
        let log = JsSourceDebugFormatter::format_search_log("笔趣阁", "斗破", 42, 350);
        assert_eq!(log, "[笔趣阁] 搜索 \"斗破\" → 42 条结果 (350ms)");
    }

    #[test]
    fn test_format_toc_log() {
        let log = JsSourceDebugFormatter::format_toc_log("笔趣阁", 1200, 800);
        assert_eq!(log, "[笔趣阁] 获取目录 → 1200 章 (800ms)");
    }

    #[test]
    fn test_format_content_log() {
        let log = JsSourceDebugFormatter::format_content_log("笔趣阁", "第一章", 5000, 200);
        assert_eq!(log, "[笔趣阁] 获取正文 \"第一章\" → 5000 字符 (200ms)");
    }

    #[test]
    fn test_format_error() {
        let log = JsSourceDebugFormatter::format_error("笔趣阁", "搜索", "网络超时");
        assert_eq!(log, "[笔趣阁] ❌ 搜索 失败: 网络超时");
    }

    #[test]
    fn test_format_value_short() {
        assert_eq!(JsSourceDebugFormatter::format_value("短文本"), "短文本");
    }

    #[test]
    fn test_format_value_truncated() {
        let long_text = "a".repeat(600);
        let formatted = JsSourceDebugFormatter::format_value(&long_text);
        assert!(formatted.ends_with(TRUNCATED_SUFFIX));
        assert!(formatted.len() < 600 + TRUNCATED_SUFFIX.len() + 1);
    }

    #[test]
    fn test_format_book_list() {
        let lines = JsSourceDebugFormatter::format_book_list("测试源", 5, Some("第一本书"));
        assert!(lines[0].contains("获取书籍列表"));
        assert!(lines[1].contains("5"));
        assert!(lines.iter().any(|l| l.contains("第一本书")));
    }

    #[test]
    fn test_format_chapter_list() {
        let lines = JsSourceDebugFormatter::format_chapter_list(
            "测试源",
            100,
            Some("第一章"),
            Some("第一百章"),
        );
        assert!(lines[0].contains("获取目录列表"));
        assert!(lines.iter().any(|l| l.contains("第一章")));
        assert!(lines.iter().any(|l| l.contains("第一百章")));
    }

    #[test]
    fn test_format_content_detail() {
        let lines = JsSourceDebugFormatter::format_content_detail("章节标题", 3000);
        assert_eq!(lines.len(), 4);
        assert!(lines[1].contains("章节标题"));
        assert!(lines[3].contains("3000"));
    }
}
