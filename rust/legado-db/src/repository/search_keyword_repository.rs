//! SearchKeyword Repository - search_keywords 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// 搜索关键词数据访问层
pub struct SearchKeywordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> SearchKeywordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入搜索关键词（自动去重：若已存在则更新时间）
    pub fn insert(&self, keyword: &str, _book_name: &str) -> LegadoResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        // 先删除旧记录实现去重
        self.conn
            .execute(
                "DELETE FROM search_keywords WHERE keyword = ?1",
                params![keyword],
            )
            .map_err(|e| LegadoError::Database(format!("去重删除失败: {e}")))?;
        self.conn
            .execute(
                "INSERT INTO search_keywords (keyword, time) VALUES (?1, ?2)",
                params![keyword, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入搜索关键词失败: {e}")))?;
        Ok(())
    }

    /// 查询最近搜索的关键词，返回 (keyword, book_name占位, time)
    pub fn find_recent(&self, limit: i32) -> LegadoResult<Vec<(String, String, i64)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT keyword, time FROM search_keywords ORDER BY id DESC LIMIT ?1")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![limit], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    String::new(),
                    row.get::<_, i64>(1)?,
                ))
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按关键词删除
    pub fn delete(&self, keyword: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "DELETE FROM search_keywords WHERE keyword = ?1",
                params![keyword],
            )
            .map_err(|e| LegadoError::Database(format!("删除搜索关键词失败: {e}")))?;
        Ok(())
    }

    /// 清空所有搜索历史
    pub fn clear_all(&self) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM search_keywords", [])
            .map_err(|e| LegadoError::Database(format!("清空搜索历史失败: {e}")))?;
        Ok(())
    }

    /// 按前缀搜索关键词（用于搜索建议）
    pub fn find_by_prefix(&self, prefix: &str) -> LegadoResult<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT keyword FROM search_keywords WHERE keyword LIKE ?1 ORDER BY id DESC")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let pattern = format!("{}%", prefix);
        let rows = stmt
            .query_map(params![pattern], |row| row.get::<_, String>(0))
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取关键词总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM search_keywords", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_recent() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("斗破苍穹", "").unwrap();
        repo.insert("完美世界", "").unwrap();

        let recent = repo.find_recent(10).unwrap();
        assert_eq!(recent.len(), 2);
        // 最近插入的排在前面
        assert_eq!(recent[0].0, "完美世界");
    }

    #[test]
    fn test_insert_dedup() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("斗破苍穹", "").unwrap();
        repo.insert("斗破苍穹", "").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("keyword1", "").unwrap();
        repo.insert("keyword2", "").unwrap();
        repo.delete("keyword1").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let recent = repo.find_recent(10).unwrap();
        assert_eq!(recent[0].0, "keyword2");
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("a", "").unwrap();
        repo.insert("b", "").unwrap();
        repo.insert("c", "").unwrap();
        repo.clear_all().unwrap();

        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_find_by_prefix() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("斗破苍穹", "").unwrap();
        repo.insert("斗战神", "").unwrap();
        repo.insert("完美世界", "").unwrap();

        let results = repo.find_by_prefix("斗").unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_find_recent_limit() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        for i in 0..10 {
            repo.insert(&format!("kw{i}"), "").unwrap();
        }
        let recent = repo.find_recent(3).unwrap();
        assert_eq!(recent.len(), 3);
    }
}
