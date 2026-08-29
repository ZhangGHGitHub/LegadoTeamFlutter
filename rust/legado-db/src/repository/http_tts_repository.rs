//! HttpTts Repository - httpTTS 表 CRUD（对齐 Room v95 + isEnabled 超集）

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// HTTP TTS 朗读源
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HttpTts {
    pub id: i64,
    pub name: String,
    pub url: String,
    #[serde(default, rename = "contentType")]
    pub content_type: String,
    #[serde(default, rename = "isEnabled")]
    pub is_enabled: bool,
    #[serde(default, rename = "lastUpdateTime")]
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
        // Room 主键非自增；取 MAX(id)+1（与 Android 导入正 id 共存）
        let next_id: i64 = self
            .conn
            .query_row("SELECT COALESCE(MAX(id), 0) + 1 FROM httpTTS", [], |row| {
                row.get(0)
            })
            .unwrap_or(1);
        self.conn
            .execute(
                "INSERT INTO httpTTS (id, name, url, contentType, pauseDuration, concurrentRate,
                 enabledCookieJar, lastUpdateTime, isEnabled)
                 VALUES (?1, ?2, ?3, '', 0, '0', 0, ?4, 1)",
                params![next_id, name, url, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入 TTS 源失败: {e}")))?;
        Ok(next_id)
    }

    /// 获取所有 TTS 源
    pub fn find_all(&self) -> LegadoResult<Vec<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, url, contentType, isEnabled, lastUpdateTime
                 FROM httpTTS ORDER BY lastUpdateTime DESC",
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
                "SELECT id, name, url, contentType, isEnabled, lastUpdateTime
                 FROM httpTTS WHERE id = ?1",
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
        let now = current_time_millis();
        let affected = self
            .conn
            .execute(
                "UPDATE httpTTS SET name = ?1, url = ?2, lastUpdateTime = ?3 WHERE id = ?4",
                params![name, url, now, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除 TTS 源
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM httpTTS WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 获取所有已启用的 TTS 源
    pub fn find_enabled(&self) -> LegadoResult<Vec<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, url, contentType, isEnabled, lastUpdateTime
                 FROM httpTTS WHERE isEnabled = 1 ORDER BY lastUpdateTime DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_http_tts)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE httpTTS SET isEnabled = ?1 WHERE id = ?2",
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("引擎A", "http://a.example/tts").unwrap();
        assert!(id > 0);
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "引擎A");
        assert!(all[0].is_enabled);
    }

    #[test]
    fn test_update_delete_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("旧名", "http://old").unwrap();
        assert!(repo.update(id, "新名", "http://new").unwrap());
        let item = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(item.name, "新名");
        assert!(repo.set_enabled(id, false).unwrap());
        assert!(!repo.find_by_id(id).unwrap().unwrap().is_enabled);
        assert!(repo.find_enabled().unwrap().is_empty());
        assert!(repo.delete(id).unwrap());
        assert!(repo.find_by_id(id).unwrap().is_none());
    }
}
