//! RssReadRecord Repository - rssReadRecords 表 CRUD（对齐 Room v95：主键 record）

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 已读记录行（用于列表查询返回）
#[derive(Debug, Clone, serde::Serialize)]
pub struct RssReadRecordRow {
    /// 来源 URL
    pub origin: String,
    /// 文章标题
    pub title: String,
    /// 文章链接（= Room record 主键）
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

    /// 标记文章为已读（主键 record = link；无 link 时用 legacy:origin:title）
    pub fn mark_read(&self, origin: &str, title: &str, link: Option<&str>) -> LegadoResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let record = match link {
            Some(l) if !l.trim().is_empty() => l.to_string(),
            _ => format!("legacy:{origin}:{title}"),
        };
        self.conn
            .execute(
                "INSERT OR REPLACE INTO rssReadRecords
                 (record, title, readTime, \"read\", origin, sort, image, type, durPos, pubDate)
                 VALUES (?1, ?2, ?3, 1, ?4, '', NULL, 0, 0, NULL)",
                params![record, title, now, origin],
            )
            .map_err(|e| LegadoError::Database(format!("标记已读失败: {e}")))?;
        Ok(())
    }

    /// 判断文章是否已读（按 record/link 匹配）
    pub fn is_read(&self, link: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssReadRecords WHERE record = ?1",
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
    pub fn list_records(&self, limit: Option<i32>) -> LegadoResult<Vec<RssReadRecordRow>> {
        let limit = limit.unwrap_or(100);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, title, record, readTime FROM rssReadRecords
                 ORDER BY readTime DESC LIMIT ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![limit], |row| {
                let record: String = row.get(2)?;
                Ok(RssReadRecordRow {
                    origin: row.get(0)?,
                    title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    link: if record.is_empty() {
                        None
                    } else {
                        Some(record)
                    },
                    read_time: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询已读记录失败: {e}")))?;
        let records = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("Row mapping failed: {e}")))?;
        Ok(records)
    }

    /// 按 origin 获取已读记录（按 readTime 降序，对齐原版 getRecordsByOrigin）
    pub fn list_records_by_origin(
        &self,
        origin: &str,
        limit: Option<i32>,
    ) -> LegadoResult<Vec<RssReadRecordRow>> {
        let limit = limit.unwrap_or(100);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, title, record, readTime FROM rssReadRecords
                 WHERE origin = ?1 ORDER BY readTime DESC LIMIT ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![origin, limit], |row| {
                let record: String = row.get(2)?;
                Ok(RssReadRecordRow {
                    origin: row.get(0)?,
                    title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    link: if record.is_empty() {
                        None
                    } else {
                        Some(record)
                    },
                    read_time: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询已读记录失败: {e}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("Row mapping failed: {e}")))
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
        assert!(repo.is_read("legacy:https://rss.com:NoLink").unwrap());
    }

    #[test]
    fn test_list_records() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        let records = repo.list_records(None).unwrap();
        assert!(records.is_empty());

        for i in 0..5 {
            repo.mark_read(
                "https://rss.com",
                &format!("Title{i}"),
                Some(&format!("link{i}")),
            )
            .unwrap();
        }

        let records = repo.list_records(None).unwrap();
        assert_eq!(records.len(), 5);

        let records = repo.list_records(Some(3)).unwrap();
        assert_eq!(records.len(), 3);

        let first = &records[0];
        assert_eq!(first.origin, "https://rss.com");
        assert!(first.link.is_some());
        assert!(first.read_time > 0);
    }

    #[test]
    fn test_list_records_by_origin() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        repo.mark_read("https://a.com", "A1", Some("l1")).unwrap();
        repo.mark_read("https://b.com", "B1", Some("l2")).unwrap();
        repo.mark_read("https://a.com", "A2", Some("l3")).unwrap();

        let a_records = repo.list_records_by_origin("https://a.com", None).unwrap();
        assert_eq!(a_records.len(), 2);
        assert!(a_records.iter().all(|r| r.origin == "https://a.com"));

        let b_records = repo.list_records_by_origin("https://b.com", None).unwrap();
        assert_eq!(b_records.len(), 1);
        assert_eq!(b_records[0].title, "B1");
    }
}
