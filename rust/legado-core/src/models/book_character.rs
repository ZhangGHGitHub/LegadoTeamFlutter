//! 角色卡（book_character_profiles）数据模型
//!
//! 逐字段对齐参考版 `data/entities/BookKnowledge.kt:8-70` 的
//! `BookCharacterProfile`（Room schema v97+，17 列）：
//!
//! 字段语义：
//! - `id`：String 主键（参考版 UUID；FFI 保存空 id 时生成 UUID v4）；
//! - `book_url`：书籍稳定主键（换源不迁移，对齐参考版已知差异）；
//! - `name`：角色名——与 `book_url` 组成 `UNIQUE(bookUrl, name)`「一书一名唯一」；
//! - `aliases_json` / `tags_json`：JSON 数组字符串（原样存取，不解析）；
//! - `avatar_uri`：可空（本地 `file://` URI）；
//! - `role`：`male_lead` / `female_lead` / `male_supporting` /
//!   `female_supporting` / `""`；
//! - `voice_gender` / `voice_age_band`：参考版 v97 追加，默认 `unknown`
//!   （后者存「声音池名」，非固定枚举）；
//! - `personality` / `summary`：性格 / 简介；
//! - `status`：`0`=DRAFT / `1`=ACTIVE / `2`=DISABLED / `3`=DELETED
//!   （列表查询排除 3）；
//! - `source`：`user` / `ai` / `import`；`confidence`：0–1（手动恒 1.0）；
//! - `schema_version`：行级 schema 版本（全仓仅写入）；
//! - `created_at` / `updated_at`：Unix **毫秒**（`updated_at` 为列表排序键）。
//!
//! 序列化键名为 camelCase（与 Room 列名/跨 FFI JSON 一致）。

use serde::{Deserialize, Serialize};

/// 角色卡（book_character_profiles 表）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookCharacter {
    /// 主键（String；空串表示尚未入库，保存时按 (bookUrl,name) 查重复用或生成 UUID v4）
    #[serde(default)]
    pub id: String,
    /// 书籍稳定主键
    #[serde(default)]
    pub book_url: String,
    /// 角色名（与 bookUrl 组成唯一约束）
    #[serde(default)]
    pub name: String,
    /// 别名 JSON 数组字符串（原样存取）
    #[serde(default = "default_json_array")]
    pub aliases_json: String,
    /// 头像本地 URI（可空）
    #[serde(default)]
    pub avatar_uri: Option<String>,
    /// 标签 JSON 数组字符串（原样存取）
    #[serde(default = "default_json_array")]
    pub tags_json: String,
    /// 角色定位（male_lead/female_lead/male_supporting/female_supporting/""）
    #[serde(default)]
    pub role: String,
    /// 声音性别（male/female/unknown）
    #[serde(default = "default_unknown")]
    pub voice_gender: String,
    /// 声音年龄带（存声音池名，默认 unknown）
    #[serde(default = "default_unknown")]
    pub voice_age_band: String,
    /// 性格
    #[serde(default)]
    pub personality: String,
    /// 简介
    #[serde(default)]
    pub summary: String,
    /// 状态：0=DRAFT / 1=ACTIVE / 2=DISABLED / 3=DELETED
    #[serde(default = "default_status")]
    pub status: i32,
    /// 来源：user / ai / import
    #[serde(default = "default_source")]
    pub source: String,
    /// 置信度 0–1（手动恒 1.0）
    #[serde(default = "default_confidence")]
    pub confidence: f64,
    /// 行级 schema 版本
    #[serde(default = "default_schema_version")]
    pub schema_version: i32,
    /// 创建时间（Unix 毫秒）
    #[serde(default)]
    pub created_at: i64,
    /// 更新时间（Unix 毫秒；列表排序键）
    #[serde(default)]
    pub updated_at: i64,
}

fn default_json_array() -> String {
    "[]".to_string()
}

fn default_unknown() -> String {
    "unknown".to_string()
}

fn default_status() -> i32 {
    1
}

fn default_source() -> String {
    "user".to_string()
}

fn default_confidence() -> f64 {
    1.0
}

fn default_schema_version() -> i32 {
    1
}

impl Default for BookCharacter {
    fn default() -> Self {
        Self {
            id: String::new(),
            book_url: String::new(),
            name: String::new(),
            aliases_json: default_json_array(),
            avatar_uri: None,
            tags_json: default_json_array(),
            role: String::new(),
            voice_gender: default_unknown(),
            voice_age_band: default_unknown(),
            personality: String::new(),
            summary: String::new(),
            status: default_status(),
            source: default_source(),
            confidence: default_confidence(),
            schema_version: default_schema_version(),
            created_at: 0,
            updated_at: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults_match_reference_entity() {
        let character = BookCharacter::default();
        assert_eq!(character.aliases_json, "[]");
        assert_eq!(character.tags_json, "[]");
        assert_eq!(character.voice_gender, "unknown");
        assert_eq!(character.voice_age_band, "unknown");
        assert_eq!(character.status, 1);
        assert_eq!(character.source, "user");
        assert_eq!(character.confidence, 1.0);
        assert_eq!(character.schema_version, 1);
        assert!(character.avatar_uri.is_none());
        assert!(character.id.is_empty());
    }

    #[test]
    fn test_serde_camel_case_and_missing_defaults() {
        let json = r#"{"bookUrl":"https://a/1","name":"角色甲"}"#;
        let character: BookCharacter = serde_json::from_str(json).unwrap();
        assert_eq!(character.book_url, "https://a/1");
        assert_eq!(character.name, "角色甲");
        assert!(character.id.is_empty());
        assert_eq!(character.aliases_json, "[]", "缺键 aliasesJson 应为 []");
        assert_eq!(character.tags_json, "[]");
        assert_eq!(character.status, 1, "缺键 status 应为 1");
        assert_eq!(character.source, "user", "缺键 source 应为 user");
        assert_eq!(character.confidence, 1.0, "缺键 confidence 应为 1.0");
        assert_eq!(character.voice_gender, "unknown");
        assert_eq!(character.voice_age_band, "unknown");
        assert_eq!(character.schema_version, 1);

        let back = serde_json::to_value(&character).unwrap();
        assert_eq!(back["bookUrl"], "https://a/1");
        assert_eq!(back["aliasesJson"], "[]");
        assert_eq!(back["voiceGender"], "unknown");
        assert_eq!(back["voiceAgeBand"], "unknown");
        assert_eq!(back["schemaVersion"], 1);
        assert_eq!(back["createdAt"], 0);
        assert_eq!(back["updatedAt"], 0);
        assert!(back.get("book_url").is_none(), "序列化键名应为 camelCase");
        assert!(back.get("aliases_json").is_none());
    }

    #[test]
    fn test_serde_roundtrip_full() {
        let character = BookCharacter {
            id: "c1".into(),
            book_url: "https://a.com/b1".into(),
            name: "角色甲".into(),
            aliases_json: r#"["小甲","阿甲"]"#.into(),
            avatar_uri: Some("file:///avatars/c1.png".into()),
            tags_json: r#"["主角"]"#.into(),
            role: "male_lead".into(),
            voice_gender: "male".into(),
            voice_age_band: "young_adult".into(),
            personality: "沉稳".into(),
            summary: "简介".into(),
            status: 1,
            source: "user".into(),
            confidence: 1.0,
            schema_version: 1,
            created_at: 100,
            updated_at: 200,
        };
        let json = serde_json::to_string(&character).unwrap();
        let back: BookCharacter = serde_json::from_str(&json).unwrap();
        assert_eq!(character, back);
    }
}
