//! 高亮体系数据模型
//!
//! 对齐 Android 原版实体：
//! - `BookHighlight` → `io.legado.app.data.entities.BookHighlight`（highlights 表）
//! - `HighlightRule` → `io.legado.app.data.entities.HighlightRule`（highlightRules 表）
//!
//! serde 字段名与 Room 列名严格一致（camelCase），保证跨 FFI JSON 序列化
//! 与 Android Room 数据库双向兼容。

use serde::{Deserialize, Serialize};

/// layoutTitleLength 未知值（对齐 Kotlin `BookHighlight.UNKNOWN_TITLE_LENGTH`）
pub const UNKNOWN_TITLE_LENGTH: i32 = -1;

/// 高亮规则默认超时毫秒数（对齐 Kotlin `HighlightRule.DEFAULT_TIMEOUT_MILLISECONDS`）
pub const DEFAULT_TIMEOUT_MILLISECONDS: i64 = 3000;

/// 正文高亮记录（highlights 表）
///
/// 主键为 `time`（Unix 毫秒），bookUrl/chapterUrl 定位高亮所属书籍与章节，
/// chapterPos/chapterPosEnd 为高亮在章节排版布局中的起止位置（含标题长度偏移）。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BookHighlight {
    /// 高亮创建时间（Unix 毫秒，主键）
    pub time: i64,
    /// 所属书籍 URL
    #[serde(default)]
    pub bookUrl: String,
    /// 所属章节 URL
    #[serde(default)]
    pub chapterUrl: String,
    /// 书名（冗余存储，用于分组展示）
    #[serde(default)]
    pub bookName: String,
    /// 书作者（冗余存储，用于分组展示）
    #[serde(default)]
    pub bookAuthor: String,
    /// 章节索引
    #[serde(default)]
    pub chapterIndex: i32,
    /// 高亮起始位置（排版布局位置，含标题长度偏移）
    #[serde(default)]
    pub chapterPos: i32,
    /// 高亮结束位置（排版布局位置，含标题长度偏移）
    #[serde(default)]
    pub chapterPosEnd: i32,
    /// 创建时记录的标题长度（-1 表示未知，用于换算正文相对位置）
    #[serde(default = "default_layout_title_length")]
    pub layoutTitleLength: i32,
    /// 章节名
    #[serde(default)]
    pub chapterName: String,
    /// 高亮的正文文本
    #[serde(default)]
    pub bookText: String,
    /// 高亮样式（HighlightStyle JSON）
    #[serde(default)]
    pub style: String,
    /// 笔记内容
    #[serde(default)]
    pub note: String,
}

fn default_layout_title_length() -> i32 {
    UNKNOWN_TITLE_LENGTH
}

impl Default for BookHighlight {
    fn default() -> Self {
        Self {
            time: 0,
            bookUrl: String::new(),
            chapterUrl: String::new(),
            bookName: String::new(),
            bookAuthor: String::new(),
            chapterIndex: 0,
            chapterPos: 0,
            chapterPosEnd: 0,
            layoutTitleLength: UNKNOWN_TITLE_LENGTH,
            chapterName: String::new(),
            bookText: String::new(),
            style: String::new(),
            note: String::new(),
        }
    }
}

/// 自动高亮规则（highlightRules 表）
///
/// 对齐 Kotlin `HighlightRule`：`order` 字段在 Room 中映射为 `sortOrder` 列，
/// Rust 侧直接使用列名 `sortOrder` 作为序列化字段名。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HighlightRule {
    /// 规则 ID（自增主键，0 表示未保存）
    #[serde(default)]
    pub id: i64,
    /// 规则名称
    #[serde(default)]
    pub name: String,
    /// 匹配模式（正则表达式或普通文本）
    #[serde(default)]
    pub pattern: String,
    /// 是否为正则匹配
    #[serde(default)]
    pub isRegex: bool,
    /// 生效范围（书名或书源名，空/None 表示全局）
    #[serde(default)]
    pub scope: Option<String>,
    /// 是否启用
    #[serde(default = "default_true")]
    pub isEnabled: bool,
    /// 高亮样式（HighlightStyle JSON）
    #[serde(default)]
    pub style: String,
    /// 排序值（Room 列名 sortOrder，对应 Kotlin 字段 order）
    #[serde(default)]
    pub sortOrder: i32,
    /// 匹配超时毫秒数
    #[serde(default = "default_timeout")]
    pub timeoutMillisecond: i64,
    /// 是否应用到标题
    #[serde(default)]
    pub applyToTitle: bool,
}

fn default_true() -> bool {
    true
}

fn default_timeout() -> i64 {
    DEFAULT_TIMEOUT_MILLISECONDS
}

impl Default for HighlightRule {
    fn default() -> Self {
        Self {
            id: 0,
            name: String::new(),
            pattern: String::new(),
            isRegex: false,
            scope: None,
            isEnabled: true,
            style: String::new(),
            sortOrder: 0,
            timeoutMillisecond: DEFAULT_TIMEOUT_MILLISECONDS,
            applyToTitle: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_highlight_serde_roundtrip() {
        let highlight = BookHighlight {
            time: 1_700_000_000_000,
            bookUrl: "bk://1".to_string(),
            chapterUrl: "ch://1".to_string(),
            bookName: "书名".to_string(),
            bookAuthor: "作者".to_string(),
            chapterIndex: 3,
            chapterPos: 10,
            chapterPosEnd: 20,
            layoutTitleLength: -1,
            chapterName: "第一章".to_string(),
            bookText: "高亮文本".to_string(),
            style: "{}".to_string(),
            note: "笔记".to_string(),
        };
        let json = serde_json::to_string(&highlight).unwrap();
        // 字段名必须与 Room 列名一致（camelCase）
        assert!(json.contains("\"bookUrl\""));
        assert!(json.contains("\"layoutTitleLength\""));
        let decoded: BookHighlight = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, highlight);
    }

    #[test]
    fn test_book_highlight_default_values() {
        // 缺失字段时使用默认值（layoutTitleLength 默认 -1）
        let decoded: BookHighlight = serde_json::from_str(r#"{"time": 1}"#).unwrap();
        assert_eq!(decoded.time, 1);
        assert_eq!(decoded.layoutTitleLength, UNKNOWN_TITLE_LENGTH);
        assert_eq!(decoded.bookUrl, "");
    }

    #[test]
    fn test_highlight_rule_serde_roundtrip() {
        let rule = HighlightRule {
            id: 5,
            name: "关键词规则".to_string(),
            pattern: "重要".to_string(),
            isRegex: false,
            scope: Some("书名A".to_string()),
            isEnabled: true,
            style: "{}".to_string(),
            sortOrder: 2,
            timeoutMillisecond: 3000,
            applyToTitle: true,
        };
        let json = serde_json::to_string(&rule).unwrap();
        assert!(json.contains("\"sortOrder\""));
        assert!(json.contains("\"timeoutMillisecond\""));
        let decoded: HighlightRule = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, rule);
    }

    #[test]
    fn test_highlight_rule_default_values() {
        let decoded: HighlightRule = serde_json::from_str(r#"{"pattern": "abc"}"#).unwrap();
        assert!(decoded.isEnabled);
        assert_eq!(decoded.timeoutMillisecond, DEFAULT_TIMEOUT_MILLISECONDS);
        assert!(!decoded.applyToTitle);
    }
}
