//! RSS 已读记录 API
//!
//! 提供 RSS 文章已读标记的增删查操作，通过 RssReadRecordRepository 访问数据库。

use legado_core::LegadoResult;
use legado_db::{RssReadRecordRepository, RssReadRecordRow};

use crate::db_state::with_database;

/// 标记文章为已读
pub fn mark_read(origin: &str, title: &str, link: Option<&str>) -> LegadoResult<()> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read(origin, title, link)
    })
}

/// 判断文章是否已读（按 link 匹配）
pub fn is_read(link: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.is_read(link)
    })
}

/// 判断文章是否已读（按 origin + title 匹配）
pub fn is_read_by_title(origin: &str, title: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.is_read_by_title(origin, title)
    })
}

/// 清空所有已读记录
pub fn clear_all() -> LegadoResult<()> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.clear_all()
    })
}

/// 获取已读记录总数
pub fn count() -> LegadoResult<i64> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.count()
    })
}

/// 获取已读记录列表（按 readTime 降序）
pub fn list_records(limit: Option<i32>) -> LegadoResult<Vec<RssReadRecordRow>> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.list_records(limit)
    })
}

/// 按 origin 获取已读记录列表（对齐原版 RssReadRecordDao.getRecordsByOrigin）
pub fn list_records_by_origin(
    origin: &str,
    limit: Option<i32>,
) -> LegadoResult<Vec<RssReadRecordRow>> {
    with_database(|db| {
        let repo = RssReadRecordRepository::new(db.connection());
        repo.list_records_by_origin(origin, limit)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rss_read_record_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 标记已读
        mark_read("https://rss.example.com", "Test Article", Some("https://link.com/1")).unwrap();

        // 判断已读
        assert!(is_read("https://link.com/1").unwrap());
        assert!(!is_read("https://link.com/999").unwrap());

        // 按标题判断
        assert!(is_read_by_title("https://rss.example.com", "Test Article").unwrap());
        assert!(!is_read_by_title("https://rss.example.com", "Other").unwrap());

        // 计数
        let c = count().unwrap();
        assert!(c >= 1);

        // 列表
        let records = list_records(Some(10)).unwrap();
        assert!(records.iter().any(|r| r.title == "Test Article"));

        // 按 origin 列表
        mark_read("https://other.com", "Other", Some("https://link.com/2")).unwrap();
        let by_origin = list_records_by_origin("https://rss.example.com", None).unwrap();
        assert!(by_origin.iter().all(|r| r.origin == "https://rss.example.com"));
        assert_eq!(by_origin.len(), 1);

        // 清空
        clear_all().unwrap();
        assert_eq!(count().unwrap(), 0);
    }
}
