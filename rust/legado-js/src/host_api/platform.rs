//! 平台专属 API 桩
//!
//! 这些 API 在 Kotlin 侧依赖 Android 平台（WebView、Toast、Intent 等），
//! 在 Rust 运行时中无法实现。统一返回明确的错误提示字符串。

const NOT_SUPPORTED: &str = "[ERROR] This API is not supported in Rust runtime";

/// webView — 需要 Android WebView
pub fn web_view(url: &str) -> String {
    format!(
        "[ERROR] webView not supported in Rust runtime. URL: {}",
        url
    )
}

/// webViewGetSource — 需要 Android WebView
pub fn web_view_get_source(url: &str) -> String {
    format!(
        "[ERROR] webViewGetSource not supported in Rust runtime. URL: {}",
        url
    )
}

/// webViewGetOverrideUrl
pub fn web_view_get_override_url() -> String {
    NOT_SUPPORTED.to_string()
}

/// startBrowser — 需要 Android Intent
pub fn start_browser(url: &str) -> String {
    format!(
        "[ERROR] startBrowser not supported in Rust runtime. URL: {}",
        url
    )
}

/// openUrl — 需要 Android Intent
pub fn open_url(url: &str) -> String {
    format!(
        "[ERROR] openUrl not supported in Rust runtime. URL: {}",
        url
    )
}

/// toast — 需要 Android Toast
pub fn toast(msg: &str) -> String {
    // 在 Rust 运行时输出到 stderr 作为替代
    eprintln!("[Toast] {}", msg);
    String::new()
}

/// getVerificationCode — 需要 Android WebView + 人机交互
pub fn get_verification_code(url: &str) -> String {
    format!(
        "[ERROR] getVerificationCode not supported in Rust runtime. URL: {}",
        url
    )
}

/// androidId — 需要 Android Context
pub fn android_id() -> String {
    NOT_SUPPORTED.to_string()
}

/// getWebViewUA — 需要 Android WebView
pub fn get_web_view_ua() -> String {
    NOT_SUPPORTED.to_string()
}

/// openVideoPlayer — 需要 Android Intent
pub fn open_video_player(url: &str) -> String {
    format!("[ERROR] openVideoPlayer not supported. URL: {}", url)
}

/// getReadBookConfig — 需要 Android SharedPreferences
pub fn get_read_book_config() -> String {
    "{}".to_string() // 返回空 JSON 作为降级
}

/// getThemeMode
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
