//! 阅读统计模块

use serde::{Deserialize, Serialize};

/// 阅读会话
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingSession {
    pub id: i64,
    pub book_url: String,
    pub chapter_index: i32,
    pub chapter_name: Option<String>,
    pub start_time: i64, // Unix 毫秒时间戳
    pub end_time: Option<i64>,
    pub word_count: i32,    // 本次阅读字数
    pub reading_speed: f64, // 字/分钟
}

/// 累计阅读统计
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingStats {
    pub book_url: String,
    pub total_reading_time_ms: i64, // 总阅读时长
    pub total_word_count: i64,      // 总阅读字数
    pub session_count: i32,         // 阅读次数
    pub average_speed: f64,         // 平均阅读速度
    pub last_read_time: i64,        // 最后阅读时间
    pub daily_reading_days: i32,    // 累计阅读天数
}

/// 每日阅读摘要
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyReadingSummary {
    pub date: String, // YYYY-MM-DD
    pub total_time_ms: i64,
    pub total_words: i64,
    pub session_count: i32,
    pub books_read: Vec<String>, // 当天阅读的书籍 URL 列表
}

/// 阅读统计计算器
pub struct ReadingStatsCalculator;

impl ReadingStatsCalculator {
    /// 计算阅读速度（字/分钟）
    ///
    /// - `word_count`: 阅读字数
    /// - `duration_ms`: 时长（毫秒）
    ///
    /// 若 `duration_ms <= 0` 则返回 `0.0`。
    pub fn calculate_speed(word_count: i32, duration_ms: i64) -> f64 {
        if duration_ms <= 0 {
            return 0.0;
        }
        (word_count as f64) / (duration_ms as f64 / 60_000.0)
    }

    /// 合并会话统计，生成指定书籍的累计统计。
    ///
    /// 仅统计 `book_url` 匹配的会话；若没有匹配会话则返回空统计。
    pub fn aggregate_sessions(sessions: &[ReadingSession], book_url: &str) -> ReadingStats {
        let filtered: Vec<&ReadingSession> =
            sessions.iter().filter(|s| s.book_url == book_url).collect();

        if filtered.is_empty() {
            return ReadingStats {
                book_url: book_url.to_string(),
                total_reading_time_ms: 0,
                total_word_count: 0,
                session_count: 0,
                average_speed: 0.0,
                last_read_time: 0,
                daily_reading_days: 0,
            };
        }

        let total_reading_time_ms: i64 = filtered
            .iter()
            .map(|s| s.end_time.map(|e| (e - s.start_time).max(0)).unwrap_or(0))
            .sum();

        let total_word_count: i64 = filtered.iter().map(|s| s.word_count as i64).sum();
        let session_count = filtered.len() as i32;

        let average_speed = if total_reading_time_ms > 0 {
            (total_word_count as f64) / (total_reading_time_ms as f64 / 60_000.0)
        } else {
            0.0
        };

        let last_read_time = filtered
            .iter()
            .map(|s| s.end_time.unwrap_or(s.start_time))
            .max()
            .unwrap_or(0);

        // 计算独立阅读天数（按 start_time 的日期去重）
        let mut days: Vec<String> = filtered
            .iter()
            .map(|s| millis_to_date(s.start_time))
            .collect();
        days.sort();
        days.dedup();
        let daily_reading_days = days.len() as i32;

        ReadingStats {
            book_url: book_url.to_string(),
            total_reading_time_ms,
            total_word_count,
            session_count,
            average_speed,
            last_read_time,
            daily_reading_days,
        }
    }

    /// 生成指定日期的每日摘要。
    ///
    /// `date` 格式为 `YYYY-MM-DD`；仅包含该日期内的会话。
    pub fn daily_summary(sessions: &[ReadingSession], date: &str) -> DailyReadingSummary {
        let filtered: Vec<&ReadingSession> = sessions
            .iter()
            .filter(|s| millis_to_date(s.start_time) == date)
            .collect();

        let total_time_ms: i64 = filtered
            .iter()
            .map(|s| s.end_time.map(|e| (e - s.start_time).max(0)).unwrap_or(0))
            .sum();

        let total_words: i64 = filtered.iter().map(|s| s.word_count as i64).sum();
        let session_count = filtered.len() as i32;

        let mut books_read: Vec<String> = filtered.iter().map(|s| s.book_url.clone()).collect();
        books_read.sort();
        books_read.dedup();

        DailyReadingSummary {
            date: date.to_string(),
            total_time_ms,
            total_words,
            session_count,
            books_read,
        }
    }
}

/// 将毫秒时间戳转换为 `YYYY-MM-DD` 字符串（UTC）。
fn millis_to_date(millis: i64) -> String {
    // 简单 UTC 日期计算，不引入额外依赖
    let secs = millis / 1000;
    let days_since_epoch = secs / 86400;
    // 使用 civil_from_days 算法（Howard Hinnant）
    let (y, m, d) = civil_from_days(days_since_epoch);
    format!("{:04}-{:02}-{:02}", y, m, d)
}

/// Howard Hinnant 的 civil_from_days 算法，将 Unix 天数转为 (year, month, day)。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_session(
        id: i64,
        book_url: &str,
        start: i64,
        end: Option<i64>,
        word_count: i32,
    ) -> ReadingSession {
        let duration = end.map(|e| e - start).unwrap_or(0);
        let speed = ReadingStatsCalculator::calculate_speed(word_count, duration);
        ReadingSession {
            id,
            book_url: book_url.to_string(),
            chapter_index: 0,
            chapter_name: None,
            start_time: start,
            end_time: end,
            word_count,
            reading_speed: speed,
        }
    }

    // 2024-01-15 00:00:00 UTC in millis
    const DAY1: i64 = 1705276800000;
    // 2024-01-16 00:00:00 UTC in millis
    const DAY2: i64 = 1705363200000;

    #[test]
    fn test_calculate_speed_normal() {
        // 300 words in 60_000 ms (1 minute) → 300 wpm
        let speed = ReadingStatsCalculator::calculate_speed(300, 60_000);
        assert!((speed - 300.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_calculate_speed_zero_duration() {
        assert_eq!(ReadingStatsCalculator::calculate_speed(100, 0), 0.0);
        assert_eq!(ReadingStatsCalculator::calculate_speed(100, -1), 0.0);
    }

    #[test]
    fn test_calculate_speed_partial_minute() {
        // 100 words in 30_000 ms (0.5 min) → 200 wpm
        let speed = ReadingStatsCalculator::calculate_speed(100, 30_000);
        assert!((speed - 200.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_aggregate_sessions_empty() {
        let stats = ReadingStatsCalculator::aggregate_sessions(&[], "book1");
        assert_eq!(stats.session_count, 0);
        assert_eq!(stats.total_word_count, 0);
    }

    #[test]
    fn test_aggregate_sessions_filters_by_book() {
        let sessions = vec![
            make_session(1, "book1", DAY1, Some(DAY1 + 60_000), 100),
            make_session(2, "book2", DAY1, Some(DAY1 + 60_000), 200),
            make_session(3, "book1", DAY2, Some(DAY2 + 120_000), 150),
        ];
        let stats = ReadingStatsCalculator::aggregate_sessions(&sessions, "book1");
        assert_eq!(stats.session_count, 2);
        assert_eq!(stats.total_word_count, 250);
        assert_eq!(stats.total_reading_time_ms, 180_000);
        assert_eq!(stats.daily_reading_days, 2);
    }

    #[test]
    fn test_aggregate_sessions_last_read_time() {
        let sessions = vec![
            make_session(1, "book1", DAY1, Some(DAY1 + 60_000), 100),
            make_session(2, "book1", DAY2, Some(DAY2 + 30_000), 50),
        ];
        let stats = ReadingStatsCalculator::aggregate_sessions(&sessions, "book1");
        assert_eq!(stats.last_read_time, DAY2 + 30_000);
    }

    #[test]
    fn test_daily_summary_correct() {
        let sessions = vec![
            make_session(1, "book1", DAY1, Some(DAY1 + 60_000), 100),
            make_session(2, "book1", DAY1 + 3_600_000, Some(DAY1 + 3_660_000), 80),
            make_session(3, "book2", DAY1, Some(DAY1 + 30_000), 50),
            make_session(4, "book1", DAY2, Some(DAY2 + 60_000), 120),
        ];
        let summary = ReadingStatsCalculator::daily_summary(&sessions, "2024-01-15");
        assert_eq!(summary.session_count, 3);
        assert_eq!(summary.total_words, 230);
        assert_eq!(summary.books_read.len(), 2);
        assert!(summary.books_read.contains(&"book1".to_string()));
        assert!(summary.books_read.contains(&"book2".to_string()));
    }

    #[test]
    fn test_daily_summary_no_sessions() {
        let summary = ReadingStatsCalculator::daily_summary(&[], "2024-01-15");
        assert_eq!(summary.session_count, 0);
        assert_eq!(summary.total_words, 0);
        assert!(summary.books_read.is_empty());
    }

    #[test]
    fn test_millis_to_date() {
        assert_eq!(millis_to_date(DAY1), "2024-01-15");
        assert_eq!(millis_to_date(DAY2), "2024-01-16");
        assert_eq!(millis_to_date(0), "1970-01-01");
    }

    #[test]
    fn test_aggregate_average_speed() {
        let sessions = vec![
            make_session(1, "book1", DAY1, Some(DAY1 + 60_000), 300), // 1 min, 300 words
        ];
        let stats = ReadingStatsCalculator::aggregate_sessions(&sessions, "book1");
        // 300 words / 1 min = 300 wpm
        assert!((stats.average_speed - 300.0).abs() < 0.01);
    }
}
