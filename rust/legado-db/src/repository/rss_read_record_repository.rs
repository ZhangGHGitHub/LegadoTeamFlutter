//! RssReadRecord Repository - rssReadRecords 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 已读记录数据访问层
pub struct RssReadRecordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssReadRecordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 标记文章为已读
    pub fn mark_read(&self, origin: &str, title: &str, link: Option<&str>) -> LegadoResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        self.conn
            .execute(
                "INSERT INTO rssReadRecords (origin, title, readTime, link)
                 VALUES (?1, ?2, ?3, ?4)",
                params![origin, title, now, link],
            )
            .map_err(|e| LegadoError::Database(format!("标记已读失败: {e}")))?;
        Ok(())
    }

    /// 判断文章是否已读（按 link 匹配）
    pub fn is_read(&self, link: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssReadRecords WHERE link = ?1",
                params![link],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询已读状态失败: {e}")))?;
        Ok(count > 0)
    }

    /// 判断文章是否已读（按 origin + title 匹配）
    pub fn is_read_by_title(&self, origin: &str, title: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssReadRecords WHERE origin = ?1 AND title = ?2",
                params![origin, title],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询已读状态失败: {e}")))?;
        Ok(count > 0)
    }

    /// 清空所有已读记录
    pub fn clear_all(&self) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rssReadRecords", [])
            .map_err(|e| LegadoError::Database(format!("清空已读记录失败: {e}")))?;
        Ok(())
    }

    /// 获取已读记录总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM rssReadRecords", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mark_read_and_is_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "Article1", Some("https://link.com/1"))
            .unwrap();

        assert!(repo.is_read("https://link.com/1").unwrap());
        assert!(!repo.is_read("https://link.com/2").unwrap());
    }

    #[test]
    fn test_is_read_by_title() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "Article1", None).unwrap();

        assert!(repo
            .is_read_by_title("https://rss.com", "Article1")
            .unwrap());
        assert!(!repo
            .is_read_by_title("https://rss.com", "Article2")
            .unwrap());
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "A1", Some("l1")).unwrap();
        repo.mark_read("https://rss.com", "A2", Some("l2")).unwrap();
        repo.clear_all().unwrap();

        assert_eq!(repo.count().unwrap(), 0);
        assert!(!repo.is_read("l1").unwrap());
    }

    #[test]
    fn test_multiple_reads() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        for i in 0..5 {
            repo.mark_read("https://rss.com", &format!("A{i}"), Some(&format!("l{i}")))
                .unwrap();
        }
        assert_eq!(repo.count().unwrap(), 5);
    }

    #[test]
    fn test_mark_read_no_link() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "NoLink", None).unwrap();

        assert!(repo.is_read_by_title("https://rss.com", "NoLink").unwrap());
        assert_eq!(repo.count().unwrap(), 1);
    }
}
