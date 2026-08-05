//! 平台专属 API
//!
//! 这些 API 在 Kotlin 侧依赖 Android 平台（WebView、Toast、Intent 等），
//! 在 Rust 运行时（无头模式）中无法直接实现。
//!
//! # 实现策略
//!
//! 需要平台能力的 API 分两类：
//!
//! 1. **一次性平台动作**（webView / openUrl 等）：返回结构化 JSON 桥接载荷，
//!    由 Flutter / 平台侧拦截并真正执行（与 `openVideoPlayer` 相同模式）：
//!    - `webView` → `{"action":"webView","html":...,"url":...,"js":...}`
//!    - `webViewGetSource` → `{"action":"webViewGetSource",...,"sourceRegex":...}`
//!    - `webViewGetOverrideUrl` → `{"action":"webViewGetOverrideUrl",...,"overrideUrlRegex":...}`
//!    - `startBrowser` → `{"action":"startBrowser","url":...,"title":...}`
//!    - `showBrowser` → `{"action":"openBrowser","url":...,"html":...}`
//!    - `openUrl` → `{"action":"openUrl","url":...,"mimeType":...}`
//!
//! 2. **需要挂起等待用户交互的 API**（验证码）：接入全局验证码交互通道
//!    （`legado_core::verification_channel`，Task #90）：JS 侧阻塞挂起 →
//!    FFI 事件流推送请求 → UI 弹验证码对话框 → 用户输入回传唤醒。
//!    对齐 Kotlin `SourceVerificationHelp.getVerificationResult` 语义。

use legado_core::verification_channel;

use super::current_source;

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

/// WebView API — 获取 WebView 拦截的跳转 URL → 结构化桥接载荷
///
/// 对应 Kotlin: `webViewGetOverrideUrl(html, url, js, overrideUrlRegex,
/// cacheFirst, delayTime): String?`（内部用 BackstageWebView 拦截跳转 URL）。
///
/// Rust 无头运行时无法执行真实 WebView，因此返回桥接载荷，
/// 由 Flutter 侧使用真实 WebView 处理后回填结果（与 webView / webViewGetSource 同模式）。
///
/// 返回 JSON：
/// ```json
/// {"action":"webViewGetOverrideUrl","html":"...","url":"...","js":"...",
///  "overrideUrlRegex":"...","cacheFirst":false,"delayTime":0}
/// ```
pub fn web_view_get_override_url(
    html: &str,
    url: &str,
    js: &str,
    override_url_regex: &str,
    cache_first: bool,
    delay_time: i64,
) -> String {
    serde_json::json!({
        "action": "webViewGetOverrideUrl",
        "html": html,
        "url": url,
        "js": js,
        "overrideUrlRegex": override_url_regex,
        "cacheFirst": cache_first,
        "delayTime": delay_time,
    })
    .to_string()
}

/// showBrowser(url, html?, preloadJs?, config?) → 结构化桥接载荷
///
/// 对应 Kotlin: `showBrowser(url, html, preloadJs, config)`（弹出应用内 WebView 对话框）。
/// Rust 无头运行时返回桥接载荷，由 Flutter 侧拦截并打开浏览器/WebView 页面。
///
/// 返回 JSON：
/// ```json
/// {"action":"openBrowser","url":"...","html":"...","preloadJs":"...","config":"..."}
/// ```
pub fn show_browser(url: &str, html: &str, preload_js: &str, config: &str) -> String {
    serde_json::json!({
        "action": "openBrowser",
        "url": url,
        "html": html,
        "preloadJs": preload_js,
        "config": config,
    })
    .to_string()
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

/// getVerificationCode(imageUrl) — 图片验证码交互（阻塞等待用户输入）
///
/// 对应 Kotlin: `getVerificationCode(imageUrl: String): String`
/// （内部 `SourceVerificationHelp.getVerificationResult(source, imageUrl, "", false)`）
///
/// 阻塞当前 JS 工作线程（默认超时 5 分钟，对齐 Kotlin），
/// 经全局验证码通道挂起等待 UI 侧提交结果：
/// - 用户提交非空验证码 → 返回验证码字符串
/// - 取消 / 空结果 / 超时 → 返回 `[ERROR] ...`（对齐 Kotlin 抛错后的规则失败表现）
///
/// 书源标识取自当前线程上下文（[`current_source`]，对齐 Kotlin `getSource()`）。
pub fn get_verification_code(image_url: &str) -> String {
    let source_url = current_source::current_source_tag().unwrap_or_default();
    match verification_channel::request_verification_code(
        &source_url,
        "",
        image_url,
        "",
        false,
    ) {
        Ok(code) => code,
        Err(e) => format!("[ERROR] {e}"),
    }
}

/// startBrowserAwait(url, title) — 浏览器验证降级实现
///
/// 对应 Kotlin: `startBrowserAwait(url, title, refetchAfterSuccess, html)`
/// （内部 `getVerificationResult(source, url, title, useBrowser = true)`）
///
/// 桌面端无内置浏览器，useBrowser 模式一律降级为图片验证码流程：
/// 把传入 url 作为验证资源地址经验证码通道挂起等待用户输入，
/// 返回验证码字符串（或 `[ERROR] ...`）。
pub fn start_browser_await(url: &str, title: &str) -> String {
    let source_url = current_source::current_source_tag().unwrap_or_default();
    match verification_channel::request_verification_code(
        &source_url,
        "",
        url,
        title,
        false,
    ) {
        Ok(code) => code,
        Err(e) => format!("[ERROR] {e}"),
    }
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
    fn test_web_view_get_override_url_bridge_payload() {
        let payload =
            web_view_get_override_url("", "http://test.com", "", "legado://.*", true, 500);
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "webViewGetOverrideUrl");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["overrideUrlRegex"], "legado://.*");
        assert_eq!(parsed["cacheFirst"], true);
        assert_eq!(parsed["delayTime"], 500);
    }

    #[test]
    fn test_show_browser_bridge_payload() {
        let payload = show_browser("http://test.com", "<html/>", "console.log(1)", "");
        let parsed: serde_json::Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(parsed["action"], "openBrowser");
        assert_eq!(parsed["url"], "http://test.com");
        assert_eq!(parsed["html"], "<html/>");
        assert_eq!(parsed["preloadJs"], "console.log(1)");
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
    fn test_get_verification_code_blocks_until_submit() {
        use std::time::{Duration, Instant};

        let image_url = "http://img.com/captcha-platform-test.png";
        // UI 侧：订阅验证码请求事件
        let rx = verification_channel::verification_manager().subscribe();

        // JS 侧：后台线程阻塞等待（模拟 JS 工作线程）
        let url = image_url.to_string();
        let worker = std::thread::spawn(move || get_verification_code(&url));

        // 定位本次请求事件（全局通道可能存在其他测试的请求，按 imageUrl 过滤）
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == image_url => {
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到验证码请求事件");
        assert!(verification_channel::submit_verification_result(&key, "8888"));
        assert_eq!(worker.join().unwrap(), "8888");
    }

    #[test]
    fn test_start_browser_await_degrades_to_image_channel() {
        use std::time::{Duration, Instant};

        let url = "http://verify.example.com/browser-degrade-test";
        let rx = verification_channel::verification_manager().subscribe();

        let u = url.to_string();
        let worker = std::thread::spawn(move || start_browser_await(&u, "人机验证"));

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut key = None;
        while Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(req) if req.image_url == url => {
                    assert_eq!(req.title, "人机验证");
                    assert!(!req.use_browser, "浏览器模式应降级为图片验证码");
                    key = Some(req.key);
                    break;
                }
                Ok(_) => continue,
                Err(_) => continue,
            }
        }
        let key = key.expect("应收到降级验证请求事件");
        assert!(verification_channel::submit_verification_result(&key, "ok-code"));
        assert_eq!(worker.join().unwrap(), "ok-code");
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
