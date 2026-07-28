//! KeyboardAssist Repository - keyboard_assists 表 CRUD

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 键盘辅助规则记录
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KeyboardAssist {
    pub id: i64,
    pub name: String,
    pub key: String,
    pub value: String,
    pub is_enabled: bool,
    pub sort_order: i32,
}

/// 键盘辅助规则数据访问层
pub struct KeyboardAssistRepository<'a> {
    conn: &'a Connection,
}

impl<'a> KeyboardAssistRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条键盘辅助规则，返回新 ID
    pub fn insert(&self, name: &str, key: &str, value: &str) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO keyboard_assists (name, key, value, is_enabled, sort_order)
                 VALUES (?1, ?2, ?3, 1, 0)",
                params![name, key, value],
            )
            .map_err(|e| LegadoError::Database(format!("插入键盘辅助规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 获取所有键盘辅助规则（按 sort_order 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, key, value, is_enabled, sort_order
                 FROM keyboard_assists ORDER BY sort_order ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_keyboard_assist)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, key, value, is_enabled, sort_order
                 FROM keyboard_assists WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![id], row_to_keyboard_assist)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新键盘辅助规则
    pub fn update(&self, id: i64, name: &str, key: &str, value: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE keyboard_assists SET name = ?1, key = ?2, value = ?3 WHERE id = ?4",
                params![name, key, value, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新键盘辅助规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除键盘辅助规则
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM keyboard_assists WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除键盘辅助规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE keyboard_assists SET is_enabled = ?1 WHERE id = ?2",
                params![enabled as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("设置键盘辅助启用状态失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 按 key 查询辅助规则
    pub fn find_by_key(&self, key: &str) -> LegadoResult<Vec<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, key, value, is_enabled, sort_order
                 FROM keyboard_assists WHERE key = ?1 ORDER BY sort_order ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![key], row_to_keyboard_assist)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
}

fn row_to_keyboard_assist(row: &rusqlite::Row<'_>) -> rusqlite::Result<KeyboardAssist> {
    let is_enabled: i32 = row.get(4)?;
    Ok(KeyboardAssist {
        id: row.get(0)?,
        name: row.get(1)?,
        key: row.get(2)?,
        value: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
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
        let repo = KeyboardAssistRepository::new(db.connection());
        let id1 = repo.insert("换源", "source", "换源操作").unwrap();
        let id2 = repo.insert("刷新", "refresh", "刷新目录").unwrap();
        assert!(id1 > 0);
        assert!(id2 > id1);

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        let id = repo.insert("Test", "test_key", "test_value").unwrap();

        let found = repo.find_by_id(id).unwrap();
        assert!(found.is_some());
        let assist = found.unwrap();
        assert_eq!(assist.name, "Test");
        assert_eq!(assist.key, "test_key");
        assert_eq!(assist.value, "test_value");
        assert!(assist.is_enabled);

        assert!(repo.find_by_id(9999).unwrap().is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        let id = repo.insert("Old", "old_key", "old_val").unwrap();

        assert!(repo.update(id, "New", "new_key", "new_val").unwrap());
        let updated = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(updated.name, "New");
        assert_eq!(updated.key, "new_key");
        assert_eq!(updated.value, "new_val");

        assert!(!repo.update(9999, "X", "x", "x").unwrap());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        let id = repo.insert("ToDelete", "del_key", "del_val").unwrap();

        assert!(repo.delete(id).unwrap());
        assert!(!repo.delete(id).unwrap());
        assert!(repo.find_all().unwrap().is_empty());
    }

    #[test]
    fn test_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        let id = repo.insert("Toggle", "toggle_key", "toggle_val").unwrap();

        assert!(repo.set_enabled(id, false).unwrap());
        let assist = repo.find_by_id(id).unwrap().unwrap();
        assert!(!assist.is_enabled);

        assert!(repo.set_enabled(id, true).unwrap());
        let assist = repo.find_by_id(id).unwrap().unwrap();
        assert!(assist.is_enabled);
    }

    #[test]
    fn test_find_by_key() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert("A1", "search", "搜索A").unwrap();
        repo.insert("A2", "search", "搜索B").unwrap();
        repo.insert("B1", "other", "其他").unwrap();

        let results = repo.find_by_key("search").unwrap();
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|r| r.key == "search"));
    }
}
