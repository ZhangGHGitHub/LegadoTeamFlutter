//! 阅读记录 API
//!
//! 提供阅读记录的增删查操作，通过 ReadRecordRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::ReadRecordRepository;

use crate::db_state::with_database;

/// 阅读记录 DTO（camelCase 对齐 Flutter `ReadRecord.fromJson`）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadRecordDto {
    pub book_name: String,
    pub read_time: i64,
    pub last_read: i64,
    #[serde(default)]
    pub device_id: String,
}

/// 获取所有阅读记录（按 readTime 降序）
pub fn get_read_records() -> LegadoResult<Vec<ReadRecordDto>> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        let records = repo.find_all()?;
        Ok(records
            .into_iter()
            .map(|r| ReadRecordDto {
                book_name: r.book_name,
                read_time: r.read_time,
                last_read: r.last_read,
                device_id: r.device_id,
            })
            .collect())
    })
}

/// 添加/更新阅读记录，返回阅读时长；写入 lastRead=当前毫秒（对齐原版 upReadTime）
pub fn upsert_read_record(book_name: &str, read_time: i64) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        let last_read = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let (device_id, author) = match repo.get_record(book_name)? {
            Some(r) => (r.device_id, r.author),
            None => (String::new(), String::new()),
        };
        repo.upsert_full(&device_id, book_name, &author, read_time, last_read)?;
        Ok(read_time)
    })
}

/// 删除指定书籍的阅读记录
pub fn delete_read_record(book_name: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        repo.delete_by_book_name(book_name)
    })
}

/// 清空所有阅读记录
pub fn clear_read_records() -> LegadoResult<bool> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        repo.clear_all()?;
        Ok(true)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_read_record_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 添加记录
        let rt = upsert_read_record("测试书籍", 5000).unwrap();
        assert_eq!(rt, 5000);

        // 获取列表
        let records = get_read_records().unwrap();
        assert!(records.iter().any(|r| r.book_name == "测试书籍"));

        // 更新记录
        upsert_read_record("测试书籍", 8000).unwrap();
        let records = get_read_records().unwrap();
        let rec = records.iter().find(|r| r.book_name == "测试书籍").unwrap();
        assert_eq!(rec.read_time, 8000);

        // 删除记录
        assert!(delete_read_record("测试书籍").unwrap());
        let records = get_read_records().unwrap();
        assert!(!records.iter().any(|r| r.book_name == "测试书籍"));
    }
}
