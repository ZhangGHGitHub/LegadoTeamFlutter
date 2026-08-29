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

/// 读取指定书籍的当前阅读时长；无记录时返回 0
pub fn get_read_time(book_name: &str) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        Ok(repo
            .get_record(book_name)?
            .map(|r| r.read_time)
            .unwrap_or(0))
    })
}

/// 添加/更新阅读记录，返回阅读时长；写入 lastRead=当前毫秒（对齐原版 upReadTime）
///
/// [热力图每日时长契约] 同步累加当日阅读时长到 readRecordDaily（热力图"每日时长"数据源）：
/// 增量 = 新 readTime − 旧 readTime，仅增量 > 0 时入账（本地时区日期，YYYY-MM-DD）。
pub fn upsert_read_record(book_name: &str, read_time: i64) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        let existing = repo.get_record(book_name)?;
        let old_read_time = existing.as_ref().map(|r| r.read_time).unwrap_or(0);
        let delta = read_time - old_read_time;
        let last_read = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let (device_id, author) = match existing {
            Some(r) => (r.device_id, r.author),
            None => (String::new(), String::new()),
        };
        repo.upsert_full(&device_id, book_name, &author, read_time, last_read)?;
        if delta > 0 {
            let today = chrono::Local::now().format("%Y-%m-%d").to_string();
            repo.add_daily_seconds(&today, delta)?;
        }
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

    /// [热力图每日时长契约] upsert 增量同步 readRecordDaily（热力图"每日时长"契约）：
    /// 无记录时增量 = 全量；已有时增量 = 差值；get_read_time 如实反映当前值
    #[test]
    fn test_upsert_syncs_daily_duration() {
        let _db_guard = crate::db_state::ensure_test_db();
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let year: i32 = today[..4].parse().unwrap();

        // 无记录 → 增量为全量 5000
        upsert_read_record("每日聚合书", 5000).unwrap();
        assert_eq!(get_read_time("每日聚合书").unwrap(), 5000);
        // 已有 → 增量为差值 3000
        upsert_read_record("每日聚合书", 8000).unwrap();
        assert_eq!(get_read_time("每日聚合书").unwrap(), 8000);

        let rows = with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.list_daily_year(year)
        })
        .unwrap();
        // 共享测试库中其他用例也会向当日累加，只断言本书两次增量（5000+3000）均已入账
        let hit = rows
            .iter()
            .find(|(d, _)| d == &today)
            .expect("当日应有聚合行");
        assert!(hit.1 >= 8000, "当日聚合应 ≥ 8000，实际: {}", hit.1);
        // 查询不存在的书返回 0
        assert_eq!(get_read_time("无此书").unwrap(), 0);
    }
}
