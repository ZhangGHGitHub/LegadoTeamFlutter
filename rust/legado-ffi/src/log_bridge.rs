//! Rust `log` → Android logcat 桥（批34c）
//!
//! 背景：高亮匹配的降级路径（无效正则 / 单规则或整体超时）走 `log::warn!`，
//! 但工作区此前没有安装任何 `log` 实现——Android 上既不进 logcat 也不进
//! Flutter 日志，设备验收无法确认降级是否发生（批34 遗留「日志不可见」）。
//!
//! 复用 `legado-core::regex_safe` 的既有做法：Android 目标经 liblog 的
//! `__android_log_write`（tag=`legado-rust`）写入 logcat；其他平台走
//! `eprintln!`。默认只放行 `warn` 及以上（避免 info/debug 刷屏），可用环境
//! 变量 `LEGADO_LOG_LEVEL`（off/error/warn/info/debug/trace）调整。
//!
//! — full-stack-engineer + Bridge

use std::sync::Once;

use log::{LevelFilter, Metadata, Record};

static INIT: Once = Once::new();

/// 安装全局 `log` 实现（幂等）
///
/// 若宿主已自行安装 logger（`log::set_boxed_logger` 返回 Err），保持宿主
/// 实现不变，不覆盖其级别设置。
pub fn init() {
    INIT.call_once(|| {
        let filter = level_filter_from_env();
        if log::set_boxed_logger(Box::new(RustLogBridge)).is_ok() {
            log::set_max_level(filter);
        }
    });
}

/// 解析级别字符串（大小写不敏感；非法值按 warn）
fn parse_level_filter(raw: &str) -> LevelFilter {
    match raw.trim().to_ascii_lowercase().as_str() {
        "off" => LevelFilter::Off,
        "error" => LevelFilter::Error,
        "warn" | "warning" => LevelFilter::Warn,
        "info" => LevelFilter::Info,
        "debug" => LevelFilter::Debug,
        "trace" => LevelFilter::Trace,
        _ => LevelFilter::Warn,
    }
}

/// 从 `LEGADO_LOG_LEVEL` 读取级别；未设置时默认 warn
fn level_filter_from_env() -> LevelFilter {
    std::env::var("LEGADO_LOG_LEVEL")
        .map(|raw| parse_level_filter(&raw))
        .unwrap_or(LevelFilter::Warn)
}

struct RustLogBridge;

impl log::Log for RustLogBridge {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        // 带 target 便于定位降级来源（如 api::highlight_api）
        let line = format!("[{}] {}", record.target(), record.args());
        #[cfg(target_os = "android")]
        android_log(record.level(), &line);
        #[cfg(not(target_os = "android"))]
        eprintln!("[{}] {}", record.level(), line);
    }

    fn flush(&self) {}
}

#[cfg(target_os = "android")]
mod android {
    use std::ffi::{c_char, c_int, CString};

    const ANDROID_LOG_ERROR: c_int = 6;
    const ANDROID_LOG_WARN: c_int = 5;
    const ANDROID_LOG_INFO: c_int = 4;
    const ANDROID_LOG_DEBUG: c_int = 3;
    const ANDROID_LOG_VERBOSE: c_int = 2;

    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(prio: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }

    /// 写入 logcat；CString 不接受内嵌 NUL，替换为 '?' 后写入
    pub(super) fn write(prio: c_int, tag: &str, text: &str) {
        let text = text.replace('\0', "?");
        let Ok(text) = CString::new(text) else {
            return;
        };
        let Ok(tag) = CString::new(tag) else {
            return;
        };
        unsafe {
            __android_log_write(prio, tag.as_ptr(), text.as_ptr());
        }
    }

    pub(super) fn priority(level: log::Level) -> c_int {
        match level {
            log::Level::Error => ANDROID_LOG_ERROR,
            log::Level::Warn => ANDROID_LOG_WARN,
            log::Level::Info => ANDROID_LOG_INFO,
            log::Level::Debug => ANDROID_LOG_DEBUG,
            log::Level::Trace => ANDROID_LOG_VERBOSE,
        }
    }
}

#[cfg(target_os = "android")]
fn android_log(level: log::Level, line: &str) {
    android::write(android::priority(level), "legado-rust", line);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_level_filter() {
        assert_eq!(parse_level_filter("warn"), LevelFilter::Warn);
        assert_eq!(parse_level_filter("WARNING"), LevelFilter::Warn);
        assert_eq!(parse_level_filter(" info "), LevelFilter::Info);
        assert_eq!(parse_level_filter("Debug"), LevelFilter::Debug);
        assert_eq!(parse_level_filter("trace"), LevelFilter::Trace);
        assert_eq!(parse_level_filter("error"), LevelFilter::Error);
        assert_eq!(parse_level_filter("off"), LevelFilter::Off);
        // 非法值按 warn 兜底（不静默关闭日志）
        assert_eq!(parse_level_filter("verbose"), LevelFilter::Warn);
    }
}
