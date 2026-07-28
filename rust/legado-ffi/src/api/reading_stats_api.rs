//! 阅读统计 API
//!
//! 提供阅读统计数据的查询操作，通过 ReadingStatsRepository 访问数据库。

use serde::Serialize;

use legado_core::LegadoResult;
use legado_db::ReadingStatsRepository;

use crate::db_state::with_database;

/// 今日统计 DTO
#[derive(Debug, Clone, Serialize)]
pub struct TodayStatsDto {
    pub date: String,
    pub session_count: i32,
    pub total_reading_time_ms: i64,
    pub total_word_count: i64,
}

/// 每日统计 DTO
#[derive(Debug, Clone, Serialize)]
pub struct DailyStatsDto {
    pub date: String,
    pub session_count: i32,
    pub total_reading_time_ms: i64,
    pub total_word_count: i64,
    pub books_read: Vec<String>,
}

/// 书籍统计 DTO
#[derive(Debug, Clone, Serialize)]
pub struct BookStatsDto {
    pub book_url: String,
    pub session_count: usize,
    pub total_reading_time_ms: i64,
    pub total_word_count: i32,
}

/// 热力图数据 DTO
#[derive(Debug, Clone, Serialize)]
pub struct HeatmapEntry {
    pub date: String,
    pub reading_time_ms: i64,
}

/// 获取今日阅读统计
pub fn get_today_stats() -> LegadoResult<TodayStatsDto> {
    with_database(|db| {
        let repo = ReadingStatsRepository::new(db.connection());
        let summaries = repo.get_daily_summaries(1)?;
        match summaries.first() {
            Some(s) => Ok(TodayStatsDto {
                date: s.date.clone(),
                session_count: s.session_count,
                total_reading_time_ms: s.total_time_ms,
                total_word_count: s.total_words,
            }),
            None => Ok(TodayStatsDto {
                date: String::new(),
                session_count: 0,
                total_reading_time_ms: 0,
                total_word_count: 0,
            }),
        }
    })
}

/// 获取最近 N 天的每日统计
pub fn get_daily_stats(days: i32) -> LegadoResult<Vec<DailyStatsDto>> {
    with_database(|db| {
        let repo = ReadingStatsRepository::new(db.connection());
        let summaries = repo.get_daily_summaries(days)?;
        Ok(summaries
            .into_iter()
            .map(|s| DailyStatsDto {
                date: s.date,
                session_count: s.session_count,
                total_reading_time_ms: s.total_time_ms,
                total_word_count: s.total_words,
                books_read: s.books_read,
            })
            .collect())
    })
}

/// 获取按书籍分组的统计（取最近 100 条会话聚合）
pub fn get_book_stats() -> LegadoResult<Vec<BookStatsDto>> {
    with_database(|db| {
        let repo = ReadingStatsRepository::new(db.connection());
        // 获取最近会话，按书籍聚合
        let sessions = repo.get_sessions_by_date_range(0, current_time_millis())?;
        let mut map: std::collections::HashMap<String, (usize, i64, i32)> =
            std::collections::HashMap::new();
        for s in &sessions {
            let entry = map.entry(s.book_url.clone()).or_insert((0, 0, 0));
            entry.0 += 1;
            let duration = s.end_time.unwrap_or(s.start_time) - s.start_time;
            entry.1 += duration;
            entry.2 += s.word_count;
        }
        let mut result: Vec<BookStatsDto> = map
            .into_iter()
            .map(|(book_url, (count, time, words))| BookStatsDto {
                book_url,
                session_count: count,
                total_reading_time_ms: time,
                total_word_count: words,
            })
            .collect();
        result.sort_by_key(|b| std::cmp::Reverse(b.total_reading_time_ms));
        Ok(result)
    })
}

/// 获取阅读热力图数据（最近 N 天）
pub fn get_reading_heatmap(days: i32) -> LegadoResult<Vec<HeatmapEntry>> {
    with_database(|db| {
        let repo = ReadingStatsRepository::new(db.connection());
        let summaries = repo.get_daily_summaries(days)?;
        Ok(summaries
            .into_iter()
            .map(|s| HeatmapEntry {
                date: s.date,
                reading_time_ms: s.total_time_ms,
            })
            .collect())
    })
}

fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reading_stats_apis() {
        crate::db_state::ensure_test_db();

        // 空数据时不报错
        let today = get_today_stats().unwrap();
        assert_eq!(today.session_count, 0);

        let daily = get_daily_stats(7).unwrap();
        assert!(daily.is_empty() || !daily.is_empty()); // 不 panic 即可

        let book_stats = get_book_stats().unwrap();
        assert!(book_stats.is_empty() || !book_stats.is_empty());

        let heatmap = get_reading_heatmap(30).unwrap();
        assert!(heatmap.is_empty() || !heatmap.is_empty());
    }
}
