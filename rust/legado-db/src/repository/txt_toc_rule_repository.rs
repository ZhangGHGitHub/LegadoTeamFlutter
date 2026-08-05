//! TxtTocRule Repository - txtTocRules 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// TXT 目录规则记录（v101 补齐 replacement，对齐 Room 99.json）
#[derive(Debug, Clone, Default)]
pub struct TxtTocRuleRecord {
    pub id: i64,
    pub name: String,
    pub rule: String,
    /// 替换内容（对齐 Kotlin TxtTocRule.replacement，默认空串）
    pub replacement: String,
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

    /// 插入规则，返回新行 id（replacement 默认空串）
    pub fn insert(&self, name: &str, rule: &str, order: i32) -> LegadoResult<i64> {
        self.insert_with_replacement(name, rule, "", order)
    }

    /// 插入规则（含替换内容，对齐 Kotlin TxtTocRule.replacement），返回新行 id
    pub fn insert_with_replacement(
        &self,
        name: &str,
        rule: &str,
        replacement: &str,
        order: i32,
    ) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO txtTocRules (name, rule, replacement, serialNumber) VALUES (?1, ?2, ?3, ?4)",
                params![name, rule, replacement, order],
            )
            .map_err(|e| LegadoError::Database(format!("插入 TXT 目录规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 查询所有规则（按 serialNumber 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<TxtTocRuleRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, rule, replacement, serialNumber, enable, example
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

    /// 更新规则名称、正则与替换内容（覆盖 v101 全部可变列）
    pub fn update(&self, id: i64, name: &str, rule: &str) -> LegadoResult<()> {
        self.update_with_replacement(id, name, rule, "")
    }

    /// 更新规则（含替换内容）
    pub fn update_with_replacement(
        &self,
        id: i64,
        name: &str,
        rule: &str,
        replacement: &str,
    ) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE txtTocRules SET name = ?1, rule = ?2, replacement = ?3 WHERE id = ?4",
                params![name, rule, replacement, id],
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
                "SELECT id, name, rule, replacement, serialNumber, enable, example
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
        replacement: row.get(3)?,
        serial_number: row.get(4)?,
        enable: row.get::<_, i32>(5)? != 0,
        example: row.get(6)?,
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

    // ─── v101 新增字段读写测试（replacement）────────────

    #[test]
    fn test_replacement_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        let id = repo
            .insert_with_replacement("带替换规则", r"^卷\s*\d+", "", 0)
            .unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all[0].replacement, "");

        // 更新时写入替换内容
        repo.update_with_replacement(id, "带替换规则", r"^卷\s*\d+", "[卷]")
            .unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].replacement, "[卷]");
    }

    #[test]
    fn test_legacy_insert_default_replacement() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = TxtTocRuleRepository::new(db.connection());
        // 旧接口 insert：replacement 默认空串，不丢字段
        repo.insert("旧接口规则", r"^第.+章", 0).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].replacement, "");

        // 旧接口 update：replacement 置空串，不丢字段
        repo.update(all[0].id, "旧接口规则-改", r"^第.+节").unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].name, "旧接口规则-改");
        assert_eq!(all[0].replacement, "");
    }
}
