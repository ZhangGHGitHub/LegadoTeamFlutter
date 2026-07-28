//! DictRule Repository - dict_rules 表 CRUD

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 词典规则记录
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
                "INSERT INTO dict_rules (name, url_rule, show_rule, is_enabled, sort_order)
                 VALUES (?1, ?2, ?3, 1, 0)",
                params![name, url_rule, show_rule],
            )
            .map_err(|e| LegadoError::Database(format!("插入词典规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 获取所有词典规则（按 sort_order 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<DictRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, url_rule, show_rule, is_enabled, sort_order
                 FROM dict_rules ORDER BY sort_order ASC",
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
                "SELECT id, name, url_rule, show_rule, is_enabled, sort_order
                 FROM dict_rules WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![id], row_to_dict_rule)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新词典规则
    pub fn update(&self, id: i64, name: &str, url_rule: &str, show_rule: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE dict_rules SET name = ?1, url_rule = ?2, show_rule = ?3 WHERE id = ?4",
                params![name, url_rule, show_rule, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新词典规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除词典规则
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM dict_rules WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除词典规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE dict_rules SET is_enabled = ?1 WHERE id = ?2",
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
                "SELECT id, name, url_rule, show_rule, is_enabled, sort_order
                 FROM dict_rules WHERE is_enabled = 1 ORDER BY sort_order ASC",
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = DictRuleRepository::new(db.connection());
        let id1 = repo.insert("百度词典", "https://dict.baidu.com/s?wd={{key}}", "json.data").unwrap();
        let id2 = repo.insert("有道词典", "https://dict.youdao.com/s?q={{key}}", "xpath://div").unwrap();
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

        assert!(repo.update(id, "New", "http://new.com", "new_rule").unwrap());
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
}
