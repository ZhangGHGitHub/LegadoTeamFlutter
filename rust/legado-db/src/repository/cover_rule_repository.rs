//! CoverRule Repository — coverRules 表数据访问层
//!
//! Task #73（契约 §2.4.8 `searchCoverRules`）：对齐 Android 原版
//! `CoverRuleDao`（`findAllEnable` 等）。原版实体字段：
//! id（自增主键）/ name / rule（JSON：`{"searchUrl":"...","coverRule":"..."}`）/ enable。
//!
//! 表结构以 [`crate::default_data::DefaultDataManager::ensure_tables`] 的
//! coverRules DDL 为准。该表不在 schema.rs 建表清单中（仅默认数据导入时
//! 按需创建），故本 Repository 在每个入口做幂等的
//! `CREATE TABLE IF NOT EXISTS`（不新增列/索引、不走版本迁移，
//! 与 DB 迁移冻结约束兼容）。

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 封面规则记录（对齐原版 `CoverRule` 实体）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CoverRule {
    /// 自增主键（0 表示未入库）
    pub id: i64,
    /// 规则名称
    pub name: String,
    /// 规则 JSON 字符串：`{"searchUrl":"...","coverRule":"..."}`
    pub rule: String,
    /// 是否启用（enable=1）
    pub enable: bool,
}

/// 封面规则数据访问层
pub struct CoverRuleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> CoverRuleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 幂等建表（DDL 与 default_data.rs ensure_tables 的 coverRules 完全一致）
    fn ensure_table(&self) -> LegadoResult<()> {
        self.conn
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS coverRules (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL DEFAULT '',
                    rule TEXT NOT NULL DEFAULT '',
                    enable INTEGER NOT NULL DEFAULT 1
                );",
            )
            .map_err(|e| LegadoError::Database(format!("创建 coverRules 表失败: {e}")))
    }

    /// 查询全部封面规则（对齐 DAO `findAll`，按 id 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<CoverRule>> {
        self.ensure_table()?;
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, rule, enable FROM coverRules ORDER BY id ASC")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map([], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询封面规则失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 查询全部启用的封面规则（对齐 DAO `findAllEnable`：enable=1）
    pub fn find_enabled(&self) -> LegadoResult<Vec<CoverRule>> {
        self.ensure_table()?;
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, rule, enable FROM coverRules
                 WHERE enable = 1 ORDER BY id ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map([], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询启用封面规则失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 插入封面规则（id>0 时 INSERT OR REPLACE；否则自增主键），返回实际 ID
    pub fn insert(&self, rule: &CoverRule) -> LegadoResult<i64> {
        self.ensure_table()?;
        if rule.id > 0 {
            self.conn
                .execute(
                    "INSERT OR REPLACE INTO coverRules (id, name, rule, enable)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![rule.id, rule.name, rule.rule, rule.enable],
                )
                .map_err(|e| LegadoError::Database(format!("插入封面规则失败: {e}")))?;
            Ok(rule.id)
        } else {
            self.conn
                .execute(
                    "INSERT INTO coverRules (name, rule, enable) VALUES (?1, ?2, ?3)",
                    params![rule.name, rule.rule, rule.enable],
                )
                .map_err(|e| LegadoError::Database(format!("插入封面规则失败: {e}")))?;
            Ok(self.conn.last_insert_rowid())
        }
    }

    /// 按 ID 删除封面规则，返回是否实际删除
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        self.ensure_table()?;
        let rows = self
            .conn
            .execute("DELETE FROM coverRules WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除封面规则失败: {e}")))?;
        Ok(rows > 0)
    }

    /// 清空封面规则表（测试隔离用）
    pub fn delete_all(&self) -> LegadoResult<()> {
        self.ensure_table()?;
        self.conn
            .execute("DELETE FROM coverRules", [])
            .map_err(|e| LegadoError::Database(format!("清空封面规则失败: {e}")))?;
        Ok(())
    }

    /// 规则总数
    pub fn count(&self) -> LegadoResult<i64> {
        self.ensure_table()?;
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM coverRules", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

/// 行数据映射为 CoverRule（列顺序与查询列一致）
fn row_to_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<CoverRule> {
    let enable: i64 = row.get(3)?;
    Ok(CoverRule {
        id: row.get(0)?,
        name: row.get(1)?,
        rule: row.get(2)?,
        enable: enable != 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_rule(name: &str, rule: &str, enable: bool) -> CoverRule {
        CoverRule {
            id: 0,
            name: name.to_string(),
            rule: rule.to_string(),
            enable,
        }
    }

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CoverRuleRepository::new(db.connection());
        let id1 = repo
            .insert(&make_rule(
                "规则1",
                r#"{"searchUrl":"https://a.com/s?q={{key}}","coverRule":"$.cover"}"#,
                true,
            ))
            .unwrap();
        assert!(id1 > 0);
        repo.insert(&make_rule("规则2", "{}", false)).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].name, "规则1");
        assert!(all[0].enable);
        assert!(!all[1].enable);
    }

    #[test]
    fn test_find_enabled_only() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CoverRuleRepository::new(db.connection());
        repo.insert(&make_rule("启用", "{}", true)).unwrap();
        repo.insert(&make_rule("禁用", "{}", false)).unwrap();

        let enabled = repo.find_enabled().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].name, "启用");
    }

    #[test]
    fn test_insert_replace_with_explicit_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CoverRuleRepository::new(db.connection());
        let mut rule = make_rule("旧", "{}", true);
        let id = repo.insert(&rule).unwrap();
        rule.id = id;
        rule.name = "新".to_string();
        repo.insert(&rule).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.find_all().unwrap()[0].name, "新");
    }

    #[test]
    fn test_delete_and_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CoverRuleRepository::new(db.connection());
        let id = repo.insert(&make_rule("r", "{}", true)).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        assert!(repo.delete(id).unwrap());
        assert!(!repo.delete(999).unwrap());
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_table_auto_created_on_fresh_db() {
        // 全新库（schema.rs 不含 coverRules）：Repository 应幂等自建表
        let db = crate::init_in_memory_database().unwrap();
        let repo = CoverRuleRepository::new(db.connection());
        assert_eq!(repo.find_enabled().unwrap().len(), 0);
        assert_eq!(repo.count().unwrap(), 0);
    }
}
