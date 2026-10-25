//! SearchKeyword Repository - search_keywords 表 CRUD（对齐 Room v95）

use rusqlite::{params, Connection};

use legado_core::models::SearchKeyword;
use legado_core::{LegadoError, LegadoResult};

/// 搜索关键词数据访问层
pub struct SearchKeywordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> SearchKeywordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入搜索关键词（已存在则 usage+1 并刷新 lastUseTime）
    pub fn insert(&self, keyword: &str, _book_name: &str) -> LegadoResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO search_keywords (word, usage, lastUseTime) VALUES (?1, 1, ?2)
                 ON CONFLICT(word) DO UPDATE SET
                   usage = usage + 1,
                   lastUseTime = excluded.lastUseTime",
                params![keyword, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入搜索关键词失败: {e}")))?;
        Ok(())
    }

    /// 获取全部搜索关键词（含 usage/lastUseTime，供备份收集）
    ///
    /// 与 [`find_recent`] 不同：本方法不做条数截断、返回全字段记录。
    pub fn find_all(&self) -> LegadoResult<Vec<SearchKeyword>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT word, usage, lastUseTime FROM search_keywords
                 ORDER BY lastUseTime DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(SearchKeyword {
                    word: row.get(0)?,
                    usage: row.get::<_, Option<i32>>(1)?.unwrap_or(1),
                    last_use_time: row.get(2)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 全字段 upsert 搜索关键词（INSERT OR REPLACE，供备份恢复使用）
    ///
    /// 与 [`insert`] 的「usage+1 刷新」语义不同：恢复路径需原样保留
    /// 备份中的 usage 与 lastUseTime，不做计数累加。
    pub fn upsert_record(&self, record: &SearchKeyword) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO search_keywords (word, usage, lastUseTime)
                 VALUES (?1, ?2, ?3)",
                params![record.word, record.usage, record.last_use_time],
            )
            .map_err(|e| LegadoError::Database(format!("恢复搜索关键词失败: {e}")))?;
        Ok(())
    }

    /// 查询最近搜索的关键词，返回 (keyword, book_name占位, time)
    pub fn find_recent(&self, limit: i32) -> LegadoResult<Vec<(String, String, i64)>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT word, lastUseTime FROM search_keywords
                 ORDER BY lastUseTime DESC LIMIT ?1",
            )
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
                "DELETE FROM search_keywords WHERE word = ?1",
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
            .prepare(
                "SELECT word FROM search_keywords WHERE word LIKE ?1
                 ORDER BY lastUseTime DESC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let pattern = format!("{prefix}%");
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
    fn test_insert_dedup_increments_usage() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("仙侠", "").unwrap();
        repo.insert("仙侠", "").unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        let usage: i64 = db
            .connection()
            .query_row(
                "SELECT usage FROM search_keywords WHERE word = '仙侠'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(usage, 2);
    }

    #[test]
    fn test_find_recent_and_prefix() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("斗破", "").unwrap();
        repo.insert("斗罗", "").unwrap();
        let recent = repo.find_recent(10).unwrap();
        assert_eq!(recent.len(), 2);
        let prefix = repo.find_by_prefix("斗").unwrap();
        assert_eq!(prefix.len(), 2);
    }

    /// find_all：返回全量关键词且包含 usage/lastUseTime（备份收集路径）
    #[test]
    fn test_find_all_full_fields() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());
        repo.insert("仙侠", "").unwrap();
        repo.insert("仙侠", "").unwrap(); // usage 累加到 2

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].word, "仙侠");
        assert_eq!(all[0].usage, 2);
        assert!(all[0].last_use_time > 0);
    }

    /// 恢复路径 upsert_record：usage/lastUseTime 原样落库，不做 usage+1 累加
    #[test]
    fn test_upsert_record_preserves_usage_and_time() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = SearchKeywordRepository::new(db.connection());

        repo.upsert_record(&SearchKeyword {
            word: "玄幻".to_string(),
            usage: 7,
            last_use_time: 1700000000000,
        })
        .unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].word, "玄幻");
        assert_eq!(all[0].usage, 7, "恢复不得累加 usage");
        assert_eq!(all[0].last_use_time, 1700000000000);

        // 同词重复恢复：整行替换
        repo.upsert_record(&SearchKeyword {
            word: "玄幻".to_string(),
            usage: 3,
            last_use_time: 1700000001000,
        })
        .unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].usage, 3);
        assert_eq!(all[0].last_use_time, 1700000001000);
    }
}
