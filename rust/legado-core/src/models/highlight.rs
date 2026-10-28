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
#[allow(non_snake_case)] // Room/FFI JSON 列名必须为 camelCase
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
#[allow(non_snake_case)] // Room/FFI JSON 列名必须为 camelCase
pub struct HighlightRule {
    /// 规则 ID（自增主键，0 表示未保存）
    #[serde(default)]
    pub id: i64,
    /// 规则身份 UUID（唯一索引，导入按其去重）
    ///
    /// 对齐 Kotlin `HighlightRule.uuid`：实体默认值为 `UUID.randomUUID()`，
    /// 旧 JSON 缺失该字段时同样生成随机 UUID（保证唯一索引可用）。
    #[serde(default = "default_uuid")]
    pub uuid: String,
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
    /// 规则分组（对齐 Kotlin `HighlightRule.group: String?`，Room 列
    /// `"group" TEXT DEFAULT ''`，DatabaseMigrations v108→109 增列）
    ///
    /// 批28：本批只做字段/DB 往返保真（导入、导出、备份、编辑保存不丢分组）；
    /// 原版导入前 `normalizeForRestore` 会把空白分组规整为 null，见
    /// [`HighlightRule::normalize_for_restore`]。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// 是否应用到标题（对齐 Kotlin `applyToTitle`，默认 false）
    #[serde(default)]
    pub applyToTitle: bool,
    /// 是否应用到正文（对齐 Kotlin `applyToBody`，默认 true；
    /// 与 applyToTitle 双开关共同决定标题/正文两侧匹配，缺一会导致
    /// 「标题规则被错误应用到正文」）
    #[serde(default = "default_true")]
    pub applyToBody: bool,
}

fn default_true() -> bool {
    true
}

fn default_timeout() -> i64 {
    DEFAULT_TIMEOUT_MILLISECONDS
}

/// 规则身份默认值：随机 UUID（对齐 Kotlin `UUID.randomUUID().toString()`）
fn default_uuid() -> String {
    uuid::Uuid::new_v4().to_string()
}

impl HighlightRule {
    /// 导入前规整（对齐 Kotlin `HighlightRule.normalizeForRestore`）
    ///
    /// - uuid 非法（无法按 UUID 解析）时重新生成随机 UUID；
    /// - name/pattern/style 为空规整为空串；
    /// - group 去首尾空白，空白规整为 None（对齐原版
    ///   `group = (group as String?)?.trim()?.takeIf { it.isNotEmpty() }`）；
    /// - timeoutMillisecond <= 0 时回退默认超时。
    ///
    /// 原版同时会把空白 style 替换为默认 `HighlightStyle().normalized()`，
    /// 我方 Rust 侧无 HighlightStyle 模型且样式读取方（原版 `styleObj()`）
    /// 对空样式本就回退默认样式，故此处保留空串不动。
    pub fn normalize_for_restore(&mut self) {
        self.uuid = match uuid::Uuid::parse_str(self.uuid.trim()) {
            Ok(valid) => valid.to_string(),
            Err(_) => uuid::Uuid::new_v4().to_string(),
        };
        // name/pattern/style 为 String 非 null，无需原版 (x as String?).orEmpty() 等价处理
        self.group = self
            .group
            .take()
            .map(|g| g.trim().to_string())
            .filter(|g| !g.is_empty());
        if self.timeoutMillisecond <= 0 {
            self.timeoutMillisecond = DEFAULT_TIMEOUT_MILLISECONDS;
        }
    }
}

impl Default for HighlightRule {
    fn default() -> Self {
        Self {
            id: 0,
            uuid: default_uuid(),
            name: String::new(),
            pattern: String::new(),
            isRegex: false,
            scope: None,
            isEnabled: true,
            style: String::new(),
            sortOrder: 0,
            timeoutMillisecond: DEFAULT_TIMEOUT_MILLISECONDS,
            group: None,
            applyToTitle: false,
            applyToBody: true,
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
            ..HighlightRule::default()
        };
        let json = serde_json::to_string(&rule).unwrap();
        assert!(json.contains("\"sortOrder\""));
        assert!(json.contains("\"timeoutMillisecond\""));
        assert!(json.contains("\"uuid\""));
        assert!(json.contains("\"applyToBody\""));
        let decoded: HighlightRule = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, rule);
    }

    #[test]
    fn test_highlight_rule_default_values() {
        let decoded: HighlightRule = serde_json::from_str(r#"{"pattern": "abc"}"#).unwrap();
        assert!(decoded.isEnabled);
        assert_eq!(decoded.timeoutMillisecond, DEFAULT_TIMEOUT_MILLISECONDS);
        // [P2-11] 双开关默认值对齐原版实体：applyToTitle=false、applyToBody=true
        assert!(!decoded.applyToTitle);
        assert!(decoded.applyToBody);
        // 旧 JSON 缺 uuid 时生成随机 UUID（对齐 Kotlin 实体默认值 UUID.randomUUID()）
        assert!(!decoded.uuid.is_empty());
        assert!(uuid::Uuid::parse_str(&decoded.uuid).is_ok());
    }

    /// [P2-11] uuid 缺省随机生成保证唯一索引可用：两次反序列化不撞 uuid
    #[test]
    fn test_highlight_rule_missing_uuid_generates_unique() {
        let a: HighlightRule = serde_json::from_str("{}").unwrap();
        let b: HighlightRule = serde_json::from_str("{}").unwrap();
        assert_ne!(a.uuid, b.uuid);
    }

    /// 批28：`group`（原版 HighlightRule.group，Room 列 `"group" TEXT DEFAULT ''`）
    /// 按同名字段往返；缺键 → None；None 时省略输出键
    #[test]
    fn test_highlight_rule_group_serde_roundtrip() {
        let rule: HighlightRule =
            serde_json::from_str(r#"{"pattern": "abc", "group": "重要标注"}"#).unwrap();
        assert_eq!(rule.group.as_deref(), Some("重要标注"));

        let value = serde_json::to_value(&rule).unwrap();
        assert_eq!(value["group"], "重要标注");
        let decoded: HighlightRule = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.group, rule.group);

        // 缺键 / 显式 null → None，且 None 时省略输出键
        let missing: HighlightRule = serde_json::from_str(r#"{"pattern": "abc"}"#).unwrap();
        assert!(missing.group.is_none());
        let explicit_null: HighlightRule =
            serde_json::from_str(r#"{"pattern": "abc", "group": null}"#).unwrap();
        assert!(explicit_null.group.is_none());
        assert!(!serde_json::to_string(&missing)
            .unwrap()
            .contains("\"group\""));
    }

    /// 批28：normalize_for_restore 对齐原版对 group 的规整
    /// （trim 后空白 → None；有内容保留 trim 结果）
    #[test]
    fn test_highlight_rule_normalize_group() {
        let mut blank: HighlightRule =
            serde_json::from_str(r#"{"pattern": "a", "group": "   "}"#).unwrap();
        blank.normalize_for_restore();
        assert!(blank.group.is_none(), "空白分组应规整为 None");

        let mut padded: HighlightRule =
            serde_json::from_str(r#"{"pattern": "a", "group": "  分组A  "}"#).unwrap();
        padded.normalize_for_restore();
        assert_eq!(padded.group.as_deref(), Some("分组A"));
    }

    /// [P2-11] normalize_for_restore 对齐原版：非法 uuid 重生成、超时回退默认
    #[test]
    fn test_highlight_rule_normalize_for_restore() {
        // 非法 uuid → 随机重生成
        let mut rule: HighlightRule =
            serde_json::from_str(r#"{"uuid": "not-a-uuid", "timeoutMillisecond": -5}"#).unwrap();
        rule.normalize_for_restore();
        assert!(uuid::Uuid::parse_str(&rule.uuid).is_ok());
        assert_eq!(rule.timeoutMillisecond, DEFAULT_TIMEOUT_MILLISECONDS);

        // 大写合法 uuid → 规范化为小写形式（对齐 UUID.fromString().toString()）
        let mut rule2: HighlightRule =
            serde_json::from_str(r#"{"uuid": "0B946E46-A08B-4C41-BC61-0C57C31C93F8"}"#).unwrap();
        rule2.normalize_for_restore();
        assert_eq!(rule2.uuid, "0b946e46-a08b-4c41-bc61-0c57c31c93f8");
    }
}
