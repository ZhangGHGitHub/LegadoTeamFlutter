//! 时间工具 API
//!
//! 提供时间处理函数，对应 Kotlin 端 `JsExtensions` 中的时间方法：
//! - formatTime — 时间戳格式化
//! - currentTimeMillis — 当前毫秒时间
//! - parseTime — 解析时间字符串
//! - timeFormatUTC — UTC 时区格式化

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_time_utils {
    use chrono::{DateTime, Local, NaiveDateTime, Utc};

    /// 默认时间格式（对应 Kotlin dateFormat）
    pub const DEFAULT_FORMAT: &str = "%Y-%m-%d %H:%M:%S";

    /// 将毫秒时间戳格式化为本地时间字符串
    ///
    /// 对应 Kotlin: `timeFormat(time: Long)`
    pub fn format_time(timestamp_ms: i64, format: Option<&str>) -> Result<String, String> {
        let fmt = format.unwrap_or(DEFAULT_FORMAT);
        let secs = timestamp_ms / 1000;
        let nanos = ((timestamp_ms % 1000) * 1_000_000) as u32;
        let dt =
            DateTime::from_timestamp(secs, nanos).ok_or_else(|| "Invalid timestamp".to_string())?;
        let local_dt = dt.with_timezone(&Local);
        Ok(local_dt.format(fmt).to_string())
    }

    /// 将毫秒时间戳格式化为 UTC 时间字符串
    ///
    /// 对应 Kotlin: `timeFormatUTC(time, format, sh)`
    /// - `offset_seconds` 为时区偏移秒数
    pub fn format_time_utc(
        timestamp_ms: i64,
        format: Option<&str>,
        offset_seconds: i32,
    ) -> Result<String, String> {
        let fmt = format.unwrap_or(DEFAULT_FORMAT);
        let secs = timestamp_ms / 1000;
        let nanos = ((timestamp_ms % 1000) * 1_000_000) as u32;
        let dt =
            DateTime::from_timestamp(secs, nanos).ok_or_else(|| "Invalid timestamp".to_string())?;
        let naive = dt.naive_utc() + chrono::Duration::seconds(offset_seconds as i64);
        Ok(naive.format(fmt).to_string())
    }

    /// 获取当前毫秒时间戳
    ///
    /// 对应 Kotlin: `System.currentTimeMillis()`
    pub fn current_time_millis() -> i64 {
        Utc::now().timestamp_millis()
    }

    /// 解析时间字符串为毫秒时间戳
    ///
    /// 对应 Kotlin: `SimpleDateFormat.parse(str).time`
    pub fn parse_time(time_str: &str, format: Option<&str>) -> Result<i64, String> {
        let fmt = format.unwrap_or(DEFAULT_FORMAT);
        let naive = NaiveDateTime::parse_from_str(time_str, fmt)
            .map_err(|e| format!("Time parse error: {}", e))?;
        Ok(naive.and_utc().timestamp_millis())
    }

    /// 计算两个时间戳之间的差值（毫秒）
    pub fn time_diff_ms(start_ms: i64, end_ms: i64) -> i64 {
        end_ms - start_ms
    }
}

#[cfg(feature = "quickjs")]
pub use impl_time_utils::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_time_utils {
    fn not_available() -> String {
        "time_utils not available: build with --features quickjs".to_string()
    }

    pub const DEFAULT_FORMAT: &str = "%Y-%m-%d %H:%M:%S";

    pub fn format_time(_timestamp_ms: i64, _format: Option<&str>) -> Result<String, String> {
        Err(not_available())
    }
    pub fn format_time_utc(
        _timestamp_ms: i64,
        _format: Option<&str>,
        _offset_seconds: i32,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn current_time_millis() -> i64 {
        0
    }
    pub fn parse_time(_time_str: &str, _format: Option<&str>) -> Result<i64, String> {
        Err(not_available())
    }
    pub fn time_diff_ms(_start_ms: i64, _end_ms: i64) -> i64 {
        0
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_time_utils::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    #[test]
    fn test_format_time_default() {
        // 2024-01-01 00:00:00 UTC = 1704067200000 ms
        let result = format_time_utc(1704067200000, None, 0).unwrap();
        assert_eq!(result, "2024-01-01 00:00:00");
    }

    #[test]
    fn test_format_time_custom_format() {
        let result = format_time_utc(1704067200000, Some("%Y-%m-%d"), 0).unwrap();
        assert_eq!(result, "2024-01-01");
    }

    #[test]
    fn test_format_time_with_offset() {
        // +8 hours (CST)
        let result = format_time_utc(1704067200000, Some("%Y-%m-%d %H:%M:%S"), 8 * 3600).unwrap();
        assert_eq!(result, "2024-01-01 08:00:00");
    }

    #[test]
    fn test_current_time_millis_positive() {
        let now = current_time_millis();
        assert!(now > 0);
    }

    #[test]
    fn test_parse_time_basic() {
        let ts = parse_time("2024-01-01 00:00:00", None).unwrap();
        // Should be 1704067200000 in UTC
        assert_eq!(ts, 1704067200000);
    }

    #[test]
    fn test_parse_time_invalid() {
        assert!(parse_time("not-a-date", None).is_err());
    }

    #[test]
    fn test_time_diff_ms() {
        assert_eq!(time_diff_ms(1000, 5000), 4000);
    }

    #[test]
    fn test_format_time_invalid_timestamp() {
        // Extremely large value that overflows
        let result = format_time(i64::MAX, None);
        assert!(result.is_err());
    }
}
