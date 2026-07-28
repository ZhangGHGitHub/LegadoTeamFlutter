//! ReadRecord Repository - readRecord 表 CRUD

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 阅读记录
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ReadRecord {
    pub book_name: String,
    pub read_time: i64,
}

/// 阅读记录数据访问层
pub struct ReadRecordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReadRecordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 添加/更新阅读记录（主键冲突时替换）
    pub fn upsert(&self, book_name: &str, read_time: i64) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO readRecord (bookName, readTime) VALUES (?1, ?2)",
                params![book_name, read_time],
            )
            .map_err(|e| LegadoError::Database(format!("更新阅读记录失败: {e}")))?;
        Ok(())
    }

    /// 获取所有阅读记录（按 readTime 降序）
    pub fn find_all(&self) -> LegadoResult<Vec<ReadRecord>> {
        let mut stmt = self
            .conn
            .prepare("SELECT bookName, readTime FROM readRecord ORDER BY readTime DESC")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(ReadRecord {
                    book_name: row.get(0)?,
                    read_time: row.get(1)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取指定书籍的阅读记录
    pub fn find_by_book_name(&self, book_name: &str) -> LegadoResult<Option<ReadRecord>> {
        let mut stmt = self
            .conn
            .prepare("SELECT bookName, readTime FROM readRecord WHERE bookName = ?1")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let record = stmt
            .query_row(params![book_name], |row| {
                Ok(ReadRecord {
                    book_name: row.get(0)?,
                    read_time: row.get(1)?,
                })
            })
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(record)
    }

    /// 删除指定书籍的阅读记录
    pub fn delete_by_book_name(&self, book_name: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM readRecord WHERE bookName = ?1",
                params![book_name],
            )
            .map_err(|e| LegadoError::Database(format!("删除阅读记录失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 清空所有阅读记录，返回删除的行数
    pub fn clear_all(&self) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute("DELETE FROM readRecord", [])
            .map_err(|e| LegadoError::Database(format!("清空阅读记录失败: {e}")))?;
        Ok(affected)
    }

    /// 获取阅读记录总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM readRecord", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

use rusqlite::OptionalExtension;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_upsert_and_find() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();

        let record = repo.find_by_book_name("book1").unwrap();
        assert!(record.is_some());
        let r = record.unwrap();
        assert_eq!(r.book_name, "book1");
        assert_eq!(r.read_time, 1000);
    }

    #[test]
    fn test_upsert_replaces_existing() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book1", 2000).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let r = repo.find_by_book_name("book1").unwrap().unwrap();
        assert_eq!(r.read_time, 2000);
    }

    #[test]
    fn test_find_all_ordered() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book_a", 100).unwrap();
        repo.upsert("book_b", 300).unwrap();
        repo.upsert("book_c", 200).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].book_name, "book_b");
        assert_eq!(all[1].book_name, "book_c");
        assert_eq!(all[2].book_name, "book_a");
    }

    #[test]
    fn test_find_by_book_name_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        let result = repo.find_by_book_name("nonexistent").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_delete_by_book_name() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book2", 2000).unwrap();

        assert!(repo.delete_by_book_name("book1").unwrap());
        assert!(!repo.delete_by_book_name("book1").unwrap());
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        repo.upsert("book1", 1000).unwrap();
        repo.upsert("book2", 2000).unwrap();
        repo.upsert("book3", 3000).unwrap();

        let deleted = repo.clear_all().unwrap();
        assert_eq!(deleted, 3);
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadRecordRepository::new(db.connection());
        assert_eq!(repo.count().unwrap(), 0);
        repo.upsert("book1", 1000).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        repo.upsert("book2", 2000).unwrap();
        assert_eq!(repo.count().unwrap(), 2);
    }
}
