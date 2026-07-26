//! ReadingStats Repository - reading_sessions 表 CRUD

use rusqlite::{params, Connection};

use legado_core::reading_stats::{
    DailyReadingSummary, ReadingSession, ReadingStats, ReadingStatsCalculator,
};
use legado_core::{LegadoError, LegadoResult};

/// 阅读统计数据访问层
pub struct ReadingStatsRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReadingStatsRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条阅读会话，返回新插入行的 rowid
    pub fn insert_session(&self, session: &ReadingSession) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO reading_sessions
                 (book_url, chapter_index, chapter_name, start_time, end_time, word_count, reading_speed)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    session.book_url,
                    session.chapter_index,
                    session.chapter_name,
                    session.start_time,
                    session.end_time,
                    session.word_count,
                    session.reading_speed,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入阅读会话失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 按书籍 URL 查询所有阅读会话
    pub fn get_sessions_by_book(&self, book_url: &str) -> LegadoResult<Vec<ReadingSession>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, chapter_name, start_time, end_time,
                        word_count, reading_speed
                 FROM reading_sessions
                 WHERE book_url = ?1
                 ORDER BY start_time ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![book_url], row_to_session)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按时间范围查询阅读会话（start_time 在 [start, end] 区间内）
    pub fn get_sessions_by_date_range(
        &self,
        start: i64,
        end: i64,
    ) -> LegadoResult<Vec<ReadingSession>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, chapter_name, start_time, end_time,
                        word_count, reading_speed
                 FROM reading_sessions
                 WHERE start_time >= ?1 AND start_time <= ?2
                 ORDER BY start_time ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![start, end], row_to_session)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取指定书籍的累计阅读统计
    pub fn get_stats_by_book(&self, book_url: &str) -> LegadoResult<ReadingStats> {
        let sessions = self.get_sessions_by_book(book_url)?;
        Ok(ReadingStatsCalculator::aggregate_sessions(
            &sessions, book_url,
        ))
    }

    /// 获取最近 N 天的每日阅读摘要（按 start_time 降序，取最近 days 天的数据）
    pub fn get_daily_summaries(&self, days: i32) -> LegadoResult<Vec<DailyReadingSummary>> {
        // 获取所有会话，然后按日期分组生成摘要
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, book_url, chapter_index, chapter_name, start_time, end_time,
                        word_count, reading_speed
                 FROM reading_sessions
                 ORDER BY start_time DESC
                 LIMIT 10000",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let all_sessions: Vec<ReadingSession> = stmt
            .query_map([], row_to_session)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();

        // 按日期分组
        let mut date_map: std::collections::BTreeMap<String, Vec<ReadingSession>> =
            std::collections::BTreeMap::new();
        for session in all_sessions {
            let date = millis_to_date(session.start_time);
            date_map.entry(date).or_default().push(session);
        }

        // 取最近 days 天（BTreeMap 按 key 升序，取最后 N 个）
        let summaries: Vec<DailyReadingSummary> = date_map
            .iter()
            .rev()
            .take(days as usize)
            .map(|(date, sessions)| ReadingStatsCalculator::daily_summary(sessions, date))
            .collect();

        Ok(summaries)
    }

    /// 删除指定时间戳之前的所有阅读会话，返回删除的行数
    pub fn delete_old_sessions(&self, before: i64) -> LegadoResult<usize> {
        let count = self
            .conn
            .execute(
                "DELETE FROM reading_sessions WHERE start_time < ?1",
                params![before],
            )
            .map_err(|e| LegadoError::Database(format!("删除旧会话失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<ReadingSession> {
    Ok(ReadingSession {
        id: row.get(0)?,
        book_url: row.get(1)?,
        chapter_index: row.get(2)?,
        chapter_name: row.get(3)?,
        start_time: row.get(4)?,
        end_time: row.get(5)?,
        word_count: row.get(6)?,
        reading_speed: row.get(7)?,
    })
}

/// 将毫秒时间戳转换为 `YYYY-MM-DD` 字符串（UTC）
fn millis_to_date(millis: i64) -> String {
    let secs = millis / 1000;
    let days_since_epoch = secs / 86400;
    let (y, m, d) = civil_from_days(days_since_epoch);
    format!("{:04}-{:02}-{:02}", y, m, d)
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::reading_stats::ReadingStatsCalculator;

    /// 2024-01-15 00:00:00 UTC in millis
    const DAY1: i64 = 1705276800000;
    /// 2024-01-16 00:00:00 UTC in millis
    const DAY2: i64 = 1705363200000;

    fn make_session(
        book_url: &str,
        start: i64,
        end: Option<i64>,
        word_count: i32,
    ) -> ReadingSession {
        let duration = end.map(|e| e - start).unwrap_or(0);
        let speed = ReadingStatsCalculator::calculate_speed(word_count, duration);
        ReadingSession {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: 0,
            chapter_name: Some("第一章".to_string()),
            start_time: start,
            end_time: end,
            word_count,
            reading_speed: speed,
        }
    }

    #[test]
    fn test_insert_and_get_sessions_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        let session = make_session("book1", DAY1, Some(DAY1 + 60_000), 300);
        let id = repo.insert_session(&session).unwrap();
        assert!(id > 0);

        let sessions = repo.get_sessions_by_book("book1").unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].book_url, "book1");
        assert_eq!(sessions[0].word_count, 300);
        assert_eq!(sessions[0].chapter_name.as_deref(), Some("第一章"));
    }

    #[test]
    fn test_get_sessions_by_book_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());
        let sessions = repo.get_sessions_by_book("nonexistent").unwrap();
        assert!(sessions.is_empty());
    }

    #[test]
    fn test_get_sessions_by_date_range() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        repo.insert_session(&make_session("book1", DAY1, Some(DAY1 + 60_000), 100))
            .unwrap();
        repo.insert_session(&make_session("book1", DAY2, Some(DAY2 + 60_000), 200))
            .unwrap();
        // 超出范围
        repo.insert_session(&make_session(
            "book1",
            DAY2 + 86_400_000,
            Some(DAY2 + 86_400_000 + 60_000),
            300,
        ))
        .unwrap();

        let sessions = repo.get_sessions_by_date_range(DAY1, DAY2 + 1).unwrap();
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn test_get_stats_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        repo.insert_session(&make_session("book1", DAY1, Some(DAY1 + 60_000), 300))
            .unwrap();
        repo.insert_session(&make_session("book1", DAY2, Some(DAY2 + 120_000), 400))
            .unwrap();
        // 另一本书的数据，不应影响 book1 的统计
        repo.insert_session(&make_session("book2", DAY1, Some(DAY1 + 60_000), 999))
            .unwrap();

        let stats = repo.get_stats_by_book("book1").unwrap();
        assert_eq!(stats.session_count, 2);
        assert_eq!(stats.total_word_count, 700);
        assert_eq!(stats.total_reading_time_ms, 180_000);
        assert_eq!(stats.daily_reading_days, 2);
    }

    #[test]
    fn test_delete_old_sessions() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        repo.insert_session(&make_session("book1", DAY1, Some(DAY1 + 60_000), 100))
            .unwrap();
        repo.insert_session(&make_session("book1", DAY2, Some(DAY2 + 60_000), 200))
            .unwrap();

        // 删除 DAY2 之前的会话
        let deleted = repo.delete_old_sessions(DAY2).unwrap();
        assert_eq!(deleted, 1);

        let remaining = repo.get_sessions_by_book("book1").unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].word_count, 200);
    }

    #[test]
    fn test_get_daily_summaries() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        repo.insert_session(&make_session("book1", DAY1, Some(DAY1 + 60_000), 100))
            .unwrap();
        repo.insert_session(&make_session("book2", DAY1, Some(DAY1 + 30_000), 50))
            .unwrap();
        repo.insert_session(&make_session("book1", DAY2, Some(DAY2 + 60_000), 200))
            .unwrap();

        let summaries = repo.get_daily_summaries(7).unwrap();
        assert_eq!(summaries.len(), 2);
        // summaries 按时间倒序，第一天是 DAY2
        assert_eq!(summaries[0].date, "2024-01-16");
        assert_eq!(summaries[0].session_count, 1);
        assert_eq!(summaries[1].date, "2024-01-15");
        assert_eq!(summaries[1].session_count, 2);
        assert_eq!(summaries[1].books_read.len(), 2);
    }

    #[test]
    fn test_insert_multiple_and_count() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReadingStatsRepository::new(db.connection());

        for i in 0..5 {
            repo.insert_session(&make_session(
                "book1",
                DAY1 + i * 3_600_000,
                Some(DAY1 + i * 3_600_000 + 60_000),
                100,
            ))
            .unwrap();
        }

        let sessions = repo.get_sessions_by_book("book1").unwrap();
        assert_eq!(sessions.len(), 5);

        let stats = repo.get_stats_by_book("book1").unwrap();
        assert_eq!(stats.session_count, 5);
        assert_eq!(stats.total_word_count, 500);
    }
}
