//! 平台专属 API
//!
//! 这些 API 在 Kotlin 侧依赖 Android 平台（WebView、Toast、Intent 等），
//! 在 Rust 运行时（无头模式）中无法直接实现。
//!
//! # 实现策略
//!
//! 需要平台能力的 API 统一返回**结构化 JSON 桥接载荷**，
//! 由 Flutter / 平台侧拦截并真正执行（与 `openVideoPlayer` 相同模式）：
//! - `webView` → `{"action":"webView","html":...,"url":...,"js":...}`
//! - `webViewGetSource` → `{"action":"webViewGetSource",...,"sourceRegex":...}`
//! - `startBrowser` → `{"action":"startBrowser","url":...,"title":...}`
//! - `openUrl` → `{"action":"openUrl","url":...,"mimeType":...}`
//! - `getVerificationCode` → `{"action":"getVerificationCode","imageUrl":...}`
//!
//! 这样书源 JS 调用不再得到纯错误字符串，而是可被上层消费的结构化请求。

const NOT_SUPPORTED: &str = "[ERROR] This API is not supported in Rust runtime";

/// webView(html, url, js) → 结构化桥接载荷
///
/// 对应 Kotlin: `webView(html: String?, url: String?, js: String?): String?`
///
/// 加载指定 URL 并执行 JS，返回渲染/执行结果。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧使用真实 WebView 处理。
///
/// 返回 JSON：
/// ```json
/// {"action":"webView","html":"...","url":"...","js":"..."}
/// ```
pub fn web_view(html: &str, url: &str, js: &str) -> String {
    serde_json::json!({
        "action": "webView",
        "html": html,
        "url": url,
        "js": js,
    })
    .to_string()
}

/// webViewGetSource(html, url, js, sourceRegex) → 结构化桥接载荷
///
/// 对应 Kotlin: `webViewGetSource(html, url, js, sourceRegex): String?`
///
/// 获取 WebView 页面源码（匹配 sourceRegex 的内容）。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧处理。
///
/// 返回 JSON：
/// ```json
/// {"action":"webViewGetSource","html":"...","url":"...","js":"...","sourceRegex":"..."}
/// ```
pub fn web_view_get_source(html: &str, url: &str, js: &str, source_regex: &str) -> String {
    serde_json::json!({
        "action": "webViewGetSource",
        "html": html,
        "url": url,
        "js": js,
        "sourceRegex": source_regex,
    })
    .to_string()
}

/// WebView API — 获取 WebView 拦截的跳转 URL
///
/// 对应 Kotlin: `webViewGetOverrideUrl(html, url, js, overrideUrlRegex): String?`
/// Rust 无头运行时不支持此操作，返回错误提示。
pub fn web_view_get_override_url() -> String {
    NOT_SUPPORTED.to_string()
}

/// startBrowser(url, title, html?) → 结构化桥接载荷
///
/// 对应 Kotlin: `startBrowser(url: String, title: String, html: String?)`
///
/// 启动外部浏览器（或应用内浏览器页面）。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧通过平台通道真正启动。
///
/// 返回 JSON：
/// ```json
/// {"action":"startBrowser","url":"...","title":"...","html":"..."}
/// ```
pub fn start_browser(url: &str, title: &str, html: &str) -> String {
    serde_json::json!({
        "action": "startBrowser",
        "url": url,
        "title": title,
        "html": html,
    })
    .to_string()
}

/// openUrl(url, mimeType?) → 结构化桥接载荷
///
/// 对应 Kotlin: `openUrl(url: String, mimeType: String? = null)`
///
/// 打开 URL（支持 legado:// / yuedu:// 协议及 http/https）。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧处理。
///
/// 返回 JSON：
/// ```json
/// {"action":"openUrl","url":"...","mimeType":"..."}
/// ```
pub fn open_url(url: &str, mime_type: &str) -> String {
    serde_json::json!({
        "action": "openUrl",
        "url": url,
        "mimeType": mime_type,
    })
    .to_string()
}

/// Toast 提示 — 需要 Android Toast / Flutter SnackBar
///
/// Rust 运行时降级为 stderr 输出。
pub fn toast(msg: &str) -> String {
    // 在 Rust 运行时输出到 stderr 作为替代
    eprintln!("[Toast] {}", msg);
    String::new()
}

/// getVerificationCode(imageUrl) → 结构化桥接载荷
///
/// 对应 Kotlin: `getVerificationCode(imageUrl: String): String`
///
/// 显示人机验证页面（验证码/滑块等），需要 WebView + 用户交互。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧弹出验证对话框。
///
/// 返回 JSON：
/// ```json
/// {"action":"getVerificationCode","imageUrl":"..."}
/// ```
pub fn get_verification_code(image_url: &str) -> String {
    serde_json::json!({
        "action": "getVerificationCode",
        "imageUrl": image_url,
    })
    .to_string()
}

/// 获取 Android ID — 需要 Android Context
///
/// Rust 运行时（无头模式）不支持此操作。
pub fn android_id() -> String {
    NOT_SUPPORTED.to_string()
}

/// WebView API — 获取 WebView 默认 User-Agent
///
/// Rust 运行时（无头模式）不支持此操作。
pub fn get_web_view_ua() -> String {
    NOT_SUPPORTED.to_string()
}

/// 打开视频播放器 — 需要 Android Intent / Flutter 平台通道
///
/// 对齐 Kotlin `JsExtensions.openVideoPlayer(url, title, isFloat)` →
/// `SourceHelp.openVideoPlayer(source, url, title, isFloat)`。
///
/// Rust 无头运行时无法直接拉起播放器，因此返回一个结构化 JSON 桥接载荷，
/// 由 Flutter / 平台侧拦截并真正打开内置视频播放器（或悬浮窗）。
///
/// 返回 JSON：
/// ```json
/// {"action":"openVideoPlayer","url":"...","title":"...","isFloat":false}
/// ```
pub fn open_video_player(url: &str, title: &str, is_float: bool) -> String {
    serde_json::json!({
        "action": "openVideoPlayer",
        "url": url,
        "title": title,
        "isFloat": is_float,
    })
    .to_string()
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
    fn test_web_view_bridge_payload() {
        let payload = web_view("", "http://test.com", "document.title");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "webView");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["js"], "document.title");
    }

    #[test]
    fn test_web_view_get_source_bridge_payload() {
        let payload = web_view_get_source("", "http://test.com", "", "content");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "webViewGetSource");
        assert_eq!(parsed["sourceRegex"], "content");
    }

    #[test]
    fn test_start_browser_bridge_payload() {
        let payload = start_browser("http://test.com", "标题", "");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "startBrowser");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["title"], "标题");
    }

    #[test]
    fn test_open_url_bridge_payload() {
        let payload = open_url("legado://import", "");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "openUrl");
        assert_eq!(parsed["url"], "legado://import");
    }

    #[test]
    fn test_get_verification_code_bridge_payload() {
        let payload = get_verification_code("http://img.com/captcha.png");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "getVerificationCode");
        assert_eq!(parsed["imageUrl"], "http://img.com/captcha.png");
    }

    #[test]
    fn test_degraded_defaults() {
        assert_eq!(get_read_book_config(), "{}");
        assert_eq!(get_theme_mode(), "light");
    }

    #[test]
    fn test_open_video_player_bridge_payload() {
        let payload = open_video_player("http://v.com/x.mp4", "第1集", false);
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "openVideoPlayer");
        assert_eq!(parsed["url"], "http://v.com/x.mp4");
        assert_eq!(parsed["title"], "第1集");
        assert_eq!(parsed["isFloat"], false);
    }

    #[test]
    fn test_open_video_player_float_flag() {
        let payload = open_video_player("http://v.com/y.m3u8", "", true);
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["isFloat"], true);
    }
}
