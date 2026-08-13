//! DictRule Repository - dictRules 表 CRUD
//!
//! Task #137 / D1：对齐 Android 原版字典规则体系（`DictRule` 实体 + `DictRuleDao`）。
//! 表名/列名对齐 Room：`dictRules(name,urlRule,showRule,enabled,sortNumber)`；
//! `id` 为 Rust 超集（便于既有 id 基 CRUD）。
//! 原版默认数据位于 `app/src/main/assets/defaultData/dictRules.json`。

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 原版默认字典规则 JSON（与 Android assets 逐字节同源，编译期内嵌）
const DEFAULT_DICT_RULES_JSON: &str =
    include_str!("../../../../app/src/main/assets/defaultData/dictRules.json");

/// 词典规则记录（Rust 字段 snake_case；DB 列为 Room camelCase）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DictRule {
    pub id: i64,
    pub name: String,
    pub url_rule: String,
    pub show_rule: String,
    pub is_enabled: bool,
    pub sort_order: i32,
}

/// 词典规则数据访问层
pub struct DictRuleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> DictRuleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条词典规则，返回新 ID
    pub fn insert(&self, name: &str, url_rule: &str, show_rule: &str) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO dictRules (name, urlRule, showRule, enabled, sortNumber)
                 VALUES (?1, ?2, ?3, 1, 0)",
                params![name, url_rule, show_rule],
            )
            .map_err(|e| LegadoError::Database(format!("插入词典规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 全字段插入词典规则（含启用状态与排序），返回新 ID
    pub fn insert_record(&self, rule: &DictRule) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO dictRules (name, urlRule, showRule, enabled, sortNumber)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    rule.name,
                    rule.url_rule,
                    rule.show_rule,
                    rule.is_enabled as i32,
                    rule.sort_order
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入词典规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 注入原版默认字典规则（表为空时写入 5 源）
    pub fn seed_default_rules(&self) -> LegadoResult<usize> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM dictRules", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("统计词典规则失败: {e}")))?;
        if count > 0 {
            return Ok(0);
        }

        let defaults = default_dict_rules()?;
        for rule in &defaults {
            self.insert_record(rule)?;
        }
        Ok(defaults.len())
    }

    /// 获取所有词典规则（按 sortNumber 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<DictRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, urlRule, showRule, enabled, sortNumber
                 FROM dictRules ORDER BY sortNumber ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_dict_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<DictRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, urlRule, showRule, enabled, sortNumber
                 FROM dictRules WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![id], row_to_dict_rule)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新词典规则
    pub fn update(
        &self,
        id: i64,
        name: &str,
        url_rule: &str,
        show_rule: &str,
    ) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE dictRules SET name = ?1, urlRule = ?2, showRule = ?3 WHERE id = ?4",
                params![name, url_rule, show_rule, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新词典规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除词典规则
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM dictRules WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除词典规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除全部词典规则
    pub fn delete_all(&self) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute("DELETE FROM dictRules", [])
            .map_err(|e| LegadoError::Database(format!("删除词典规则失败: {e}")))?;
        Ok(affected)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE dictRules SET enabled = ?1 WHERE id = ?2",
                params![enabled as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("设置词典规则启用状态失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 查询所有已启用的规则
    pub fn find_enabled(&self) -> LegadoResult<Vec<DictRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, urlRule, showRule, enabled, sortNumber
                 FROM dictRules WHERE enabled = 1 ORDER BY sortNumber ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_dict_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
}

fn row_to_dict_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<DictRule> {
    let is_enabled: i32 = row.get(4)?;
    Ok(DictRule {
        id: row.get(0)?,
        name: row.get(1)?,
        url_rule: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        show_rule: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        is_enabled: is_enabled != 0,
        sort_order: row.get(5)?,
    })
}

/// 解析原版默认字典规则 JSON 为 DB 记录
pub fn default_dict_rules() -> LegadoResult<Vec<DictRule>> {
    let models: Vec<legado_core::models::DictRule> =
        serde_json::from_str(DEFAULT_DICT_RULES_JSON)
            .map_err(|e| LegadoError::Internal(format!("解析原版默认字典规则失败: {e}")))?;
    Ok(models
        .into_iter()
        .map(|m| DictRule {
            id: 0,
            name: m.name,
            url_rule: m.url_rule,
            show_rule: m.show_rule,
            is_enabled: m.enabled,
            sort_order: m.sort_number,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id1 = repo
            .insert(
                "百度词典",
                "https://dict.baidu.com/s?wd={{key}}",
                "json.data",
            )
            .unwrap();
        let id2 = repo
            .insert(
                "有道词典",
                "https://dict.youdao.com/s?q={{key}}",
                "xpath://div",
            )
            .unwrap();
        assert!(id1 > 0);
        assert!(id2 > id1);

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id = repo.insert("Test", "http://test.com", "rule").unwrap();

        let found = repo.find_by_id(id).unwrap();
        assert!(found.is_some());
        let rule = found.unwrap();
        assert_eq!(rule.name, "Test");
        assert_eq!(rule.url_rule, "http://test.com");
        assert_eq!(rule.show_rule, "rule");
        assert!(rule.is_enabled);

        assert!(repo.find_by_id(9999).unwrap().is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id = repo.insert("Old", "http://old.com", "old_rule").unwrap();

        assert!(repo
            .update(id, "New", "http://new.com", "new_rule")
            .unwrap());
        let updated = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(updated.name, "New");
        assert_eq!(updated.url_rule, "http://new.com");
        assert_eq!(updated.show_rule, "new_rule");

        assert!(!repo.update(9999, "X", "http://x.com", "x").unwrap());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id = repo.insert("ToDelete", "http://del.com", "rule").unwrap();

        assert!(repo.delete(id).unwrap());
        assert!(!repo.delete(id).unwrap());
        assert!(repo.find_all().unwrap().is_empty());
    }

    #[test]
    fn test_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id = repo.insert("Toggle", "http://toggle.com", "rule").unwrap();

        assert!(repo.set_enabled(id, false).unwrap());
        let rule = repo.find_by_id(id).unwrap().unwrap();
        assert!(!rule.is_enabled);

        assert!(repo.set_enabled(id, true).unwrap());
        let rule = repo.find_by_id(id).unwrap().unwrap();
        assert!(rule.is_enabled);
    }

    #[test]
    fn test_find_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        repo.insert("Enabled", "http://1.com", "r1").unwrap();
        let id2 = repo.insert("Disabled", "http://2.com", "r2").unwrap();
        repo.set_enabled(id2, false).unwrap();

        let enabled = repo.find_enabled().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].name, "Enabled");
    }

    #[test]
    fn test_default_dict_rules_integrity() {
        let defaults = default_dict_rules().unwrap();
        assert_eq!(defaults.len(), 5, "原版内置字典源应为 5 个");

        let mut sorted = defaults.clone();
        sorted.sort_by_key(|r| r.sort_order);
        let names: Vec<&str> = sorted.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["海词中文", "海词英文", "有道", "哔哩", "百度汉语"],
            "默认字典源名称与排序应对齐原版"
        );
        for (i, rule) in sorted.iter().enumerate() {
            assert_eq!(rule.sort_order, i as i32, "sortNumber 应为 0..4");
            assert!(rule.is_enabled, "原版默认字典源均为启用状态");
            assert!(!rule.url_rule.is_empty(), "urlRule 不应为空");
        }

        let haici_zh = &sorted[0];
        assert_eq!(haici_zh.url_rule, "https://hanyu.dict.cn/{{key}}");
        let haici_en = &sorted[1];
        assert_eq!(haici_en.url_rule, "https://apii.dict.cn/mini.php?q={{key}}");
        assert_eq!(haici_en.show_rule, "tag.body@all");
        let youdao = &sorted[2];
        assert!(youdao.url_rule.starts_with("https://m.youdao.com/translate"));
        assert!(youdao.url_rule.contains("inputtext={{key}}"));
        let baidu = &sorted[4];
        assert!(baidu.url_rule.starts_with("data:;base64,"));
    }

    #[test]
    fn test_seed_default_rules() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());

        let inserted = repo.seed_default_rules().unwrap();
        assert_eq!(inserted, 5);
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 5);
        assert_eq!(all[0].name, "海词中文");

        let again = repo.seed_default_rules().unwrap();
        assert_eq!(again, 0);
        assert_eq!(repo.find_all().unwrap().len(), 5);
    }

    #[test]
    fn test_insert_record_full_fields() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id = repo
            .insert_record(&DictRule {
                id: 0,
                name: "自定义".into(),
                url_rule: "https://example.com/{{key}}".into(),
                show_rule: "@js:result".into(),
                is_enabled: false,
                sort_order: 7,
            })
            .unwrap();
        let rule = repo.find_by_id(id).unwrap().unwrap();
        assert!(!rule.is_enabled);
        assert_eq!(rule.sort_order, 7);
        assert!(repo.find_enabled().unwrap().is_empty());
    }
}
