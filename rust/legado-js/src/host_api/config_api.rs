//! 配置读取 API
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 getReadBookConfig / getThemeConfig / getThemeMode /
//! getWebViewUA / androidId 等配置相关方法。
//! 在 Rust 侧返回合理的默认值。

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
pub fn get_theme_config() -> String {
    serde_json::json!({
        "themeName": "默认",
        "isNightTheme": false,
        "primaryColor": "#FF4CAF50",
        "accentColor": "#FFFF5722",
        "backgroundColor": "#FFFFFFFF",
        "bottomBackground": "#FFF5F5F5",
        "statusBarColor": "#FF4CAF50",
        "navigationBarColor": "#FFFFFFFF"
    })
    .to_string()
}

/// 获取主题模式
///
/// 对应 Kotlin: `getThemeMode()` -> AppConfig.themeMode ?: "0"
/// 返回 "light" / "dark" / "auto"
pub fn get_theme_mode() -> String {
    "light".to_string()
}

/// 获取 WebView User-Agent
///
/// 对应 Kotlin: `getWebViewUA()` -> WebSettings.getDefaultUserAgent(appCtx)
pub fn get_web_view_ua() -> String {
    "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.6422.165 Mobile Safari/537.36".to_string()
}

/// 获取 Android ID（设备标识）
///
/// 对应 Kotlin: `androidId()` -> AppConst.androidId
/// 在 Rust 侧返回一个基于随机 UUID 的稳定 ID
pub fn get_android_id() -> String {
    use std::sync::OnceLock;
    static DEVICE_ID: OnceLock<String> = OnceLock::new();
    DEVICE_ID
        .get_or_init(|| {
            // 生成一个稳定的伪设备 ID
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
    }

    #[test]
    fn test_get_theme_mode() {
        assert_eq!(get_theme_mode(), "light");
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
