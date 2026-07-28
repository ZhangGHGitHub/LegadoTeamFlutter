//! HttpTts Repository - http_tts 表 CRUD

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// HTTP TTS 朗读源
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HttpTts {
    pub id: i64,
    pub name: String,
    pub url: String,
    pub content_type: String,
    pub is_enabled: bool,
    pub created_at: i64,
}

/// HTTP TTS 数据访问层
pub struct HttpTtsRepository<'a> {
    conn: &'a Connection,
}

impl<'a> HttpTtsRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条 TTS 源，返回新 ID
    pub fn insert(&self, name: &str, url: &str) -> LegadoResult<i64> {
        let now = current_time_millis();
        self.conn
            .execute(
                "INSERT INTO http_tts (name, url, content_type, is_enabled, created_at)
                 VALUES (?1, ?2, '', 1, ?3)",
                params![name, url, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入 TTS 源失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 获取所有 TTS 源
    pub fn find_all(&self) -> LegadoResult<Vec<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, url, content_type, is_enabled, created_at
                 FROM http_tts ORDER BY created_at DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_http_tts)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, url, content_type, is_enabled, created_at
                 FROM http_tts WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![id], row_to_http_tts)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新 TTS 源
    pub fn update(&self, id: i64, name: &str, url: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE http_tts SET name = ?1, url = ?2 WHERE id = ?3",
                params![name, url, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除 TTS 源
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM http_tts WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE http_tts SET is_enabled = ?1 WHERE id = ?2",
                params![enabled as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("设置 TTS 启用状态失败: {e}")))?;
        Ok(affected > 0)
    }
}

fn row_to_http_tts(row: &rusqlite::Row<'_>) -> rusqlite::Result<HttpTts> {
    let is_enabled: i32 = row.get(4)?;
    Ok(HttpTts {
        id: row.get(0)?,
        name: row.get(1)?,
        url: row.get(2)?,
        content_type: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        is_enabled: is_enabled != 0,
        created_at: row.get(5)?,
    })
}

fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

use rusqlite::OptionalExtension;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id1 = repo.insert("TTS1", "http://tts.example.com/1").unwrap();
        let id2 = repo.insert("TTS2", "http://tts.example.com/2").unwrap();
        assert!(id1 > 0);
        assert!(id2 > id1);

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("Test", "http://tts.test.com").unwrap();

        let found = repo.find_by_id(id).unwrap();
        assert!(found.is_some());
        let tts = found.unwrap();
        assert_eq!(tts.name, "Test");
        assert_eq!(tts.url, "http://tts.test.com");
        assert!(tts.is_enabled);

        assert!(repo.find_by_id(9999).unwrap().is_none());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("Old", "http://old.com").unwrap();

        assert!(repo.update(id, "New", "http://new.com").unwrap());
        let updated = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(updated.name, "New");
        assert_eq!(updated.url, "http://new.com");

        assert!(!repo.update(9999, "X", "http://x.com").unwrap());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("ToDelete", "http://del.com").unwrap();

        assert!(repo.delete(id).unwrap());
        assert!(!repo.delete(id).unwrap());
        assert!(repo.find_all().unwrap().is_empty());
    }

    #[test]
    fn test_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("Toggle", "http://toggle.com").unwrap();

        assert!(repo.set_enabled(id, false).unwrap());
        let tts = repo.find_by_id(id).unwrap().unwrap();
        assert!(!tts.is_enabled);

        assert!(repo.set_enabled(id, true).unwrap());
        let tts = repo.find_by_id(id).unwrap().unwrap();
        assert!(tts.is_enabled);

        assert!(!repo.set_enabled(9999, true).unwrap());
    }

    #[test]
    fn test_find_all_ordered_by_created_desc() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id1 = repo.insert("First", "http://1.com").unwrap();
        let id2 = repo.insert("Second", "http://2.com").unwrap();
        let id3 = repo.insert("Third", "http://3.com").unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 3);
        // ID 递增确认插入顺序
        assert!(id3 > id2);
        assert!(id2 > id1);
        // 所有记录均存在
        assert!(all.iter().any(|t| t.name == "First"));
        assert!(all.iter().any(|t| t.name == "Second"));
        assert!(all.iter().any(|t| t.name == "Third"));
    }
}
