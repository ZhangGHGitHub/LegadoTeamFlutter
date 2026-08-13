//! KeyboardAssist Repository - keyboardAssists 表 CRUD
//!
//! D1：对齐 Room `KeyboardAssist`（主键 type+key；列 type/key/value/serialNo）。

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 键盘辅助规则记录（对齐 Room；serde 用 camelCase 便于互读）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct KeyboardAssist {
    /// 类型（Room `type`）
    #[serde(rename = "type")]
    pub assist_type: i32,
    pub key: String,
    pub value: String,
    #[serde(rename = "serialNo")]
    pub serial_no: i32,
}

/// 键盘辅助规则数据访问层
pub struct KeyboardAssistRepository<'a> {
    conn: &'a Connection,
}

impl<'a> KeyboardAssistRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条键盘辅助规则（INSERT OR REPLACE 按主键 type+key）
    pub fn insert(&self, assist_type: i32, key: &str, value: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO keyboardAssists (type, key, value, serialNo)
                 VALUES (?1, ?2, ?3, 0)",
                params![assist_type, key, value],
            )
            .map_err(|e| LegadoError::Database(format!("插入键盘辅助规则失败: {e}")))?;
        Ok(())
    }

    /// 全字段插入
    pub fn insert_record(&self, record: &KeyboardAssist) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO keyboardAssists (type, key, value, serialNo)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    record.assist_type,
                    record.key,
                    record.value,
                    record.serial_no
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入键盘辅助规则失败: {e}")))?;
        Ok(())
    }

    /// 获取所有键盘辅助规则（按 serialNo 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT type, key, value, serialNo
                 FROM keyboardAssists ORDER BY serialNo ASC, type ASC, key ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_keyboard_assist)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按主键查询
    pub fn find_by_pk(&self, assist_type: i32, key: &str) -> LegadoResult<Option<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT type, key, value, serialNo
                 FROM keyboardAssists WHERE type = ?1 AND key = ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![assist_type, key], row_to_keyboard_assist)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新（按主键）
    pub fn update(
        &self,
        assist_type: i32,
        key: &str,
        value: &str,
        serial_no: i32,
    ) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE keyboardAssists SET value = ?1, serialNo = ?2
                 WHERE type = ?3 AND key = ?4",
                params![value, serial_no, assist_type, key],
            )
            .map_err(|e| LegadoError::Database(format!("更新键盘辅助规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除（按主键）
    pub fn delete(&self, assist_type: i32, key: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM keyboardAssists WHERE type = ?1 AND key = ?2",
                params![assist_type, key],
            )
            .map_err(|e| LegadoError::Database(format!("删除键盘辅助规则失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 按 key 查询辅助规则
    pub fn find_by_key(&self, key: &str) -> LegadoResult<Vec<KeyboardAssist>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT type, key, value, serialNo
                 FROM keyboardAssists WHERE key = ?1 ORDER BY serialNo ASC",
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
    Ok(KeyboardAssist {
        assist_type: row.get(0)?,
        key: row.get(1)?,
        value: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
        serial_no: row.get(3)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert(0, "source", "换源操作").unwrap();
        repo.insert(0, "refresh", "刷新目录").unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_pk() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert(0, "test_key", "test_value").unwrap();

        let found = repo.find_by_pk(0, "test_key").unwrap();
        assert!(found.is_some());
        let assist = found.unwrap();
        assert_eq!(assist.assist_type, 0);
        assert_eq!(assist.key, "test_key");
        assert_eq!(assist.value, "test_value");

        assert!(repo.find_by_pk(0, "missing").unwrap().is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert(0, "old_key", "old_val").unwrap();

        assert!(repo.update(0, "old_key", "new_val", 3).unwrap());
        let updated = repo.find_by_pk(0, "old_key").unwrap().unwrap();
        assert_eq!(updated.value, "new_val");
        assert_eq!(updated.serial_no, 3);

        assert!(!repo.update(0, "missing", "x", 0).unwrap());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert(0, "del_key", "del_val").unwrap();

        assert!(repo.delete(0, "del_key").unwrap());
        assert!(!repo.delete(0, "del_key").unwrap());
        assert!(repo.find_all().unwrap().is_empty());
    }

    #[test]
    fn test_find_by_key() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = KeyboardAssistRepository::new(db.connection());
        repo.insert_record(&KeyboardAssist {
            assist_type: 0,
            key: "search".into(),
            value: "搜索A".into(),
            serial_no: 0,
        })
        .unwrap();
        repo.insert_record(&KeyboardAssist {
            assist_type: 1,
            key: "search".into(),
            value: "搜索B".into(),
            serial_no: 1,
        })
        .unwrap();
        repo.insert(0, "other", "其他").unwrap();

        let results = repo.find_by_key("search").unwrap();
        assert_eq!(results.len(), 2);
        assert!(results.iter().all(|r| r.key == "search"));
    }
}
