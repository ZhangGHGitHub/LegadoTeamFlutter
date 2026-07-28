//! 平台专属 API 桩
//!
//! 这些 API 在 Kotlin 侧依赖 Android 平台（WebView、Toast、Intent 等），
//! 在 Rust 运行时（无头模式）中无法实现。统一返回明确的错误提示字符串。
//!
//! # WebView API 说明
//!
//! 以下 6 个 WebView 相关 API 仅在 Flutter/Android 侧实现：
//! - `web_view` — 加载 URL 并返回渲染后的 HTML
//! - `web_view_get_source` — 获取 WebView 当前页面源码
//! - `web_view_get_override_url` — 获取 WebView 拦截的 URL
//! - `get_verification_code` — 人机验证（需 WebView + 用户交互）
//! - `get_web_view_ua` — 获取 WebView 默认 User-Agent
//! - `start_browser` — 启动外部浏览器
//!
//! Rust 运行时（无头模式）不支持 WebView 操作，
//! 书源中使用此 API 将返回错误提示。

const NOT_SUPPORTED: &str = "[ERROR] This API is not supported in Rust runtime";

/// WebView API — 仅在 Flutter 侧实现
///
/// 加载指定 URL 并返回渲染后的 HTML 内容。
/// Rust 运行时（无头模式）不支持 WebView 操作，
/// 书源中使用此 API 将返回错误提示。
pub fn web_view(url: &str) -> String {
    format!(
        "[ERROR] webView not supported in Rust runtime. URL: {}",
        url
    )
}

/// WebView API — 仅在 Flutter 侧实现
///
/// 获取 WebView 当前加载页面的 HTML 源码。
/// Rust 运行时（无头模式）不支持 WebView 操作，
/// 书源中使用此 API 将返回错误提示。
pub fn web_view_get_source(url: &str) -> String {
    format!(
        "[ERROR] webViewGetSource not supported in Rust runtime. URL: {}",
        url
    )
}

/// WebView API — 仅在 Flutter 侧实现
///
/// 获取 WebView 中 shouldOverrideUrlLoading 拦截的 URL。
/// Rust 运行时（无头模式）不支持 WebView 操作，
/// 书源中使用此 API 将返回错误提示。
pub fn web_view_get_override_url() -> String {
    NOT_SUPPORTED.to_string()
}

/// 启动外部浏览器 — 需要 Android Intent / Flutter url_launcher
///
/// Rust 运行时（无头模式）不支持此操作，
/// 书源中使用此 API 将返回错误提示。
pub fn start_browser(url: &str) -> String {
    format!(
        "[ERROR] startBrowser not supported in Rust runtime. URL: {}",
        url
    )
}

/// 打开 URL — 需要 Android Intent / Flutter url_launcher
///
/// Rust 运行时（无头模式）不支持此操作，
/// 书源中使用此 API 将返回错误提示。
pub fn open_url(url: &str) -> String {
    format!(
        "[ERROR] openUrl not supported in Rust runtime. URL: {}",
        url
    )
}

/// Toast 提示 — 需要 Android Toast / Flutter SnackBar
///
/// Rust 运行时降级为 stderr 输出。
pub fn toast(msg: &str) -> String {
    // 在 Rust 运行时输出到 stderr 作为替代
    eprintln!("[Toast] {}", msg);
    String::new()
}

/// WebView API — 仅在 Flutter 侧实现
///
/// 显示人机验证页面（验证码/滑块等），需要 WebView + 用户交互。
/// Rust 运行时（无头模式）不支持 WebView 操作，
/// 书源中使用此 API 将返回错误提示。
pub fn get_verification_code(url: &str) -> String {
    format!(
        "[ERROR] getVerificationCode not supported in Rust runtime. URL: {}",
        url
    )
}

/// 获取 Android ID — 需要 Android Context
///
/// Rust 运行时（无头模式）不支持此操作。
pub fn android_id() -> String {
    NOT_SUPPORTED.to_string()
}

/// WebView API — 仅在 Flutter 侧实现
///
/// 获取 WebView 默认的 User-Agent 字符串。
/// Rust 运行时（无头模式）不支持 WebView 操作，
/// 书源中使用此 API 将返回错误提示。
pub fn get_web_view_ua() -> String {
    NOT_SUPPORTED.to_string()
}

/// 打开视频播放器 — 需要 Android Intent / Flutter 平台通道
///
/// Rust 运行时（无头模式）不支持此操作。
pub fn open_video_player(url: &str) -> String {
    format!("[ERROR] openVideoPlayer not supported. URL: {}", url)
}

/// 获取阅读配置 — 需要 Android SharedPreferences
///
/// Rust 运行时返回空 JSON 作为降级。
pub fn get_read_book_config() -> String {
    "{}".to_string() // 返回空 JSON 作为降级
}

/// 获取主题模式
///
/// Rust 运行时默认返回浅色主题。
pub fn get_theme_mode() -> String {
    "light".to_string() // 默认浅色主题
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_platform_stubs_return_error() {
        assert!(web_view("http://test.com").contains("[ERROR]"));
        assert!(start_browser("http://test.com").contains("[ERROR]"));
        assert!(get_verification_code("http://test.com").contains("[ERROR]"));
    }

    #[test]
    fn test_degraded_defaults() {
        assert_eq!(get_read_book_config(), "{}");
        assert_eq!(get_theme_mode(), "light");
    }
}
