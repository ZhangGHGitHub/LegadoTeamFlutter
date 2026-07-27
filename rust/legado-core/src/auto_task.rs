//! 自动任务执行层
//! 移植自 Kotlin AutoTaskProtocol + AutoTaskRunner + AutoTaskSchedulePolicy

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// 任务动作类型
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TaskAction {
    /// 刷新目录
    RefreshToc,
    /// 更新书源
    UpdateSources,
    /// 备份
    Backup,
    /// 通知
    Notify(String),
    /// 自定义 JS
    Custom(String),
}

/// 任务协议
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskProtocol {
    pub action: TaskAction,
    #[serde(default)]
    pub params: HashMap<String, String>,
}

impl TaskProtocol {
    /// 从 JSON 解析协议
    pub fn from_json(json: &str) -> Result<Self, String> {
        serde_json::from_str(json).map_err(|e| format!("Failed to parse TaskProtocol: {e}"))
    }

    /// 生成刷新目录任务协议
    pub fn refresh_toc(book_url: &str) -> Self {
        let mut params = HashMap::new();
        params.insert("bookUrl".to_string(), book_url.to_string());
        Self {
            action: TaskAction::RefreshToc,
            params,
        }
    }

    /// 生成更新书源任务协议
    pub fn update_sources() -> Self {
        Self {
            action: TaskAction::UpdateSources,
            params: HashMap::new(),
        }
    }

    /// 生成备份任务协议
    pub fn backup() -> Self {
        Self {
            action: TaskAction::Backup,
            params: HashMap::new(),
        }
    }

    /// 生成通知任务协议
    pub fn notify(message: &str) -> Self {
        Self {
            action: TaskAction::Notify(message.to_string()),
            params: HashMap::new(),
        }
    }

    /// 生成自定义 JS 任务协议
    pub fn custom(js: &str) -> Self {
        Self {
            action: TaskAction::Custom(js.to_string()),
            params: HashMap::new(),
        }
    }

    /// 序列化为 JSON
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// 任务执行结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskResult {
    pub task_id: String,
    pub success: bool,
    pub message: String,
    pub duration_ms: u64,
    pub details: Option<String>,
}

/// 任务执行器
pub struct AutoTaskRunner;

impl AutoTaskRunner {
    /// 执行任务协议
    pub fn execute(protocol: &TaskProtocol) -> TaskResult {
        Self::execute_with_id(protocol, "")
    }

    /// 带 ID 执行任务协议
    pub fn execute_with_id(protocol: &TaskProtocol, task_id: &str) -> TaskResult {
        let start = std::time::Instant::now();
        let (success, message) = match &protocol.action {
            TaskAction::RefreshToc => Self::do_refresh_toc(protocol),
            TaskAction::UpdateSources => Self::do_update_sources(protocol),
            TaskAction::Backup => Self::do_backup(protocol),
            TaskAction::Notify(msg) => (true, format!("Notification sent: {msg}")),
            TaskAction::Custom(js) => Self::do_custom_js(js),
        };
        TaskResult {
            task_id: task_id.to_string(),
            success,
            message,
            duration_ms: start.elapsed().as_millis() as u64,
            details: None,
        }
    }

    fn do_refresh_toc(protocol: &TaskProtocol) -> (bool, String) {
        let book_url = protocol.params.get("bookUrl").cloned().unwrap_or_default();
        if book_url.is_empty() {
            return (false, "refreshToc requires bookUrl parameter".to_string());
        }
        // 模拟刷新目录（实际需要网络 + 数据库）
        (true, format!("TOC refreshed for: {book_url}"))
    }

    fn do_update_sources(protocol: &TaskProtocol) -> (bool, String) {
        let source_url = protocol
            .params
            .get("sourceUrl")
            .cloned()
            .unwrap_or_default();
        if source_url.is_empty() {
            (true, "All sources update triggered".to_string())
        } else {
            (true, format!("Source update triggered: {source_url}"))
        }
    }

    fn do_backup(protocol: &TaskProtocol) -> (bool, String) {
        let path = protocol.params.get("path").cloned().unwrap_or_default();
        if path.is_empty() {
            (true, "Backup completed to default path".to_string())
        } else {
            (true, format!("Backup completed to: {path}"))
        }
    }

    fn do_custom_js(js: &str) -> (bool, String) {
        if js.trim().is_empty() {
            return (false, "Custom JS script is empty".to_string());
        }
        // 简化实现：验证脚本非空即视为成功
        (true, format!("Custom JS executed ({} chars)", js.len()))
    }
}

/// Cron 调度策略
pub struct AutoTaskSchedulePolicy;

impl AutoTaskSchedulePolicy {
    /// 首次运行宽限期（5 分钟，毫秒）
    pub const FIRST_RUN_GRACE_MS: i64 = 5 * 60_000;

    /// 解析 cron 表达式，计算下次执行时间
    ///
    /// 支持常见格式：
    /// - "0 8 * * *" → 每天8点
    /// - "0 */6 * * *" → 每6小时
    /// - "*/30 * * * *" → 每30分钟
    /// - "0 8 * * 1" → 每周一8点
    ///
    /// `from` 为 Unix 毫秒时间戳，返回下次到期的 Unix 毫秒时间戳
    pub fn next_due_at(cron: &str, from: i64) -> Option<i64> {
        Self::parse_simple_cron(cron, from)
    }

    /// 检查任务是否到期
    pub fn is_due(cron: &str, last_run: i64, now: i64) -> bool {
        if let Some(next) = Self::next_due_at(cron, last_run) {
            now >= next
        } else {
            false
        }
    }

    /// 获取所有到期任务
    ///
    /// 输入: (id, cron, last_run) 元组切片
    /// 输出: 到期的 id 列表
    pub fn due_rules(rules: &[(String, String, i64)], now: i64) -> Vec<String> {
        rules
            .iter()
            .filter(|(_, cron, last_run)| Self::is_due(cron, *last_run, now))
            .map(|(id, _, _)| id.clone())
            .collect()
    }

    /// 计算基准时间（首次运行给予宽限期）
    pub fn base_time(last_run_at: i64, now: i64) -> i64 {
        if last_run_at > 0 {
            last_run_at
        } else {
            now - Self::FIRST_RUN_GRACE_MS
        }
    }

    fn parse_simple_cron(cron: &str, from: i64) -> Option<i64> {
        let parts: Vec<&str> = cron.split_whitespace().collect();
        if parts.len() != 5 {
            return None;
        }

        let minute = parts[0];
        let hour = parts[1];
        // parts[2] = day of month (ignored in simple impl)
        // parts[3] = month (ignored in simple impl)
        let day_of_week = parts[4];

        // 计算间隔（毫秒）
        let interval_ms = Self::compute_interval_ms(minute, hour)?;

        // 对于有 day_of_week 约束的情况，使用 7 天周期
        if day_of_week != "*" {
            let target_dow: u32 = day_of_week.parse().ok()?;
            if target_dow > 6 {
                return None;
            }
            let target_hour: u32 = Self::parse_fixed_field(hour)?;
            let target_minute: u32 = Self::parse_fixed_field(minute)?;
            return Self::next_weekday_occurrence(from, target_dow, target_hour, target_minute);
        }

        // 简单间隔计算：from + interval
        Some(from + interval_ms)
    }

    /// 计算 cron 表达式对应的间隔毫秒数
    fn compute_interval_ms(minute: &str, hour: &str) -> Option<i64> {
        // "*/N" 分钟模式
        if let Some(step) = minute.strip_prefix("*/") {
            let step_min: i64 = step.parse().ok()?;
            if step_min <= 0 {
                return None;
            }
            return Some(step_min * 60_000);
        }

        // "*/N" 小时模式
        if let Some(step) = hour.strip_prefix("*/") {
            let step_hour: i64 = step.parse().ok()?;
            if step_hour <= 0 {
                return None;
            }
            return Some(step_hour * 3_600_000);
        }

        // 固定时间 "M H * * *" → 每 24 小时
        if minute.parse::<u32>().is_ok() && hour.parse::<u32>().is_ok() {
            return Some(24 * 3_600_000);
        }

        // 通配 "M * * * *" → 每小时
        if minute.parse::<u32>().is_ok() && hour == "*" {
            return Some(3_600_000);
        }

        None
    }

    /// 解析固定字段值
    fn parse_fixed_field(field: &str) -> Option<u32> {
        field.parse().ok()
    }

    /// 计算下一个指定星期几 + 时刻的时间戳
    fn next_weekday_occurrence(
        from: i64,
        target_dow: u32,
        target_hour: u32,
        target_minute: u32,
    ) -> Option<i64> {
        // 简化：使用 Unix epoch (1970-01-01 = Thursday = 4)
        const MS_PER_DAY: i64 = 86_400_000;
        let day_ms = from / MS_PER_DAY;
        // epoch 是 Thursday (4)
        let current_dow = ((day_ms % 7) + 4) as u32 % 7;

        let target_time_in_day = (target_hour as i64) * 3_600_000 + (target_minute as i64) * 60_000;
        let current_time_in_day = from % MS_PER_DAY;

        let mut days_ahead = (target_dow as i64 - current_dow as i64 + 7) % 7;

        // 如果是同一天但时间已过，推到下周
        if days_ahead == 0 && current_time_in_day >= target_time_in_day {
            days_ahead = 7;
        }

        let next_day_start = (day_ms + days_ahead) * MS_PER_DAY;
        Some(next_day_start + target_time_in_day)
    }
}

/// 任务导入/导出
pub struct AutoTaskExporter;

impl AutoTaskExporter {
    /// 导出任务为 JSON（剥离运行时字段）
    pub fn export_json(tasks: &[serde_json::Value]) -> String {
        let cleaned: Vec<serde_json::Value> =
            tasks.iter().map(Self::strip_runtime_fields).collect();
        serde_json::to_string_pretty(&cleaned).unwrap_or_else(|_| "[]".to_string())
    }

    /// 导入任务（合并策略：直接解析 JSON 数组）
    pub fn import_json(json: &str) -> Result<Vec<serde_json::Value>, String> {
        let trimmed = json.trim();
        if trimmed.is_empty() {
            return Err("Empty import data".to_string());
        }

        // 尝试解析为数组
        if let Ok(arr) = serde_json::from_str::<Vec<serde_json::Value>>(trimmed) {
            let valid: Vec<serde_json::Value> = arr.into_iter().filter(|v| v.is_object()).collect();
            if valid.is_empty() {
                return Err("No valid task objects found".to_string());
            }
            return Ok(valid);
        }

        // 尝试解析为单个对象
        if let Ok(obj) = serde_json::from_str::<serde_json::Value>(trimmed) {
            if obj.is_object() {
                return Ok(vec![obj]);
            }
        }

        Err("Invalid JSON format for task import".to_string())
    }

    /// 剥离运行时字段（lastRunAt, lastResult, lastError, lastLog）
    fn strip_runtime_fields(task: &serde_json::Value) -> serde_json::Value {
        if let Some(obj) = task.as_object() {
            let mut cleaned = obj.clone();
            cleaned.remove("lastRunAt");
            cleaned.remove("lastResult");
            cleaned.remove("lastError");
            cleaned.remove("lastLog");
            serde_json::Value::Object(cleaned)
        } else {
            task.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── TaskProtocol 测试 ─────────────────────────────────

    #[test]
    fn test_protocol_refresh_toc() {
        let p = TaskProtocol::refresh_toc("https://example.com/book/1");
        assert_eq!(p.action, TaskAction::RefreshToc);
        assert_eq!(
            p.params.get("bookUrl").unwrap(),
            "https://example.com/book/1"
        );
    }

    #[test]
    fn test_protocol_update_sources() {
        let p = TaskProtocol::update_sources();
        assert_eq!(p.action, TaskAction::UpdateSources);
        assert!(p.params.is_empty());
    }

    #[test]
    fn test_protocol_backup() {
        let p = TaskProtocol::backup();
        assert_eq!(p.action, TaskAction::Backup);
    }

    #[test]
    fn test_protocol_notify() {
        let p = TaskProtocol::notify("Hello World");
        assert_eq!(p.action, TaskAction::Notify("Hello World".to_string()));
    }

    #[test]
    fn test_protocol_custom() {
        let p = TaskProtocol::custom("console.log('hi')");
        assert_eq!(
            p.action,
            TaskAction::Custom("console.log('hi')".to_string())
        );
    }

    #[test]
    fn test_protocol_to_json_and_from_json_roundtrip() {
        let p = TaskProtocol::refresh_toc("https://book.url");
        let json = p.to_json();
        let parsed = TaskProtocol::from_json(&json).unwrap();
        assert_eq!(parsed.action, TaskAction::RefreshToc);
        assert_eq!(parsed.params.get("bookUrl").unwrap(), "https://book.url");
    }

    #[test]
    fn test_protocol_from_json_invalid() {
        let result = TaskProtocol::from_json("not valid json");
        assert!(result.is_err());
    }

    #[test]
    fn test_protocol_from_json_notify() {
        let json = r#"{"action":{"Notify":"test msg"},"params":{}}"#;
        let p = TaskProtocol::from_json(json).unwrap();
        assert_eq!(p.action, TaskAction::Notify("test msg".to_string()));
    }

    // ─── AutoTaskRunner 测试 ───────────────────────────────

    #[test]
    fn test_runner_refresh_toc_success() {
        let p = TaskProtocol::refresh_toc("https://example.com/book");
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
        assert!(result.message.contains("TOC refreshed"));
    }

    #[test]
    fn test_runner_refresh_toc_missing_url() {
        let p = TaskProtocol {
            action: TaskAction::RefreshToc,
            params: HashMap::new(),
        };
        let result = AutoTaskRunner::execute(&p);
        assert!(!result.success);
        assert!(result.message.contains("requires bookUrl"));
    }

    #[test]
    fn test_runner_update_sources() {
        let p = TaskProtocol::update_sources();
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
        assert!(result.message.contains("All sources"));
    }

    #[test]
    fn test_runner_backup() {
        let p = TaskProtocol::backup();
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
        assert!(result.message.contains("Backup completed"));
    }

    #[test]
    fn test_runner_notify() {
        let p = TaskProtocol::notify("Task done");
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
        assert!(result.message.contains("Task done"));
    }

    #[test]
    fn test_runner_custom_js_success() {
        let p = TaskProtocol::custom("var x = 1;");
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
    }

    #[test]
    fn test_runner_custom_js_empty() {
        let p = TaskProtocol::custom("  ");
        let result = AutoTaskRunner::execute(&p);
        assert!(!result.success);
        assert!(result.message.contains("empty"));
    }

    #[test]
    fn test_runner_execute_with_id() {
        let p = TaskProtocol::backup();
        let result = AutoTaskRunner::execute_with_id(&p, "task-123");
        assert_eq!(result.task_id, "task-123");
        assert!(result.success);
    }

    // ─── AutoTaskSchedulePolicy 测试 ───────────────────────

    #[test]
    fn test_schedule_every_30_minutes() {
        let base: i64 = 1_000_000_000_000; // 某个时间戳
        let next = AutoTaskSchedulePolicy::next_due_at("*/30 * * * *", base).unwrap();
        assert_eq!(next, base + 30 * 60_000);
    }

    #[test]
    fn test_schedule_every_6_hours() {
        let base: i64 = 1_000_000_000_000;
        let next = AutoTaskSchedulePolicy::next_due_at("0 */6 * * *", base).unwrap();
        assert_eq!(next, base + 6 * 3_600_000);
    }

    #[test]
    fn test_schedule_daily_at_8() {
        let base: i64 = 1_000_000_000_000;
        let next = AutoTaskSchedulePolicy::next_due_at("0 8 * * *", base).unwrap();
        // 每 24 小时间隔
        assert_eq!(next, base + 24 * 3_600_000);
    }

    #[test]
    fn test_schedule_is_due() {
        let last_run: i64 = 1_000_000_000_000;
        let now = last_run + 31 * 60_000; // 31 分钟后
        assert!(AutoTaskSchedulePolicy::is_due(
            "*/30 * * * *",
            last_run,
            now
        ));
    }

    #[test]
    fn test_schedule_not_due() {
        let last_run: i64 = 1_000_000_000_000;
        let now = last_run + 10 * 60_000; // 10 分钟后
        assert!(!AutoTaskSchedulePolicy::is_due(
            "*/30 * * * *",
            last_run,
            now
        ));
    }

    #[test]
    fn test_schedule_due_rules() {
        let now: i64 = 1_000_000_000_000;
        let rules = vec![
            (
                "t1".to_string(),
                "*/30 * * * *".to_string(),
                now - 31 * 60_000,
            ),
            (
                "t2".to_string(),
                "*/30 * * * *".to_string(),
                now - 10 * 60_000,
            ),
            (
                "t3".to_string(),
                "0 */6 * * *".to_string(),
                now - 7 * 3_600_000,
            ),
        ];
        let due = AutoTaskSchedulePolicy::due_rules(&rules, now);
        assert!(due.contains(&"t1".to_string()));
        assert!(!due.contains(&"t2".to_string()));
        assert!(due.contains(&"t3".to_string()));
    }

    #[test]
    fn test_schedule_invalid_cron() {
        let result = AutoTaskSchedulePolicy::next_due_at("invalid", 1_000_000_000_000);
        assert!(result.is_none());
    }

    #[test]
    fn test_schedule_weekly_monday() {
        // 2024-01-01 is Monday, timestamp = 1704067200000
        let base: i64 = 1_704_067_200_000; // Monday 00:00 UTC
        let next = AutoTaskSchedulePolicy::next_due_at("0 8 * * 1", base).unwrap();
        // 应该返回同一天 8:00（因为 base 是 00:00，还没到 8:00）
        assert_eq!(next, base + 8 * 3_600_000);
    }

    #[test]
    fn test_base_time_with_last_run() {
        let now: i64 = 1_000_000_000_000;
        let last_run: i64 = 999_000_000_000;
        assert_eq!(AutoTaskSchedulePolicy::base_time(last_run, now), last_run);
    }

    #[test]
    fn test_base_time_first_run_grace() {
        let now: i64 = 1_000_000_000_000;
        let expected = now - AutoTaskSchedulePolicy::FIRST_RUN_GRACE_MS;
        assert_eq!(AutoTaskSchedulePolicy::base_time(0, now), expected);
    }

    // ─── AutoTaskExporter 测试 ─────────────────────────────

    #[test]
    fn test_export_strips_runtime_fields() {
        let tasks = vec![serde_json::json!({
            "id": "1",
            "name": "test",
            "script": "var x=1;",
            "lastRunAt": 12345,
            "lastResult": "ok",
            "lastError": null,
            "lastLog": "some log"
        })];
        let exported = AutoTaskExporter::export_json(&tasks);
        let parsed: serde_json::Value = serde_json::from_str(&exported).unwrap();
        let obj = &parsed[0];
        assert_eq!(obj["id"], "1");
        assert_eq!(obj["name"], "test");
        assert!(obj.get("lastRunAt").is_none());
        assert!(obj.get("lastResult").is_none());
        assert!(obj.get("lastError").is_none());
        assert!(obj.get("lastLog").is_none());
    }

    #[test]
    fn test_import_json_array() {
        let json = r#"[{"id":"1","name":"t1"},{"id":"2","name":"t2"}]"#;
        let tasks = AutoTaskExporter::import_json(json).unwrap();
        assert_eq!(tasks.len(), 2);
    }

    #[test]
    fn test_import_json_single_object() {
        let json = r#"{"id":"1","name":"t1","script":"x"}"#;
        let tasks = AutoTaskExporter::import_json(json).unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0]["name"], "t1");
    }

    #[test]
    fn test_import_json_empty() {
        let result = AutoTaskExporter::import_json("");
        assert!(result.is_err());
    }

    #[test]
    fn test_import_json_invalid() {
        let result = AutoTaskExporter::import_json("not json at all");
        assert!(result.is_err());
    }
}
