//! 阅读记录 API
//!
//! 提供阅读记录的增删查操作，通过 ReadRecordRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::ReadRecordRepository;

use crate::db_state::with_database;

/// 阅读记录 DTO（camelCase 对齐 Flutter `ReadRecord.fromJson`）
///
/// v113（批27）：13 字段对齐原版 `readRecord.json`/Room 实体；主键
/// `(deviceId, bookName, author)`，同名不同作者分行返回。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadRecordDto {
    pub book_name: String,
    pub author: String,
    pub read_time: i64,
    pub last_read: i64,
    #[serde(default)]
    pub device_id: String,
    pub last_chapter_title: Option<String>,
    pub last_chapter_index: i32,
    pub last_chapter_pos: i32,
    pub cover_url: Option<String>,
    pub resolved_author: Option<String>,
    pub display_book_name: String,
    pub display_author: String,
    pub metadata_edited_at: i64,
}

/// 获取所有阅读记录（13 字段，按 readTime 降序）
pub fn get_read_records() -> LegadoResult<Vec<ReadRecordDto>> {
    with_database(|db| {
        let repo = ReadRecordRepository::new(db.connection());
        let records = repo.find_all()?;
        Ok(records
            .into_iter()
            .map(|r| ReadRecordDto {
                book_name: r.book_name,
                author: r.author,
                read_time: r.read_time,
                last_read: r.last_read,
                device_id: r.device_id,
                last_chapter_title: r.last_chapter_title,
                last_chapter_index: r.last_chapter_index,
                last_chapter_pos: r.last_chapter_pos,
                cover_url: r.cover_url,
                resolved_author: r.resolved_author,
                display_book_name: r.display_book_name,
                display_author: r.display_author,
                metadata_edited_at: r.metadata_edited_at,
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
/// 按下限整秒差值入账，仅 > 0 时累加（本地时区日期，YYYY-MM-DD）。
///
/// readTime 单位为毫秒，而 readRecordDaily 契约为秒（readRecordDailyList 返回
/// `[{date, seconds}]`）。取「各自下限整秒再作差」而非「差值再除 1000」：两者对单次
/// 累加等价，但前者不会因频繁的小增量同步被反复截断丢秒，累计值不随调用次数漂移。
pub fn upsert_read_record(
    book_name: &str,
    read_time: i64,
    book_url: Option<&str>,
) -> LegadoResult<i64> {
    with_database(|db| {
        // [批35] 书籍级阅读记录开关守卫（对齐参考版
        // `ReadRecordRepository.saveReadSession` 写前判断）：
        // `book_url` 非空且该书 disableReadRecord=true 时整次跳过，
        // readRecord 与 readRecordDaily 均零写入；书籍不存在按无记录处理
        // （临时书/未落库书不阻断阅读）。Dart 侧另有本地短路，此处是
        // 「详情页切换后阅读器仍持有旧 Book 副本」的第二道保险。
        if let Some(url) = book_url.map(str::trim).filter(|u| !u.is_empty()) {
            let book_repo = legado_db::BookRepository::new(db.connection());
            if book_repo.is_read_record_disabled(url)? {
                return Ok(read_time);
            }
        }
        let repo = ReadRecordRepository::new(db.connection());
        let existing = repo.get_record(book_name)?;
        let old_read_time = existing.as_ref().map(|r| r.read_time).unwrap_or(0);
        let seconds_delta = read_time / 1000 - old_read_time / 1000;
        let last_read = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        let (device_id, author) = match existing {
            Some(r) => (r.device_id, r.author),
            None => (String::new(), String::new()),
        };
        repo.upsert_full(&device_id, book_name, &author, read_time, last_read)?;
        if seconds_delta > 0 {
            let today = chrono::Local::now().format("%Y-%m-%d").to_string();
            repo.add_daily_seconds(&today, seconds_delta)?;
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
    use legado_db::repository::Repository;

    #[test]
    fn test_read_record_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 添加记录
        let rt = upsert_read_record("测试书籍", 5000, None).unwrap();
        assert_eq!(rt, 5000);

        // 获取列表
        let records = get_read_records().unwrap();
        assert!(records.iter().any(|r| r.book_name == "测试书籍"));

        // 更新记录
        upsert_read_record("测试书籍", 8000, None).unwrap();
        let records = get_read_records().unwrap();
        let rec = records.iter().find(|r| r.book_name == "测试书籍").unwrap();
        assert_eq!(rec.read_time, 8000);

        // 删除记录
        assert!(delete_read_record("测试书籍").unwrap());
        let records = get_read_records().unwrap();
        assert!(!records.iter().any(|r| r.book_name == "测试书籍"));
    }

    /// [热力图每日时长契约] upsert 增量同步 readRecordDaily（热力图"每日时长"契约）：
    /// 无记录时增量 = 全量；已有时增量 = 差值；get_read_time 如实反映当前值。
    /// 单位口径（2026-09-11 修复）：readTime 为毫秒、readRecordDaily 契约为秒，
    /// 入账值按整秒差值折算（5000ms → 5s，3000ms 增量 → +3s）。
    #[test]
    fn test_upsert_syncs_daily_duration() {
        let _db_guard = crate::db_state::ensure_test_db();
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let year: i32 = today[..4].parse().unwrap();

        let before = daily_seconds_today(&today, year);

        // 无记录 → 增量为全量 5000ms = 5s
        upsert_read_record("每日聚合书", 5000, None).unwrap();
        assert_eq!(get_read_time("每日聚合书").unwrap(), 5000);
        // 已有 → 增量为差值 3000ms = 3s
        upsert_read_record("每日聚合书", 8000, None).unwrap();
        assert_eq!(get_read_time("每日聚合书").unwrap(), 8000);

        // 共享测试库中其他用例也会向当日累加，只断言本书两次增量（5s+3s=8s）均已入账
        let after = daily_seconds_today(&today, year);
        assert_eq!(
            after - before,
            8,
            "当日聚合应恰增 8 秒（5000ms+3000ms），实际增量: {}",
            after - before
        );
        // 查询不存在的书返回 0
        assert_eq!(get_read_time("无此书").unwrap(), 0);
    }

    /// [批27b P1-1 | 2026-10-28] 同名不同作者：写路径只以「主记录」旧值算每日增量
    ///
    /// 两行同名书：主记录 P（`author=''`，readTime=100_000ms）与另一作者 S
    /// （readTime=900_000ms）。upsert 传入主记录口径的新时长 160_000ms 后：
    /// - 主记录 readTime = 160_000（不吸收 S 的 900_000）；
    /// - S 行原样保留（写路径只碰主记录）；
    /// - readRecordDaily 仅 +60 秒（160_000/1000 − 100_000/1000）。
    ///
    /// Dart 侧会话基数必须同口径（`reader_notifier._primaryReadRecord`）：
    /// 若基数改为两行求和（旧实现），本用例的 900_000ms 会在每次会话被重复
    /// 叠加进主记录（红→绿回归锚点）。
    #[test]
    fn test_upsert_uses_primary_row_for_daily_delta() {
        let _db_guard = crate::db_state::ensure_test_db();
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let year: i32 = today[..4].parse().unwrap();
        let book = "主记录口径书";

        with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.upsert_full("", book, "", 100_000, 10)?;
            repo.upsert_full("", book, "另一作者", 900_000, 99)?;
            Ok(())
        })
        .unwrap();

        let before = daily_seconds_today(&today, year);
        upsert_read_record(book, 160_000, None).unwrap();
        let after = daily_seconds_today(&today, year);

        assert_eq!(
            after - before,
            60,
            "每日增量应只按主记录差值（160s−100s），实际增量: {}",
            after - before
        );

        let records = get_read_records().unwrap();
        let primary = records
            .iter()
            .find(|r| r.book_name == book && r.author.is_empty())
            .expect("主记录应存在");
        assert_eq!(primary.read_time, 160_000);
        let other = records
            .iter()
            .find(|r| r.book_name == book && r.author == "另一作者")
            .expect("另一作者行应存在");
        assert_eq!(other.read_time, 900_000, "其他作者行不得被写路径覆盖");
    }

    /// 读取当日聚合秒数（无当日行返回 0）
    fn daily_seconds_today(today: &str, year: i32) -> i64 {
        with_database(|db| {
            let repo = ReadRecordRepository::new(db.connection());
            repo.list_daily_year(year)
        })
        .unwrap()
        .iter()
        .find(|(d, _)| d == today)
        .map(|(_, s)| *s)
        .unwrap_or(0)
    }

    /// [批35] 书级开关为真时写路径整次跳过（readRecord 与每日时长零写入），
    /// 重新开启后恢复写入。
    #[test]
    fn test_upsert_read_record_skips_when_book_disabled() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch35-read-record-guard.example.com/book/1";
        let book_name = "批35阅读记录守卫书";
        let today = chrono::Local::now().format("%Y-%m-%d").to_string();
        let year = chrono::Local::now()
            .format("%Y")
            .to_string()
            .parse::<i32>()
            .unwrap();

        with_database(|db| {
            let repo = legado_db::BookRepository::new(db.connection());
            let _ = repo.delete_by_url(book_url);
            repo.insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                name: book_name.to_string(),
                origin: "https://batch35.example.com".to_string(),
                ..legado_core::models::Book::default()
            })
        })
        .expect("测试书入库失败");
        let _ = delete_read_record(book_name);

        let _ =
            crate::api::bookshelf::set_read_record_disabled(book_url, true).expect("开关置真失败");
        let before = daily_seconds_today(&today, year);
        let returned = upsert_read_record(book_name, 90_000, Some(book_url)).unwrap();
        assert_eq!(returned, 90_000, "跳过写入时返回传入 readTime");
        assert!(
            !get_read_records()
                .unwrap()
                .iter()
                .any(|r| r.book_name == book_name),
            "关闭后不得创建阅读记录"
        );
        assert_eq!(
            daily_seconds_today(&today, year),
            before,
            "关闭后不得累加每日阅读时长"
        );

        let _ =
            crate::api::bookshelf::set_read_record_disabled(book_url, false).expect("开关置假失败");
        upsert_read_record(book_name, 90_000, Some(book_url)).unwrap();
        assert!(
            get_read_records()
                .unwrap()
                .iter()
                .any(|r| r.book_name == book_name),
            "重新开启后应恢复写入"
        );

        // 清理（共享测试库不留固定行）
        let _ = delete_read_record(book_name);
        with_database(|db| {
            let _ = legado_db::BookRepository::new(db.connection()).delete_by_url(book_url);
            Ok(())
        })
        .ok();
    }
}
