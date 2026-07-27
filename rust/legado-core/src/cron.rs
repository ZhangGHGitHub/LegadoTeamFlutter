//! 完整 Cron 表达式解析
//! 移植自 Kotlin CronSchedule.kt (136行)
//!
//! 支持标准 5 段 cron 格式：`分 时 日 月 周`
//! - `*` 全部值
//! - `*/N` 步长
//! - `N-M` 范围
//! - `N-M/S` 范围步长
//! - `N,M,O` 列表
//! - `N/S` 单值步长（从 N 到 max）
//! - 周日可用 0 或 7 表示
//! - 日/周 OR 语义（当两者都不以 `*` 开头时）

use std::collections::BTreeSet;

/// 最大扫描天数（8年，覆盖闰年周期）
const MAX_DAYS: i64 = 8 * 366;

/// Cron 表达式
#[derive(Debug, Clone)]
pub struct CronExpression {
    /// 分钟 0-59
    pub minutes: BTreeSet<u32>,
    /// 小时 0-23
    pub hours: BTreeSet<u32>,
    /// 日 1-31
    pub days_of_month: BTreeSet<u32>,
    /// 月 1-12
    pub months: BTreeSet<u32>,
    /// 周几 0-6 (0=Sunday)
    pub days_of_week: BTreeSet<u32>,
    /// 日字段是否以 * 开头
    dom_starts_with_star: bool,
    /// 周字段是否以 * 开头
    dow_starts_with_star: bool,
}

impl CronExpression {
    /// 解析 cron 表达式（5段：分 时 日 月 周）
    pub fn parse(expr: &str) -> Result<Self, String> {
        let parts: Vec<&str> = expr.split_whitespace().collect();
        if parts.len() != 5 {
            return Err(format!(
                "Invalid cron expression: expected 5 fields, got {}",
                parts.len()
            ));
        }
        if parts.iter().any(|p| p.is_empty()) {
            return Err("Invalid cron expression: empty field".to_string());
        }

        let minutes = Self::parse_field(parts[0], 0, 59, false)?;
        let hours = Self::parse_field(parts[1], 0, 23, false)?;
        let days_of_month = Self::parse_field(parts[2], 1, 31, false)?;
        let months = Self::parse_field(parts[3], 1, 12, false)?;
        let days_of_week = Self::parse_field(parts[4], 0, 6, true)?;

        Ok(Self {
            dom_starts_with_star: parts[2].starts_with('*'),
            dow_starts_with_star: parts[4].starts_with('*'),
            minutes: minutes.values,
            hours: hours.values,
            days_of_month: days_of_month.values,
            months: months.values,
            days_of_week: days_of_week.values,
        })
    }

    /// 计算下次执行时间（从 from_ms 毫秒时间戳开始）
    ///
    /// 返回下次触发的毫秒时间戳，如果在 MAX_DAYS 内无匹配则返回 None。
    pub fn next_fire_time(&self, from_ms: i64) -> Option<i64> {
        // 对齐到下一分钟整
        let from_secs = from_ms / 1000;
        let threshold = (from_secs / 60 + 1) * 60; // 下一分钟起始

        // 逐日扫描
        let start_days = threshold / 86400;
        for day_offset in 0..MAX_DAYS {
            let day_start_secs = (start_days + day_offset) * 86400;
            if let Some(ts) = self.find_first_on_day(day_start_secs, threshold) {
                return Some(ts * 1000);
            }
        }
        None
    }

    /// 在指定日期查找第一个匹配时间
    fn find_first_on_day(&self, day_start_secs: i64, threshold: i64) -> Option<i64> {
        let (_, month, day, weekday) = Self::decompose_date(day_start_secs);

        // 检查月份
        if !self.months.contains(&month) {
            return None;
        }

        // 检查日/周（OR 语义：当两者都不以 * 开头时用 OR，否则用 AND）
        let dom_match = self.days_of_month.contains(&day);
        let dow_match = self.days_of_week.contains(&weekday);
        let day_matches = if self.dom_starts_with_star || self.dow_starts_with_star {
            dom_match && dow_match
        } else {
            dom_match || dow_match
        };
        if !day_matches {
            return None;
        }

        // 在该日查找第一个匹配的时:分
        for &hour in &self.hours {
            for &minute in &self.minutes {
                let ts = day_start_secs + (hour as i64) * 3600 + (minute as i64) * 60;
                if ts >= threshold {
                    return Some(ts);
                }
            }
        }
        None
    }

    /// 分解 Unix 时间戳为 (year, month, day, weekday)
    /// weekday: 0=Sunday, 1=Monday, ..., 6=Saturday
    fn decompose_date(ts_secs: i64) -> (i64, u32, u32, u32) {
        let days = ts_secs.div_euclid(86400);
        let weekday = ((days + 4) % 7).unsigned_abs() as u32; // 1970-01-01 = Thursday(4)
        let (year, month, day) = Self::days_to_ymd(days);
        (year, month, day, weekday)
    }

    /// Howard Hinnant 算法：从 1970-01-01 起的天数转为 (year, month, day)
    fn days_to_ymd(days: i64) -> (i64, u32, u32) {
        let z = days + 719468;
        let era = if z >= 0 { z } else { z - 146096 } / 146097;
        let doe = (z - era * 146097) as u64;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let y = yoe as i64 + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
        let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
        let y = if m <= 2 { y + 1 } else { y };
        (y, m, d)
    }

    /// 解析单个字段
    fn parse_field(
        field: &str,
        min: u32,
        max: u32,
        map_sunday_to_zero: bool,
    ) -> Result<FieldResult, String> {
        if field.is_empty() || field.contains('?') {
            return Err(format!("Invalid field: '{field}'"));
        }

        let mut values = BTreeSet::new();

        for segment in field.split(',') {
            if segment.is_empty() {
                return Err("Empty segment in field".to_string());
            }

            let step_parts: Vec<&str> = segment.split('/').collect();
            if step_parts.len() > 2 {
                return Err(format!("Invalid segment: '{segment}'"));
            }

            let step: u32 = if step_parts.len() == 1 {
                1
            } else {
                step_parts[1]
                    .parse()
                    .map_err(|_| format!("Invalid step: '{}'", step_parts[1]))?
            };
            if step == 0 {
                return Err("Step must be > 0".to_string());
            }

            let base = step_parts[0];
            let range: Vec<u32> = if base == "*" {
                (min..=max).collect()
            } else if base.contains('-') {
                let bounds: Vec<&str> = base.split('-').collect();
                if bounds.len() != 2 {
                    return Err(format!("Invalid range: '{base}'"));
                }
                let start: u32 = bounds[0]
                    .parse()
                    .map_err(|_| format!("Invalid value: '{}'", bounds[0]))?;
                let end: u32 = bounds[1]
                    .parse()
                    .map_err(|_| format!("Invalid value: '{}'", bounds[1]))?;
                if start < min || end > max || start > end {
                    return Err(format!(
                        "Range out of bounds: {start}-{end} (allowed {min}-{max})"
                    ));
                }
                (start..=end).collect()
            } else {
                let value: u32 = base
                    .parse()
                    .map_err(|_| format!("Invalid value: '{base}'"))?;
                if value < min || value > max {
                    // 特殊处理：周日 7 映射到 0
                    if map_sunday_to_zero && value == 7 {
                        // 允许 7，后面会映射
                    } else {
                        return Err(format!("Value out of range: {value} (allowed {min}-{max})"));
                    }
                }
                if step_parts.len() == 2 {
                    // N/S 表示从 N 到 max 步长 S
                    (value..=max).collect()
                } else {
                    vec![value]
                }
            };

            // 应用步长
            let mut i = 0usize;
            while i < range.len() {
                let mut val = range[i];
                if map_sunday_to_zero && val == 7 {
                    val = 0;
                }
                values.insert(val);
                i += step as usize;
            }
        }

        if values.is_empty() {
            return Err("Field produced no values".to_string());
        }

        Ok(FieldResult { values })
    }
}

/// 字段解析结果
struct FieldResult {
    values: BTreeSet<u32>,
}

/// 便捷函数：检查 cron 是否到期
///
/// 从 last_run_ms 计算下次触发时间，判断 now_ms 是否已到达。
pub fn is_cron_due(cron_expr: &str, last_run_ms: i64, now_ms: i64) -> bool {
    match CronExpression::parse(cron_expr) {
        Ok(cron) => match cron.next_fire_time(last_run_ms) {
            Some(next) => now_ms >= next,
            None => false,
        },
        Err(_) => false,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_every_minute() {
        let cron = CronExpression::parse("* * * * *").unwrap();
        assert_eq!(cron.minutes.len(), 60);
        assert_eq!(cron.hours.len(), 24);
        assert_eq!(cron.days_of_month.len(), 31);
        assert_eq!(cron.months.len(), 12);
        assert_eq!(cron.days_of_week.len(), 7);
    }

    #[test]
    fn test_parse_specific_values() {
        let cron = CronExpression::parse("30 8 * * *").unwrap();
        assert_eq!(cron.minutes.len(), 1);
        assert!(cron.minutes.contains(&30));
        assert_eq!(cron.hours.len(), 1);
        assert!(cron.hours.contains(&8));
    }

    #[test]
    fn test_parse_step() {
        let cron = CronExpression::parse("*/15 * * * *").unwrap();
        assert_eq!(cron.minutes.len(), 4);
        assert!(cron.minutes.contains(&0));
        assert!(cron.minutes.contains(&15));
        assert!(cron.minutes.contains(&30));
        assert!(cron.minutes.contains(&45));
    }

    #[test]
    fn test_parse_range() {
        let cron = CronExpression::parse("0 9-17 * * *").unwrap();
        assert_eq!(cron.hours.len(), 9);
        assert!(cron.hours.contains(&9));
        assert!(cron.hours.contains(&17));
        assert!(!cron.hours.contains(&8));
        assert!(!cron.hours.contains(&18));
    }

    #[test]
    fn test_parse_range_with_step() {
        let cron = CronExpression::parse("0 0-23/2 * * *").unwrap();
        assert_eq!(cron.hours.len(), 12);
        assert!(cron.hours.contains(&0));
        assert!(cron.hours.contains(&2));
        assert!(cron.hours.contains(&22));
        assert!(!cron.hours.contains(&1));
    }

    #[test]
    fn test_parse_list() {
        let cron = CronExpression::parse("0 8,12,18 * * *").unwrap();
        assert_eq!(cron.hours.len(), 3);
        assert!(cron.hours.contains(&8));
        assert!(cron.hours.contains(&12));
        assert!(cron.hours.contains(&18));
    }

    #[test]
    fn test_parse_sunday_as_7() {
        let cron = CronExpression::parse("0 0 * * 7").unwrap();
        assert!(cron.days_of_week.contains(&0)); // 7 映射到 0
        assert_eq!(cron.days_of_week.len(), 1);
    }

    #[test]
    fn test_parse_weekday_range() {
        // 周一到周五
        let cron = CronExpression::parse("0 9 * * 1-5").unwrap();
        assert_eq!(cron.days_of_week.len(), 5);
        assert!(cron.days_of_week.contains(&1));
        assert!(cron.days_of_week.contains(&5));
        assert!(!cron.days_of_week.contains(&0));
        assert!(!cron.days_of_week.contains(&6));
    }

    #[test]
    fn test_parse_invalid_too_few_fields() {
        let result = CronExpression::parse("* * *");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("expected 5 fields"));
    }

    #[test]
    fn test_parse_invalid_too_many_fields() {
        let result = CronExpression::parse("* * * * * *");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_invalid_value_out_of_range() {
        let result = CronExpression::parse("60 * * * *");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_invalid_step_zero() {
        let result = CronExpression::parse("*/0 * * * *");
        assert!(result.is_err());
    }

    #[test]
    fn test_next_fire_time_every_minute() {
        let cron = CronExpression::parse("* * * * *").unwrap();
        // 2024-01-01 00:00:00 UTC = 1704067200000 ms
        let from_ms = 1704067200000i64;
        let next = cron.next_fire_time(from_ms).unwrap();
        // 应该是下一分钟: 00:01:00
        assert_eq!(next, 1704067260000);
    }

    #[test]
    fn test_next_fire_time_specific_time() {
        let cron = CronExpression::parse("30 8 * * *").unwrap();
        // 2024-01-01 09:00:00 UTC (已过 08:30)
        let from_ms = 1704099600000i64;
        let next = cron.next_fire_time(from_ms).unwrap();
        // 应该是次日 08:30: 2024-01-02 08:30:00 UTC
        // 2024-01-02 00:00:00 = 1704153600, +8.5h = +30600s
        assert_eq!(next, (1704153600 + 30600) * 1000);
    }

    #[test]
    fn test_next_fire_time_same_day() {
        let cron = CronExpression::parse("0 12 * * *").unwrap();
        // 2024-01-01 08:00:00 UTC (还没到 12:00)
        let from_ms = 1704096000000i64;
        let next = cron.next_fire_time(from_ms).unwrap();
        // 应该是当天 12:00: 1704096000 + 4*3600 = 1704110400
        assert_eq!(next, 1704110400000);
    }

    #[test]
    fn test_next_fire_time_specific_month() {
        // 每年 3 月 1 日 0:00
        let cron = CronExpression::parse("0 0 1 3 *").unwrap();
        // 2024-04-01 00:00:00 UTC = 1711929600000
        let from_ms = 1711929600000i64;
        let next = cron.next_fire_time(from_ms).unwrap();
        // 应该是 2025-03-01 00:00:00 UTC
        // 2025-03-01 = 1740787200
        assert_eq!(next, 1740787200000);
    }

    #[test]
    fn test_is_cron_due_true() {
        // 每分钟执行
        let last_run = 1704067200000i64; // 2024-01-01 00:00:00
        let now = 1704067260000i64; // 2024-01-01 00:01:00
        assert!(is_cron_due("* * * * *", last_run, now));
    }

    #[test]
    fn test_is_cron_due_false() {
        // 每天 8:30 执行
        let last_run = 1704067200000i64; // 2024-01-01 00:00:00
        let now = 1704067260000i64; // 2024-01-01 00:01:00 (还没到 8:30)
        assert!(!is_cron_due("30 8 * * *", last_run, now));
    }

    #[test]
    fn test_is_cron_due_invalid_expr() {
        assert!(!is_cron_due("invalid", 0, 999999999));
    }

    #[test]
    fn test_days_to_ymd_epoch() {
        // 1970-01-01
        let (y, m, d) = CronExpression::days_to_ymd(0);
        assert_eq!((y, m, d), (1970, 1, 1));
    }

    #[test]
    fn test_days_to_ymd_known_date() {
        // 2024-01-01 = day 19723
        let (y, m, d) = CronExpression::days_to_ymd(19723);
        assert_eq!((y, m, d), (2024, 1, 1));
    }

    #[test]
    fn test_days_to_ymd_leap_year() {
        // 2024-02-29 = day 19782
        let (y, m, d) = CronExpression::days_to_ymd(19782);
        assert_eq!((y, m, d), (2024, 2, 29));
    }

    #[test]
    fn test_weekday_calculation() {
        // 2024-01-01 是周一 (weekday=1)
        let ts = 19723 * 86400;
        let (_, _, _, weekday) = CronExpression::decompose_date(ts);
        assert_eq!(weekday, 1); // Monday
    }

    #[test]
    fn test_dom_dow_or_semantics() {
        // "每月1号 或 周一" — 两者都不以 * 开头 → OR
        let cron = CronExpression::parse("0 0 1 * 1").unwrap();
        assert!(!cron.dom_starts_with_star);
        assert!(!cron.dow_starts_with_star);

        // 2024-01-01 是周一且是1号 → 匹配
        let ts = 19723 * 86400;
        let result = cron.find_first_on_day(ts, 0);
        assert!(result.is_some());

        // 2024-01-02 是周二，不是1号 → 不匹配
        let ts2 = 19724 * 86400;
        let result2 = cron.find_first_on_day(ts2, 0);
        assert!(result2.is_none());

        // 2024-01-08 是周一，不是1号 → 匹配（OR 语义）
        let ts3 = 19730 * 86400;
        let result3 = cron.find_first_on_day(ts3, 0);
        assert!(result3.is_some());
    }

    #[test]
    fn test_dom_dow_and_semantics() {
        // "*/1 日 * 周1" — dom 以 * 开头 → AND
        let cron = CronExpression::parse("0 0 * * 1").unwrap();
        assert!(cron.dom_starts_with_star);

        // 2024-01-01 是周一 → 匹配
        let ts = 19723 * 86400;
        let result = cron.find_first_on_day(ts, 0);
        assert!(result.is_some());

        // 2024-01-02 是周二 → 不匹配
        let ts2 = 19724 * 86400;
        let result2 = cron.find_first_on_day(ts2, 0);
        assert!(result2.is_none());
    }

    #[test]
    fn test_parse_single_value_with_step() {
        // "5/10" 表示从 5 开始，步长 10，到 max
        let cron = CronExpression::parse("5/10 * * * *").unwrap();
        assert!(cron.minutes.contains(&5));
        assert!(cron.minutes.contains(&15));
        assert!(cron.minutes.contains(&25));
        assert!(cron.minutes.contains(&35));
        assert!(cron.minutes.contains(&45));
        assert!(cron.minutes.contains(&55));
        assert_eq!(cron.minutes.len(), 6);
    }
}
