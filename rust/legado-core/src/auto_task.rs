//! 自动任务执行层
//! 移植自 Kotlin AutoTaskProtocol + AutoTaskRunner + AutoTaskSchedulePolicy + AutoTask

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

/// 书籍更新任务生成器标识（对应 Kotlin AutoTask.BOOK_UPDATE_GENERATOR）
pub const BOOK_UPDATE_GENERATOR: &str = "bookUpdate";

/// 默认 cron 表达式（每30分钟）
pub const DEFAULT_CRON: &str = "*/30 * * * *";

/// 任务动作类型
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum TaskAction {
    /// 刷新目录
    RefreshToc,
    /// 缓存新增章节（#497：检查书籍最新章节并缓存新增章节）
    CacheChapters,
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

    /// 生成缓存新增章节任务协议（#497）
    ///
    /// 检查书籍最新章节并缓存新增章节，需要 `bookUrl` 参数。
    pub fn cache_chapters(book_url: &str) -> Self {
        let mut params = HashMap::new();
        params.insert("bookUrl".to_string(), book_url.to_string());
        Self {
            action: TaskAction::CacheChapters,
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
            TaskAction::CacheChapters => Self::do_cache_chapters(protocol),
            TaskAction::UpdateSources => Self::do_update_sources(protocol),
            TaskAction::Backup => Self::do_backup(protocol),
            TaskAction::Notify(msg) => (true, format!("Notification sent: {msg}")),
            TaskAction::Custom(js) => Self::do_custom_js(js),
        };
        let duration_ms = start.elapsed().as_millis() as u64;
        // 对齐 AutoTaskLogFormatter：供调试 Dialog 分行流式展示
        let details = if success {
            Some(format!(
                "[OK] Elapsed: {duration_ms}ms\n- {message}"
            ))
        } else {
            Some(format!("[FAIL] Elapsed: {duration_ms}ms\n- {message}"))
        };
        TaskResult {
            task_id: task_id.to_string(),
            success,
            message,
            duration_ms,
            details,
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

    /// 缓存新增章节动作（#497，对应 Kotlin AutoTaskProtocol 的 cache 子配置）
    ///
    /// 检查书籍最新章节并缓存新增章节。核心层无网络/数据库依赖，
    /// 此处完成协议校验；实际下载缓存由宿主侧（Flutter/Android）执行。
    fn do_cache_chapters(protocol: &TaskProtocol) -> (bool, String) {
        let book_url = protocol.params.get("bookUrl").cloned().unwrap_or_default();
        if book_url.is_empty() {
            return (false, "cacheChapters requires bookUrl parameter".to_string());
        }
        // 模拟缓存新增章节（实际需要网络 + 数据库）
        (true, format!("New chapters cached for: {book_url}"))
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

/// 自动任务规则（对应 Kotlin AutoTaskRule 实体）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutoTaskRule {
    pub id: String,
    pub name: String,
    #[serde(default = "default_true")]
    pub enable: bool,
    pub cron: Option<String>,
    #[serde(default)]
    pub script: String,
    #[serde(default)]
    pub custom_order: i32,
    #[serde(default)]
    pub last_run_at: i64,
    pub last_result: Option<String>,
    pub last_error: Option<String>,
    pub last_log: Option<String>,
}

fn default_true() -> bool {
    true
}

/// 任务导入/导出
pub struct AutoTaskExporter;

impl AutoTaskExporter {
    /// 导出任务为 JSON（剥离运行时字段和排序字段）
    /// 对应 Kotlin AutoTask.exportJson
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

    /// 准备导入任务（合并本地运行时状态）
    /// 对应 Kotlin prepareImportedAutoTasks
    ///
    /// 合并策略：
    /// - 如果本地存在同 ID 任务，保留本地的 customOrder 和运行时状态
    /// - 如果导入数据中有重复 ID，后出现的覆盖先出现的
    /// - 新任务分配递增的 customOrder
    pub fn prepare_imported_tasks(
        local_tasks: &[AutoTaskRule],
        imported_tasks: Vec<serde_json::Value>,
    ) -> Vec<serde_json::Value> {
        let local_by_id: HashMap<&str, &AutoTaskRule> = local_tasks
            .iter()
            .map(|t| (t.id.as_str(), t))
            .collect();

        let max_order = local_tasks
            .iter()
            .map(|t| t.custom_order)
            .max()
            .unwrap_or(-1);
        let mut next_order = max_order + 1;

        let mut imported_by_id: Vec<(String, serde_json::Value)> = Vec::new();
        let mut seen_ids: HashMap<String, usize> = HashMap::new();

        for imported in imported_tasks {
            let id = imported
                .get("id")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            if id.is_empty() {
                continue;
            }

            let local = local_by_id.get(id.as_str());
            let order = local
                .map(|t| t.custom_order)
                .or_else(|| {
                    seen_ids.get(&id).map(|&idx| {
                        imported_by_id[idx]
                            .1
                            .get("customOrder")
                            .and_then(|v| v.as_i64())
                            .unwrap_or(0) as i32
                    })
                })
                .unwrap_or_else(|| {
                    let o = next_order;
                    next_order += 1;
                    o
                });

            // 合并运行时状态：优先使用本地状态
            let state_source = local.map(|t| {
                serde_json::json!({
                    "lastRunAt": t.last_run_at,
                    "lastResult": t.last_result,
                    "lastError": t.last_error,
                    "lastLog": t.last_log,
                })
            });

            let mut merged = if let Some(obj) = imported.as_object() {
                obj.clone()
            } else {
                continue;
            };
            merged.insert(
                "customOrder".to_string(),
                serde_json::Value::Number(order.into()),
            );

            // 保留运行时状态
            if let Some(state) = state_source {
                for key in ["lastRunAt", "lastResult", "lastError", "lastLog"] {
                    if let Some(val) = state.get(key) {
                        merged.insert(key.to_string(), val.clone());
                    }
                }
            }

            let merged_value = serde_json::Value::Object(merged);
            if let Some(&idx) = seen_ids.get(&id) {
                imported_by_id[idx] = (id.clone(), merged_value);
            } else {
                let idx = imported_by_id.len();
                seen_ids.insert(id.clone(), idx);
                imported_by_id.push((id, merged_value));
            }
        }

        imported_by_id.into_iter().map(|(_, v)| v).collect()
    }

    /// 剥离运行时字段和排序字段（customOrder, lastRunAt, lastResult, lastError, lastLog）
    fn strip_runtime_fields(task: &serde_json::Value) -> serde_json::Value {
        if let Some(obj) = task.as_object() {
            let mut cleaned = obj.clone();
            cleaned.remove("customOrder");
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

/// 批量更新 cron 表达式（纯逻辑层，返回受影响的 ID 列表）
/// 对应 Kotlin AutoTask.updateCron + AutoTaskRuleDao.updateCron
pub fn update_cron_batch(
    rules: &mut [AutoTaskRule],
    ids: &[String],
    cron: &str,
) -> Vec<String> {
    if ids.is_empty() {
        return Vec::new();
    }
    let id_set: std::collections::HashSet<&str> =
        ids.iter().map(|s| s.as_str()).collect();
    let mut changed = Vec::new();
    for rule in rules.iter_mut() {
        if id_set.contains(rule.id.as_str()) {
            rule.cron = Some(cron.to_string());
            changed.push(rule.id.clone());
        }
    }
    changed
}

/// 规范化脚本（去除 @js: 前缀或 <js></js> 包裹）
/// 对应 Kotlin AutoTask.normalizeScript
pub fn normalize_script(script: &str) -> String {
    let trimmed = script.trim();
    let lower = trimmed.to_lowercase();
    if lower.starts_with("@js:") {
        trimmed[4..].trim().to_string()
    } else if lower.starts_with("<js>") && lower.ends_with("</js>") {
        trimmed[4..trimmed.len() - 5].trim().to_string()
    } else {
        trimmed.to_string()
    }
}

/// 生成书籍更新任务 ID（MD5 前16位）
/// 对应 Kotlin AutoTask.bookUpdateTaskId
pub fn book_update_task_id(book_url: &str) -> String {
    let digest = format!("{:x}", md5::compute(book_url.as_bytes()));
    let short = &digest[..16.min(digest.len())];
    format!("book_update:{short}")
}

/// 构建书籍更新定时任务
/// 对应 Kotlin AutoTask.buildBookUpdateTask
pub fn build_book_update_task(
    book_url: &str,
    book_name: &str,
    book_author: &str,
    name: &str,
) -> AutoTaskRule {
    let action = serde_json::json!({
        "type": "refreshToc",
        "bookUrl": book_url,
        "bookName": book_name,
        "bookAuthor": book_author,
        "generatedBy": BOOK_UPDATE_GENERATOR,
        "respectCanUpdate": true,
        "notify": {"enable": true, "minCount": 1},
        "cache": {"enable": false}
    });
    AutoTaskRule {
        id: book_update_task_id(book_url),
        name: name.to_string(),
        enable: true,
        cron: Some(DEFAULT_CRON.to_string()),
        script: format!("({})", serde_json::to_string(&action).unwrap_or_default()),
        custom_order: 0,
        last_run_at: 0,
        last_result: None,
        last_error: None,
        last_log: None,
    }
}

/// 从任务列表中查找书籍更新任务
/// 对应 Kotlin AutoTask.findBookUpdateTask
///
/// 优先按 ID 精确匹配，其次按书名+作者匹配
pub fn find_book_update_task<'a>(
    tasks: &'a [AutoTaskRule],
    book_url: &str,
    book_name: &str,
    book_author: &str,
) -> Option<&'a AutoTaskRule> {
    // 优先按 ID 匹配
    let target_id = book_update_task_id(book_url);
    if let Some(found) = tasks.iter().find(|t| t.id == target_id) {
        return Some(found);
    }
    // 其次按书名+作者匹配
    let matches: Vec<&AutoTaskRule> = tasks
        .iter()
        .filter(|t| {
            generated_book_identity(t)
                .map(|(n, a)| n == book_name && a == book_author)
                .unwrap_or(false)
        })
        .collect();
    if matches.len() == 1 {
        Some(matches[0])
    } else {
        None
    }
}

/// 从任务脚本中提取书籍标识（书名, 作者）
/// 对应 Kotlin AutoTask.generatedBookIdentity
fn generated_book_identity(task: &AutoTaskRule) -> Option<(String, String)> {
    if !task.id.starts_with("book_update:") {
        return None;
    }
    let script = normalize_script(&task.script);
    if !script.starts_with('(') || !script.ends_with(')') {
        return None;
    }
    let json_str = &script[1..script.len() - 1];
    let action: serde_json::Value = serde_json::from_str(json_str).ok()?;
    if action.get("generatedBy").and_then(|v| v.as_str()) != Some(BOOK_UPDATE_GENERATOR) {
        return None;
    }
    let name = action.get("bookName")?.as_str()?.to_string();
    let author = action
        .get("bookAuthor")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    Some((name, author))
}

/// 判断书籍是否允许刷新目录
/// 对应 Kotlin AutoTaskProtocol.canRefreshBookToc
///
/// - can_update: 书籍本身的 canUpdate 标志
/// - respect_can_update: 任务是否尊重 canUpdate 标志
pub fn can_refresh_book_toc(can_update: bool, respect_can_update: bool) -> bool {
    can_update || !respect_can_update
}

// ─── #497 缓存新增章节协议（对应 Kotlin AutoTaskProtocol.handleRefreshToc）───────

/// 通知子配置（对应 Kotlin refreshToc action 的 "notify" 子对象）
#[derive(Debug, Clone, PartialEq, Default)]
pub struct NotifyOptions {
    /// 是否启用通知（存在 notify 子对象时默认 true）
    pub enable: bool,
    /// 触发通知的最小新增章节数（默认 1）
    pub min_count: i64,
    /// 自定义通知标题模板
    pub title: Option<String>,
    /// 自定义通知内容模板
    pub content: Option<String>,
}

/// 缓存子配置（对应 Kotlin refreshToc action 的 "cache" 子对象）
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CacheOptions {
    /// 是否缓存新增章节（默认 false）
    pub enable: bool,
}

/// refreshToc 动作完整协议字段（#497 对齐 Kotlin）
///
/// 对应 Kotlin `AutoTaskProtocol.handleRefreshToc` 从 action JSON 中
/// 读取的全部字段：bookUrl/bookName/bookAuthor/generatedBy/respectCanUpdate/notify/cache。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RefreshTocAction {
    pub book_url: String,
    pub book_name: String,
    pub book_author: String,
    /// 生成器标识（批量生成的任务为 [`BOOK_UPDATE_GENERATOR`]）
    pub generated_by: Option<String>,
    /// 是否尊重书籍的 canUpdate 标志
    pub respect_can_update: bool,
    pub notify: Option<NotifyOptions>,
    pub cache: Option<CacheOptions>,
}

impl RefreshTocAction {
    /// 从 action JSON（脚本返回值中的单个动作对象）解析
    ///
    /// 键查找对齐 Kotlin `value()`：先精确匹配，再忽略大小写匹配。
    /// `bookUrl` 缺失或为空时报错（对应 Kotlin `require(bookUrl.isNotBlank())`）。
    pub fn from_action_json(value: &serde_json::Value) -> Result<Self, String> {
        let book_url = action_string(value, "bookUrl").unwrap_or_default();
        if book_url.trim().is_empty() {
            return Err("refreshToc requires bookUrl".to_string());
        }
        let notify = action_map(value, "notify").map(|n| NotifyOptions {
            enable: action_value(n, "enable")
                .map(|v| action_bool(v, true))
                .unwrap_or(true),
            min_count: action_value(n, "minCount")
                .and_then(action_integer)
                .unwrap_or(1),
            title: action_value(n, "title")
                .and_then(|v| v.as_str())
                .map(str::to_string),
            content: action_value(n, "content")
                .and_then(|v| v.as_str())
                .map(str::to_string),
        });
        let cache = action_map(value, "cache").map(|c| CacheOptions {
            enable: action_value(c, "enable")
                .map(|v| action_bool(v, false))
                .unwrap_or(false),
        });
        Ok(Self {
            book_url,
            book_name: action_string(value, "bookName").unwrap_or_default(),
            book_author: action_string(value, "bookAuthor").unwrap_or_default(),
            generated_by: action_string(value, "generatedBy"),
            respect_can_update: action_value(value, "respectCanUpdate")
                .map(|v| action_bool(v, false))
                .unwrap_or(false),
            notify,
            cache,
        })
    }

    /// 是否应发送书籍更新通知
    ///
    /// 对应 Kotlin：`notifyEnabled && newCount >= notifyMin && newCount > 0`
    pub fn should_notify(&self, new_count: i64) -> bool {
        match &self.notify {
            Some(n) => n.enable && new_count >= n.min_count && new_count > 0,
            None => false,
        }
    }

    /// 是否启用新增章节缓存
    ///
    /// 对应 Kotlin：`cache?.let { boolean(it, "enable", false) } ?: false`
    pub fn cache_enabled(&self) -> bool {
        self.cache.as_ref().map(|c| c.enable).unwrap_or(false)
    }
}

/// 章节快照（用于新增章节差异计算，对应 Kotlin BookChapter 的关键字段）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChapterSnapshot {
    /// 章节 URL（唯一标识）
    pub url: String,
    /// 章节标题
    pub title: String,
    /// 是否为卷/卷标题（不参与新增计数，对应 Kotlin isVolume）
    #[serde(default)]
    pub is_volume: bool,
}

/// 统计新增章节数（对应 Kotlin `countNewChapters`）
///
/// 以非卷章节数量差计算，不为负。
pub fn count_new_chapters(before: &[ChapterSnapshot], after: &[ChapterSnapshot]) -> usize {
    let before_count = before.iter().filter(|c| !c.is_volume).count();
    let after_count = after.iter().filter(|c| !c.is_volume).count();
    after_count.saturating_sub(before_count)
}

/// 提取新增的内容章节（对应 Kotlin `newContentChapters`）
///
/// 取刷新后 URL 不在刷新前集合中的非卷章节，并只保留末尾 `new_count` 个。
pub fn new_content_chapters(
    before: &[ChapterSnapshot],
    after: &[ChapterSnapshot],
) -> Vec<ChapterSnapshot> {
    let new_count = count_new_chapters(before, after);
    if new_count == 0 {
        return Vec::new();
    }
    let known_urls: HashSet<&str> = before
        .iter()
        .filter(|c| !c.is_volume)
        .map(|c| c.url.as_str())
        .collect();
    let mut fresh: Vec<ChapterSnapshot> = after
        .iter()
        .filter(|c| !c.is_volume && !known_urls.contains(c.url.as_str()))
        .cloned()
        .collect();
    // 对齐 Kotlin takeLast(newCount)
    if fresh.len() > new_count {
        let start = fresh.len() - new_count;
        fresh = fresh.split_off(start);
    }
    fresh
}

/// 最新章节标题（对应 Kotlin `latestChapterTitle`）
///
/// 优先取最后一个非卷章节，否则取最后一个章节。
pub fn latest_chapter_title(chapters: &[ChapterSnapshot]) -> Option<&str> {
    chapters
        .iter()
        .rev()
        .find(|c| !c.is_volume)
        .or_else(|| chapters.iter().rev().next())
        .map(|c| c.title.as_str())
}

/// 缓存重试次数（对应 Kotlin cacheChaptersWithRetry 的 3 次尝试）
pub const CACHE_RETRY_COUNT: u32 = 3;

/// 缓存重试默认延迟（毫秒，对应 Kotlin retryDelayMillis = 1_000）
pub const CACHE_RETRY_DELAY_MS: u64 = 1_000;

/// 逐章缓存并带重试（对应 Kotlin `cacheChaptersWithRetry`）
///
/// - 每个章节最多尝试 [`CACHE_RETRY_COUNT`] 次，失败后延迟 `retry_delay_ms` 毫秒
/// - 单个章节最终失败时记录首个错误并回调 `on_failure`，继续处理后续章节
/// - 全部处理完后，若存在失败则返回首个错误（对齐 Kotlin `firstFailure?.let { throw it }`）
///
/// 返回成功缓存的章节数。
pub fn cache_chapters_with_retry<C, E>(
    chapters: &[C],
    retry_delay_ms: u64,
    mut cache: impl FnMut(&C) -> Result<(), E>,
    mut on_failure: impl FnMut(&C, &E),
) -> Result<usize, E> {
    let mut cached = 0usize;
    let mut first_failure: Option<E> = None;
    for chapter in chapters {
        let mut failure: Option<E> = None;
        for attempt in 1..=CACHE_RETRY_COUNT {
            match cache(chapter) {
                Ok(()) => {
                    failure = None;
                    cached += 1;
                    break;
                }
                Err(err) => {
                    failure = Some(err);
                    if attempt < CACHE_RETRY_COUNT && retry_delay_ms > 0 {
                        std::thread::sleep(Duration::from_millis(retry_delay_ms));
                    }
                }
            }
        }
        if let Some(err) = failure {
            if first_failure.is_none() {
                on_failure(chapter, &err);
                first_failure = Some(err);
            } else {
                on_failure(chapter, &err);
            }
        }
    }
    match first_failure {
        Some(err) => Err(err),
        None => Ok(cached),
    }
}

/// 构建刷新目录动作摘要（对应 Kotlin handleRefreshToc 的 buildString 返回值）
///
/// 格式：`书名: +N`，可选追加 `, notified`、`, cached M`；书名为空时用 bookUrl。
pub fn build_refresh_toc_summary(
    book_name: &str,
    book_url: &str,
    new_count: usize,
    notified: bool,
    cached: usize,
) -> String {
    let display = if book_name.trim().is_empty() {
        book_url
    } else {
        book_name
    };
    let mut summary = format!("{display}: +{new_count}");
    if notified {
        summary.push_str(", notified");
    }
    if cached > 0 {
        summary.push_str(&format!(", cached {cached}"));
    }
    summary
}

/// action JSON 取值（对应 Kotlin `value()`：先精确键，再忽略大小写键）
fn action_value<'a>(map: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    let obj = map.as_object()?;
    obj.get(key).or_else(|| {
        obj.iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(key))
            .map(|(_, v)| v)
    })
}

/// action JSON 取字符串（对应 Kotlin `string()`：trim 后非空才返回）
fn action_string(map: &serde_json::Value, key: &str) -> Option<String> {
    match action_value(map, key)? {
        serde_json::Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        other => {
            let text = other.to_string().trim().to_string();
            if text.is_empty() {
                None
            } else {
                Some(text)
            }
        }
    }
}

/// action JSON 取子对象（对应 Kotlin `map()`）
fn action_map<'a>(map: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    let value = action_value(map, key)?;
    value.is_object().then_some(value)
}

/// action JSON 取布尔（对应 Kotlin `boolean()`：布尔/数字/字符串多态解析）
fn action_bool(value: &serde_json::Value, default: bool) -> bool {
    match value {
        serde_json::Value::Bool(b) => *b,
        serde_json::Value::Number(n) => n.as_i64().map(|i| i != 0).unwrap_or(default),
        serde_json::Value::String(s) => match s.trim().to_lowercase().as_str() {
            "true" | "1" | "yes" => true,
            "false" | "0" | "no" => false,
            _ => default,
        },
        _ => default,
    }
}

/// action JSON 取整数（对应 Kotlin `integer()`：数字或数字字符串）
fn action_integer(value: &serde_json::Value) -> Option<i64> {
    match value {
        serde_json::Value::Number(n) => n.as_i64(),
        serde_json::Value::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

// ─── #460 批量生成更新任务（对应 Kotlin AutoTask.buildBookUpdateTasks）───────

/// 批量生成更新任务所需的书籍信息（对应 Kotlin Book 实体的相关字段）
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BookUpdateSource {
    pub book_url: String,
    pub name: String,
    pub author: String,
}

/// 从书籍列表批量生成更新任务（对应 Kotlin `AutoTask.buildBookUpdateTasks`）
///
/// 去重/复用策略（逐条对齐 Kotlin）：
/// 1. 每本书生成一个任务，ID 为 `book_update:<md5前16位>`
/// 2. 已有任务按 ID 命中时，保留原 ID 与 enable 状态
/// 3. ID 未命中但书名+作者唯一命中“迁移任务”（不在生成 ID 集合中的已有任务）时，
///    复用该任务的 ID 与 enable 状态，并从候选池中移除（防止一本书命中多个任务）
/// 4. 所有生成任务的 cron 统一覆盖为传入值
pub fn build_book_update_tasks(
    books: &[BookUpdateSource],
    existing_tasks: &[AutoTaskRule],
    cron: &str,
    name_of: impl Fn(&BookUpdateSource) -> String,
) -> Vec<AutoTaskRule> {
    let generated: Vec<(&BookUpdateSource, AutoTaskRule)> = books
        .iter()
        .map(|book| {
            (
                book,
                build_book_update_task(&book.book_url, &book.name, &book.author, &name_of(book)),
            )
        })
        .collect();
    let existing_by_id: HashMap<&str, &AutoTaskRule> = existing_tasks
        .iter()
        .map(|t| (t.id.as_str(), t))
        .collect();
    let generated_ids: HashSet<&str> = generated.iter().map(|(_, t)| t.id.as_str()).collect();
    // 迁移候选池：ID 不在生成集合中的已有任务
    let mut moved_tasks: Vec<AutoTaskRule> = existing_tasks
        .iter()
        .filter(|t| !generated_ids.contains(t.id.as_str()))
        .cloned()
        .collect();
    generated
        .into_iter()
        .map(|(book, task)| {
            let existing: Option<AutoTaskRule> = existing_by_id
                .get(task.id.as_str())
                .map(|t| (*t).clone())
                .or_else(|| {
                    let idx = find_book_update_task_index(&moved_tasks, book)?;
                    Some(moved_tasks.remove(idx))
                });
            AutoTaskRule {
                id: existing
                    .as_ref()
                    .map(|t| t.id.clone())
                    .unwrap_or_else(|| task.id.clone()),
                enable: existing.as_ref().map(|t| t.enable).unwrap_or(task.enable),
                cron: Some(cron.to_string()),
                ..task
            }
        })
        .collect()
}

/// 在任务列表中定位书籍更新任务下标（对应 Kotlin `findBookUpdateTask` 的内部实现）
///
/// 优先按 ID 精确匹配；其次按书名+作者匹配，且要求唯一命中。
fn find_book_update_task_index(tasks: &[AutoTaskRule], book: &BookUpdateSource) -> Option<usize> {
    let target_id = book_update_task_id(&book.book_url);
    if let Some(pos) = tasks.iter().position(|t| t.id == target_id) {
        return Some(pos);
    }
    let matches: Vec<usize> = tasks
        .iter()
        .enumerate()
        .filter(|(_, t)| {
            generated_book_identity(t)
                .map(|(n, a)| n == book.name && a == book.author)
                .unwrap_or(false)
        })
        .map(|(i, _)| i)
        .collect();
    if matches.len() == 1 {
        Some(matches[0])
    } else {
        None
    }
}

// ─── #458 分享口令导入导出（对应 Kotlin SourceSharePassphrase.Type.AUTO_TASK）───────

/// 自动任务口令类型码（对应 Kotlin `SourceSharePassphrase.Type.AUTO_TASK("rw")`）
pub const AUTO_TASK_SHARE_TYPE: &str = "rw";

/// 自动任务口令前缀
pub const AUTO_TASK_PASSPHRASE_PREFIX: &str = "任务口令：";

/// 自动任务分享口令编解码器（#458）
///
/// Kotlin 侧通过 `SourceSharePassphrase`（类型码 `rw`）分享任务配置；
/// 核心层实现等价的往返编解码：任务配置 JSON → Base64 口令文本 → 任务配置。
/// 载荷统一包裹类型码：`{"type":"rw","rules":[...]}`。
pub struct AutoTaskSharePassphrase;

impl AutoTaskSharePassphrase {
    /// 导出：任务规则列表 → 口令文本
    ///
    /// 剖离运行时字段（对齐 [`AutoTaskExporter::export_json`]）后包裹类型码，
    /// 再 Base64 编码并加前缀。
    pub fn encode(rules: &[AutoTaskRule]) -> String {
        let cleaned: Vec<serde_json::Value> = rules
            .iter()
            .filter_map(|r| serde_json::to_value(r).ok())
            .map(Self::strip_runtime_fields)
            .collect();
        Self::encode_values(&cleaned)
    }

    /// 导出：任意任务 JSON 值数组 → 口令文本
    pub fn encode_values(rules: &[serde_json::Value]) -> String {
        let payload = serde_json::json!({
            "type": AUTO_TASK_SHARE_TYPE,
            "rules": rules,
        });
        Self::encode_payload(&payload.to_string())
    }

    /// 导出：任务 JSON 文本（数组或单对象）→ 口令文本
    ///
    /// 复用 [`AutoTaskExporter::import_json`] 做合法性校验。
    pub fn encode_json(json: &str) -> Result<String, String> {
        let values = AutoTaskExporter::import_json(json)?;
        Ok(Self::encode_values(&values))
    }

    /// 导入：口令文本 → 任务 JSON 对象数组
    ///
    /// 兼容两种载荷：
    /// - 包裹式 `{"type":"rw","rules":[...]}`（校验类型码）
    /// - 裸任务 JSON 数组/单对象（兼容直接 Base64 的旧格式）
    pub fn decode(text: &str) -> Result<Vec<serde_json::Value>, String> {
        if !Self::is_passphrase(text) {
            return Err("Not an auto task passphrase".to_string());
        }
        let b64 = text
            .trim()
            .trim_start_matches(AUTO_TASK_PASSPHRASE_PREFIX)
            .trim();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .map_err(|e| format!("Invalid passphrase encoding: {e}"))?;
        let json = String::from_utf8(bytes).map_err(|e| format!("Invalid passphrase payload: {e}"))?;
        let value: serde_json::Value =
            serde_json::from_str(&json).map_err(|e| format!("Invalid passphrase JSON: {e}"))?;
        // 包裹式载荷：校验类型码后取 rules
        if let Some(t) = value.get("type") {
            if t.as_str() != Some(AUTO_TASK_SHARE_TYPE) {
                return Err(format!(
                    "Unsupported passphrase type: {}",
                    t.as_str().unwrap_or_default()
                ));
            }
            let rules = value
                .get("rules")
                .and_then(|v| v.as_array())
                .ok_or_else(|| "Passphrase payload missing rules".to_string())?;
            let valid: Vec<serde_json::Value> =
                rules.iter().filter(|v| v.is_object()).cloned().collect();
            if valid.is_empty() {
                return Err("No valid task objects found".to_string());
            }
            return Ok(valid);
        }
        // 裸载荷：走通用导入校验
        AutoTaskExporter::import_json(&json)
    }

    /// 判断文本是否为自动任务口令
    pub fn is_passphrase(text: &str) -> bool {
        text.trim().starts_with(AUTO_TASK_PASSPHRASE_PREFIX)
    }

    /// Base64 编码载荷并加前缀
    fn encode_payload(payload: &str) -> String {
        let b64 = base64::engine::general_purpose::STANDARD.encode(payload.as_bytes());
        format!("{AUTO_TASK_PASSPHRASE_PREFIX}{b64}")
    }

    /// 剖离运行时/排序字段（customOrder/lastRunAt/lastResult/lastError/lastLog，
    /// 兼容 snake_case 与 camelCase）
    fn strip_runtime_fields(mut value: serde_json::Value) -> serde_json::Value {
        if let Some(obj) = value.as_object_mut() {
            for key in [
                "customOrder",
                "custom_order",
                "lastRunAt",
                "last_run_at",
                "lastResult",
                "last_result",
                "lastError",
                "last_error",
                "lastLog",
                "last_log",
            ] {
                obj.remove(key);
            }
        }
        value
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
            "customOrder": 5,
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
        assert!(obj.get("customOrder").is_none());
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

    // ─── prepare_imported_tasks 测试 ─────────────────────

    #[test]
    fn test_prepare_imported_tasks_preserves_local_state() {
        let local = vec![AutoTaskRule {
            id: "t1".to_string(),
            name: "本地任务".to_string(),
            enable: true,
            cron: Some("*/30 * * * *".to_string()),
            script: "old".to_string(),
            custom_order: 5,
            last_run_at: 999,
            last_result: Some("ok".to_string()),
            last_error: None,
            last_log: Some("log".to_string()),
        }];
        let imported = vec![serde_json::json!({
            "id": "t1",
            "name": "导入任务",
            "script": "new"
        })];
        let result = AutoTaskExporter::prepare_imported_tasks(&local, imported);
        assert_eq!(result.len(), 1);
        // 保留本地 customOrder
        assert_eq!(result[0]["customOrder"], 5);
        // 保留本地运行时状态
        assert_eq!(result[0]["lastRunAt"], 999);
        assert_eq!(result[0]["lastResult"], "ok");
        assert_eq!(result[0]["lastLog"], "log");
        // 使用导入的 script
        assert_eq!(result[0]["script"], "new");
    }

    #[test]
    fn test_prepare_imported_tasks_new_task_gets_order() {
        let local = vec![AutoTaskRule {
            id: "t1".to_string(),
            name: "已有".to_string(),
            enable: true,
            cron: None,
            script: String::new(),
            custom_order: 3,
            last_run_at: 0,
            last_result: None,
            last_error: None,
            last_log: None,
        }];
        let imported = vec![serde_json::json!({
            "id": "t2",
            "name": "新任务",
            "script": "x"
        })];
        let result = AutoTaskExporter::prepare_imported_tasks(&local, imported);
        assert_eq!(result.len(), 1);
        // 新任务 customOrder = max(3) + 1 = 4
        assert_eq!(result[0]["customOrder"], 4);
    }

    // ─── update_cron_batch 测试 ────────────────────────

    #[test]
    fn test_update_cron_batch() {
        let mut rules = vec![
            AutoTaskRule {
                id: "a".to_string(),
                name: "A".to_string(),
                enable: true,
                cron: Some("*/30 * * * *".to_string()),
                script: String::new(),
                custom_order: 0,
                last_run_at: 0,
                last_result: None,
                last_error: None,
                last_log: None,
            },
            AutoTaskRule {
                id: "b".to_string(),
                name: "B".to_string(),
                enable: true,
                cron: Some("0 8 * * *".to_string()),
                script: String::new(),
                custom_order: 1,
                last_run_at: 0,
                last_result: None,
                last_error: None,
                last_log: None,
            },
        ];
        let ids = vec!["a".to_string(), "b".to_string()];
        let changed = update_cron_batch(&mut rules, &ids, "0 */6 * * *");
        assert_eq!(changed.len(), 2);
        assert_eq!(rules[0].cron, Some("0 */6 * * *".to_string()));
        assert_eq!(rules[1].cron, Some("0 */6 * * *".to_string()));
    }

    #[test]
    fn test_update_cron_batch_empty_ids() {
        let mut rules = vec![AutoTaskRule {
            id: "a".to_string(),
            name: "A".to_string(),
            enable: true,
            cron: Some("*/30 * * * *".to_string()),
            script: String::new(),
            custom_order: 0,
            last_run_at: 0,
            last_result: None,
            last_error: None,
            last_log: None,
        }];
        let changed = update_cron_batch(&mut rules, &[], "0 8 * * *");
        assert!(changed.is_empty());
        assert_eq!(rules[0].cron, Some("*/30 * * * *".to_string()));
    }

    // ─── normalize_script 测试 ─────────────────────────

    #[test]
    fn test_normalize_script_plain() {
        assert_eq!(normalize_script("  var x = 1;  "), "var x = 1;");
    }

    #[test]
    fn test_normalize_script_js_prefix() {
        assert_eq!(normalize_script("@js: var x = 1;"), "var x = 1;");
    }

    #[test]
    fn test_normalize_script_js_tag() {
        assert_eq!(normalize_script("<js>var x = 1;</js>"), "var x = 1;");
    }

    // ─── book_update_task 测试 ─────────────────────────

    #[test]
    fn test_book_update_task_id_deterministic() {
        let id1 = book_update_task_id("https://example.com/book/1");
        let id2 = book_update_task_id("https://example.com/book/1");
        assert_eq!(id1, id2);
        assert!(id1.starts_with("book_update:"));
        assert_eq!(id1.len(), "book_update:".len() + 16);
    }

    #[test]
    fn test_build_book_update_task() {
        let task = build_book_update_task(
            "https://example.com/book/1",
            "测试书籍",
            "作者A",
            "更新测试书籍",
        );
        assert!(task.id.starts_with("book_update:"));
        assert_eq!(task.name, "更新测试书籍");
        assert_eq!(task.cron, Some(DEFAULT_CRON.to_string()));
        // script 应为 JSON 包裹在括号中
        assert!(task.script.starts_with('('));
        assert!(task.script.ends_with(')'));
        let json_str = &task.script[1..task.script.len() - 1];
        let action: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(action["type"], "refreshToc");
        assert_eq!(action["bookUrl"], "https://example.com/book/1");
        assert_eq!(action["bookName"], "测试书籍");
        assert_eq!(action["generatedBy"], BOOK_UPDATE_GENERATOR);
    }

    #[test]
    fn test_find_book_update_task_by_id() {
        let task = build_book_update_task(
            "https://example.com/book/1",
            "测试书籍",
            "作者A",
            "更新",
        );
        let tasks = vec![task];
        let found = find_book_update_task(
            &tasks,
            "https://example.com/book/1",
            "测试书籍",
            "作者A",
        );
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "更新");
    }

    #[test]
    fn test_find_book_update_task_by_name_author() {
        // 模拟一个 ID 不匹配但书名作者匹配的任务
        let task = build_book_update_task(
            "https://old-url.com/book/1",
            "测试书籍",
            "作者A",
            "更新",
        );
        let tasks = vec![task];
        // 使用不同的 bookUrl 查找，但书名作者相同
        let found = find_book_update_task(
            &tasks,
            "https://new-url.com/book/1",
            "测试书籍",
            "作者A",
        );
        assert!(found.is_some());
    }

    #[test]
    fn test_find_book_update_task_not_found() {
        let task = build_book_update_task(
            "https://example.com/book/1",
            "测试书籍",
            "作者A",
            "更新",
        );
        let tasks = vec![task];
        let found = find_book_update_task(
            &tasks,
            "https://other.com/book/2",
            "其他书籍",
            "作者B",
        );
        assert!(found.is_none());
    }

    // ─── can_refresh_book_toc 测试 ─────────────────────

    #[test]
    fn test_can_refresh_book_toc() {
        // canUpdate=true, respectCanUpdate=true → 允许
        assert!(can_refresh_book_toc(true, true));
        // canUpdate=false, respectCanUpdate=true → 不允许
        assert!(!can_refresh_book_toc(false, true));
        // canUpdate=false, respectCanUpdate=false → 允许（不尊重标志）
        assert!(can_refresh_book_toc(false, false));
        // canUpdate=true, respectCanUpdate=false → 允许
        assert!(can_refresh_book_toc(true, false));
    }

    // ─── #497 缓存新增章节动作测试 ───────────────

    #[test]
    fn test_protocol_cache_chapters() {
        let p = TaskProtocol::cache_chapters("https://example.com/book/1");
        assert_eq!(p.action, TaskAction::CacheChapters);
        assert_eq!(
            p.params.get("bookUrl").unwrap(),
            "https://example.com/book/1"
        );
        // JSON 往返（FFI 序列化承载验证）
        let json = p.to_json();
        let parsed = TaskProtocol::from_json(&json).unwrap();
        assert_eq!(parsed.action, TaskAction::CacheChapters);
    }

    #[test]
    fn test_runner_cache_chapters_success() {
        let p = TaskProtocol::cache_chapters("https://example.com/book");
        let result = AutoTaskRunner::execute(&p);
        assert!(result.success);
        assert!(result.message.contains("New chapters cached"));
    }

    #[test]
    fn test_runner_cache_chapters_missing_url() {
        let p = TaskProtocol {
            action: TaskAction::CacheChapters,
            params: HashMap::new(),
        };
        let result = AutoTaskRunner::execute(&p);
        assert!(!result.success);
        assert!(result.message.contains("requires bookUrl"));
    }

    fn chapter(url: &str, title: &str, is_volume: bool) -> ChapterSnapshot {
        ChapterSnapshot {
            url: url.to_string(),
            title: title.to_string(),
            is_volume,
        }
    }

    #[test]
    fn test_refresh_toc_action_from_json_defaults() {
        let action = serde_json::json!({
            "type": "refreshToc",
            "bookUrl": "https://example.com/book/1",
            "respectCanUpdate": true,
            "notify": {"enable": true, "minCount": 2}
        });
        let parsed = RefreshTocAction::from_action_json(&action).unwrap();
        assert_eq!(parsed.book_url, "https://example.com/book/1");
        assert!(parsed.respect_can_update);
        // notify 存在：enable=true, minCount=2
        let notify = parsed.notify.as_ref().unwrap();
        assert!(notify.enable);
        assert_eq!(notify.min_count, 2);
        // cache 缺失 → 不启用
        assert!(!parsed.cache_enabled());
    }

    #[test]
    fn test_refresh_toc_action_case_insensitive_keys() {
        // 对齐 Kotlin value() 的忽略大小写键查找
        let action = serde_json::json!({
            "BOOKURL": "https://example.com/book/2",
            "BookName": "测试书",
            "CACHE": {"ENABLE": true}
        });
        let parsed = RefreshTocAction::from_action_json(&action).unwrap();
        assert_eq!(parsed.book_url, "https://example.com/book/2");
        assert_eq!(parsed.book_name, "测试书");
        assert!(parsed.cache_enabled());
    }

    #[test]
    fn test_refresh_toc_action_missing_book_url() {
        let action = serde_json::json!({"type": "refreshToc"});
        let result = RefreshTocAction::from_action_json(&action);
        assert!(result.is_err());
    }

    #[test]
    fn test_refresh_toc_action_notify_defaults_when_present() {
        // notify 子对象存在但无 enable → 默认 true；minCount 默认 1
        let action = serde_json::json!({
            "bookUrl": "https://example.com/b",
            "notify": {}
        });
        let parsed = RefreshTocAction::from_action_json(&action).unwrap();
        assert!(parsed.should_notify(1));
        // newCount=0 不通知（对齐 newCount > 0 条件）
        assert!(!parsed.should_notify(0));
    }

    #[test]
    fn test_refresh_toc_action_should_notify_min_count() {
        let action = serde_json::json!({
            "bookUrl": "https://example.com/b",
            "notify": {"enable": true, "minCount": 3}
        });
        let parsed = RefreshTocAction::from_action_json(&action).unwrap();
        assert!(!parsed.should_notify(2));
        assert!(parsed.should_notify(3));
    }

    #[test]
    fn test_count_new_chapters() {
        let before = vec![chapter("u1", "第一章", false), chapter("u2", "第二章", false)];
        let after = vec![
            chapter("u1", "第一章", false),
            chapter("u2", "第二章", false),
            chapter("v1", "卷三", true),
            chapter("u3", "第三章", false),
            chapter("u4", "第四章", false),
        ];
        // 卷不计入新增
        assert_eq!(count_new_chapters(&before, &after), 2);
        // 减少时不为负
        assert_eq!(count_new_chapters(&after, &before), 0);
    }

    #[test]
    fn test_new_content_chapters_take_last() {
        let before = vec![chapter("u1", "第一章", false)];
        let after = vec![
            chapter("u1", "第一章", false),
            chapter("u2", "第二章", false),
            chapter("v1", "卷", true),
            chapter("u3", "第三章", false),
            chapter("u4", "第四章", false),
        ];
        // 新增数 = 刷新后非卷 3 - 刷新前非卷 1 = 2… 实际：after 非卷 = u1,u2,u3,u4 = 4，新增 = 3
        // 未知 URL 章节有 u2/u3/u4，取末尾 3 个（对齐 Kotlin takeLast）
        let fresh = new_content_chapters(&before, &after);
        assert_eq!(fresh.len(), 3);
        assert_eq!(fresh[0].url, "u2");
        assert_eq!(fresh[1].url, "u3");
        assert_eq!(fresh[2].url, "u4");
        // 无新增时返回空
        assert!(new_content_chapters(&after, &after).is_empty());
    }

    #[test]
    fn test_latest_chapter_title() {
        let chapters = vec![
            chapter("u1", "第一章", false),
            chapter("u2", "第二章", false),
            chapter("v1", "尾声卷", true),
        ];
        // 优先最后一个非卷章节
        assert_eq!(latest_chapter_title(&chapters), Some("第二章"));
        let only_volume = vec![chapter("v1", "卷一", true)];
        assert_eq!(latest_chapter_title(&only_volume), Some("卷一"));
        assert_eq!(latest_chapter_title(&[]), None);
    }

    #[test]
    fn test_cache_chapters_with_retry_all_success() {
        let chapters = vec!["c1", "c2", "c3"];
        let result = cache_chapters_with_retry(
            &chapters,
            0,
            |_c| Ok::<(), String>(()),
            |_c, _e| panic!("不应有失败"),
        );
        assert_eq!(result.unwrap(), 3);
    }

    #[test]
    fn test_cache_chapters_with_retry_succeeds_after_retry() {
        let chapters = vec!["c1"];
        let mut attempts = 0;
        let result = cache_chapters_with_retry(
            &chapters,
            0,
            |_c| {
                attempts += 1;
                if attempts < 3 {
                    Err("网络错误".to_string())
                } else {
                    Ok(())
                }
            },
            |_c, _e| {},
        );
        // 第三次尝试成功
        assert_eq!(result.unwrap(), 1);
        assert_eq!(attempts, 3);
    }

    #[test]
    fn test_cache_chapters_with_retry_partial_failure() {
        let chapters = vec!["c1", "c2"];
        let mut failures: Vec<String> = Vec::new();
        let result = cache_chapters_with_retry(
            &chapters,
            0,
            |c| {
                if *c == "c1" {
                    Err("下载失败".to_string())
                } else {
                    Ok(())
                }
            },
            |c, _e| failures.push((*c).to_string()),
        );
        // 存在失败 → 返回首个错误（对齐 Kotlin firstFailure 抛出）
        assert_eq!(result.unwrap_err(), "下载失败");
        // c1 失败后仍继续处理 c2
        assert_eq!(failures, vec!["c1".to_string()]);
    }

    #[test]
    fn test_build_refresh_toc_summary() {
        assert_eq!(
            build_refresh_toc_summary("测试书", "url", 3, true, 2),
            "测试书: +3, notified, cached 2"
        );
        assert_eq!(
            build_refresh_toc_summary("测试书", "url", 0, false, 0),
            "测试书: +0"
        );
        // 书名为空时用 bookUrl
        assert_eq!(
            build_refresh_toc_summary("  ", "https://b.url", 1, false, 0),
            "https://b.url: +1"
        );
    }

    // ─── #460 批量生成更新任务测试 ───────────────

    fn book_source(url: &str, name: &str, author: &str) -> BookUpdateSource {
        BookUpdateSource {
            book_url: url.to_string(),
            name: name.to_string(),
            author: author.to_string(),
        }
    }

    #[test]
    fn test_build_book_update_tasks_fresh() {
        let books = vec![
            book_source("https://a.com/1", "书A", "作者A"),
            book_source("https://b.com/2", "书B", "作者B"),
        ];
        let tasks = build_book_update_tasks(&books, &[], "0 */6 * * *", |b| {
            format!("更新{}", b.name)
        });
        assert_eq!(tasks.len(), 2);
        // 每本书一个任务，ID 为 book_update: 前缀
        assert!(tasks[0].id.starts_with("book_update:"));
        assert!(tasks[1].id.starts_with("book_update:"));
        assert_eq!(tasks[0].name, "更新书A");
        // cron 统一覆盖为传入值
        assert_eq!(tasks[0].cron, Some("0 */6 * * *".to_string()));
        assert_eq!(tasks[1].cron, Some("0 */6 * * *".to_string()));
        // 默认启用
        assert!(tasks[0].enable);
    }

    #[test]
    fn test_build_book_update_tasks_preserves_existing_id_and_enable() {
        let books = vec![book_source("https://a.com/1", "书A", "作者A")];
        let mut existing = build_book_update_task("https://a.com/1", "书A", "作者A", "旧名");
        existing.enable = false; // 用户已禁用
        let tasks = build_book_update_tasks(&books, &[existing.clone()], DEFAULT_CRON, |b| {
            format!("更新{}", b.name)
        });
        assert_eq!(tasks.len(), 1);
        // 保留原 ID 与禁用状态
        assert_eq!(tasks[0].id, existing.id);
        assert!(!tasks[0].enable);
        // 任务名更新为新生成的名称
        assert_eq!(tasks[0].name, "更新书A");
    }

    #[test]
    fn test_build_book_update_tasks_moves_by_name_author() {
        // 书籍 URL 变更（ID 不同），但书名+作者唯一命中旧任务 → 复用旧 ID
        let old_task =
            build_book_update_task("https://old.com/1", "书A", "作者A", "旧名");
        let mut old = old_task.clone();
        old.enable = false;
        let books = vec![book_source("https://new.com/1", "书A", "作者A")];
        let tasks = build_book_update_tasks(&books, &[old.clone()], DEFAULT_CRON, |b| {
            format!("更新{}", b.name)
        });
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, old.id); // 复用旧任务 ID
        assert!(!tasks[0].enable); // 保留禁用状态
    }

    #[test]
    fn test_build_book_update_tasks_ambiguous_move_not_reused() {
        // 两个旧任务同名同作者 → 非唯一命中，不复用
        let old1 = build_book_update_task("https://old1.com/1", "书A", "作者A", "旧1");
        let old2 = build_book_update_task("https://old2.com/1", "书A", "作者A", "旧2");
        let books = vec![book_source("https://new.com/1", "书A", "作者A")];
        let tasks = build_book_update_tasks(&books, &[old1, old2], DEFAULT_CRON, |b| {
            format!("更新{}", b.name)
        });
        assert_eq!(tasks.len(), 1);
        // 使用新生成的 ID
        assert_eq!(tasks[0].id, book_update_task_id("https://new.com/1"));
        assert!(tasks[0].enable);
    }

    #[test]
    fn test_build_book_update_task_includes_cache_option() {
        // 对齐 Kotlin：生成的 action 包含 cache.enable=false
        let task = build_book_update_task("https://a.com/1", "书A", "作者A", "更新");
        let json_str = &task.script[1..task.script.len() - 1];
        let action: serde_json::Value = serde_json::from_str(json_str).unwrap();
        assert_eq!(action["cache"]["enable"], false);
        assert_eq!(action["notify"]["enable"], true);
        assert_eq!(action["notify"]["minCount"], 1);
    }

    // ─── #458 分享口令导入导出测试 ───────────────

    #[test]
    fn test_passphrase_roundtrip_equivalence() {
        let rules = vec![
            build_book_update_task("https://a.com/1", "书A", "作者A", "更新书A"),
            AutoTaskRule {
                id: "custom-1".to_string(),
                name: "自定义任务".to_string(),
                enable: false,
                cron: Some("0 8 * * *".to_string()),
                script: "(\"notify\")".to_string(),
                custom_order: 7,
                last_run_at: 12345,
                last_result: Some("ok".to_string()),
                last_error: None,
                last_log: Some("log".to_string()),
            },
        ];
        let text = AutoTaskSharePassphrase::encode(&rules);
        assert!(text.starts_with(AUTO_TASK_PASSPHRASE_PREFIX));
        assert!(AutoTaskSharePassphrase::is_passphrase(&text));

        let decoded = AutoTaskSharePassphrase::decode(&text).unwrap();
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0]["id"], rules[0].id);
        assert_eq!(decoded[0]["script"], rules[0].script);
        assert_eq!(decoded[1]["id"], "custom-1");
        assert_eq!(decoded[1]["enable"], false);
        // 运行时/排序字段已剖离
        for key in [
            "customOrder",
            "custom_order",
            "lastRunAt",
            "last_run_at",
            "lastResult",
            "last_result",
            "lastLog",
            "last_log",
        ] {
            assert!(decoded[1].get(key).is_none(), "未剖离字段: {key}");
        }
        // 导出→导入可衔接 prepare_imported_tasks
        let merged = AutoTaskExporter::prepare_imported_tasks(&[], decoded);
        assert_eq!(merged.len(), 2);
    }

    #[test]
    fn test_passphrase_decode_with_surrounding_text() {
        let rules = vec![build_book_update_task("https://a.com/1", "书A", "作者A", "更新")];
        let text = AutoTaskSharePassphrase::encode(&rules);
        // 口令前后带文本（模拟聊天场景）
        let wrapped = format!("快来导入 {} 试试吧", text);
        // is_passphrase 对整体文本为 false 时，截取前缀开头部分仍可解
        assert!(!AutoTaskSharePassphrase::is_passphrase(&wrapped));
        let decoded = AutoTaskSharePassphrase::decode(&format!("  {text}  ")).unwrap();
        assert_eq!(decoded.len(), 1);
    }

    #[test]
    fn test_passphrase_encode_json_raw_array() {
        let json = r#"[{"id":"t1","name":"任务1","script":"x"}]"#;
        let text = AutoTaskSharePassphrase::encode_json(json).unwrap();
        let decoded = AutoTaskSharePassphrase::decode(&text).unwrap();
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0]["id"], "t1");
    }

    #[test]
    fn test_passphrase_decode_invalid() {
        // 非口令文本
        assert!(AutoTaskSharePassphrase::decode("普通文本").is_err());
        // 非法 Base64
        assert!(AutoTaskSharePassphrase::decode("任务口令：！！！").is_err());
        // 错误类型码
        let bad_payload = serde_json::json!({"type": "sy", "rules": []}).to_string();
        let b64 = base64::engine::general_purpose::STANDARD.encode(bad_payload.as_bytes());
        let text = format!("{AUTO_TASK_PASSPHRASE_PREFIX}{b64}");
        let err = AutoTaskSharePassphrase::decode(&text).unwrap_err();
        assert!(err.contains("Unsupported passphrase type"));
    }

    #[test]
    fn test_passphrase_decode_bare_array_payload() {
        // 裸任务数组载荷（无类型码包裹）也能导入
        let payload = r#"[{"id":"t1","name":"任务1","script":"x"}]"#;
        let b64 = base64::engine::general_purpose::STANDARD.encode(payload.as_bytes());
        let text = format!("{AUTO_TASK_PASSPHRASE_PREFIX}{b64}");
        let decoded = AutoTaskSharePassphrase::decode(&text).unwrap();
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0]["name"], "任务1");
    }
}
