//! 配置读取 API
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 getReadBookConfig / getThemeConfig / getThemeMode /
//! getWebViewUA / androidId 等配置相关方法。
//! 在 Rust 侧返回合理的默认值。
//!
//! UI_MD3_ALIGNMENT_PLAN.md Batch 0（R1/R2）：主题透传进程级注入
//! （同 `device_id` 模式）：Flutter 侧 `RustApi.init` 经 FFI 注入当前
//! 调色板主题色 + 主题模式，JS 书源 `getThemeConfig/getThemeMode`
//! 即可感知界面实际主题；未注入时回退 MD3 wh 调色板默认值。

/// 获取阅读配置（返回默认 JSON）
///
/// 对应 Kotlin: `getReadBookConfig()` -> GSON.toJson(ReadBookConfig.durConfig)
pub fn get_read_book_config() -> String {
    serde_json::json!({
        "name": "默认",
        "bgStr": "#FFFFFF",
        "bgType": 0,
        "textColor": "#333333",
        "textSize": 18,
        "lineSpacingExtra": 8,
        "paragraphSpacing": 4,
        "paddingTop": 16,
        "paddingBottom": 16,
        "paddingLeft": 16,
        "paddingRight": 16,
        "headerPaddingTop": 8,
        "footerPaddingBottom": 8,
        "letterSpacing": 0.0,
        "textBold": 0,
        "font": "",
        "darkStatusIcon": true,
        "tipHeaderLeft": "title",
        "tipHeaderMiddle": "",
        "tipHeaderRight": "battery",
        "tipFooterLeft": "chapterTitle",
        "tipFooterMiddle": "",
        "tipFooterRight": "page",
        "tipColor": "#99999900"
    })
    .to_string()
}

/// 获取主题配置（返回默认 JSON）
///
/// 对应 Kotlin: `getThemeConfig()` -> GSON.toJson(ThemeConfig.getDurConfig(appCtx))
/// R1（UI_MD3_ALIGNMENT_PLAN.md Batch 0）：默认值对齐 MD3 wh 调色板亮色
///（primary #FF5C5C5C / background #FFF8F8F8，见 md3_colors.dart wh.light）；
/// Flutter 注入后优先返回注入值（见 `set_injected_theme_config`）。
pub fn get_theme_config() -> String {
    if let Some(injected) = injected_theme_config() {
        return injected;
    }
    serde_json::json!({
        "themeName": "默认",
        "isNightTheme": false,
        "primaryColor": "#FF5C5C5C",
        "accentColor": "#FF5F5E5E",
        "backgroundColor": "#FFF8F8F8",
        "bottomBackground": "#FFF1EDEC",
        "statusBarColor": "#FF5C5C5C",
        "navigationBarColor": "#FFF8F8F8"
    })
    .to_string()
}

/// 获取主题模式
///
/// 对应 Kotlin: `getThemeMode()` -> AppConfig.themeMode ?: "0"
/// R2（UI_MD3_ALIGNMENT_PLAN.md Batch 0）：Flutter 侧 `setThemeMode` 时经
/// `set_injected_theme_mode` 注入（"0"=跟随系统 / "1"=亮色 / "2"=暗色，
/// 对齐 Kotlin themeMode "0/1/2"）；未注入回退 "light"。
/// 返回 "light" / "dark" / "auto"
pub fn get_theme_mode() -> String {
    match injected_theme_mode().as_deref() {
        Some("1") => "light".to_string(),
        Some("2") => "dark".to_string(),
        Some("0") | None => "light".to_string(),
        Some(other) => other.to_string(),
    }
}

/// 注入主题配置 JSON（Flutter 启动/切换调色板时经 FFI 调用）
///
/// 入参为 `get_theme_config` 同形 JSON 字符串；空串不覆盖。
pub fn set_injected_theme_config(json: &str) {
    let json = json.trim().to_string();
    if json.is_empty() {
        return;
    }
    *theme_config_store().write().unwrap_or_else(|p| p.into_inner()) = Some(json);
}

/// 注入主题模式（Flutter `setThemeMode` 时经 FFI 调用）
///
/// 取值对齐 Kotlin themeMode："0"=跟随系统 / "1"=亮色 / "2"=暗色。
pub fn set_injected_theme_mode(mode: &str) {
    let mode = mode.trim().to_string();
    if mode.is_empty() {
        return;
    }
    *theme_mode_store().write().unwrap_or_else(|p| p.into_inner()) = Some(mode);
}

/// 读取已注入的主题配置 JSON（无注入时返回空）
fn injected_theme_config() -> Option<String> {
    theme_config_store()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

/// 读取已注入的主题模式（无注入时返回空）
fn injected_theme_mode() -> Option<String> {
    theme_mode_store()
        .read()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

fn theme_config_store() -> &'static std::sync::RwLock<Option<String>> {
    static STORE: std::sync::OnceLock<std::sync::RwLock<Option<String>>> =
        std::sync::OnceLock::new();
    STORE.get_or_init(|| std::sync::RwLock::new(None))
}

fn theme_mode_store() -> &'static std::sync::RwLock<Option<String>> {
    static STORE: std::sync::OnceLock<std::sync::RwLock<Option<String>>> =
        std::sync::OnceLock::new();
    STORE.get_or_init(|| std::sync::RwLock::new(None))
}

/// 获取 WebView User-Agent
///
/// 对应 Kotlin: `getWebViewUA()` -> WebSettings.getDefaultUserAgent(appCtx)
pub fn get_web_view_ua() -> String {
    "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.165 Mobile Safari/537.36".to_string()
}

/// 获取 Android ID（设备标识）
///
/// 对应 Kotlin: `androidId()` -> AppConst.androidId（Settings.Secure.ANDROID_ID）
/// 优先用 Flutter 侧注入的真实设备 ID（书山聚合等源登录时登记该设备、
/// 正文请求需携带匹配的 X-Device-Id 才返回明文）；未注入时回退伪随机 ID。
/// — 书山正文修复
pub fn get_android_id() -> String {
    // 优先使用 Flutter 注入的真实设备 ID（每次读取，避免 OnceLock 缓存
    // 导致注入前首次调用（探针/其他测试）固化伪 ID 后注入失效）
    if let Some(v) = crate::host_api::device_id::device_id() {
        return v;
    }
    // 生成一个稳定的伪设备 ID
    use std::sync::OnceLock;
    static FALLBACK_ID: OnceLock<String> = OnceLock::new();
    FALLBACK_ID
        .get_or_init(|| {
            format!(
                "{:016x}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            )
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_read_book_config_is_valid_json() {
        let config = get_read_book_config();
        let parsed: serde_json::Value = serde_json::from_str(&config).unwrap();
        assert_eq!(parsed["textSize"], 18);
        assert!(parsed["name"].is_string());
    }

    #[test]
    fn test_get_theme_config_is_valid_json() {
        let config = get_theme_config();
        let parsed: serde_json::Value = serde_json::from_str(&config).unwrap();
        assert_eq!(parsed["isNightTheme"], false);
        // R1：默认值对齐 MD3 wh 调色板亮色（见 md3_colors.dart wh.light）
        assert_eq!(parsed["primaryColor"], "#FF5C5C5C");
        assert_eq!(parsed["backgroundColor"], "#FFF8F8F8");
    }

    #[test]
    fn test_get_theme_mode() {
        assert_eq!(get_theme_mode(), "light");
    }

    #[test]
    fn test_injected_theme_mode_mapping() {
        set_injected_theme_mode("2");
        assert_eq!(get_theme_mode(), "dark");
        set_injected_theme_mode("1");
        assert_eq!(get_theme_mode(), "light");
        set_injected_theme_mode("0");
        assert_eq!(get_theme_mode(), "light");
    }

    #[test]
    fn test_injected_theme_config_passthrough() {
        let custom = r#"{"themeName":"自定义","isNightTheme":true}"#;
        set_injected_theme_config(custom);
        assert_eq!(get_theme_config(), custom);
    }

    #[test]
    fn test_get_web_view_ua() {
        let ua = get_web_view_ua();
        assert!(ua.contains("Mozilla/5.0"));
        assert!(ua.contains("Android"));
    }

    #[test]
    fn test_get_android_id_stable() {
        let id1 = get_android_id();
        let id2 = get_android_id();
        assert_eq!(id1, id2);
        assert!(!id1.is_empty());
    }
}
