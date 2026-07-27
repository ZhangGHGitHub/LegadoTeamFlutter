//! TxtTocRule Repository - txtTocRules 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// TXT 目录规则记录
#[derive(Debug, Clone, Default)]
pub struct TxtTocRuleRecord {
    pub id: i64,
    pub name: String,
    pub rule: String,
    pub serial_number: i32,
    pub enable: bool,
    pub example: Option<String>,
}

/// TXT 目录规则数据访问层
pub struct TxtTocRuleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> TxtTocRuleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入规则，返回新行 id
    pub fn insert(&self, name: &str, rule: &str, order: i32) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO txtTocRules (name, rule, serialNumber) VALUES (?1, ?2, ?3)",
                params![name, rule, order],
            )
            .map_err(|e| LegadoError::Database(format!("插入 TXT 目录规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 查询所有规则（按 serialNumber 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<TxtTocRuleRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, rule, serialNumber, enable, example
                 FROM txtTocRules ORDER BY serialNumber ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 更新规则名称和正则
    pub fn update(&self, id: i64, name: &str, rule: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE txtTocRules SET name = ?1, rule = ?2 WHERE id = ?3",
                params![name, rule, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TXT 目录规则失败: {e}")))?;
        Ok(())
    }

    /// 按 id 删除规则
    pub fn delete(&self, id: i64) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM txtTocRules WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除 TXT 目录规则失败: {e}")))?;
        Ok(())
    }

    /// 查询所有已启用的规则
    pub fn find_enabled(&self) -> LegadoResult<Vec<TxtTocRuleRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, rule, serialNumber, enable, example
                 FROM txtTocRules WHERE enable = 1 ORDER BY serialNumber ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取规则总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM txtTocRules", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<TxtTocRuleRecord> {
    Ok(TxtTocRuleRecord {
        id: row.get(0)?,
        name: row.get(1)?,
        rule: row.get(2)?,
        serial_number: row.get(3)?,
        enable: row.get::<_, i32>(4)? != 0,
        example: row.get(5)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        let id = repo.insert("默认规则", r"^第\s*\d+\s*章", 0).unwrap();
        assert!(id > 0);

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "默认规则");
        assert_eq!(all[0].rule, r"^第\s*\d+\s*章");
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        let id = repo.insert("Rule1", "pattern1", 0).unwrap();
        repo.update(id, "Rule1-Updated", "pattern2").unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all[0].name, "Rule1-Updated");
        assert_eq!(all[0].rule, "pattern2");
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        let id1 = repo.insert("R1", "p1", 0).unwrap();
        repo.insert("R2", "p2", 1).unwrap();
        repo.delete(id1).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].name, "R2");
    }

    #[test]
    fn test_find_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        repo.insert("Enabled", "p1", 0).unwrap();
        let id2 = repo.insert("Disabled", "p2", 1).unwrap();
        // 手动禁用
        db.connection()
            .execute(
                "UPDATE txtTocRules SET enable = 0 WHERE id = ?1",
                params![id2],
            )
            .unwrap();

        let enabled = repo.find_enabled().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].name, "Enabled");
    }

    #[test]
    fn test_ordering() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        repo.insert("Third", "p3", 3).unwrap();
        repo.insert("First", "p1", 1).unwrap();
        repo.insert("Second", "p2", 2).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all[0].name, "First");
        assert_eq!(all[1].name, "Second");
        assert_eq!(all[2].name, "Third");
    }

    #[test]
    fn test_find_all_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        let all = repo.find_all().unwrap();
        assert!(all.is_empty());
    }
}
