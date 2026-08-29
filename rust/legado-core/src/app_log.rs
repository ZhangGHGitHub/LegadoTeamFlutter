//! 应用日志体系（Task #79，对齐 Kotlin `AppLog.kt` + 上游 #512/#524/#543）
//!
//! Kotlin 原版（`app/src/main/java/io/legado/app/constant/AppLog.kt`）以
//! `ArrayList<Triple<Long, String, Throwable?>>` 保存应用消息日志（上限 100 条，
//! 最新在前），经 EventBus `APP_LOG_UPDATED` 驱动 `AppLogDialog` 实时刷新；
//! #543 增加导出（`menu_export`，文本超过 64_000 字符时落文件分享）。
//!
//! Rust 侧在此建立进程级应用日志缓冲：
//!
//! - 三级日志：`message`（应用消息）/ `crash`（崩溃）/ `http`（请求日志），
//!   分级缓冲互不挤占（Kotlin 单级混存 → Rust 三级分桶增强）
//! - 线程安全环形缓冲（`Mutex` + `VecDeque`，每级容量上限 [`MAX_LOGS_PER_LEVEL`]），
//!   最新条目在队首（对齐 Kotlin `mLogs.add(0, ...)` 语义）
//! - 日志条目 [`LogEntry`]：timestamp（毫秒）/ level / message，
//!   对齐 Kotlin `Triple<Long, String, Throwable?>` 的 JSON 化形态
//! - 导出 [`AppLogStore::export_text`]：全级别合并按时间升序格式化，
//!   超过 [`MAX_EXPORT_CHARS`]（64_000，对齐 #543 `MAX_SHARE_TEXT`）按字符边界截断
//! - 全局单例（`OnceLock`），经 [`app_log_store`] 访问
//!
//! 时间戳格式化为 `yyyy-MM-dd HH:mm:ss.SSS`（UTC，引擎侧无时区依赖；
//! UI 轨如需本地时区展示可自行二次格式化）。

use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

/// 每级日志环形缓冲容量上限（Kotlin 原版为 100 条混存，Rust 三级各 500）
pub const MAX_LOGS_PER_LEVEL: usize = 500;

/// 导出文本字符上限（对齐 #543 `AppLogDialog.MAX_SHARE_TEXT = 64_000`）
pub const MAX_EXPORT_CHARS: usize = 64_000;

/// 日志级别（对齐 Kotlin 体系的 message/crash/http 三类）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    /// 应用消息日志（对应 Kotlin `AppLog.put`）
    Message,
    /// 崩溃日志（对应 Kotlin CrashHandler 体系）
    Crash,
    /// HTTP 请求日志（对应 Kotlin `HttpLogStore`）
    Http,
}

impl LogLevel {
    /// 全部级别（固定顺序：message / crash / http）
    pub const ALL: [LogLevel; 3] = [LogLevel::Message, LogLevel::Crash, LogLevel::Http];

    /// 级别名称（小写，用于 JSON / 文本标签）
    pub fn as_str(self) -> &'static str {
        match self {
            LogLevel::Message => "message",
            LogLevel::Crash => "crash",
            LogLevel::Http => "http",
        }
    }

    /// 级别显示标签（导出文本用，大写）
    pub fn as_label(self) -> &'static str {
        match self {
            LogLevel::Message => "MESSAGE",
            LogLevel::Crash => "CRASH",
            LogLevel::Http => "HTTP",
        }
    }

    /// 从字符串解析（大小写不敏感），非法值返回 `None`
    pub fn parse(s: &str) -> Option<LogLevel> {
        match s.to_ascii_lowercase().as_str() {
            "message" => Some(LogLevel::Message),
            "crash" => Some(LogLevel::Crash),
            "http" => Some(LogLevel::Http),
            _ => None,
        }
    }

    /// 级别在缓冲数组中的下标
    fn index(self) -> usize {
        match self {
            LogLevel::Message => 0,
            LogLevel::Crash => 1,
            LogLevel::Http => 2,
        }
    }
}

/// 日志条目（对齐 Kotlin `Triple<Long, String, Throwable?>` 的 JSON 形态）
///
/// JSON 字段：`timestamp`（毫秒）/ `level`（"message"|"crash"|"http"）/ `message`。
/// Kotlin 侧 Throwable 在跨 FFI 传递时已退化为字符串并入 message（Dart
/// `CrashLogService.LogEntry.error` 亦为可选对象），故此处不单独建模。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogEntry {
    /// 时间戳（Unix 毫秒）
    pub timestamp: i64,
    /// 日志级别
    pub level: LogLevel,
    /// 日志消息
    pub message: String,
}

/// 应用日志存储器：三级独立的线程安全环形缓冲
///
/// 每级缓冲为 `Mutex<VecDeque<LogEntry>>`，队首为最新条目；
/// 超过 [`MAX_LOGS_PER_LEVEL`] 时从队尾弹出最旧条目（环形淘汰）。
pub struct AppLogStore {
    /// 分级缓冲（下标见 [`LogLevel::index`]：0=message / 1=crash / 2=http）
    buffers: [Mutex<VecDeque<LogEntry>>; 3],
}

impl AppLogStore {
    /// 创建空日志存储器（每级独立缓冲）
    pub fn new() -> Self {
        Self {
            buffers: [
                Mutex::new(VecDeque::with_capacity(MAX_LOGS_PER_LEVEL)),
                Mutex::new(VecDeque::with_capacity(MAX_LOGS_PER_LEVEL)),
                Mutex::new(VecDeque::with_capacity(MAX_LOGS_PER_LEVEL)),
            ],
        }
    }

    /// 写入一条日志（最新在队首；超容量时环形淘汰最旧条目）
    ///
    /// 对齐 Kotlin `AppLog.put` 的 `mLogs.add(0, ...)` + `removeLastOrNull()` 语义。
    pub fn push(&self, level: LogLevel, message: impl Into<String>) {
        let message = message.into();
        let entry = LogEntry {
            timestamp: now_millis(),
            level,
            message,
        };
        let mut buf = self.buffers[level.index()].lock().unwrap();
        if buf.len() >= MAX_LOGS_PER_LEVEL {
            buf.pop_back();
        }
        buf.push_front(entry);
    }

    /// 获取指定级别的日志列表（最新在前，对齐 Kotlin `AppLog.logs`）
    pub fn logs(&self, level: LogLevel) -> Vec<LogEntry> {
        self.buffers[level.index()]
            .lock()
            .unwrap()
            .iter()
            .cloned()
            .collect()
    }

    /// 指定级别的日志条数
    pub fn len(&self, level: LogLevel) -> usize {
        self.buffers[level.index()].lock().unwrap().len()
    }

    /// 指定级别是否为空
    pub fn is_empty(&self, level: LogLevel) -> bool {
        self.len(level) == 0
    }

    /// 清空指定级别的日志（对齐 Kotlin `AppLog.clear` 的分级版）
    pub fn clear(&self, level: LogLevel) {
        self.buffers[level.index()].lock().unwrap().clear();
    }

    /// 清空全部级别日志（对齐 #543 清空确认后的 `AppLog.clear() + HttpLogStore.clear()`）
    pub fn clear_all(&self) {
        for level in LogLevel::ALL {
            self.clear(level);
        }
    }

    /// 导出全部日志为文本（对齐 Kotlin `AppLog.exportText` + #543 截断）
    ///
    /// - 三级合并按时间戳**升序**排列（Kotlin 内存态最新在前，导出用
    ///   `asReversed()` 转为最旧在前，此处等价）
    /// - 行格式：`yyyy-MM-dd HH:mm:ss.SSS [LEVEL] message`
    /// - 超过 [`MAX_EXPORT_CHARS`] 时按字符边界截断并追加截断标记
    pub fn export_text(&self) -> String {
        let mut all: Vec<LogEntry> = Vec::new();
        for level in LogLevel::ALL {
            let mut logs = self.logs(level);
            logs.reverse(); // 转为最旧在前（对齐 Kotlin exportText 的 asReversed）
            all.extend(logs);
        }
        // 稳定排序：仅按时间戳升序；同毫秒条目保持 message/crash/http 拼接顺序
        all.sort_by_key(|e| e.timestamp);

        let mut out = String::new();
        for entry in &all {
            out.push_str(&format_timestamp_ms(entry.timestamp));
            out.push_str(" [");
            out.push_str(entry.level.as_label());
            out.push_str("] ");
            out.push_str(&entry.message);
            out.push('\n');
        }
        truncate_chars(&mut out, MAX_EXPORT_CHARS);
        out
    }
}

impl Default for AppLogStore {
    fn default() -> Self {
        Self::new()
    }
}

/// 全局日志单例槽位
static APP_LOG_STORE: OnceLock<AppLogStore> = OnceLock::new();

/// 获取全局应用日志存储器（首次调用时惰性创建）
pub fn app_log_store() -> &'static AppLogStore {
    APP_LOG_STORE.get_or_init(AppLogStore::new)
}

/// 便捷入口：向全局存储器写入日志
pub fn push_log(level: LogLevel, message: impl Into<String>) {
    app_log_store().push(level, message);
}

/// 便捷入口：读取全局存储器指定级别日志（最新在前）
pub fn get_logs(level: LogLevel) -> Vec<LogEntry> {
    app_log_store().logs(level)
}

/// 便捷入口：清空全局存储器指定级别日志
pub fn clear_logs(level: LogLevel) {
    app_log_store().clear(level);
}

/// 便捷入口：导出全局存储器全部日志文本（64K 字符截断）
pub fn export_logs() -> String {
    app_log_store().export_text()
}

// ─── 内部工具 ────────────────────────────────────────────────

/// 当前 Unix 毫秒时间戳
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 将 Unix 毫秒时间戳格式化为 `yyyy-MM-dd HH:mm:ss.SSS`（UTC）
///
/// 使用 Howard Hinnant 的 civil-from-days 算法（公有领域），
/// 避免引入 chrono 依赖；与 Kotlin `SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS")` 输出形态一致。
fn format_timestamp_ms(millis: i64) -> String {
    let days = millis.div_euclid(86_400_000);
    let ms_of_day = millis.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    let hour = ms_of_day / 3_600_000;
    let minute = (ms_of_day % 3_600_000) / 60_000;
    let second = (ms_of_day % 60_000) / 1_000;
    let ms = ms_of_day % 1_000;
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        year, month, day, hour, minute, second, ms
    )
}

/// civil-from-days（Hinnant 算法）：自 1970-01-01 的天数 → (年, 月, 日)
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097); // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 按字符边界截断字符串（对齐 #543 的 64_000 上限），超限时追加截断标记。
///
/// 不变量：截断后字符数恒 ≤ `max_chars`（上限小于标记长度时不追加标记）。
fn truncate_chars(s: &mut String, max_chars: usize) {
    let count = s.chars().count();
    if count <= max_chars {
        return;
    }
    let marker = "\n…[日志过长已截断]";
    let marker_len = marker.chars().count();
    // 极小上限（不超过标记长度）：直接硬截断，保证不超限
    let keep = match max_chars.checked_sub(marker_len) {
        Some(k) if k > 0 => k,
        _ => {
            let cut = s
                .char_indices()
                .nth(max_chars)
                .map(|(idx, _)| idx)
                .unwrap_or(s.len());
            s.truncate(cut);
            return;
        }
    };
    let cut = s
        .char_indices()
        .nth(keep)
        .map(|(idx, _)| idx)
        .unwrap_or(s.len());
    s.truncate(cut);
    s.push_str(marker);
}

// ─── 测试 ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 串行保护：以下测试会读写全局单例，需串行执行避免相互干扰
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn test_log_level_parse() {
        assert_eq!(LogLevel::parse("message"), Some(LogLevel::Message));
        assert_eq!(LogLevel::parse("CRASH"), Some(LogLevel::Crash));
        assert_eq!(LogLevel::parse("Http"), Some(LogLevel::Http));
        assert_eq!(LogLevel::parse("unknown"), None);
        assert_eq!(LogLevel::parse(""), None);
    }

    #[test]
    fn test_log_entry_json_roundtrip() {
        let entry = LogEntry {
            timestamp: 1_722_816_000_123,
            level: LogLevel::Crash,
            message: "测试崩溃".into(),
        };
        let json = serde_json::to_string(&entry).unwrap();
        // camelCase 对齐 Dart 模型习惯（timestamp/level/message）
        assert!(json.contains(r#""timestamp":1722816000123"#));
        assert!(json.contains(r#""level":"crash""#));
        let back: LogEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back, entry);
    }

    #[test]
    fn test_push_and_order_newest_first() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        store.push(LogLevel::Message, "第一条");
        store.push(LogLevel::Message, "第二条");
        let logs = store.logs(LogLevel::Message);
        assert_eq!(logs.len(), 2);
        assert_eq!(logs[0].message, "第二条", "最新条目应在队首（对齐 Kotlin）");
        assert_eq!(logs[1].message, "第一条");
        assert!(logs[0].timestamp >= logs[1].timestamp);
    }

    #[test]
    fn test_ring_buffer_capacity() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        for i in 0..(MAX_LOGS_PER_LEVEL + 10) {
            store.push(LogLevel::Http, format!("req-{i}"));
        }
        assert_eq!(
            store.len(LogLevel::Http),
            MAX_LOGS_PER_LEVEL,
            "超容量应环形淘汰"
        );
        let logs = store.logs(LogLevel::Http);
        assert_eq!(
            logs[0].message,
            format!("req-{}", MAX_LOGS_PER_LEVEL + 9),
            "队首应为最新条目"
        );
        assert_eq!(
            logs.last().unwrap().message,
            "req-10",
            "最旧的 10 条应被淘汰"
        );
    }

    #[test]
    fn test_levels_isolated() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        store.push(LogLevel::Message, "msg");
        store.push(LogLevel::Crash, "crash");
        store.push(LogLevel::Http, "http");
        assert_eq!(store.len(LogLevel::Message), 1);
        assert_eq!(store.len(LogLevel::Crash), 1);
        assert_eq!(store.len(LogLevel::Http), 1);
        store.clear(LogLevel::Crash);
        assert_eq!(store.len(LogLevel::Crash), 0);
        assert_eq!(store.len(LogLevel::Message), 1, "清空一级不影响其他级别");
    }

    #[test]
    fn test_clear_all() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        for level in LogLevel::ALL {
            store.push(level, "x");
        }
        store.clear_all();
        for level in LogLevel::ALL {
            assert!(store.is_empty(level));
        }
    }

    #[test]
    fn test_concurrent_push() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = std::sync::Arc::new(AppLogStore::new());
        let mut handles = Vec::new();
        // 8 线程 × 200 条 = 1600 条，远超容量 500，验证并发安全 + 环形淘汰
        for t in 0..8 {
            let store = std::sync::Arc::clone(&store);
            handles.push(std::thread::spawn(move || {
                for i in 0..200 {
                    store.push(LogLevel::Message, format!("t{t}-{i}"));
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(store.len(LogLevel::Message), MAX_LOGS_PER_LEVEL);
        // 所有保留条目必须来自合法写入（前缀匹配），无脏数据
        for entry in store.logs(LogLevel::Message) {
            assert!(
                entry.message.starts_with('t'),
                "条目应来自并发写入: {}",
                entry.message
            );
        }
    }

    #[test]
    fn test_export_text_format_and_order() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        store.push(LogLevel::Message, "消息日志");
        store.push(LogLevel::Http, "GET /api 200 12ms");
        let text = store.export_text();
        // 两条日志、升序输出（先写入的消息日志在前）
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("[MESSAGE] 消息日志"));
        assert!(lines[1].contains("[HTTP] GET /api 200 12ms"));
        // 时间格式 yyyy-MM-dd HH:mm:ss.SSS
        assert!(lines[0].chars().nth(4) == Some('-'));
        assert!(lines[0].len() > "yyyy-MM-dd HH:mm:ss.SSS".len());
    }

    #[test]
    fn test_export_truncation() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        // 每条约 1KB，500 条 × 3 级 ≈ 1.5MB，必然触发 64K 截断
        let big = "长".repeat(340); // 340 字符 ≈ 1KB UTF-8
        for _ in 0..MAX_LOGS_PER_LEVEL {
            store.push(LogLevel::Message, big.clone());
            store.push(LogLevel::Crash, big.clone());
            store.push(LogLevel::Http, big.clone());
        }
        let text = store.export_text();
        assert!(
            text.chars().count() <= MAX_EXPORT_CHARS,
            "导出文本字符数应不超过 {}（实际 {}）",
            MAX_EXPORT_CHARS,
            text.chars().count()
        );
        assert!(text.ends_with("…[日志过长已截断]"), "超限时应带截断标记");
    }

    #[test]
    fn test_export_no_truncation_when_small() {
        let _g = TEST_LOCK.lock().unwrap();
        let store = AppLogStore::new();
        store.push(LogLevel::Message, "短日志");
        let text = store.export_text();
        assert!(!text.contains("已截断"));
        assert!(text.ends_with("短日志\n"));
    }

    #[test]
    fn test_global_singleton() {
        let _g = TEST_LOCK.lock().unwrap();
        app_log_store().clear_all();
        push_log(LogLevel::Message, "全局单例写入");
        let logs = get_logs(LogLevel::Message);
        assert_eq!(logs.len(), 1);
        assert_eq!(logs[0].message, "全局单例写入");
        let exported = export_logs();
        assert!(exported.contains("全局单例写入"));
        clear_logs(LogLevel::Message);
        assert!(get_logs(LogLevel::Message).is_empty());
    }

    #[test]
    fn test_format_timestamp_ms() {
        // 2024-08-05 00:00:00.000 UTC = 1722816000000
        assert_eq!(
            format_timestamp_ms(1_722_816_000_000),
            "2024-08-05 00:00:00.000"
        );
        // 1970-01-01 00:00:00.123 UTC
        assert_eq!(format_timestamp_ms(123), "1970-01-01 00:00:00.123");
        // 2026-02-28 23:59:59.999 UTC（非闰年 2 月最后一天，次日即 3-1）
        assert_eq!(
            format_timestamp_ms(1_772_323_199_999),
            "2026-02-28 23:59:59.999"
        );
        // 闰年 2024-02-29
        assert_eq!(
            format_timestamp_ms(1_709_164_800_000),
            "2024-02-29 00:00:00.000"
        );
    }

    #[test]
    fn test_truncate_chars_boundary() {
        let mut s = "中文".repeat(10); // 20 字符
        truncate_chars(&mut s, 5);
        assert!(s.chars().count() <= 5);
        // 不应在多字节字符中间截断（truncate 走 char_indices，天然安全）
        assert!(std::str::from_utf8(s.as_bytes()).is_ok());
    }
}
