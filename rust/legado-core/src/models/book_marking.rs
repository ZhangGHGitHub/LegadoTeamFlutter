//! 书签标记（book_marks）数据模型
//!
//! 逐字段对齐参考版 `data/entities/BookMarking.kt:21-46`：
//! 用户划线/高亮笔记（标记）与书签（页面导航）、AI 正文处理完全独立，
//! 单独存 `book_marks` 表，**不写入** `highlights` 表，也不复用 `bookmarks` 表。
//!
//! 字段语义：
//! - `id`：String 主键（参考版为 UUID；FFI 保存时空串由 Rust 生成 UUID v4）；
//! - `bookUrl`：创建时的源地址，跳转校验用；
//! - `bookName` + `bookAuthor`：跨源关联键——换源后标记仍可见可管理；
//! - `chapterIndex`：可空（`textProcess` 允许全书级标记）；
//! - `anchorJson`：章节内定位锚点（参考版 `TextProcessAnchor` 序列化），必填；
//! - `styleJson`：线段/颜色等样式（参考版 `TextProcessStyle` JSON），可空；
//! - `note`：用户备注；
//! - `chapterName`：冗余章节标题，目录笔记页展示用；
//! - `enabled`：是否启用，默认 `true`；
//! - `createdAt` / `updatedAt`：Unix 毫秒。
//!
//! 序列化键名为 camelCase（与 Room 列名/跨 FFI JSON 一致）。

use serde::{Deserialize, Serialize};

/// 书签标记（book_marks 表）
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookMarking {
    /// 主键（String；空串表示尚未入库，保存时由 Rust 生成 UUID v4）
    #[serde(default)]
    pub id: String,
    /// 创建时的源地址（跳转校验用；跨源关联不改写本列）
    #[serde(default)]
    pub book_url: String,
    /// 书名（跨源关联键）
    #[serde(default)]
    pub book_name: String,
    /// 作者（跨源关联键）
    #[serde(default)]
    pub book_author: String,
    /// 章节索引（可空）
    #[serde(default)]
    pub chapter_index: Option<i32>,
    /// 章节内定位锚点 JSON（必填非空，参考版 `TextProcessAnchor`）
    #[serde(default)]
    pub anchor_json: String,
    /// 样式 JSON（可空，参考版 `TextProcessStyle`；样式即类型）
    #[serde(default)]
    pub style_json: Option<String>,
    /// 用户备注
    #[serde(default)]
    pub note: String,
    /// 章节标题（冗余存储，目录笔记页展示用）
    #[serde(default)]
    pub chapter_name: String,
    /// 是否启用（默认 true，对齐参考版实体默认值）
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    /// 创建时间（Unix 毫秒；<=0 保存时补当前时间）
    #[serde(default)]
    pub created_at: i64,
    /// 更新时间（Unix 毫秒；保存/启停恒写当前时间）
    #[serde(default)]
    pub updated_at: i64,
}

fn default_enabled() -> bool {
    true
}

impl Default for BookMarking {
    fn default() -> Self {
        Self {
            id: String::new(),
            book_url: String::new(),
            book_name: String::new(),
            book_author: String::new(),
            chapter_index: None,
            anchor_json: String::new(),
            style_json: None,
            note: String::new(),
            chapter_name: String::new(),
            enabled: true,
            created_at: 0,
            updated_at: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_enabled_true() {
        let marking = BookMarking::default();
        assert!(marking.enabled);
        assert!(marking.chapter_index.is_none());
        assert!(marking.style_json.is_none());
    }

    #[test]
    fn test_serde_camel_case_and_missing_defaults() {
        let json = r#"{"id":"m1","anchorJson":"{}"}"#;
        let marking: BookMarking = serde_json::from_str(json).unwrap();
        assert_eq!(marking.id, "m1");
        assert_eq!(marking.anchor_json, "{}");
        assert!(marking.enabled, "缺键 enabled 应为 true");
        assert!(marking.book_name.is_empty());
        assert_eq!(marking.created_at, 0);

        let back = serde_json::to_value(&marking).unwrap();
        assert_eq!(back["id"], "m1");
        assert_eq!(back["anchorJson"], "{}");
        assert_eq!(back["enabled"], true);
        assert!(
            back.get("anchor_json").is_none(),
            "序列化键名应为 camelCase"
        );
        assert_eq!(back["chapterIndex"], serde_json::Value::Null);
    }

    #[test]
    fn test_serde_roundtrip_full() {
        let marking = BookMarking {
            id: "m1".into(),
            book_url: "https://a.com/b1".into(),
            book_name: "书".into(),
            book_author: "作者".into(),
            chapter_index: Some(3),
            anchor_json: r#"{"chapterIndex":3}"#.into(),
            style_json: Some(r#"{"textColor":-1}"#.into()),
            note: "备注".into(),
            chapter_name: "第三章".into(),
            enabled: false,
            created_at: 100,
            updated_at: 200,
        };
        let json = serde_json::to_string(&marking).unwrap();
        let back: BookMarking = serde_json::from_str(&json).unwrap();
        assert_eq!(marking, back);
    }
}
