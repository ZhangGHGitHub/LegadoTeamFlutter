//! RssReadRecord Repository - rssReadRecords 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 已读记录行（用于列表查询返回）
#[derive(Debug, Clone, serde::Serialize)]
pub struct RssReadRecordRow {
    /// 来源 URL
    pub origin: String,
    /// 文章标题
    pub title: String,
    /// 文章链接
    pub link: Option<String>,
    /// 阅读时间（Unix 毫秒）
    pub read_time: i64,
}

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

    /// 获取已读记录列表（按 readTime 降序）
    ///
    /// `limit` — 最大返回条数，None 时默认 100
    pub fn list_records(&self, limit: Option<i32>) -> LegadoResult<Vec<RssReadRecordRow>> {
        let limit = limit.unwrap_or(100);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, title, link, readTime FROM rssReadRecords ORDER BY readTime DESC LIMIT ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![limit], |row| {
                Ok(RssReadRecordRow {
                    origin: row.get(0)?,
                    title: row.get(1)?,
                    link: row.get(2)?,
                    read_time: row.get(3)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询已读记录失败: {e}")))?;
        let records = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("Row mapping failed: {e}")))?;
        Ok(records)
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

    #[test]
    fn test_list_records() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        // 空列表
        let records = repo.list_records(None).unwrap();
        assert!(records.is_empty());

        // 插入多条
        for i in 0..5 {
            repo.mark_read("https://rss.com", &format!("Title{i}"), Some(&format!("link{i}")))
                .unwrap();
        }

        // 默认 limit=100 返回全部
        let records = repo.list_records(None).unwrap();
        assert_eq!(records.len(), 5);

        // 限制返回条数
        let records = repo.list_records(Some(3)).unwrap();
        assert_eq!(records.len(), 3);

        // 验证字段
        let first = &records[0];
        assert_eq!(first.origin, "https://rss.com");
        assert!(first.link.is_some());
        assert!(first.read_time > 0);
    }
}
