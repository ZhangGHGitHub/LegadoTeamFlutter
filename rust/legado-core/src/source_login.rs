//! 书源登录管理
//!
//! 管理书源的登录状态、Cookie、Token 等认证信息。
//! 供书源请求时附加认证头、判断登录有效性等场景使用。

use serde::{Deserialize, Serialize};

/// 登录信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceLoginInfo {
    pub source_url: String,
    pub login_url: String,
    pub cookies: Vec<LoginCookie>,
    pub headers: Vec<LoginHeader>,
    pub token: Option<String>,
    /// 登录时间（Unix 毫秒时间戳）
    pub logged_in_at: i64,
    /// 过期时间（Unix 毫秒时间戳），None 表示永不过期
    pub expires_at: Option<i64>,
}

/// 登录 Cookie
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
}

/// 登录附加请求头
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginHeader {
    pub name: String,
    pub value: String,
}

/// 登录状态
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoginStatus {
    NotLoggedIn,
    LoggedIn,
    Expired,
}

/// 登录管理器
pub struct SourceLoginManager;

impl SourceLoginManager {
    /// 检查登录状态
    pub fn check_status(info: &SourceLoginInfo) -> LoginStatus {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;

        if info.cookies.is_empty() && info.token.is_none() {
            LoginStatus::NotLoggedIn
        } else if let Some(expires) = info.expires_at {
            if now > expires {
                LoginStatus::Expired
            } else {
                LoginStatus::LoggedIn
            }
        } else {
            LoginStatus::LoggedIn
        }
    }

    /// 清除登录信息
    pub fn clear_login(info: &mut SourceLoginInfo) {
        info.cookies.clear();
        info.headers.clear();
        info.token = None;
    }

    /// 生成 Cookie 字符串（用于 HTTP 请求头）
    pub fn cookie_string(info: &SourceLoginInfo) -> String {
        info.cookies
            .iter()
            .map(|c| format!("{}={}", c.name, c.value))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_info() -> SourceLoginInfo {
        SourceLoginInfo {
            source_url: "https://example.com".to_string(),
            login_url: "https://example.com/login".to_string(),
            cookies: vec![LoginCookie {
                name: "session".to_string(),
                value: "abc123".to_string(),
                domain: "example.com".to_string(),
                path: "/".to_string(),
            }],
            headers: vec![LoginHeader {
                name: "Authorization".to_string(),
                value: "Bearer xyz".to_string(),
            }],
            token: Some("xyz".to_string()),
            logged_in_at: 0,
            expires_at: None,
        }
    }

    #[test]
    fn test_status_logged_in() {
        let info = sample_info();
        assert_eq!(
            SourceLoginManager::check_status(&info),
            LoginStatus::LoggedIn
        );
    }

    #[test]
    fn test_status_not_logged_in() {
        let mut info = sample_info();
        info.cookies.clear();
        info.token = None;
        assert_eq!(
            SourceLoginManager::check_status(&info),
            LoginStatus::NotLoggedIn
        );
    }

    #[test]
    fn test_status_expired() {
        let mut info = sample_info();
        // 设置一个已经过去很久的过期时间
        info.expires_at = Some(1);
        assert_eq!(
            SourceLoginManager::check_status(&info),
            LoginStatus::Expired
        );
    }

    #[test]
    fn test_status_not_expired_when_future() {
        let mut info = sample_info();
        // 远未来的过期时间
        info.expires_at = Some(i64::MAX);
        assert_eq!(
            SourceLoginManager::check_status(&info),
            LoginStatus::LoggedIn
        );
    }

    #[test]
    fn test_clear_login() {
        let mut info = sample_info();
        SourceLoginManager::clear_login(&mut info);
        assert!(info.cookies.is_empty());
        assert!(info.headers.is_empty());
        assert!(info.token.is_none());
        assert_eq!(
            SourceLoginManager::check_status(&info),
            LoginStatus::NotLoggedIn
        );
    }

    #[test]
    fn test_cookie_string() {
        let mut info = sample_info();
        info.cookies.push(LoginCookie {
            name: "uid".to_string(),
            value: "42".to_string(),
            domain: "example.com".to_string(),
            path: "/".to_string(),
        });
        let s = SourceLoginManager::cookie_string(&info);
        assert_eq!(s, "session=abc123; uid=42");
    }

    #[test]
    fn test_cookie_string_empty() {
        let mut info = sample_info();
        info.cookies.clear();
        assert_eq!(SourceLoginManager::cookie_string(&info), "");
    }

    #[test]
    fn test_login_info_serde_roundtrip() {
        let info = sample_info();
        let json = serde_json::to_string(&info).unwrap();
        let de: SourceLoginInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de.source_url, info.source_url);
        assert_eq!(de.cookies.len(), 1);
        assert_eq!(de.token, Some("xyz".to_string()));
    }
}
